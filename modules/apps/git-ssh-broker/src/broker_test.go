package main

import (
	"bytes"
	"compress/zlib"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	if os.Getenv("BROKER_TEST_AS_CLIENT") == "1" {
		os.Exit(clientMain(os.Args[2:]))
	}
	os.Exit(m.Run())
}

func need(t *testing.T, tools ...string) {
	t.Helper()
	for _, tool := range tools {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s not found", tool)
		}
	}
}

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	out, err := gitErr(dir, args...)
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return strings.TrimSpace(out)
}

func gitErr(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	return string(out), err
}

type fixture struct {
	remote, work string
}

func setup(t *testing.T) fixture {
	rw, err := newRewritePolicy([]string{"feature/*"}, []string{"Test@Example.COM", "me@example.org"})
	if err != nil {
		t.Fatal(err)
	}
	return setupWith(t, rw)
}

func setupWith(t *testing.T, rw rewritePolicy) fixture {
	need(t, "git")
	root := t.TempDir()
	remotes := filepath.Join(root, "remotes")
	remote := filepath.Join(remotes, "acme", "app.git")
	work := filepath.Join(root, "work")

	t.Setenv("HOME", root)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	t.Setenv("GIT_CONFIG_GLOBAL", filepath.Join(root, "gitconfig"))
	os.WriteFile(filepath.Join(root, "gitconfig"), []byte("[user]\n\tname = Test\n\temail = test@example.com\n[init]\n\tdefaultBranch = main\n[protocol]\n\tversion = 2\n"), 0o644)

	seed := filepath.Join(root, "seed")
	git(t, root, "init", "-q", seed)
	os.WriteFile(filepath.Join(seed, "a"), []byte("a\n"), 0o644)
	git(t, seed, "add", "a")
	git(t, seed, "commit", "-q", "-m", "one")
	os.MkdirAll(filepath.Dir(remote), 0o755)
	git(t, root, "clone", "-q", "--bare", seed, remote)

	fakeSSH := filepath.Join(root, "fake-ssh")
	os.WriteFile(fakeSSH, []byte(`#!/bin/sh
for a; do last=$a; done
verb=${last%% *}
path=${last#* \'}
path=${path%\'}
exec $verb "$FAKE_REMOTES/$path"
`), 0o755)
	t.Setenv("FAKE_REMOTES", remotes)

	sock := filepath.Join(root, "git.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	tr := &transport{hosts: map[string]bool{"github.com": true}, sshCmd: []string{fakeSSH}, rewrite: rw, logf: t.Logf}
	go tr.serve(l)

	self, _ := os.Executable()
	t.Setenv("BROKER_TEST_AS_CLIENT", "1")
	t.Setenv("GIT_SSH_BROKER_SOCKET", sock)
	t.Setenv("GIT_SSH_COMMAND", self+" client")
	t.Setenv("GIT_SSH_VARIANT", "ssh")

	git(t, root, "clone", "-q", "git@github.com:acme/app.git", work)
	return fixture{remote: remote, work: work}
}

func commit(t *testing.T, dir, file string) {
	t.Helper()
	os.WriteFile(filepath.Join(dir, file), []byte(file+"\n"), 0o644)
	git(t, dir, "add", file)
	git(t, dir, "commit", "-q", "-m", file)
}

func remoteRef(t *testing.T, f fixture, ref string) string {
	out, _ := gitErr(f.remote, "rev-parse", "--verify", "-q", ref)
	return strings.TrimSpace(out)
}

func refused(t *testing.T, f fixture, why string, args ...string) {
	t.Helper()
	out, err := gitErr(f.work, args...)
	if err == nil {
		t.Fatalf("git %s succeeded, want it refused", strings.Join(args, " "))
	}
	if !strings.Contains(out, "push refused: ") || !strings.Contains(out, why) {
		t.Fatalf("git %s: want a refusal mentioning %q, got:\n%s", strings.Join(args, " "), why, out)
	}
}

func TestPushPolicy(t *testing.T) {
	f := setup(t)

	git(t, f.work, "switch", "-q", "-c", "feature/x")
	commit(t, f.work, "b")
	git(t, f.work, "push", "-q", "-u", "origin", "feature/x")
	commit(t, f.work, "c")
	git(t, f.work, "push", "-q")
	if got, want := remoteRef(t, f, "feature/x"), git(t, f.work, "rev-parse", "HEAD"); got != want {
		t.Fatalf("remote feature/x = %s, want %s", got, want)
	}

	git(t, f.work, "switch", "-q", "-c", "develop")
	git(t, f.work, "push", "-q", "-u", "origin", "develop")
	for _, b := range []string{"main", "develop"} {
		git(t, f.work, "switch", "-q", b)
		commit(t, f.work, b+"-1")
		git(t, f.work, "push", "-q", "origin", b)
		before := remoteRef(t, f, b)
		git(t, f.work, "commit", "-q", "--amend", "-m", "rewritten")
		refused(t, f, "refs/heads/"+b+" is not a fast-forward", "push", "--force", "origin", b)
		refused(t, f, "refs/heads/"+b+" is not a fast-forward", "push", "origin", "+"+b)
		refused(t, f, "refs/heads/"+b+" is not a fast-forward", "push", "--force-with-lease", "origin", b)
		if got := remoteRef(t, f, b); got != before {
			t.Fatalf("a refused force push moved the remote %s to %s", b, got)
		}
		git(t, f.work, "reset", "-q", "--hard", before)
	}
	git(t, f.work, "switch", "-q", "feature/x")

	refused(t, f, "deleting refs/heads/feature/x", "push", "origin", "--delete", "feature/x")
	refused(t, f, "deleting refs/heads/feature/x", "push", "origin", ":feature/x")
	if remoteRef(t, f, "feature/x") == "" {
		t.Fatal("a refused delete removed the branch")
	}

	git(t, f.work, "tag", "v1", "main")
	git(t, f.work, "push", "-q", "origin", "v1")
	refused(t, f, "deleting refs/tags/v1", "push", "origin", "--delete", "v1")
	git(t, f.work, "tag", "-f", "v1", "HEAD")
	refused(t, f, "moving the existing tag refs/tags/v1", "push", "--force", "origin", "v1")

	git(t, f.work, "fetch", "-q", "origin")
}

func TestPushMixedRefusesAll(t *testing.T) {
	f := setup(t)
	git(t, f.work, "switch", "-q", "-c", "ok")
	commit(t, f.work, "b")
	refused(t, f, "deleting refs/heads/main", "push", "origin", "ok", ":main")
	if remoteRef(t, f, "ok") != "" {
		t.Fatal("part of a refused push reached the remote")
	}
}

func commitAs(t *testing.T, dir, file string, env ...string) {
	t.Helper()
	os.WriteFile(filepath.Join(dir, file), []byte(file+"\n"), 0o644)
	git(t, dir, "add", file)
	cmd := exec.Command("git", "commit", "-q", "-m", file)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), env...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git commit: %v\n%s", err, out)
	}
}

