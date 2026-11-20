package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type seen struct {
	path, auth, host string
	body             []byte
	n                int
}

func upstreamAndGuard(t *testing.T) (*httptest.Server, *seen) {
	t.Helper()
	s := &seen{}
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.n++
		s.path, s.auth, s.host = r.URL.Path, r.Header.Get("Authorization"), r.Host
		s.body, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":{"ok":true}}`))
	}))
	t.Cleanup(up.Close)
	cfg := Config{Servers: map[string]Server{
		"atlassian": {
			Upstream: up.URL + "/v2/mcp", AuthEnv: "AUTH_A",
			GatedTools: []string{"executeWrite", "executeDestructive"},
			AllowOps:   []string{"createBitbucketRepoPullRequest", "addBitbucketRepoPullRequestComment"},
		},
		"open": {Upstream: up.URL + "/mcp", AuthEnv: "AUTH_O"},
	}}
	h, err := newGuard(cfg, func(k string) string {
		return map[string]string{"AUTH_A": "Basic YTpi", "AUTH_O": "Bearer o"}[k]
	})
	if err != nil {
		t.Fatal(err)
	}
	g := httptest.NewServer(h)
	t.Cleanup(g.Close)
	return g, s
}

func call(tool, op string) string {
	return `{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"` + tool +
		`","arguments":{"name":"` + op + `","cloudId":"c","inputs":{}}}}`
}

func post(t *testing.T, url, body string, hdr ...string) (*http.Response, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, url, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	for i := 0; i+1 < len(hdr); i += 2 {
		req.Header.Set(hdr[i], hdr[i+1])
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp, b
}

func TestForwardsWithCredential(t *testing.T) {
	g, s := upstreamAndGuard(t)
	body := `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`
	resp, _ := post(t, g.URL+"/atlassian", body, "Authorization", "Basic stolen")
	if resp.StatusCode != 200 || s.n != 1 {
		t.Fatalf("status %d, upstream calls %d", resp.StatusCode, s.n)
	}
	if s.path != "/v2/mcp" || s.auth != "Basic YTpi" || !strings.HasPrefix(s.host, "127.0.0.1:") || string(s.body) != body {
		t.Errorf("upstream saw path %q auth %q host %q body %q", s.path, s.auth, s.host, s.body)
	}
}

func TestAllowedOperationGoesThrough(t *testing.T) {
	g, s := upstreamAndGuard(t)
	for _, b := range []string{
		call("executeWrite", "createBitbucketRepoPullRequest"),
		call("executeRead", "listBitbucketRepoPipelines"),
		call("getJiraIssue", ""),
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`,
	} {
		if resp, _ := post(t, g.URL+"/atlassian", b); resp.StatusCode != 200 {
			t.Errorf("%s: status %d", b, resp.StatusCode)
		}
	}
	if s.n != 4 {
		t.Errorf("upstream calls %d, want 4", s.n)
	}
}

func TestRefusedOperations(t *testing.T) {
	g, s := upstreamAndGuard(t)
	for _, b := range []string{
		call("executeDestructive", "mergeBitbucketRepoPullRequest"),
		call("executeDestructive", "declineBitbucketRepoPullRequest"),
		call("executeWrite", "createBitbucketRepoCommit"),
		call("executeWrite", "createBitbucketRepoBranch"),
		call("executeWrite", "runBitbucketRepoPipeline"),
		call("executeWrite", ""),
		`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"executeWrite","arguments":"x"}}`,
		`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":"x"}`,
		`{"jsonrpc":"2.0","id":7,"Method":"x","method":"tools/call","params":{"name":"executeDestructive","arguments":{"name":"mergeBitbucketRepoPullRequest"}}}`,
		`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"Name":"getJiraIssue","name":"executeDestructive","arguments":{"name":"mergeBitbucketRepoPullRequest"}}}`,
		`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"executeWrite","arguments":{"NAME":"createBitbucketRepoPullRequest","name":"createBitbucketRepoCommit"}}}`,
		`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"executeWrite","arguments":{"name":["createBitbucketRepoPullRequest"]}}}`,
		`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"executeWrite","arguments":{"name":"mergeBitbucketRepoPullRequest","name":"createBitbucketRepoPullRequest"}}}`,
		`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"executeDestructive","name":"getJiraIssue","arguments":{"name":"mergeBitbucketRepoPullRequest"}}}`,
	} {
		resp, out := post(t, g.URL+"/atlassian", b)
		var r struct {
			ID     int `json:"id"`
			Result struct {
				IsError bool `json:"isError"`
				Content []struct {
					Text string `json:"text"`
				} `json:"content"`
			} `json:"result"`
		}
		if err := json.Unmarshal(out, &r); err != nil || resp.StatusCode != 200 || r.ID != 7 || !r.Result.IsError ||
			len(r.Result.Content) != 1 || !strings.HasPrefix(r.Result.Content[0].Text, "mcp-guard: ") {
			t.Errorf("%s: status %d, response %s", b, resp.StatusCode, out)
		}
	}
	if s.n != 0 {
		t.Errorf("a refused call reached the upstream (%d calls)", s.n)
	}
}

