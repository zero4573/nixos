# Local Claude Code skills

Each subdirectory here is one Claude Code skill, materialized declaratively
into `~/.claude/skills/` by `modules/apps/claude/claude-code.nix` (and from there,
automatically visible inside `claude-sandbox` too, via its existing
`~/.claude` bind mount — see `modules/apps/claude/claude-sandbox.sh`).

To add a skill, create `modules/apps/claude/skills/<skill-name>/SKILL.md`:

```markdown
---
name: skill-name
description: One-line description of when Claude should use this skill.
---

Skill instructions body...
```

A skill directory may also contain supporting files (scripts, references,
etc.) alongside `SKILL.md` — the whole directory is copied as-is.

`~/.claude/skills/` is fully Nix-owned: it is wiped and repopulated from
this directory (plus any configured `skillSources` in `claude-code.nix`) on
every `home-manager switch` / `nixos-rebuild switch`. Anything placed there
by hand outside of Nix will be deleted on the next rebuild.

The one exception to "pinned in Nix" is the `graphify` skill: on every switch
the `claudeCodeGraphifySkill` activation step in `claude-code.nix` resolves
graphify's latest GitHub release, downloads its `SKILL.md` + `references/`
only when the release tag changed (cached in `~/.cache/claude-code/graphify-skill`),
and installs it as `~/.claude/skills/graphify/`. If GitHub is unreachable,
the cached copy is reinstalled instead.
