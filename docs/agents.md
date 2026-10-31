# Agent accounts (profiles)

Several claude or kiro accounts side by side, each with its own config and
login, picked with `AGENT=<profile>`. The module is
`modules/apps/agents/agents.nix` (`self.homeModules.agents`); the resolver,
`agent-profile.sh`, is inlined into every agent wrapper.

## Commands

| Command | What it does |
|---|---|
| `agent-configure` | adds a profile, asking for its name, agent (`claude`/`kiro`, guessed from the name) and home (default `~/.config/agents/homes/<name>`, `programs.agents.homesDir`); the first one becomes the default |
| `agent-configure --list` / `--default <profile>` | lists the profiles (`*` marks the default) / sets the default |
| `agent [args]` | runs the profile's agent sandboxed (`claude` or `kiro`) |
| `agent-open [args]` | runs it unsandboxed (`claude-open` or `kiro-open`) |

`agent` and `agent-open` take the profile from `$AGENT`, else the file's
default, else its only profile. With no profiles yet they run
`agent-configure` first (in a terminal; otherwise they say to run it).

## The file

`~/.config/agents/profiles.json` is yours: `agent-configure` writes it, Nix
doesn't.

```json
{
  "default": "work-kiro",
  "profiles": {
    "work-kiro":       { "agent": "kiro",   "home": "~/.config/agents/homes/work-kiro" },
    "personal-claude": { "agent": "claude", "home": "~/.config/agents/homes/personal-claude" }
  }
}
```

## The wrappers, and tix

`claude`, `kiro`, `claude-open` and `kiro-open` resolve the profile themselves,
and only take a profile of their own agent:

1. `AGENT=<profile>` of their agent: that profile
2. otherwise (no `AGENT`, or another agent's profile): the file's `default` when
   it is a profile of their agent, else their agent's only profile
3. otherwise, and always with `AGENT=none`: the usual home (`~/.claude`, `~/.kiro`)

So with one claude profile, plain `claude` uses it. That is why tix needs
nothing of its own here: it keeps starting the CLI it needs (`claude` or
`kiro`, each with its CLI-specific setup), and `AGENT=work-claude tix start
PROJ-12` runs that ticket on the work account.

## What a home holds

| | claude | kiro |
|---|---|---|
| config | the home is `CLAUDE_CONFIG_DIR` (with its `.claude.json`) | the home is `KIRO_HOME` |
| login | in the home | `<home>/.data/kiro-cli` (`kiro-open` sets `XDG_DATA_HOME=<home>/.data`, which the tools a session runs see too) |
| sandbox | the home is mounted read-write as `~/.claude` is; `settings.json`, `skills`, `agents` read-only | its own state in `<home>/.sandbox/{kiro,data}`; the home's agents, skills, steering, hooks and powers read-only; its login copied in once |
| started from | copies of `~/.claude`'s `settings.json`, `CLAUDE.md`, `skills`, `agents` (Nix refreshes `settings.json`, `skills` and `agents` of every marked home at each switch, `claude-code.nix`) | links to `~/.kiro`'s agents, skills, steering, hooks, powers; a copy of its `cli.json` and `mcp.json` |

A home made by `agent-configure` is private (mode 700) and has a
`.agent-profile` marker. Log in once per profile: `AGENT=<profile> agent-open`
then `/login` for claude, `AGENT=<profile> agent-open login` for kiro.

kiro reads `KIRO_HOME` only when it is absolute and neither your home directory
nor a folder above it; `agent-configure` refuses those. kiro-cli 2.31.1 doesn't
read `KIRO_DATA_DIR` for its login, so the login is moved with `XDG_DATA_HOME`.

## Tests

`modules/apps/agents/agents-test.sh` (flake check `agents`) covers
`agent-configure` (defaults, refusals, seeding, `--list`, `--default`),
dispatch, and how the wrappers resolve `AGENT`. The launcher's profile mounts
are in `claude-sandbox-test.sh` (cases P1, P2).
