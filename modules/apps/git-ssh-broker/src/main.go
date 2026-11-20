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
