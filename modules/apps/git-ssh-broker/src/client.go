package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// parseSSHArgs reads the arguments git gives an ssh command of the "ssh"
// variant: [-p port] [-4|-6] [-o option]... [user@]host command
func parseSSHArgs(args []string) (request, error) {
	var req request
	var pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "-p" || a == "-o":
			if i+1 >= len(args) {
				return req, fmt.Errorf("%s needs a value", a)
			}
			i++
			if a == "-p" {
				p, err := strconv.Atoi(args[i])
				if err != nil {
					return req, fmt.Errorf("bad port %q", args[i])
				}
				req.Port = p
			}
			// -o: only SendEnv=GIT_PROTOCOL comes from git; the value is
			// passed on through the request instead
		case a == "-4" || a == "-6":
		case strings.HasPrefix(a, "-") && len(pos) == 0:
			return req, fmt.Errorf("unsupported ssh option %q (only git's transport is brokered)", a)
		default:
			pos = append(pos, a)
		}
	}
	if len(pos) != 2 {
		return req, fmt.Errorf("expected <host> <command>, got %q", pos)
	}
	req.Host = pos[0]
	if u, h, ok := strings.Cut(pos[0], "@"); ok {
		req.User, req.Host = u, h
	}
	req.Command = pos[1]
	return req, nil
}

func clientMain(args []string) int {
	req, err := parseSSHArgs(args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "git-ssh-broker: %v\n", err)
		return 255
	}
	req.GitProtocol = os.Getenv("GIT_PROTOCOL")
	// git runs its ssh command from inside the repository: its common git
	// dir holds the objects the broker checks a push against
	if out, err := exec.Command("git", "rev-parse", "--path-format=absolute", "--git-common-dir").Output(); err == nil {
		req.GitDir = strings.TrimSpace(string(out))
	}

	sock := os.Getenv("GIT_SSH_BROKER_SOCKET")
	if sock == "" {
		fmt.Fprintln(os.Stderr, "git-ssh-broker: GIT_SSH_BROKER_SOCKET is not set")
		return 255
	}
	conn, err := net.Dial("unix", sock)
	if err != nil {
		fmt.Fprintf(os.Stderr, "git-ssh-broker: can't reach the broker at %s: %v\n", sock, err)
		return 255
	}
	defer conn.Close()
	return runClient(conn, req, os.Stdin, os.Stdout, os.Stderr)
}

// runClient sends the request, then relays stdin to the broker and the
// broker's frames to stdout/stderr, and returns the remote's exit status
func runClient(conn net.Conn, req request, stdin io.Reader, stdout, stderr io.Writer) int {
	if err := writeRequest(conn, req); err != nil {
		fmt.Fprintf(stderr, "git-ssh-broker: %v\n", err)
		return 255
	}
	fw := &frameWriter{w: conn}
	go func() {
		if fw.copyFrames(frameStdin, stdin) == nil {
			fw.frame(frameStdinEOF, nil)
		}
	}()
	r := bufio.NewReader(conn)
	for {
		typ, data, err := readFrame(r)
		if err != nil {
			fmt.Fprintf(stderr, "git-ssh-broker: connection to the broker lost: %v\n", err)
			return 255
		}
		switch typ {
		case frameStdout:
			if _, err := stdout.Write(data); err != nil {
				return 255
			}
		case frameStderr:
			stderr.Write(data)
		case frameExit:
			if len(data) != 4 {
				return 255
			}
			return int(uint32(data[0])<<24 | uint32(data[1])<<16 | uint32(data[2])<<8 | uint32(data[3]))
		}
	}
}
