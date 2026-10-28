package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// transport is the git socket's policy and how it reaches the remotes
type transport struct {
	hosts map[string]bool
	// sshCmd runs the host's ssh: argv[0] and leading arguments (a test
	// replaces it with a local stand-in)
	sshCmd []string
	logf   func(format string, args ...any)
}

var (
	commandRe = regexp.MustCompile(`^(git-upload-pack|git-receive-pack|git-upload-archive) '([^']*)'$`)
	// owner/repo(.git), optionally with a leading /; no .. components
	repoPathRe     = regexp.MustCompile(`^/?[A-Za-z0-9_.~-]+(/[A-Za-z0-9_.-]+)+$`)
	gitProtocolRe  = regexp.MustCompile(`^[A-Za-z0-9=:._-]*$`)
	errNotFastFwd  = errors.New("not a fast-forward")
	allowedPorts   = map[int]bool{0: true, 22: true, 443: true}
	zeroOIDPattern = regexp.MustCompile(`^0+$`)
)

// validate checks a request against the policy and returns the git verb and
// repo path
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
	m := commandRe.FindStringSubmatch(req.Command)
	if m == nil {
		return "", "", fmt.Errorf("command %q: only git-upload-pack, git-receive-pack and git-upload-archive are brokered", req.Command)
	}
	verb, path = m[1], m[2]
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

// sshArgs is the host ssh command for a validated request. Nothing from the
// request reaches ssh but the checked host, port and command: no options,
// so no ProxyCommand or forwarding from the sandbox.
func (t *transport) sshArgs(req request, verb, path string) []string {
	args := append([]string{}, t.sshCmd...)
	args = append(args, "-x", "-T", "-a", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes")
	if req.Port != 0 {
		args = append(args, "-p", strconv.Itoa(req.Port))
	}
	if req.GitProtocol != "" {
		args = append(args, "-o", "SendEnv=GIT_PROTOCOL")
	}
	return append(args, "git@"+strings.ToLower(req.Host), verb+" '"+path+"'")
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

// handle runs one transport command for a client connection
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

	// The client's side: frames into ssh's stdin; a push goes through the
	// ref-update check first
	var in io.Writer = stdin
	var push *pushFilter
	if verb == "git-receive-pack" {
		push = &pushFilter{dst: stdin, check: func(u refUpdate) error { return checkUpdate(u, req.GitDir) }}
		in = push
	}
	refused := ""
	for {
		typ, data, err := readFrame(r)
		if err != nil {
			break // the client is gone; ssh sees its stdin close
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
		// Nothing of the push reached the remote: stop it before it waits
		// for more
		cmd.Process.Kill()
	}
	out.Wait()
	err = cmd.Wait()
	if refused != "" {
		t.logf("refused push to %s:%s: %s", req.Host, path, refused)
		fw.frame(frameStderr, []byte("git-ssh-broker: push refused: "+refused+"\n"+
			"git-ssh-broker: force pushes, branch/tag deletes and tag moves are manual steps: run them on the host yourself\n"))
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

// refUpdate is one command of a push: <old> <new> <ref>
type refUpdate struct {
	Old, New, Ref string
}

type policyError struct{ msg string }

func (e *policyError) Error() string { return e.msg }

// checkUpdate is the push policy for one ref
func checkUpdate(u refUpdate, gitDir string) error {
	switch {
	case zeroOIDPattern.MatchString(u.New):
		return &policyError{fmt.Sprintf("deleting %s", u.Ref)}
	case zeroOIDPattern.MatchString(u.Old):
		return nil // a new ref
	case strings.HasPrefix(u.Ref, "refs/tags/"):
		return &policyError{fmt.Sprintf("moving the existing tag %s", u.Ref)}
	}
	if err := isAncestor(gitDir, u.Old, u.New); err != nil {
		if errors.Is(err, errNotFastFwd) {
			return &policyError{fmt.Sprintf("%s is not a fast-forward (a force push)", u.Ref)}
		}
		return &policyError{fmt.Sprintf("couldn't verify that %s is a fast-forward: %v", u.Ref, err)}
	}
	return nil
}

// isAncestor reports (nil) whether old is an ancestor of new among the
// objects of the client's repository. The client's repository is never used
// as a git dir (its config, hooks, replace refs and grafts could lie or run
// code on the host): a throwaway empty one reads only its object store.
// Objects are content-addressed, so the answer holds for what is pushed.
func isAncestor(gitDir, old, new string) error {
	if gitDir == "" || !filepath.IsAbs(gitDir) {
		return errors.New("no repository to check against")
	}
	objects := filepath.Join(gitDir, "objects")
	if st, err := os.Stat(objects); err != nil || !st.IsDir() {
		return fmt.Errorf("%s is not a git object store", objects)
	}
	tmp, err := os.MkdirTemp("", "git-ssh-broker-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	env := cleanGitEnv()
	if out, err := runGit(env, "init", "--quiet", "--bare", "--template=", tmp); err != nil {
		return fmt.Errorf("git init: %v: %s", err, out)
	}
	env = append(env,
		"GIT_DIR="+tmp,
		"GIT_OBJECT_DIRECTORY="+objects,
		"GIT_NO_REPLACE_OBJECTS=1",
		"GIT_NO_LAZY_FETCH=1",
	)
	out, err := runGit(env, "merge-base", "--is-ancestor", old, new)
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

// cleanGitEnv is the broker's environment without any GIT_* variable and
// without global or system git config
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

// pushFilter sits in front of git-receive-pack's stdin. It holds back the
// push's ref-update commands (pkt-lines up to the first flush), checks each,
// and only then lets them, and everything after, through. A refused push
// sends the remote nothing.
type pushFilter struct {
	dst   io.Writer
	check func(refUpdate) error
	buf   []byte
	open  bool // commands checked: pass everything through
}

func (p *pushFilter) Write(b []byte) (int, error) {
	if p.open {
		return p.dst.Write(b)
	}
	p.buf = append(p.buf, b...)
	if len(p.buf) > 16<<20 {
		return 0, &policyError{"too many ref updates in one push"}
	}
	for off := 0; ; {
		if len(p.buf)-off < 4 {
			return len(b), nil // need more
		}
		n, err := strconv.ParseUint(string(p.buf[off:off+4]), 16, 16)
		if err != nil {
			return 0, &policyError{"malformed push"}
		}
		if n == 0 { // flush: the end of the commands
			us, err := p.updates(off)
			if err != nil {
				return 0, err
			}
			for _, u := range us {
				if err := p.check(u); err != nil {
					return 0, err
				}
			}
			p.open = true
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

// updates parses the held-back command pkt-lines before end
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
			// Unknown: refused rather than let through unchecked
			return nil, &policyError{fmt.Sprintf("unexpected push command %q", line)}
		}
		us = append(us, refUpdate{Old: f[0], New: f[1], Ref: f[2]})
	}
	return us, nil
}
