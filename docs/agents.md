# Agent accounts (profiles)

Several claude or kiro accounts side by side, each with its own config and
login, picked with `AGENT=<profile>`. The module is
`modules/apps/agents/agents.nix` (`self.homeModules.agents`); the resolver,
`agent-profile.sh`, is inlined into every agent wrapper.

## Commands

| Command | What it does |
|---|---|
| `agent-configure` | adds a profile, asking for its name, agent (`claude`/`kiro`, guessed from the name) and home (default `~/.config/agents/homes/<name>`, `programs.agents.homesDir`). It becomes its agent's default when that agent has none, and `agent`'s when there is none; otherwise it asks |
| `agent-configure --agent claude\|kiro` | chooses (from that agent's profiles) or adds what `claude` / `kiro` use without `AGENT` |
| `agent-configure --default [<profile>]` | the profile `agent` / `agent-open` use without `AGENT`, and its agent's default (no argument: asks) |
| `agent-configure --list` | lists the profiles: `*` marks `agent`'s default, `+` each agent's |
| `agent [args]` | runs the profile's agent sandboxed (`claude` or `kiro`) |
| `agent-open [args]` | runs it unsandboxed (`claude-open` or `kiro-open`) |

`agent` and `agent-open` take the profile from `$AGENT`, else the file's
`default`. Nothing is guessed: with no profiles or no default, they run
`agent-configure` (in a terminal; otherwise they fail and say what to run).

## The file

`~/.config/agents/profiles.json` is yours: `agent-configure` writes it, Nix
doesn't.

```json
{
  "default": "work-kiro",
  "defaults": { "claude": "personal-claude", "kiro": "work-kiro" },
  "profiles": {
    "work-kiro":       { "agent": "kiro",   "home": "~/.config/agents/homes/work-kiro" },
    "personal-claude": { "agent": "claude", "home": "~/.config/agents/homes/personal-claude" }
  }
}
```

`default` is what `agent` / `agent-open` run; `defaults.<agent>` is what that
CLI's own commands (`claude`, `kiro`, ...) use.

## The wrappers, and tix

`claude`, `kiro`, `claude-open` and `kiro-open` resolve the profile themselves,
and only take a profile of their own agent:

1. `AGENT=<profile>` of their agent: that profile
2. otherwise (no `AGENT`, or another agent's profile): `defaults.<agent>`
3. none set: `agent-configure --agent <agent>` asks you to choose or add one and
   keeps the answer (in a terminal; otherwise the command fails and says to run
   it). Nothing is guessed, not even when the agent has only one profile.

Every run is on a profile: there is no way back to the CLI's usual home. To keep
using `~/.claude` or `~/.kiro`, add a profile with that home.

That is why tix needs nothing of its own here: it keeps starting the CLI it
needs (`claude` or `kiro`, each with its CLI-specific setup), and
`AGENT=work-claude tix start PROJ-12` runs that ticket on the work account.
A `tix` run without a terminal (none that start sessions) needs the default set.

## What a home holds

| | claude | kiro |
|---|---|---|
| config | the home is `CLAUDE_CONFIG_DIR` (with its `.claude.json`) | the home is `KIRO_HOME` |
| login | in the home | `<home>/.data/kiro-cli` (`kiro-open` sets `XDG_DATA_HOME=<home>/.data`, which the tools a session runs see too) |
| sandbox | the home is mounted read-write as `~/.claude` is; `settings.json`, `skills`, `agents` read-only | its own state and login in `<home>/.sandbox/{kiro,data}` (a chat logs in there by itself); the home's agents, skills, steering, hooks and powers read-only |
| started from | copies of `~/.claude`'s `settings.json`, `CLAUDE.md`, `skills`, `agents` (Nix refreshes `settings.json`, `skills` and `agents` of every marked home at each switch, `claude-code.nix`) | links to `~/.kiro`'s agents, skills, steering, hooks, powers; a copy of its `cli.json` and `mcp.json` |

A home made by `agent-configure` is private (mode 700) and has a
`.agent-profile` marker. Log in once per profile: `AGENT=<profile> agent-open`
then `/login` for claude, `AGENT=<profile> agent-open login` for kiro. A kiro
profile's sandbox has a login of its own, which its first chat asks for.

A claude profile's `.claude.json` starts past Claude's first-run screens:
when it's missing, empty or `{}`, the wrappers write
`hasCompletedOnboarding`, `theme: "dark"` and
`shiftEnterKeyBindingInstalled` (`agents_claude_seed` in `agent-profile.sh`),
and never touch it after that. Only the login is left. The folder-trust
dialog is skipped in the sandbox alone (`CLAUDE_CODE_SANDBOXED=1`, see
claude-sandbox.md); `claude-open` still asks.

kiro reads `KIRO_HOME` only when it is absolute and neither your home directory
nor a folder above it; `agent-configure` refuses those. kiro-cli 2.31.1 doesn't
read `KIRO_DATA_DIR` for its login, so the login is moved with `XDG_DATA_HOME`.

## Tests

`modules/apps/agents/agents-test.sh` (flake check `agents`) covers
`agent-configure` (defaults, refusals, seeding, `--list`, `--default`),
dispatch, and how the wrappers resolve `AGENT`. The launcher's profile mounts
are in `claude-sandbox-test.sh` (cases P1, P2).
