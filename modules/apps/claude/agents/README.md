# Claude Code subagents

Each `.md` file here (other than this README) is one Claude Code subagent,
copied into `~/.claude/agents/` by `modules/apps/claude/claude-code.nix` on
every switch. That directory is fully Nix-owned: anything put there by hand
is deleted on the next rebuild.

None right now: the ticket workflow's agents ship in the claude-tickets
plugin (`tickets:lead`, `tickets:task`, `tickets:mechanical`,
`tickets:reviewer`, `tickets:reviewer-deep` and `tickets:analyst`), loaded
per session.
