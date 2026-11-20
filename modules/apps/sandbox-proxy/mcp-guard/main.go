package main

import (
	"flag"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	configPath := flag.String("config", "/etc/mcp-guard.json", "the guard's config (servers, upstreams, policies)")
	flag.Parse()
	log.SetFlags(0)
	log.SetPrefix("mcp-guard: ")

	cfg, err := loadConfig(*configPath)
	if err != nil {
		log.Fatal(err)
	}
	handler, err := newGuard(cfg, os.Getenv)
	if err != nil {
		log.Fatal(err)
	}
	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           handler,
		ReadHeaderTimeout: 30 * time.Second,
	}
	log.Printf("listening on %s for %d server(s)", cfg.Listen, len(cfg.Servers))
	log.Fatal(srv.ListenAndServe())
}
