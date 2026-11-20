package main

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const sha1, sha2 = "1111111", "2222222222222222222222222222222222222222"

type fixture struct {
	ws, vault, ticketDir, calls string
}

func setup(t *testing.T, kiro string) (fixture, *broker) {
	t.Helper()
	root := t.TempDir()
	f := fixture{ws: filepath.Join(root, "work", "MAN-1"), vault: filepath.Join(root, "vault"), calls: filepath.Join(root, "calls")}
	f.ticketDir = filepath.Join(f.vault, "tickets", "manual", "MAN-1")
	for _, d := range []string{filepath.Join(f.ws, "acme-api"), filepath.Join(f.ticketDir, "reviews"), f.calls} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	write(t, filepath.Join(f.ticketDir, "MAN-1.md"), "---\nsummary: x\n---\n")
	ws, _ := json.Marshal(map[string]any{"id": "MAN-1", "vault": f.vault, "repos": []map[string]string{{"slug": "acme-api"}}})
	write(t, filepath.Join(f.ws, "workspace.json"), string(ws))
	stub := filepath.Join(root, "kiro")
	write(t, stub, "#!/bin/sh\nCALLS="+f.calls+"\n"+kiro)
	if err := os.Chmod(stub, 0o755); err != nil {
		t.Fatal(err)
	}
	b, err := newBroker(config{
		Workspace: f.ws, Kiro: stub, Models: []string{"gpt-5.6-sol", "glm-5"},
		AddDirs: []string{f.vault}, Effort: "high", MaxParallel: 1, Timeout: 5 * time.Second,
		KillGrace: time.Second, Env: hostEnv([]string{"PATH=" + os.Getenv("PATH"), "HOME=/h", "AGENT=work", "ANTHROPIC_API_KEY=secret"}),
	})
	if err != nil {
		t.Fatal(err)
	}
	return f, b
}

func write(t *testing.T, p, s string) {
	t.Helper()
	if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
		t.Fatal(err)
	}
}

func call(t *testing.T, b *broker, req any) []reply {
	t.Helper()
	sock := filepath.Join(t.TempDir(), "s")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go b.serve(ctx, ln)
	defer ln.Close()
	conn, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	var line []byte
	if s, ok := req.(string); ok {
		line = []byte(s)
	} else {
		line, _ = json.Marshal(req)
	}
	if _, err := conn.Write(append(line, '\n')); err != nil {
		t.Fatal(err)
	}
	var out []reply
	sc := bufio.NewScanner(conn)
	for sc.Scan() {
		var r reply
		if err := json.Unmarshal(sc.Bytes(), &r); err != nil {
			t.Fatalf("bad reply %q", sc.Text())
		}
		out = append(out, r)
		if r.Status != "" {
			break
		}
	}
	return out
}

func last(rs []reply) reply {
	if len(rs) == 0 {
		return reply{}
	}
	return rs[len(rs)-1]
}

func review(over map[string]any) map[string]any {
	r := map[string]any{"op": "review", "ticket": "MAN-1", "wave": 2, "repo": "acme-api", "range": sha1 + ".." + sha2, "model": "glm-5", "brief": "contract change in api/"}
	for k, v := range over {
		r[k] = v
	}
	return r
}

const writesReview = `
printf '%s\n' "$PWD" > "$CALLS/cwd"
env > "$CALLS/env"
for a in "$@"; do printf '%s\n' "$a"; done > "$CALLS/args"
f=$(printf '%s\n' "$@" | sed -n 's/^- Write the review to \(.*\) and nothing else.*/\1/p')
echo "reviewing"
echo "# review" > "$f"
`

func TestReviewRuns(t *testing.T) {
	f, b := setup(t, writesReview)
	rs := call(t, b, review(nil))
	want := filepath.Join(f.ticketDir, "reviews", "wave-2-acme-api-glm-5.md")
	if r := last(rs); r.Status != "ok" || r.ReviewFile != want {
		t.Fatalf("reply = %+v", rs)
	}
	if rs[0].Log != "reviewing" {
		t.Errorf("output not streamed: %+v", rs)
	}
	args, _ := os.ReadFile(filepath.Join(f.calls, "args"))
	for _, s := range []string{"chat\n--no-interactive\n--trust-all-tools\n--agent\ntix-reviewer-deep\n--model\nglm-5\n--effort\nhigh\n",
		"Follow the tix-wave-review skill exactly for ticket MAN-1, wave 2, repo acme-api.",
		"- Ticket worktree: " + filepath.Join(f.ws, "acme-api"), "- Range: " + sha1 + ".." + sha2,
		"Number your findings from 201 (W2-acme-api-M201", "never in the worktree", "shows the command you ran and the output it printed", "The lead's brief:\ncontract change in api/"} {
		if !strings.Contains(string(args), s) {
			t.Errorf("args miss %q:\n%s", s, args)
		}
	}
	cwd, _ := os.ReadFile(filepath.Join(f.calls, "cwd"))
	if strings.TrimSpace(string(cwd)) != f.ws {
		t.Errorf("cwd = %s", cwd)
	}
	env, _ := os.ReadFile(filepath.Join(f.calls, "env"))
	for _, s := range []string{"SANDBOX_ADD_DIRS=" + f.vault, "SANDBOX_QUIET=1", "HOME=/h"} {
		if !strings.Contains(string(env), s) {
			t.Errorf("env misses %s", s)
		}
	}
	for _, s := range []string{"AGENT=", "ANTHROPIC_API_KEY"} {
		if strings.Contains(string(env), "\n"+s) || strings.HasPrefix(string(env), s) {
			t.Errorf("env passes %s", s)
		}
	}
}

