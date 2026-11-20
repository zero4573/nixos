package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
)

const maxBody = 8 << 20

type Config struct {
	Listen  string            `json:"listen"`
	Servers map[string]Server `json:"servers"`
}

type Server struct {
	Upstream   string   `json:"upstream"`
	AuthEnv    string   `json:"authEnv"`
	GatedTools []string `json:"gatedTools,omitempty"`
	AllowOps   []string `json:"allowOps,omitempty"`
}

func loadConfig(path string) (Config, error) {
	var cfg Config
	b, err := os.ReadFile(path)
	if err != nil {
		return cfg, err
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&cfg); err != nil {
		return cfg, fmt.Errorf("%s: %w", path, err)
	}
	if cfg.Listen == "" {
		cfg.Listen = ":8080"
	}
	return cfg, nil
}

type route struct {
	name     string
	upstream *url.URL
	auth     string
	gated    map[string]bool
	allow    map[string]bool
	proxy    *httputil.ReverseProxy
}

type guard struct{ routes map[string]*route }

func newGuard(cfg Config, getenv func(string) string) (http.Handler, error) {
	g := &guard{routes: map[string]*route{}}
	for name, s := range cfg.Servers {
		u, err := url.Parse(s.Upstream)
		if err != nil || u.Scheme == "" || u.Host == "" {
			return nil, fmt.Errorf("server %s: bad upstream %q", name, s.Upstream)
		}
		auth := getenv(s.AuthEnv)
		if s.AuthEnv == "" || auth == "" {
			return nil, fmt.Errorf("server %s: no credential in $%s", name, s.AuthEnv)
		}
		r := &route{name: name, upstream: u, auth: auth, gated: set(s.GatedTools), allow: set(s.AllowOps)}
		r.proxy = &httputil.ReverseProxy{
			Rewrite: func(pr *httputil.ProxyRequest) {
				pr.Out.URL.Scheme = r.upstream.Scheme
				pr.Out.URL.Host = r.upstream.Host
				pr.Out.URL.Path = r.upstream.Path
				pr.Out.URL.RawPath = ""
				pr.Out.Host = r.upstream.Host
				pr.Out.Header.Set("Authorization", r.auth)
			},
			FlushInterval: -1,
		}
		g.routes["/"+name] = r
	}
	return g, nil
}

func set(xs []string) map[string]bool {
	m := map[string]bool{}
	for _, x := range xs {
		m[x] = true
	}
	return m
}

func (g *guard) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	r, ok := g.routes[req.URL.Path]
	if !ok {
		http.NotFound(w, req)
		return
	}
	req.Header.Del("Authorization")
	if len(r.gated) > 0 && req.Method == http.MethodPost {
		if !r.check(w, req) {
			return
		}
	}
	r.proxy.ServeHTTP(w, req)
}

func (r *route) check(w http.ResponseWriter, req *http.Request) bool {
	if enc := req.Header.Get("Content-Encoding"); enc != "" && enc != "identity" {
		http.Error(w, "mcp-guard: encoded request bodies aren't accepted", http.StatusUnsupportedMediaType)
		return false
	}
	body, err := io.ReadAll(io.LimitReader(req.Body, maxBody+1))
	if err != nil {
		http.Error(w, "mcp-guard: can't read the request", http.StatusBadRequest)
		return false
	}
	if len(body) > maxBody {
		http.Error(w, "mcp-guard: request too large", http.StatusRequestEntityTooLarge)
		return false
	}
	msgs, batch, err := parseMessages(body)
	if err != nil {
		http.Error(w, "mcp-guard: not a JSON-RPC message: "+err.Error(), http.StatusBadRequest)
		return false
	}
	var refusals []string
	refused := make([]bool, len(msgs))
	for i, m := range msgs {
		if reason := r.refusal(m); reason != "" {
			refused[i] = true
			refusals = append(refusals, reason)
		}
	}
	if len(refusals) == 0 {
		req.Body = io.NopCloser(bytes.NewReader(body))
		req.ContentLength = int64(len(body))
		return true
	}
	for _, reason := range refusals {
		log.Printf("refused %s: %s", r.name, reason)
	}
	var out []any
	for i, m := range msgs {
		if len(m.ID) == 0 {
			continue
		}
		if refused[i] {
			out = append(out, toolError(m.ID, r.refusal(m)))
		} else {
			out = append(out, rpcError(m.ID, "mcp-guard: the batch holds a refused tool call, so none of it was sent"))
		}
	}
	w.Header().Set("Content-Type", "application/json")
	if batch {
		_ = json.NewEncoder(w).Encode(out)
	} else if len(out) == 1 {
		_ = json.NewEncoder(w).Encode(out[0])
	} else {
		w.WriteHeader(http.StatusAccepted)
	}
	return false
}

