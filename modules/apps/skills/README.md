# Local Claude Code skills

Each subdirectory here is one Claude Code skill, materialized declaratively
into `~/.claude/skills/` by `modules/apps/claude-code.nix` (and from there,
automatically visible inside `claude-sandbox` too, via its existing
`~/.claude` bind mount — see `modules/apps/claude-sandbox.sh`).

To add a skill, create `modules/apps/skills/<skill-name>/SKILL.md`:

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
