package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
)

type transport struct {
	hosts   map[string]bool
	sshCmd  []string
	rewrite rewritePolicy
	logf    func(format string, args ...any)
}

type rewritePolicy struct {
	branches []string
	emails   map[string]bool
}

func newRewritePolicy(branches, emails []string) (rewritePolicy, error) {
	p := rewritePolicy{emails: map[string]bool{}}
	for _, b := range branches {
		if _, err := path.Match(b, ""); err != nil || b == "" {
			return p, fmt.Errorf("bad rewritable branch pattern %q", b)
		}
		p.branches = append(p.branches, b)
	}
	for _, e := range emails {
		if e = strings.ToLower(strings.TrimSpace(e)); e != "" {
			p.emails[e] = true
		}
	}
	return p, nil
}

func (p rewritePolicy) rewritable(ref string) bool {
	name, ok := strings.CutPrefix(ref, "refs/heads/")
	if !ok || len(p.emails) == 0 {
		return false
	}
	for _, b := range p.branches {
		if m, _ := path.Match(b, name); m {
			return true
		}
	}
	return false
}

func (p rewritePolicy) describe() string {
	if len(p.branches) == 0 || len(p.emails) == 0 {
		return "no branch"
	}
	return strings.Join(p.branches, ", ")
}

var (
	commandRe      = regexp.MustCompile(`^(git-upload-pack|git-receive-pack|git-upload-archive) '([^']*)'$`)
	lfsAuthRe      = regexp.MustCompile(`^git-lfs-authenticate '?([^' ]*)'? (download|upload)$`)
	repoPathRe     = regexp.MustCompile(`^/?[A-Za-z0-9_.~-]+(/[A-Za-z0-9_.-]+)+$`)
	gitProtocolRe  = regexp.MustCompile(`^[A-Za-z0-9=:._-]*$`)
	errNotFastFwd  = errors.New("not a fast-forward")
	allowedPorts   = map[int]bool{0: true, 22: true, 443: true}
	zeroOIDPattern = regexp.MustCompile(`^0+$`)
)

func (t *transport) validate(req request) (verb, path string, err error) {
	if req.User != "" && req.User != "git" {
		return "", "", fmt.Errorf("user %q: only git@ remotes are brokered", req.User)
	}
	if !t.hosts[strings.ToLower(req.Host)] {
		return "", "", fmt.Errorf("host %q is not allowed (allowed: %s)", req.Host, strings.Join(t.hostList(), ", "))
	}
	if !allowedPorts[req.Port] {
		return "", "", fmt.Errorf("port %d is not allowed", req.Port)
	}
	if m := commandRe.FindStringSubmatch(req.Command); m != nil {
		verb, path = m[1], m[2]
	} else if m := lfsAuthRe.FindStringSubmatch(req.Command); m != nil {
		verb, path = lfsAuthVerb+m[2], m[1]
	} else {
		return "", "", fmt.Errorf("command %q: only git-upload-pack, git-receive-pack, git-upload-archive and git-lfs-authenticate are brokered", req.Command)
	}
	if !repoPathRe.MatchString(path) {
		return "", "", fmt.Errorf("repository path %q is not allowed", path)
	}
	for _, c := range strings.Split(path, "/") {
		if c == ".." || c == "." {
			return "", "", fmt.Errorf("repository path %q is not allowed", path)
		}
	}
	if !gitProtocolRe.MatchString(req.GitProtocol) {
		return "", "", fmt.Errorf("bad GIT_PROTOCOL %q", req.GitProtocol)
	}
	return verb, path, nil
}

func (t *transport) hostList() []string {
	var hs []string
	for h := range t.hosts {
		hs = append(hs, h)
	}
	sort.Strings(hs)
	return hs
}

