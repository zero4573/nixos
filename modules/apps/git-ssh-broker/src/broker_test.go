package main

import (
	"bytes"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The test binary doubles as the client: git runs it as its ssh command
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

// git runs git in dir with the test's environment, failing the test on error
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

// setup starts a broker whose "ssh" runs the transport command on bare repos
// under a local root, and a clone of github.com:acme/app.git through it
type fixture struct {
	remote, work string
}

func setup(t *testing.T) fixture {
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

	// Stand-in for ssh: the last argument is "<verb> '<path>'"
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
	tr := &transport{hosts: map[string]bool{"github.com": true}, sshCmd: []string{fakeSSH}, logf: t.Logf}
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

	// A new branch, then a fast-forward of it
	git(t, f.work, "switch", "-q", "-c", "feature/x")
	commit(t, f.work, "b")
	git(t, f.work, "push", "-q", "-u", "origin", "feature/x")
	commit(t, f.work, "c")
	git(t, f.work, "push", "-q")
	if got, want := remoteRef(t, f, "feature/x"), git(t, f.work, "rev-parse", "HEAD"); got != want {
		t.Fatalf("remote feature/x = %s, want %s", got, want)
	}

	// A rewritten branch is a force push, however it is spelled
	before := remoteRef(t, f, "feature/x")
	git(t, f.work, "commit", "-q", "--amend", "-m", "rewritten")
	refused(t, f, "not a fast-forward", "push", "--force", "origin", "feature/x")
	refused(t, f, "not a fast-forward", "push", "origin", "+feature/x")
	refused(t, f, "not a fast-forward", "push", "--force-with-lease", "origin", "feature/x")
	if got := remoteRef(t, f, "feature/x"); got != before {
		t.Fatalf("a refused force push moved the remote branch to %s", got)
	}

	// Deleting a branch
	refused(t, f, "deleting refs/heads/feature/x", "push", "origin", "--delete", "feature/x")
	refused(t, f, "deleting refs/heads/feature/x", "push", "origin", ":feature/x")
	if remoteRef(t, f, "feature/x") == "" {
		t.Fatal("a refused delete removed the branch")
	}

	// Tags: a new one is fine; deleting or moving it isn't
	git(t, f.work, "tag", "v1", "main")
	git(t, f.work, "push", "-q", "origin", "v1")
	refused(t, f, "deleting refs/tags/v1", "push", "origin", "--delete", "v1")
	git(t, f.work, "tag", "-f", "v1", "HEAD")
	refused(t, f, "moving the existing tag refs/tags/v1", "push", "--force", "origin", "v1")

	// Fetching is plain passthrough
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
	bad := map[string]request{
		"user":    {User: "root", Host: "github.com", Command: ok.Command},
		"host":    {Host: "evil.example", Command: ok.Command},
		"port":    {Host: "github.com", Port: 2222, Command: ok.Command},
		"verb":    {Host: "github.com", Command: "sh -c 'id'"},
		"dotdot":  {Host: "github.com", Command: "git-upload-pack 'acme/../../etc'"},
		"single":  {Host: "github.com", Command: "git-upload-pack 'app.git'"},
		"quote":   {Host: "github.com", Command: "git-upload-pack 'a/b'; id'"},
		"newline": {Host: "github.com", Command: "git-upload-pack 'a/b\nc'"},
		"proto":   {Host: "github.com", Command: ok.Command, GitProtocol: "version=2;id"},
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

// signingSetup starts a real ssh-agent holding an allowed and another key,
// and the filtering agent in front of it
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
		// Only the agent has it now: ssh-keygen would otherwise fall back to
		// the file next to the .pub
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

	// Only the signing key is listed
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
	// Any other request, e.g. adding a key (17), is refused
	if got := a.answer([]byte{17}); !bytes.Equal(got, []byte{agentFailure}) {
		t.Fatalf("add-identity was not refused: %v", got)
	}
}
