package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"
)

// The remotes brokered by default: GitHub and Bitbucket Cloud, with their
// port-443 alternatives
var defaultHosts = []string{
	"github.com", "ssh.github.com",
	"bitbucket.org", "ssh.bitbucket.org", "altssh.bitbucket.org",
}

type listFlag []string

func (l *listFlag) String() string     { return strings.Join(*l, ",") }
func (l *listFlag) Set(v string) error { *l = append(*l, v); return nil }

func serveMain(args []string) int {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	gitSock := fs.String("git-socket", "", "unix socket for git's transport (GIT_SSH_BROKER_SOCKET)")
	agentSock := fs.String("agent-socket", "", "unix socket of the signing-only agent (SSH_AUTH_SOCK in the sandbox)")
	upstream := fs.String("upstream-agent", os.Getenv("SSH_AUTH_SOCK"), "the host's ssh-agent socket")
	sshBin := fs.String("ssh", "ssh", "the host's ssh command")
	var hosts, signingKeys listFlag
	fs.Var(&hosts, "allow-host", "an allowed remote host (repeatable; default GitHub and Bitbucket)")
	fs.Var(&signingKeys, "signing-key", "an OpenSSH public key the agent may sign git signatures with (repeatable)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *gitSock == "" {
		fmt.Fprintln(os.Stderr, "git-ssh-broker serve: --git-socket is required")
		return 2
	}
	logger := log.New(os.Stderr, "git-ssh-broker: ", 0)
	if len(hosts) == 0 {
		hosts = defaultHosts
	}
	t := &transport{hosts: map[string]bool{}, sshCmd: []string{*sshBin}, logf: logger.Printf}
	for _, h := range hosts {
		t.hosts[strings.ToLower(h)] = true
	}

	var listeners []net.Listener
	listen := func(path string) (net.Listener, error) {
		os.Remove(path)
		l, err := net.Listen("unix", path)
		if err == nil {
			os.Chmod(path, 0o600)
			listeners = append(listeners, l)
		}
		return l, err
	}
	gl, err := listen(*gitSock)
	if err != nil {
		logger.Print(err)
		return 1
	}
	go t.serve(gl)

	if *agentSock != "" {
		switch {
		case len(signingKeys) == 0:
			logger.Print("no --signing-key: the signing agent is off")
		case *upstream == "":
			logger.Print("no upstream agent (--upstream-agent or SSH_AUTH_SOCK): the signing agent is off")
		default:
			keys, err := loadSigningKeys(signingKeys)
			if err != nil {
				logger.Print(err)
				return 1
			}
			al, err := listen(*agentSock)
			if err != nil {
				logger.Print(err)
				return 1
			}
			a := &signingAgent{upstream: *upstream, keys: keys, logf: logger.Printf}
			go a.serve(al)
		}
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	<-sig
	for _, l := range listeners {
		l.Close() // removes the socket file
	}
	return 0
}