func (t *transport) sshArgs(req request, verb, path string) []string {
	args := append([]string{}, t.sshCmd...)
	args = append(args, "-x", "-T", "-a", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes")
	if req.Port != 0 {
		args = append(args, "-p", strconv.Itoa(req.Port))
	}
	if req.GitProtocol != "" {
		args = append(args, "-o", "SendEnv=GIT_PROTOCOL")
	}
	return append(args, "git@"+strings.ToLower(req.Host), remoteCommand(verb, path))
}

const lfsAuthVerb = "git-lfs-authenticate "

func remoteCommand(verb, path string) string {
	if operation, ok := strings.CutPrefix(verb, lfsAuthVerb); ok {
		return lfsAuthVerb + path + " " + operation
	}
	return verb + " '" + path + "'"
}

func (t *transport) serve(l net.Listener) error {
	for {
		c, err := l.Accept()
		if err != nil {
			return err
		}
		go t.handle(c)
	}
}

func (t *transport) handle(conn net.Conn) {
	defer conn.Close()
	fw := &frameWriter{w: conn}
	fail := func(format string, args ...any) {
		msg := fmt.Sprintf(format, args...)
		t.logf("refused: %s", msg)
		fw.frame(frameStderr, []byte("git-ssh-broker: "+msg+"\n"))
		fw.exit(1)
	}
	r := bufio.NewReader(conn)
	req, err := readRequest(r)
	if err != nil {
		fail("%v", err)
		return
	}
	verb, path, err := t.validate(req)
	if err != nil {
		fail("%v", err)
		return
	}
	t.logf("%s %s:%s", verb, req.Host, path)

	argv := t.sshArgs(req, verb, path)
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = os.Environ()
	if req.GitProtocol != "" {
		cmd.Env = append(cmd.Env, "GIT_PROTOCOL="+req.GitProtocol)
	}
	stdin, _ := cmd.StdinPipe()
	stdout, _ := cmd.StdoutPipe()
	stderr, _ := cmd.StderrPipe()
	if err := cmd.Start(); err != nil {
		fail("starting ssh: %v", err)
		return
	}

	var out sync.WaitGroup
	out.Add(2)
	go func() { defer out.Done(); fw.copyFrames(frameStdout, stdout) }()
	go func() { defer out.Done(); fw.copyFrames(frameStderr, stderr) }()

	var in io.Writer = stdin
	var push *pushFilter
	if verb == "git-receive-pack" {
		push = &pushFilter{dst: stdin, check: func(u refUpdate) error { return checkUpdate(u, req.GitDir, t.rewrite, t.logf) }}
		in = push
	}
	refused := ""
	for {
		typ, data, err := readFrame(r)
		if err != nil {
			break
		}
		if typ == frameStdinEOF {
			break
		}
		if typ != frameStdin {
			continue
		}
		if _, err := in.Write(data); err != nil {
			var pe *policyError
			if errors.As(err, &pe) {
				refused = pe.Error()
			}
			break
		}
	}
	stdin.Close()
	if refused != "" {
		cmd.Process.Kill()
	}
	out.Wait()
	err = cmd.Wait()
	if refused != "" {
		t.logf("refused push to %s:%s: %s", req.Host, path, refused)
		fw.frame(frameStderr, []byte("git-ssh-broker: push refused: "+refused+"\n"+
			"git-ssh-broker: force pushes (but dropping only your own commits from "+t.rewrite.describe()+"), "+
			"branch/tag deletes and tag moves are manual steps: run them on the host yourself\n"))
		fw.exit(1)
		return
	}
	code := 0
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		code = ee.ExitCode()
		if code < 0 {
			code = 255
		}
	} else if err != nil {
		code = 255
	}
	fw.exit(code)
}

type refUpdate struct {
	Old, New, Ref string
}

func (u refUpdate) deletesRef() bool { return zeroOIDPattern.MatchString(u.New) }

func (u refUpdate) createsRef() bool { return zeroOIDPattern.MatchString(u.Old) }

type policyError struct{ msg string }

func (e *policyError) Error() string { return e.msg }

