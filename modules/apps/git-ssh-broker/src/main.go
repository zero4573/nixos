// git-ssh-broker lets a sandbox use git over SSH, and sign commits, without
// ever holding an SSH key or reaching the host's ssh-agent.
//
// It runs on the host, next to one sandbox, and serves two unix sockets that
// are mounted into it:
//
//   - the git socket: the sandbox's GIT_SSH_COMMAND is `git-ssh-broker
//     client`, which forwards git's transport command (git-upload-pack,
//     git-receive-pack, git-upload-archive) here. The broker checks the host
//     and repo path, runs the host's own ssh (your ~/.ssh/config and agent)
//     and relays the stream. A push is read before it is forwarded: deleting
//     a branch or tag, moving a tag and any non-fast-forward update (a force
//     push) are refused, so those stay manual steps on the host.
//   - the agent socket: the sandbox's SSH_AUTH_SOCK. A filtering ssh-agent
//     that lists only the configured signing keys and signs only git
//     signatures (SSHSIG blobs in the "git" namespace); SSH logins and every
//     other agent request are refused.
//
// Usage:
//
//	git-ssh-broker serve --git-socket <path> [--agent-socket <path>
//	    --upstream-agent <path> --signing-key <key.pub>...] [--allow-host <h>...]
//	git-ssh-broker client [ssh args...] <[user@]host> <command>
//	    (as GIT_SSH_COMMAND with GIT_SSH_VARIANT=ssh; the socket comes from
//	    GIT_SSH_BROKER_SOCKET)
package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: git-ssh-broker serve|client ...")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "serve":
		os.Exit(serveMain(os.Args[2:]))
	case "client":
		os.Exit(clientMain(os.Args[2:]))
	default:
		fmt.Fprintf(os.Stderr, "git-ssh-broker: unknown command %q\n", os.Args[1])
		os.Exit(2)
	}
}