type message struct {
	ID     json.RawMessage
	Method string
	Params json.RawMessage
}

func object(b []byte) (map[string]json.RawMessage, error) {
	// encoding/json matches struct keys case-insensitively and parsers
	// disagree on which copy of a repeated key wins; the upstream matches exactly
	dec := json.NewDecoder(bytes.NewReader(b))
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	if d, ok := tok.(json.Delim); !ok || d != '{' {
		return nil, errors.New("not an object")
	}
	m := map[string]json.RawMessage{}
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return nil, err
		}
		key, ok := tok.(string)
		if !ok {
			return nil, errors.New("not an object")
		}
		if _, dup := m[key]; dup {
			return nil, fmt.Errorf("key %q appears twice", key)
		}
		var v json.RawMessage
		if err := dec.Decode(&v); err != nil {
			return nil, err
		}
		m[key] = v
	}
	if _, err := dec.Token(); err != nil {
		return nil, err
	}
	if dec.More() {
		return nil, errors.New("trailing data")
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, errors.New("trailing data")
	}
	return m, nil
}

func str(m map[string]json.RawMessage, key string) (string, error) {
	raw, ok := m[key]
	if !ok {
		return "", nil
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return "", fmt.Errorf("%q isn't a string", key)
	}
	return s, nil
}

func readMessage(b []byte) (message, error) {
	o, err := object(b)
	if err != nil {
		return message{}, err
	}
	method, err := str(o, "method")
	if err != nil {
		return message{}, err
	}
	return message{ID: o["id"], Method: method, Params: o["params"]}, nil
}

func parseMessages(body []byte) ([]message, bool, error) {
	t := bytes.TrimSpace(body)
	if len(t) == 0 {
		return nil, false, errors.New("empty body")
	}
	if t[0] == '[' {
		var raws []json.RawMessage
		if err := json.Unmarshal(t, &raws); err != nil {
			return nil, true, err
		}
		ms := make([]message, 0, len(raws))
		for _, raw := range raws {
			m, err := readMessage(raw)
			if err != nil {
				return nil, true, err
			}
			ms = append(ms, m)
		}
		return ms, true, nil
	}
	m, err := readMessage(t)
	if err != nil {
		return nil, false, err
	}
	return []message{m}, false, nil
}

func (r *route) refusal(m message) string {
	if m.Method != "tools/call" {
		return ""
	}
	p, err := object(m.Params)
	if err != nil {
		return "a tools/call whose params can't be read"
	}
	tool, err := str(p, "name")
	if err != nil {
		return "a tools/call whose name can't be read"
	}
	if !r.gated[tool] {
		return ""
	}
	op := ""
	if raw, ok := p["arguments"]; ok {
		a, err := object(raw)
		if err != nil {
			return fmt.Sprintf("%s with arguments that can't be read", tool)
		}
		if op, err = str(a, "name"); err != nil {
			return fmt.Sprintf("%s with an operation name that can't be read", tool)
		}
	}
	if op == "" {
		return fmt.Sprintf("%s without an operation name", tool)
	}
	if !r.allow[op] {
		return fmt.Sprintf("%s %s is not allowed from the sandbox (sandbox-proxy's allowlist for %s; do it yourself on the host)", tool, op, r.name)
	}
	return ""
}

func toolError(id json.RawMessage, text string) map[string]any {
	return map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"result": map[string]any{
			"content": []map[string]string{{"type": "text", "text": "mcp-guard: " + text}},
			"isError": true,
		},
	}
}

func rpcError(id json.RawMessage, text string) map[string]any {
	return map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"error":   map[string]any{"code": -32600, "message": text},
	}
}
