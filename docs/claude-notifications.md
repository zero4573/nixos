# Claude Code settings and notifications

`modules/apps/claude/claude-code.nix` generates Claude Code's `settings.json`
(shared by the host and claude-sandbox).

## Notifications

herdr is the notifier ([terminal-tools](./terminal-tools.md)): it sends a desktop
notification when an agent finishes or needs you in an unfocused pane. So Claude
Code's own terminal notifications are off
(`preferredNotifChannel = "notifications_disabled"`), and so are tix's desktop
pings (`env.TIX_NOTIFY = "0"`).

## Hooks and status line

- `SessionStart`: herdr's hook reports the session id to the herdr pane, which
  herdr needs to resume it. Outside herdr (no `HERDR_*` environment, as in the
  sandbox) it does nothing. It lives here because `settings.json` is Nix-owned
  and `herdr integration install claude` would be overwritten.
- The status line shows context tokens and the plan's 5h/7d limit usage as
  `/usage` does (limits only for subscribers), with `↻` counting down to the
  sooner reset (hence `refreshInterval = 60`). Levels: `ctx_warn` from 150k,
  `ctx_hot` from 250k tokens; a limit's `_warn` from 80% used, `_hot` from 95%.
  Claude's own line colours warn yellow and hot bold red.
- Inside herdr the same fields are reported as the pane's sidebar tokens, only
  when they changed; `SessionEnd` (`clear`) removes them. In the sandbox they go
  one per line to `$SANDBOX_HERDR_DIR/usage` and the launcher reports them
  ([claude-sandbox](./claude-sandbox.md#other-pieces)).

## Settings

- `cleanupPeriodDays = 90` (default 30): transcripts are what `claude --continue`
  resumes, e.g. a ticket session restarted by `tix start`.
- `permissions.deny` keeps `git push` denied on the host (`claude-open`), where it
  would use the full SSH agent; the sandbox's managed settings lift it and pushes
  go through [git-ssh-broker](./git-ssh-broker.md). Rovo tools that consume
  credits are denied ([sandbox-proxy](./sandbox-proxy.md#atlassian-rovo)).
- Ticket and spec sessions add stricter denies in their own
  `.claude/settings.json` ([tix](./tix.md)).
- Nix keeps `~/.claude` and every claude profile home from `agent-configure`
  (listed in `profiles.json` and marked `.agent-profile`) current, so
  `AGENT=<profile>` sessions get the same settings, skills and agents.
  `<home>/skills` and `<home>/agents` are wiped and repopulated on every switch.