func featureBranch(t *testing.T, f fixture, env ...string) string {
	t.Helper()
	git(t, f.work, "switch", "-q", "-c", "feature/x")
	commitAs(t, f.work, "b", env...)
	git(t, f.work, "push", "-q", "-u", "origin", "feature/x")
	return remoteRef(t, f, "feature/x")
}

func rebaseOntoNewMain(t *testing.T, f fixture) {
	t.Helper()
	git(t, f.work, "switch", "-q", "main")
	commitAs(t, f.work, "m", "GIT_AUTHOR_EMAIL=colleague@example.net", "GIT_COMMITTER_EMAIL=colleague@example.net")
	git(t, f.work, "push", "-q", "origin", "main")
	git(t, f.work, "switch", "-q", "feature/x")
	git(t, f.work, "rebase", "-q", "main")
}

func TestRewriteOwnFeatureBranch(t *testing.T) {
	f := setup(t)
	featureBranch(t, f)

	rebaseOntoNewMain(t, f)
	git(t, f.work, "push", "-q", "--force-with-lease", "origin", "feature/x")
	if got, want := remoteRef(t, f, "feature/x"), git(t, f.work, "rev-parse", "HEAD"); got != want {
		t.Fatalf("remote feature/x = %s, want the rebased %s", got, want)
	}
	git(t, f.work, "commit", "-q", "--amend", "-m", "amended")
	git(t, f.work, "push", "-q", "--force", "origin", "feature/x")
	git(t, f.work, "commit", "-q", "--amend", "-m", "amended again")
	git(t, f.work, "push", "-q", "origin", "+feature/x")
	if got, want := remoteRef(t, f, "feature/x"), git(t, f.work, "rev-parse", "HEAD"); got != want {
		t.Fatalf("remote feature/x = %s, want %s", got, want)
	}

	commit(t, f.work, "c")
	git(t, f.work, "push", "-q", "origin", "feature/x")

	refused(t, f, "deleting refs/heads/feature/x", "push", "origin", "--delete", "feature/x")
	git(t, f.work, "tag", "v1", "main")
	git(t, f.work, "push", "-q", "origin", "v1")
	git(t, f.work, "tag", "-f", "v1", "HEAD")
	refused(t, f, "moving the existing tag refs/tags/v1", "push", "--force", "origin", "v1")
	refused(t, f, "deleting refs/tags/v1", "push", "origin", "--delete", "v1")
}

