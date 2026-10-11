# Entrypoint for the graphify sidecar container that claude-sandbox runs in
# the same podman pod as Claude (so the two share localhost). Expects:
#   /graphify-requirements.txt  the hashed lock installed into /opt/graphify
#                        (see claude-sandbox-graphify-install.sh)
#   GRAPHIFY_PORT        port to serve the MCP endpoint on (127.0.0.1 only)
#   GRAPHIFY_API_KEY     bearer token the MCP endpoint requires
#   PROJECT_ROOT         project to graph (graph lands in $PROJECT_ROOT/graphify-out)
set -eu

graph="$PROJECT_ROOT/graphify-out/graph.json"

# Shared install into the claude-sandbox-graphify volume (sets $venv)
# shellcheck source=claude-sandbox-graphify-install.sh
. /graphify-install.sh

export PATH="$venv/bin:$PATH"
cd "$PROJECT_ROOT"

# Code-only AST pass: local tree-sitter, no LLM, incremental via graphify-out/cache
graphify update "$PROJECT_ROOT"

# Rebuild the graph on file changes; the MCP server reloads graph.json on mtime change
graphify watch "$PROJECT_ROOT" &

exec python3 -m graphify.serve "$graph" \
  --transport http --host 127.0.0.1 --port "$GRAPHIFY_PORT"
