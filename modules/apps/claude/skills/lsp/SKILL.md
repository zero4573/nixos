---
name: lsp
description: Use the LSP tool (language servers) instead of Grep to find a symbol's references, callers, callees, definition or implementations, or to list a file's or workspace's symbols, in Go, TypeScript/JavaScript, Ruby, Terraform, shell, YAML, Nix, Python or Dart/Flutter code. Use it before tracing usages or impact of a change by text search.
---

# Code navigation with the LSP tool

The LSP tool asks a language server, so its answers follow the code's
semantics: a method's references exclude same-named methods on other
types, comments and strings. Grep can't tell those apart. Prefer it when
the question is about a symbol:

- who calls this / what breaks if I change it: `incomingCalls`, `findReferences`
- what does this call: `outgoingCalls`
- where is it defined: `goToDefinition`
- what implements this interface: `goToImplementation`
- what's in this file: `documentSymbol`
- where is a symbol named X: `workspaceSymbol`
- its signature and docs: `hover`

Use Grep for text (log messages, config keys, SQL, templates, comments),
for files no server covers, and when the tool fails.

## Loading it

It is a deferred tool: load its schema first with ToolSearch
`select:LSP`, then call it.

## Calling it

- Every call takes `filePath` (absolute), and position operations a
  `line` and `character`, both **1-based**, as an editor shows them.
- Point the position at the symbol's name itself (the identifier in its
  declaration or in a use), not at the start of the line or at `func`.
  `workspaceSymbol` and `documentSymbol` give you positions to start from.
- Servers start on first use per language; a first call can be slow.

## Servers and quirks

- **Go** (gopls): reliable for every operation. Refs include tests.
- **TypeScript/JavaScript** (typescript-language-server): `findReferences`
  on some exported functions returns only the declaration. Use
  `incomingCalls` for callers, or `findReferences` from a call site.
- **Ruby** (ruby-lsp): indexes by name, not types, so references to a
  common method name (`call`, `save`) can include other classes'; check
  each hit. It works on any Ruby version's code. The first call may fail
  with "server is starting" while it indexes: wait a little and retry.
  It writes a self-ignored `.ruby-lsp/` in the working directory.
  ERB and HAML templates aren't covered: Grep them for helper and
  partial uses.
- **Terraform** (terraform-ls): `documentSymbol` lists a file's
  resources, variables and outputs; other operations work for
  references between them within a module.

- **Shell** (bash-language-server): functions and variables, references
  across the workspace's scripts.
- **YAML** (yaml-language-server): `documentSymbol` (the key tree) and
  `goToDefinition` for anchors; no `findReferences` or `hover`, so Grep
  for `*anchor` uses and keys.
- **Nix** (nixd): `documentSymbol`, `goToDefinition` and `findReferences`
  for let bindings; `hover` is usually empty.
- **Python** (basedpyright): every operation, with types in `hover`.
- **SQL, HAML, ERB**: no server; use Grep.

References are workspace-wide, and a ticket workspace holds every
worktree of a repo (including `tasks/`), so the same hit can show up once
per worktree: keep the ones under the checkout you're working in.

When results look incomplete (a server not covering a directory, a
generated file), cross-check with Grep rather than trusting either alone.