func TestRewriteDroppingOthersCommits(t *testing.T) {
	for name, env := range map[string][]string{
		"author":    {"GIT_AUTHOR_EMAIL=colleague@example.net"},
		"committer": {"GIT_COMMITTER_EMAIL=colleague@example.net"},
	} {
		t.Run(name, func(t *testing.T) {
			f := setup(t)
			featureBranch(t, f)
			commitAs(t, f.work, "theirs", env...)
			git(t, f.work, "push", "-q", "origin", "feature/x")
			theirs := git(t, f.work, "rev-parse", "HEAD")
			before := remoteRef(t, f, "feature/x")
			git(t, f.work, "reset", "-q", "--hard", "HEAD~1")
			commit(t, f.work, "mine")
			refused(t, f, "drops commit "+theirs, "push", "--force-with-lease", "origin", "feature/x")
			git(t, f.work, "reset", "-q", "--hard", theirs)
			rebaseOntoNewMain(t, f)
			refused(t, f, "drops commit "+theirs, "push", "--force", "origin", "feature/x")
			if got := remoteRef(t, f, "feature/x"); got != before {
				t.Fatalf("a refused rewrite moved feature/x to %s", got)
			}
		})
	}
}

func TestRewriteNotMatchingBranch(t *testing.T) {
	f := setup(t)
	for _, b := range []string{"feature/a/b", "features/x", "fix/feature/x"} {
		git(t, f.work, "switch", "-q", "-c", b, "main")
		commit(t, f.work, strings.ReplaceAll(b, "/", "-"))
		git(t, f.work, "push", "-q", "origin", b)
		git(t, f.work, "commit", "-q", "--amend", "-m", "rewritten")
		refused(t, f, "refs/heads/"+b+" is not a fast-forward (a force push)", "push", "--force", "origin", b)
	}
}