func TestBatchWithARefusedCallSendsNothing(t *testing.T) {
	g, s := upstreamAndGuard(t)
	b := "[" + call("executeWrite", "createBitbucketRepoPullRequest") + "," +
		strings.Replace(call("executeDestructive", "mergeBitbucketRepoPullRequest"), `"id":7`, `"id":8`, 1) + "]"
	resp, out := post(t, g.URL+"/atlassian", b)
	var rs []map[string]any
	if err := json.Unmarshal(out, &rs); err != nil || resp.StatusCode != 200 || len(rs) != 2 {
		t.Fatalf("status %d, response %s", resp.StatusCode, out)
	}
	if rs[0]["error"] == nil || rs[1]["result"] == nil {
		t.Errorf("want an error for the allowed call and a tool error for the refused one: %s", out)
	}
	if s.n != 0 {
		t.Errorf("part of a refused batch reached the upstream")
	}
}

func TestUnreadableBodiesAreRefused(t *testing.T) {
	g, s := upstreamAndGuard(t)
	for _, b := range []string{"not json", `{"method":"tools/call","method":"x","id":1}`, `{"id":1}{"id":2}`, `[1]`} {
		if resp, _ := post(t, g.URL+"/atlassian", b); resp.StatusCode != 400 {
			t.Errorf("%s: status %d", b, resp.StatusCode)
		}
	}
	var zipped bytes.Buffer
	zw := gzip.NewWriter(&zipped)
	_, _ = zw.Write([]byte(call("executeDestructive", "mergeBitbucketRepoPullRequest")))
	_ = zw.Close()
	if resp, _ := post(t, g.URL+"/atlassian", zipped.String(), "Content-Encoding", "gzip"); resp.StatusCode != 415 {
		t.Errorf("gzip: status %d", resp.StatusCode)
	}
	big := `{"jsonrpc":"2.0","id":1,"method":"x","params":{"p":"` + strings.Repeat("a", maxBody) + `"}}`
	if resp, _ := post(t, g.URL+"/atlassian", big); resp.StatusCode != 413 {
		t.Errorf("oversized: status %d", resp.StatusCode)
	}
	if s.n != 0 {
		t.Errorf("an unreadable request reached the upstream")
	}
}

func TestUngatedServerAndUnknownRoutes(t *testing.T) {
	g, s := upstreamAndGuard(t)
	if resp, _ := post(t, g.URL+"/open", call("executeDestructive", "anything")); resp.StatusCode != 200 || s.path != "/mcp" || s.auth != "Bearer o" {
		t.Errorf("open server: status %d, path %q, auth %q", resp.StatusCode, s.path, s.auth)
	}
	for _, p := range []string{"/", "/atlassian/x", "/nope"} {
		if resp, _ := post(t, g.URL+p, "{}"); resp.StatusCode != 404 {
			t.Errorf("%s: status %d", p, resp.StatusCode)
		}
	}
}

func TestConfigErrors(t *testing.T) {
	if _, err := newGuard(Config{Servers: map[string]Server{"a": {Upstream: "https://x/mcp", AuthEnv: "MISSING"}}}, func(string) string { return "" }); err == nil {
		t.Error("a server without its credential started")
	}
	if _, err := newGuard(Config{Servers: map[string]Server{"a": {Upstream: "mcp", AuthEnv: "A"}}}, func(string) string { return "x" }); err == nil {
		t.Error("a relative upstream was accepted")
	}
	p := filepath.Join(t.TempDir(), "c.json")
	_ = os.WriteFile(p, []byte(`{"servers":{"a":{"upstream":"https://x","authEnv":"A","allowOP":[]}}}`), 0o600)
	if _, err := loadConfig(p); err == nil {
		t.Error("a misspelled field was accepted")
	}
	_ = os.WriteFile(p, []byte(`{"servers":{}}`), 0o600)
	if c, err := loadConfig(p); err != nil || c.Listen != ":8080" {
		t.Errorf("default listen: %+v, %v", c, err)
	}
}
