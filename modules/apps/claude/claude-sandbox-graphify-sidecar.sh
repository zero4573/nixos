# Entrypoint for the graphify sidecar container that claude-sandbox runs in
# the same podman pod as Claude (so the two share localhost). Expects:
#   GRAPHIFY_VERSION     graphifyy release to install into /opt/graphify
#   GRAPHIFY_PORT        port to serve the MCP endpoint on (127.0.0.1 only)
#   GRAPHIFY_API_KEY     bearer token the MCP endpoint requires
#   PROJECT_ROOT         project to graph (graph lands in $PROJECT_ROOT/graphify-out)
#   VAULT_EXPORT_DIR     optional; Obsidian export target inside the chosen vault
set -eu

venv=/opt/graphify/venv
graph="$PROJECT_ROOT/graphify-out/graph.json"

# /opt/graphify is a named volume shared by every sandbox, so the pip
# install happens once per version; flock guards concurrent first starts.
exec 9>/opt/graphify/.lock
flock 9
if [ "$(cat /opt/graphify/.version 2>/dev/null || true)" != "$GRAPHIFY_VERSION" ]; then
  echo "graphify: installing graphifyy==$GRAPHIFY_VERSION"
  rm -rf "$venv"
  python3 -m venv "$venv"
  "$venv/bin/pip" install --quiet --no-cache-dir "graphifyy[mcp,watch]==$GRAPHIFY_VERSION"
  echo "$GRAPHIFY_VERSION" > /opt/graphify/.version
fi
flock -u 9

export PATH="$venv/bin:$PATH"
cd "$PROJECT_ROOT"

# Code-only AST pass: local tree-sitter, no LLM, incremental via graphify-out/cache
graphify update "$PROJECT_ROOT"

# Rebuild the graph on file changes; the MCP server reloads graph.json on mtime change
graphify watch "$PROJECT_ROOT" &

# Re-export Obsidian notes whenever graph.json changes
if [ -n "${VAULT_EXPORT_DIR:-}" ]; then
  (
    last=""
    while :; do
      mtime="$(stat -c %Y "$graph" 2>/dev/null || true)"
      if [ -n "$mtime" ] && [ "$mtime" != "$last" ]; then
        last="$mtime"
        graphify export obsidian --graph "$graph" --dir "$VAULT_EXPORT_DIR" >/dev/null || true
      fi
      sleep 15
    done
  ) &
fi

exec python3 -m graphify.serve "$graph" \
  --transport http --host 127.0.0.1 --port "$GRAPHIFY_PORT"
