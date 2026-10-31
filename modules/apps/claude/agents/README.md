# Claude Code subagents

Each `.md` file here (other than this README) is one Claude Code subagent,
copied into `~/.claude/agents/` by `modules/apps/claude/claude-code.nix` on
every switch. That directory is fully Nix-owned: anything put there by hand
is deleted on the next rebuild.

None right now: the ticket workflow's agents ship in the tix
plugin (`tix:lead`, `tix:task`, `tix:mechanical`,
`tix:reviewer`, `tix:reviewer-deep` and `tix:analyst`), loaded
per session.
