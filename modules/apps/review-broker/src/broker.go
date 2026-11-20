package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
)

const (
	maxRequest = 64 << 10
	maxBrief   = 8000
	maxLogLine = 2000
	agentName  = "tix-reviewer-deep"
)

type listFlag []string

func (l *listFlag) String() string     { return strings.Join(*l, ",") }
func (l *listFlag) Set(v string) error { *l = append(*l, v); return nil }

type config struct {
	Workspace   string
	Kiro        string
	Models      []string
	AddDirs     []string
	Effort      string
	MaxParallel int
	Timeout     time.Duration
	KillGrace   time.Duration
	Env         []string
}

func serveMain(args []string) int {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	var c config
	var socket string
	var models, dirs listFlag
	fs.StringVar(&socket, "socket", "", "unix socket to serve")
	fs.StringVar(&c.Workspace, "workspace", "", "the session's ticket workspace")
	fs.StringVar(&c.Kiro, "kiro", "", "the kiro sandbox launcher")
	fs.Var(&models, "model", "an allowed kiro model (repeatable)")
	fs.Var(&dirs, "add-dir", "a read-write directory of the session, mounted for kiro too (repeatable)")
	fs.StringVar(&c.Effort, "effort", "high", "kiro's --effort")
	fs.IntVar(&c.MaxParallel, "max-parallel", 2, "reviews running at once")
	fs.DurationVar(&c.Timeout, "timeout", 45*time.Minute, "a review's time limit")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	c.Models, c.AddDirs, c.KillGrace = models, dirs, 20*time.Second
	if socket == "" || c.Workspace == "" || c.Kiro == "" || len(c.Models) == 0 {
		fmt.Fprintln(os.Stderr, "review-broker: --socket, --workspace, --kiro and --model are required")
		return 2
	}
	c.Env = hostEnv(os.Environ())
	b, err := newBroker(c)
	if err != nil {
		fmt.Fprintln(os.Stderr, "review-broker:", err)
		return 2
	}
	_ = os.Remove(socket)
	ln, err := net.Listen("unix", socket)
	if err != nil {
		fmt.Fprintln(os.Stderr, "review-broker:", err)
		return 1
	}
	defer ln.Close()
	if err := os.Chmod(socket, 0o600); err != nil {
		fmt.Fprintln(os.Stderr, "review-broker:", err)
		return 1
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	go func() { <-ctx.Done(); ln.Close() }()
	log.Printf("review-broker: serving %s for %s (models %s)", socket, c.Workspace, strings.Join(c.Models, ", "))
	b.serve(ctx, ln)
	return 0
}

var keepEnv = regexp.MustCompile(`^(HOME|USER|LOGNAME|PATH|LANG|LC_[A-Z]+|TZ|XDG_[A-Z_]+|DBUS_SESSION_BUS_ADDRESS|SSH_AUTH_SOCK|WAYLAND_DISPLAY|DISPLAY)=`)

func hostEnv(env []string) []string {
	var out []string
	for _, e := range env {
		if keepEnv.MatchString(e) {
			out = append(out, e)
		}
	}
	return out
}

type broker struct {
	c   config
	sem chan struct{}
	wg  sync.WaitGroup
}

func newBroker(c config) (*broker, error) {
	for _, m := range c.Models {
		if !modelRe.MatchString(m) {
			return nil, fmt.Errorf("model %q: not a kiro model name", m)
		}
	}
	if c.MaxParallel < 1 {
		c.MaxParallel = 1
	}
	ws, err := filepath.Abs(c.Workspace)
	if err != nil {
		return nil, err
	}
	c.Workspace = ws
	return &broker{c: c, sem: make(chan struct{}, c.MaxParallel)}, nil
}

func (b *broker) serve(ctx context.Context, ln net.Listener) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			b.wg.Wait()
			return
		}
		b.wg.Add(1)
		go func() {
			defer b.wg.Done()
			defer conn.Close()
			b.handle(ctx, conn)
		}()
	}
}

type request struct {
	Op     string `json:"op"`
	Ticket string `json:"ticket"`
	Wave   int    `json:"wave"`
	Repo   string `json:"repo"`
	Range  string `json:"range"`
	Model  string `json:"model"`
	Brief  string `json:"brief"`
}

type reply struct {
	Log        string   `json:"log,omitempty"`
	Status     string   `json:"status,omitempty"`
	Detail     string   `json:"detail,omitempty"`
	ReviewFile string   `json:"reviewFile,omitempty"`
	Models     []string `json:"models,omitempty"`
}