func TestModels(t *testing.T) {
	_, b := setup(t, "")
	if r := last(call(t, b, map[string]any{"op": "models"})); r.Status != "ok" || strings.Join(r.Models, ",") != "gpt-5.6-sol,glm-5" {
		t.Fatalf("reply = %+v", r)
	}
}

func TestRefused(t *testing.T) {
	f, b := setup(t, writesReview)
	if err := os.Symlink(f.ws, filepath.Join(f.ws, "linked")); err != nil {
		t.Fatal(err)
	}
	cases := map[string]any{
		"other ticket":    review(map[string]any{"ticket": "MAN-2"}),
		"bad ticket":      review(map[string]any{"ticket": "../x"}),
		"unknown repo":    review(map[string]any{"repo": "other"}),
		"bad range":       review(map[string]any{"range": "HEAD~3..HEAD"}),
		"option in range": review(map[string]any{"range": "--output=x..abcdefa"}),
		"model":           review(map[string]any{"model": "kimi-k3"}),
		"wave":            review(map[string]any{"wave": 0}),
		"brief too long":  review(map[string]any{"brief": strings.Repeat("x", maxBrief+1)}),
		"unknown field":   review(map[string]any{"command": "rm -rf /"}),
		"unknown op":      map[string]any{"op": "run"},
		"not json":        "rm -rf /",
		"two objects":     `{"op":"models"} {"op":"models"}`,
		"repo is symlink": review(map[string]any{"repo": "linked"}),
	}
	ws, _ := json.Marshal(map[string]any{"id": "MAN-1", "vault": f.vault, "repos": []map[string]string{{"slug": "acme-api"}, {"slug": "linked"}}})
	write(t, filepath.Join(f.ws, "workspace.json"), string(ws))
	for name, req := range cases {
		if r := last(call(t, b, req)); r.Status != "refused" {
			t.Errorf("%s: reply = %+v", name, r)
		}
	}
	if _, err := os.Stat(filepath.Join(f.calls, "args")); err == nil {
		t.Error("a refused request ran kiro")
	}
}

func TestVaultMustBeMounted(t *testing.T) {
	_, b := setup(t, writesReview)
	b.c.AddDirs = nil
	if r := last(call(t, b, review(nil))); r.Status != "refused" || !strings.Contains(r.Detail, "vault") {
		t.Fatalf("reply = %+v", r)
	}
}

func TestUsageLimit(t *testing.T) {
	_, b := setup(t, "echo 'Error: monthly usage limit reached for this account' >&2\nexit 1\n")
	if r := last(call(t, b, review(nil))); r.Status != "usage-limit" || !strings.Contains(r.Detail, "usage limit") {
		t.Fatalf("reply = %+v", r)
	}
}

func TestFailed(t *testing.T) {
	_, b := setup(t, "echo 'login required' >&2\nexit 3\n")
	if r := last(call(t, b, review(nil))); r.Status != "failed" || !strings.Contains(r.Detail, "login required") {
		t.Fatalf("reply = %+v", r)
	}
	_, b = setup(t, "exit 0\n")
	if r := last(call(t, b, review(nil))); r.Status != "failed" || !strings.Contains(r.Detail, "without writing") {
		t.Fatalf("reply = %+v", r)
	}
}

func TestTimeoutKillsTheRun(t *testing.T) {
	f, b := setup(t, "trap '' TERM\necho $$ > \"$CALLS/pid\"\nsleep 30 &\nwait\n")
	b.c.Timeout, b.c.KillGrace = 300*time.Millisecond, 200*time.Millisecond
	start := time.Now()
	if r := last(call(t, b, review(nil))); r.Status != "timeout" {
		t.Fatalf("reply = %+v", r)
	}
	if time.Since(start) > 5*time.Second {
		t.Fatal("the run outlived its timeout")
	}
	pid, _ := os.ReadFile(filepath.Join(f.calls, "pid"))
	if _, err := os.Stat("/proc/" + strings.TrimSpace(string(pid))); err == nil {
		t.Error("the run is still alive")
	}
}

func TestClientGoneCancels(t *testing.T) {
	f, b := setup(t, "echo $$ > \"$CALLS/pid\"\necho started\nsleep 30\n")
	sock := filepath.Join(t.TempDir(), "s")
	ln, _ := net.Listen("unix", sock)
	defer ln.Close()
	go b.serve(context.Background(), ln)
	conn, _ := net.Dial("unix", sock)
	line, _ := json.Marshal(review(nil))
	_, _ = conn.Write(append(line, '\n'))
	sc := bufio.NewScanner(conn)
	sc.Scan()
	conn.Close()
	pid, _ := os.ReadFile(filepath.Join(f.calls, "pid"))
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat("/proc/" + strings.TrimSpace(string(pid))); err != nil {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("the run outlived its client")
}
