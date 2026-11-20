package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 || os.Args[1] != "serve" {
		fmt.Fprintln(os.Stderr, "usage: review-broker serve --socket <path> --workspace <dir> --kiro <launcher> --model <name>...")
		os.Exit(2)
	}
	os.Exit(serveMain(os.Args[2:]))
}