var (
	ticketRe = regexp.MustCompile(`^[A-Z][A-Z0-9]*-[0-9]+$`)
	slugRe   = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,99}$`)
	rangeRe  = regexp.MustCompile(`^[0-9a-f]{7,40}\.\.[0-9a-f]{7,40}$`)
	modelRe  = regexp.MustCompile(`^[a-z0-9][a-z0-9.-]{0,63}$`)
	limitRe  = regexp.MustCompile(`(?i)usage limit|limit reached|quota|out of credits|insufficient credits|credit limit|monthly limit|rate limit|throttl|too many requests`)
)

func (b *broker) handle(ctx context.Context, conn net.Conn) {
	enc := json.NewEncoder(conn)
	var mu sync.Mutex
	send := func(r reply) {
		mu.Lock()
		defer mu.Unlock()
		_ = enc.Encode(r)
	}
	line, err := bufio.NewReaderSize(io.LimitReader(conn, maxRequest), maxRequest).ReadBytes('\n')
	if err != nil && !(errors.Is(err, io.EOF) && len(line) > 0) {
		send(reply{Status: "refused", Detail: "one JSON request line, at most 64 KiB"})
		return
	}
	req, err := parseRequest(line)
	if err != nil {
		send(reply{Status: "refused", Detail: err.Error()})
		return
	}
	if req.Op == "models" {
		send(reply{Status: "ok", Models: b.c.Models})
		return
	}
	job, err := b.check(req)
	if err != nil {
		log.Printf("review-broker: refused %s wave %d %s: %v", req.Ticket, req.Wave, req.Repo, err)
		send(reply{Status: "refused", Detail: err.Error()})
		return
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		_, _ = io.Copy(io.Discard, conn)
		cancel()
	}()
	select {
	case b.sem <- struct{}{}:
	default:
		send(reply{Log: "review-broker: waiting for a free slot"})
		select {
		case b.sem <- struct{}{}:
		case <-ctx.Done():
			return
		}
	}
	defer func() { <-b.sem }()
	r := b.run(ctx, job, func(l string) { send(reply{Log: l}) })
	log.Printf("review-broker: %s wave %d %s on %s: %s %s", req.Ticket, req.Wave, req.Repo, req.Model, r.Status, r.Detail)
	send(r)
}

func parseRequest(line []byte) (request, error) {
	var req request
	dec := json.NewDecoder(strings.NewReader(string(line)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		return req, fmt.Errorf("bad request: %w", err)
	}
	if dec.More() {
		return req, errors.New("bad request: one JSON object only")
	}
	switch req.Op {
	case "models", "review":
		return req, nil
	}
	return req, fmt.Errorf("unknown op %q (models, review)", req.Op)
}

type job struct {
	req        request
	ticketDir  string
	reviewFile string
	base       int
	prompt     string
}

type wsRepo struct {
	Slug string `json:"slug"`
}

type wsFile struct {
	ID    string   `json:"id"`
	Vault string   `json:"vault"`
	Repos []wsRepo `json:"repos"`
}

func (b *broker) check(req request) (job, error) {
	j := job{req: req}
	switch {
	case !ticketRe.MatchString(req.Ticket):
		return j, errors.New("ticket: not a ticket ID")
	case req.Wave < 1 || req.Wave > 9999:
		return j, errors.New("wave: 1 to 9999")
	case !slugRe.MatchString(req.Repo):
		return j, errors.New("repo: not a repo slug")
	case !rangeRe.MatchString(req.Range):
		return j, errors.New("range: <sha>..<sha>, 7 to 40 hex digits each")
	case len(req.Brief) > maxBrief || !utf8.ValidString(req.Brief) || strings.ContainsRune(req.Brief, 0):
		return j, fmt.Errorf("brief: UTF-8 text up to %d bytes", maxBrief)
	}
	idx := -1
	for i, m := range b.c.Models {
		if m == req.Model {
			idx = i
		}
	}
	if idx < 0 {
		return j, fmt.Errorf("model %q is not allowed (%s)", req.Model, strings.Join(b.c.Models, ", "))
	}
	j.base = 100 * (idx + 1)
	data, err := os.ReadFile(filepath.Join(b.c.Workspace, "workspace.json"))
	if err != nil {
		return j, fmt.Errorf("workspace.json: %w", err)
	}
	var ws wsFile
	if err := json.Unmarshal(data, &ws); err != nil {
		return j, fmt.Errorf("workspace.json: %w", err)
	}
	if ws.ID != req.Ticket {
		return j, fmt.Errorf("ticket %s is not this workspace's (%s)", req.Ticket, ws.ID)
	}
	found := false
	for _, r := range ws.Repos {
		found = found || r.Slug == req.Repo
	}
	if !found {
		return j, fmt.Errorf("repo %s is not in workspace.json", req.Repo)
	}
	if err := plainDir(filepath.Join(b.c.Workspace, req.Repo)); err != nil {
		return j, fmt.Errorf("repo %s: %w", req.Repo, err)
	}
	vault := filepath.Clean(ws.Vault)
	if !filepath.IsAbs(vault) || !b.mounted(vault) {
		return j, fmt.Errorf("vault %s is not one of the session's directories", ws.Vault)
	}
	notes, _ := filepath.Glob(filepath.Join(vault, "tickets", "*", req.Ticket, req.Ticket+".md"))
	if len(notes) != 1 {
		return j, fmt.Errorf("ticket %s: %d notes in the vault, want 1", req.Ticket, len(notes))
	}
	j.ticketDir = filepath.Dir(notes[0])
	for _, d := range []string{j.ticketDir, filepath.Dir(j.ticketDir), filepath.Join(vault, "tickets")} {
		if err := plainDir(d); err != nil {
			return j, fmt.Errorf("ticket folder: %w", err)
		}
	}
	j.reviewFile = filepath.Join(j.ticketDir, "reviews", fmt.Sprintf("wave-%d-%s-%s.md", req.Wave, req.Repo, req.Model))
	j.prompt = b.prompt(j)
	return j, nil
}

func (b *broker) mounted(p string) bool {
	for _, d := range append([]string{b.c.Workspace}, b.c.AddDirs...) {
		d = filepath.Clean(d)
		if p == d || strings.HasPrefix(p, d+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

func plainDir(p string) error {
	st, err := os.Lstat(p)
	if err != nil {
		return err
	}
	if !st.IsDir() {
		return fmt.Errorf("%s is not a directory (a symlink?)", p)
	}
	return nil
}

func (b *broker) prompt(j job) string {
	r := j.req
	var s strings.Builder
	fmt.Fprintf(&s, "You are tix-reviewer-deep, reviewing on %s: one of several model families reviewing this wave, so judge independently.\n", r.Model)
	fmt.Fprintf(&s, "Follow the tix-wave-review skill exactly for ticket %s, wave %d, repo %s.\n", r.Ticket, r.Wave, r.Repo)
	fmt.Fprintf(&s, "- Ticket worktree: %s\n", filepath.Join(b.c.Workspace, r.Repo))
	fmt.Fprintf(&s, "- Range: %s\n", r.Range)
	fmt.Fprintf(&s, "- Ticket folder: %s\n", j.ticketDir)
	fmt.Fprintf(&s, "- Number your findings from %d (W%d-%s-M%d, S%d, C%d...), so they don't collide with the other reviews of this wave.\n", j.base+1, r.Wave, r.Repo, j.base+1, j.base+1, j.base+1)
	fmt.Fprintf(&s, "- Write the review to %s and nothing else. Never edit code, commit, push or change branches.\n", j.reviewFile)
	s.WriteString("- Run your experiments in a directory from mktemp -d, never in the worktree, and remove it when done.\n")
	s.WriteString("- A must-fix shows the command you ran and the output it printed; a suspicion no run confirmed is a should-fix or goes under Dropped.\n")
	if b := strings.TrimSpace(r.Brief); b != "" {
		fmt.Fprintf(&s, "\nThe lead's brief:\n%s\n", b)
	}
	return s.String()
}

func (b *broker) run(ctx context.Context, j job, emit func(string)) reply {
	ctx, cancel := context.WithTimeout(ctx, b.c.Timeout)
	defer cancel()
	cmd := exec.Command(b.c.Kiro, "chat", "--no-interactive", "--trust-all-tools",
		"--agent", agentName, "--model", j.req.Model, "--effort", b.c.Effort, j.prompt)
	cmd.Dir = b.c.Workspace
	cmd.Env = append(append([]string{}, b.c.Env...),
		"SANDBOX_ADD_DIRS="+strings.Join(b.c.AddDirs, ":"),
		"SANDBOX_QUIET=1",
	)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	pr, pw := io.Pipe()
	cmd.Stdout, cmd.Stderr = pw, pw
	cmd.Stdin = nil
	if err := cmd.Start(); err != nil {
		return reply{Status: "failed", Detail: "starting kiro: " + err.Error()}
	}
	var tail []string
	limited := false
	done := make(chan struct{})
	go func() {
		defer close(done)
		sc := bufio.NewScanner(pr)
		sc.Buffer(make([]byte, 64<<10), 1<<20)
		for sc.Scan() {
			l := sc.Text()
			if len(l) > maxLogLine {
				l = l[:maxLogLine] + "…"
			}
			limited = limited || limitRe.MatchString(l)
			tail = append(tail, l)
			if len(tail) > 20 {
				tail = tail[1:]
			}
			emit(l)
		}
		_, _ = io.Copy(io.Discard, pr)
	}()
	waited := make(chan error, 1)
	go func() { waited <- cmd.Wait(); pw.Close() }()
	var err error
	select {
	case err = <-waited:
	case <-ctx.Done():
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		select {
		case err = <-waited:
		case <-time.After(b.c.KillGrace):
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			err = <-waited
		}
	}
	<-done
	last := ""
	if len(tail) > 0 {
		last = tail[len(tail)-1]
	}
	switch {
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return reply{Status: "timeout", Detail: fmt.Sprintf("no review after %s", b.c.Timeout)}
	case ctx.Err() != nil:
		return reply{Status: "failed", Detail: "cancelled: the client went away"}
	case err == nil && regularFile(j.reviewFile):
		return reply{Status: "ok", ReviewFile: j.reviewFile}
	case limited:
		return reply{Status: "usage-limit", Detail: last}
	case err == nil:
		return reply{Status: "failed", Detail: "kiro exited without writing " + j.reviewFile}
	}
	return reply{Status: "failed", Detail: fmt.Sprintf("kiro: %v: %s", err, last)}
}

func regularFile(p string) bool {
	st, err := os.Lstat(p)
	return err == nil && st.Mode().IsRegular()
}