func checkUpdate(u refUpdate, gitDir string, rw rewritePolicy, logf func(string, ...any)) error {
	switch {
	case u.deletesRef():
		return &policyError{fmt.Sprintf("deleting %s", u.Ref)}
	case u.createsRef():
		return nil
	case strings.HasPrefix(u.Ref, "refs/tags/"):
		return &policyError{fmt.Sprintf("moving the existing tag %s", u.Ref)}
	}
	s, err := openObjectStore(gitDir)
	if err != nil {
		return &policyError{fmt.Sprintf("couldn't verify that %s is a fast-forward: %v", u.Ref, err)}
	}
	defer s.close()
	if !s.hasCommit(u.Old) {
		return &policyError{fmt.Sprintf("couldn't verify %s: its remote commit %s isn't in your repository (fetch first)", u.Ref, u.Old)}
	}
	if err := s.verify(u.Old, u.New); err != nil {
		return &policyError{fmt.Sprintf("couldn't verify the history of %s: %v", u.Ref, err)}
	}
	err = s.isAncestor(u.Old, u.New)
	switch {
	case err == nil:
		return nil
	case !errors.Is(err, errNotFastFwd):
		return &policyError{fmt.Sprintf("couldn't verify that %s is a fast-forward: %v", u.Ref, err)}
	case !rw.rewritable(u.Ref):
		return &policyError{fmt.Sprintf("%s is not a fast-forward (a force push)", u.Ref)}
	}
	dropped, err := s.dropped(u.Old, u.New)
	if err != nil {
		return &policyError{fmt.Sprintf("couldn't list the commits the force push of %s drops: %v", u.Ref, err)}
	}
	for _, c := range dropped {
		if !rw.emails[strings.ToLower(c.author)] || !rw.emails[strings.ToLower(c.committer)] {
			return &policyError{fmt.Sprintf("%s is not a fast-forward (a force push) and drops commit %s (author %s, committer %s), which isn't only yours",
				u.Ref, c.oid, c.author, c.committer)}
		}
	}
	logf("rewrite of %s allowed: %s -> %s drops %d commit(s), all yours", u.Ref, u.Old, u.New, len(dropped))
	return nil
}

type objectStore struct {
	tmp string
	env []string
}

var noCommitGraph = []string{"GIT_CONFIG_COUNT=1", "GIT_CONFIG_KEY_0=core.commitGraph", "GIT_CONFIG_VALUE_0=false"}

func openObjectStore(gitDir string) (*objectStore, error) {
	if gitDir == "" || !filepath.IsAbs(gitDir) {
		return nil, errors.New("no repository to check against")
	}
	objects := filepath.Join(gitDir, "objects")
	if st, err := os.Stat(objects); err != nil || !st.IsDir() {
		return nil, fmt.Errorf("%s is not a git object store", objects)
	}
	tmp, err := os.MkdirTemp("", "git-ssh-broker-")
	if err != nil {
		return nil, err
	}
	env := cleanGitEnv()
	if out, err := runGit(env, "init", "--quiet", "--bare", "--template=", tmp); err != nil {
		os.RemoveAll(tmp)
		return nil, fmt.Errorf("git init: %w: %s", err, out)
	}
	env = append(env,
		"GIT_DIR="+tmp,
		"GIT_OBJECT_DIRECTORY="+objects,
		"GIT_NO_REPLACE_OBJECTS=1",
		"GIT_NO_LAZY_FETCH=1",
	)
	env = append(env, noCommitGraph...)
	return &objectStore{tmp: tmp, env: env}, nil
}

func (s *objectStore) close() { os.RemoveAll(s.tmp) }

func (s *objectStore) verify(old, new string) error {
	vdir, err := os.MkdirTemp(s.tmp, "verified-")
	if err != nil {
		return err
	}
	venv := append(cleanGitEnv(), "GIT_DIR="+vdir, "GIT_NO_REPLACE_OBJECTS=1", "GIT_NO_LAZY_FETCH=1")
	venv = append(venv, noCommitGraph...)
	if out, err := runGit(cleanGitEnv(), "init", "--quiet", "--bare", "--template=", vdir); err != nil {
		return fmt.Errorf("git init: %w: %s", err, out)
	}
	list := exec.Command("git", "rev-list", old, new, "--")
	list.Env = s.env
	pack := exec.Command("git", "pack-objects", "--stdout", "-q")
	pack.Env = s.env
	// git doesn't re-hash an object it reads; index-pack names each one by the
	// hash of its content, so a forged object is missing from the copy
	index := exec.Command("git", "index-pack", "--stdin")
	index.Env = venv
	var errs [3]strings.Builder
	list.Stderr, pack.Stderr, index.Stderr = &errs[0], &errs[1], &errs[2]
	if pack.Stdin, err = list.StdoutPipe(); err != nil {
		return err
	}
	if index.Stdin, err = pack.StdoutPipe(); err != nil {
		return err
	}
	index.Stdout = io.Discard
	cmds := []*exec.Cmd{list, pack, index}
	for i, c := range cmds {
		if err := c.Start(); err != nil {
			for _, started := range cmds[:i] {
				_ = started.Process.Kill()
				_ = started.Wait()
			}
			return err
		}
	}
	for i, c := range cmds {
		if err := c.Wait(); err != nil {
			return fmt.Errorf("%s: %w: %s", c.Args[1], err, strings.TrimSpace(errs[i].String()))
		}
	}
	s.env = venv
	return nil
}

