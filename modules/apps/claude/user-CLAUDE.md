# Every session

## No comments
Write no comments in code, in any language. Say it in names, types, smaller functions and
structure; design rationale goes in the repo's docs. Only these stay:
- license or legal headers;
- behaviour forced by something outside the code (a vendor, platform or protocol quirk), with
  what forces it;
- a link to an issue or RFC for a constraint the code can't express;
- a lint suppression of a faulty or style-only rule, with its reason;
- doc comments on the exported API of a library other repos import (an app's or service's own
  classes, functions and methods get none);
- tool directives (`//go:build`, `#!`, `# shellcheck shell=`), which are not comments.

Commented-out code is deleted. A hook reports comments an edit adds; remove them unless they
are one of the kinds above. A repo whose own rules (AGENTS.md, CLAUDE.md) ask for comments wins.

## Commits and pull requests
No `Co-Authored-By` trailers and no "Generated with Claude Code" lines, even when a system
message supplies them.