func TestRewriteWithoutIdentities(t *testing.T) {
	rw, err := newRewritePolicy([]string{"feature/*"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	f := setupWith(t, rw)
	featureBranch(t, f)
	git(t, f.work, "commit", "-q", "--amend", "-m", "rewritten")
	refused(t, f, "refs/heads/feature/x is not a fast-forward (a force push)", "push", "--force", "origin", "feature/x")
}

func TestRewriteOldMissing(t *testing.T) {
	f := setup(t)
	featureBranch(t, f)
	tree := git(t, f.remote, "rev-parse", "feature/x^{tree}")
	parent := git(t, f.remote, "rev-parse", "feature/x")
	cmd := exec.Command("git", "commit-tree", "-p", parent, "-m", "elsewhere", tree)
	cmd.Dir = f.remote
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	moved := strings.TrimSpace(string(out))
	git(t, f.remote, "update-ref", "refs/heads/feature/x", moved)

	git(t, f.work, "commit", "-q", "--amend", "-m", "rewritten")
	refused(t, f, moved+" isn't in your repository", "push", "--force", "origin", "feature/x")
	if got := remoteRef(t, f, "feature/x"); got != moved {
		t.Fatalf("a refused rewrite moved feature/x to %s", got)
	}
}

func TestRewritePolicyConfig(t *testing.T) {
	if _, err := newRewritePolicy([]string{"feature/["}, nil); err == nil {
		t.Fatal("a bad pattern accepted")
	}
	rw, _ := newRewritePolicy([]string{"feature/*", "tix/*"}, []string{"me@example.org"})
	for ref, want := range map[string]bool{
		"refs/heads/feature/x":   true,
		"refs/heads/tix/ABC-1":   true,
		"refs/heads/feature/a/b": false,
		"refs/heads/feature":     false,
		"refs/heads/main":        false,
		"refs/tags/feature/x":    false,
		"refs/heads/x/feature/y": false,
	} {
		if got := rw.rewritable(ref); got != want {
			t.Errorf("rewritable(%s) = %v, want %v", ref, got, want)
		}
	}
}

func TestDisallowedHost(t *testing.T) {
	f := setup(t)
	out, err := gitErr(f.work, "ls-remote", "git@example.com:acme/app.git")
	if err == nil || !strings.Contains(out, `host "example.com" is not allowed`) {
		t.Fatalf("want the host refused, got err=%v:\n%s", err, out)
	}
}

func TestValidate(t *testing.T) {
	tr := &transport{hosts: map[string]bool{"github.com": true}}
	ok := request{User: "git", Host: "GitHub.com", Command: "git-receive-pack 'acme/app.git'"}
	if _, _, err := tr.validate(ok); err != nil {
		t.Fatalf("valid request refused: %v", err)
	}
	for cmd, remote := range map[string]string{
		"git-lfs-authenticate acme/app.git download": "git-lfs-authenticate acme/app.git download",
		"git-lfs-authenticate 'acme/app.git' upload": "git-lfs-authenticate acme/app.git upload",
		"git-upload-pack 'acme/app.git'":             "git-upload-pack 'acme/app.git'",
	} {
		verb, path, err := tr.validate(request{User: "git", Host: "github.com", Command: cmd})
		if err != nil {
			t.Fatalf("%q refused: %v", cmd, err)
		}
		if got := remoteCommand(verb, path); got != remote {
			t.Errorf("%q runs %q on the remote, want %q", cmd, got, remote)
		}
	}
	bad := map[string]request{
		"user":     {User: "root", Host: "github.com", Command: ok.Command},
		"host":     {Host: "evil.example", Command: ok.Command},
		"port":     {Host: "github.com", Port: 2222, Command: ok.Command},
		"verb":     {Host: "github.com", Command: "sh -c 'id'"},
		"dotdot":   {Host: "github.com", Command: "git-upload-pack 'acme/../../etc'"},
		"single":   {Host: "github.com", Command: "git-upload-pack 'app.git'"},
		"quote":    {Host: "github.com", Command: "git-upload-pack 'a/b'; id'"},
		"newline":  {Host: "github.com", Command: "git-upload-pack 'a/b\nc'"},
		"proto":    {Host: "github.com", Command: ok.Command, GitProtocol: "version=2;id"},
		"lfs-op":   {Host: "github.com", Command: "git-lfs-authenticate acme/app.git delete"},
		"lfs-dot":  {Host: "github.com", Command: "git-lfs-authenticate acme/../etc download"},
		"lfs-sh":   {Host: "github.com", Command: "git-lfs-authenticate a/b;id download"},
		"lfs-xfer": {Host: "github.com", Command: "git-lfs-transfer acme/app.git download"},
	}
	for name, req := range bad {
		if _, _, err := tr.validate(req); err == nil {
			t.Errorf("%s: %+v accepted", name, req)
		}
	}
}

func TestParseSSHArgs(t *testing.T) {
	req, err := parseSSHArgs([]string{"-o", "SendEnv=GIT_PROTOCOL", "-p", "443", "git@ssh.github.com", "git-upload-pack 'a/b.git'"})
	if err != nil {
		t.Fatal(err)
	}
	if req.User != "git" || req.Host != "ssh.github.com" || req.Port != 443 || req.Command != "git-upload-pack 'a/b.git'" {
		t.Fatalf("parsed %+v", req)
	}
	if _, err := parseSSHArgs([]string{"-L", "1:2:3", "git@github.com", "x"}); err == nil {
		t.Fatal("-L accepted")
	}
	if _, err := parseSSHArgs([]string{"git@github.com"}); err == nil {
		t.Fatal("an interactive login accepted")
	}
}

func signingSetup(t *testing.T) (dir, sock string) {
	need(t, "ssh-keygen", "ssh-agent", "ssh-add")
	dir = t.TempDir()
	for _, k := range []string{"signing", "other"} {
		out, err := exec.Command("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", k, "-f", filepath.Join(dir, k)).CombinedOutput()
		if err != nil {
			t.Fatalf("ssh-keygen: %v\n%s", err, out)
		}
	}
	upstream := filepath.Join(dir, "upstream.sock")
	agent := exec.Command("ssh-agent", "-D", "-a", upstream)
	if err := agent.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { agent.Process.Kill(); agent.Wait() })
	for i := 0; i < 50; i++ {
		if _, err := os.Stat(upstream); err == nil {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	for _, k := range []string{"signing", "other"} {
		add := exec.Command("ssh-add", "-q", filepath.Join(dir, k))
		add.Env = append(os.Environ(), "SSH_AUTH_SOCK="+upstream)
		if out, err := add.CombinedOutput(); err != nil {
			t.Fatalf("ssh-add: %v\n%s", err, out)
		}
		// ssh-keygen falls back to the private key file next to the .pub
		os.Remove(filepath.Join(dir, k))
	}
	keys, err := loadSigningKeys([]string{filepath.Join(dir, "signing.pub")})
	if err != nil {
		t.Fatal(err)
	}
	sock = filepath.Join(dir, "filtered.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go (&signingAgent{upstream: upstream, keys: keys, logf: t.Logf}).serve(l)
	return dir, sock
}

func TestSigningAgent(t *testing.T) {
	dir, sock := signingSetup(t)
	env := append(os.Environ(), "SSH_AUTH_SOCK="+sock)
	msg := filepath.Join(dir, "msg")
	os.WriteFile(msg, []byte("tree 0\n"), 0o644)

	list := exec.Command("ssh-add", "-L")
	list.Env = env
	out, _ := list.CombinedOutput()
	if !bytes.Contains(out, []byte(" signing")) || bytes.Contains(out, []byte(" other")) {
		t.Fatalf("ssh-add -L through the filter:\n%s", out)
	}

	sign := func(key, ns string) error {
		os.Remove(msg + ".sig")
		c := exec.Command("ssh-keygen", "-Y", "sign", "-f", filepath.Join(dir, key+".pub"), "-n", ns, msg)
		c.Env = env
		return c.Run()
	}
	if err := sign("signing", "git"); err != nil {
		t.Fatalf("a git signature was refused: %v", err)
	}
	if err := sign("signing", "file"); err == nil {
		t.Fatal("a non-git namespace was signed")
	}
	if err := sign("other", "git"); err == nil {
		t.Fatal("a key that isn't a signing key signed")
	}
}

func TestSigningAgentRefusesLogin(t *testing.T) {
	a := &signingAgent{keys: map[string]bool{"key": true}, logf: t.Logf}
	var p bytes.Buffer
	writeString(&p, []byte("key"))
	writeString(&p, []byte("\x00\x00\x00\x20session-id...userauth request"))
	p.Write([]byte{0, 0, 0, 0})
	if got := a.answer(append([]byte{agentSignRequest}, p.Bytes()...)); !bytes.Equal(got, []byte{agentFailure}) {
		t.Fatalf("an SSH login signature was not refused: %v", got)
	}
	const agentAddIdentity = 17
	if got := a.answer([]byte{agentAddIdentity}); !bytes.Equal(got, []byte{agentFailure}) {
		t.Fatalf("add-identity was not refused: %v", got)
	}
}

func forgeParent(t *testing.T, dir, oid, parent string) {
	t.Helper()
	tree := git(t, dir, "rev-parse", oid+"^{tree}")
	body := fmt.Sprintf("tree %s\nparent %s\nauthor Test <test@example.com> 1 +0000\ncommitter Test <test@example.com> 1 +0000\n\nforged\n", tree, parent)
	var z bytes.Buffer
	w := zlib.NewWriter(&z)
	fmt.Fprintf(w, "commit %d\x00%s", len(body), body)
	w.Close()
	p := filepath.Join(dir, ".git", "objects", oid[:2], oid[2:])
	os.Chmod(p, 0o644)
	if err := os.WriteFile(p, z.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "rev-parse", oid+"^"); got != parent {
		t.Fatalf("the forgery didn't take: %s^ = %s", oid, got)
	}
}

func TestForgedObjectsAreCaught(t *testing.T) {
	t.Run("fake fast-forward", func(t *testing.T) {
		f := setup(t)
		commit(t, f.work, "b")
		git(t, f.work, "push", "-q", "origin", "main")
		pushed := git(t, f.work, "rev-parse", "HEAD")
		git(t, f.work, "reset", "-q", "--hard", "HEAD~1")
		commit(t, f.work, "c")
		forgeParent(t, f.work, git(t, f.work, "rev-parse", "HEAD"), pushed)
		refused(t, f, "couldn't verify", "push", "--force", "origin", "main")
		if got := remoteRef(t, f, "main"); got != pushed {
			t.Fatalf("main moved to %s", got)
		}
	})
	t.Run("hidden commit of someone else", func(t *testing.T) {
		f := setup(t)
		featureBranch(t, f)
		commitAs(t, f.work, "theirs", "GIT_AUTHOR_EMAIL=colleague@example.net", "GIT_COMMITTER_EMAIL=colleague@example.net")
		git(t, f.work, "push", "-q", "origin", "feature/x")
		theirs := git(t, f.work, "rev-parse", "HEAD")
		git(t, f.work, "reset", "-q", "--hard", "HEAD~1")
		commit(t, f.work, "mine")
		forgeParent(t, f.work, git(t, f.work, "rev-parse", "HEAD"), theirs)
		refused(t, f, "couldn't verify", "push", "--force", "origin", "feature/x")
		if got := remoteRef(t, f, "feature/x"); got != theirs {
			t.Fatalf("feature/x moved to %s", got)
		}
	})
}