func (s *objectStore) hasCommit(oid string) bool {
	out, err := runGit(s.env, "cat-file", "-t", oid)
	return err == nil && strings.TrimSpace(out) == "commit"
}

func (s *objectStore) isAncestor(old, new string) error {
	out, err := runGit(s.env, "merge-base", "--is-ancestor", old, new)
	var ee *exec.ExitError
	switch {
	case err == nil:
		return nil
	case errors.As(err, &ee) && ee.ExitCode() == 1:
		return errNotFastFwd
	default:
		return fmt.Errorf("%s", strings.TrimSpace(out))
	}
}

type commitInfo struct{ oid, author, committer string }

func (s *objectStore) dropped(old, new string) ([]commitInfo, error) {
	cmd := exec.Command("git", "log", "--no-mailmap", "--format=%H%x00%ae%x00%ce", old, "--not", new, "--")
	cmd.Env = s.env
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("git log: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	var cs []commitInfo
	for _, line := range strings.Split(string(out), "\n") {
		if line == "" {
			continue
		}
		f := strings.Split(line, "\x00")
		if len(f) != 3 {
			return nil, fmt.Errorf("unexpected git log line %q", line)
		}
		cs = append(cs, commitInfo{oid: f[0], author: f[1], committer: f[2]})
	}
	return cs, nil
}

func cleanGitEnv() []string {
	var env []string
	for _, e := range os.Environ() {
		if !strings.HasPrefix(e, "GIT_") {
			env = append(env, e)
		}
	}
	return append(env, "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null")
}

func runGit(env []string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	return string(out), err
}

type pushFilter struct {
	dst             io.Writer
	check           func(refUpdate) error
	buf             []byte
	commandsChecked bool
}

const flushPkt = 0

func (p *pushFilter) Write(b []byte) (int, error) {
	if p.commandsChecked {
		return p.dst.Write(b)
	}
	p.buf = append(p.buf, b...)
	if len(p.buf) > 16<<20 {
		return 0, &policyError{"too many ref updates in one push"}
	}
	for off := 0; ; {
		if len(p.buf)-off < 4 {
			return len(b), nil
		}
		n, err := strconv.ParseUint(string(p.buf[off:off+4]), 16, 16)
		if err != nil {
			return 0, &policyError{"malformed push"}
		}
		if n == flushPkt {
			us, err := p.updates(off)
			if err != nil {
				return 0, err
			}
			for _, u := range us {
				if err := p.check(u); err != nil {
					return 0, err
				}
			}
			p.commandsChecked = true
			if _, err := p.dst.Write(p.buf); err != nil {
				return 0, err
			}
			p.buf = nil
			return len(b), nil
		}
		if n < 4 {
			return 0, &policyError{"malformed push"}
		}
		if len(p.buf)-off < int(n) {
			return len(b), nil
		}
		line := string(p.buf[off+4 : off+int(n)])
		if strings.HasPrefix(line, "push-cert") {
			return 0, &policyError{"signed pushes (push certificates) aren't supported"}
		}
		off += int(n)
	}
}

func (p *pushFilter) updates(end int) ([]refUpdate, error) {
	var us []refUpdate
	for off := 0; off < end; {
		n, _ := strconv.ParseUint(string(p.buf[off:off+4]), 16, 16)
		line := string(p.buf[off+4 : off+int(n)])
		off += int(n)
		line, _, _ = strings.Cut(line, "\x00") // capabilities follow the first
		line = strings.TrimSuffix(line, "\n")
		if strings.HasPrefix(line, "shallow ") {
			continue
		}
		f := strings.Fields(line)
		if len(f) != 3 {
			return nil, &policyError{fmt.Sprintf("unexpected push command %q", line)}
		}
		us = append(us, refUpdate{Old: f[0], New: f[1], Ref: f[2]})
	}
	return us, nil
}
