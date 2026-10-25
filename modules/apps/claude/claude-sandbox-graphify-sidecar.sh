# Entrypoint for the graphify sidecar container that claude-sandbox runs in
# the same podman pod as Claude (so the two share localhost). Expects:
#   /graphify-requirements.txt  the hashed lock installed into /opt/graphify
#                        (see claude-sandbox-graphify-install.sh)
#   GRAPHIFY_PORT        port to serve the MCP endpoint on (127.0.0.1 only)
#   GRAPHIFY_API_KEY     bearer token the MCP endpoint requires
#   PROJECT_ROOT         project to graph (graph lands in $PROJECT_ROOT/graphify-out)
#   EXTRA_ROOTS          optional, newline-separated: more codebases to graph
#                        (the session's --add-dir directories), each into its
#                        own graphify-out; then all graphs are merged into one
#                        and that's what gets served. They build in the
#                        background and join the merge as each finishes, so
#                        a large one never holds up the server.
set -eu

# Shared install into the claude-sandbox-graphify volume (sets $venv)
# shellcheck source=claude-sandbox-graphify-install.sh
. /graphify-install.sh

export PATH="$venv/bin:$PATH"
# Progress shows in `podman logs` as it happens, not when a buffer fills
export PYTHONUNBUFFERED=1
cd "$PROJECT_ROOT"

# Code-only AST pass: local tree-sitter, no LLM, incremental via graphify-out/cache
graphify update "$PROJECT_ROOT"

# Rebuild the graph on file changes; the MCP server reloads graph.json on mtime change
graphify watch "$PROJECT_ROOT" &

if [ -z "${EXTRA_ROOTS:-}" ]; then
  exec python3 -m graphify.serve "$PROJECT_ROOT/graphify-out/graph.json" \
    --transport http --host 127.0.0.1 --port "$GRAPHIFY_PORT"
fi

# Several roots: serve one merged graph (node ids prefixed per root),
# re-merged whenever one of the per-root graphs changes or a new one is
# ready. $ready lists the graphs to merge, one per line: the project's now,
# each extra root's once its first build succeeds (one that fails is left
# out rather than taking the project's graph down with it).
merged=/tmp/graphify-merged
serve_graph="$merged/graph.json"
ready="$merged/ready"
mkdir -p "$merged"
echo "$PROJECT_ROOT/graphify-out/graph.json" > "$ready"

(
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    echo "graphify: building a graph of $r"
    if (cd "$r" && graphify update "$r"); then
      echo "$r/graphify-out/graph.json" >> "$ready"
      (cd "$r" && exec graphify watch "$r") &
    else
      echo "graphify: couldn't build a graph of $r, leaving it out" >&2
    fi
  done <<EOF
$EXTRA_ROOTS
EOF
  wait
) &

# merge-graphs writes atomically, so the server never reads a half-written
# file; a single ready graph is copied the same way
merge() {
  if [ "$(wc -l < "$ready")" -lt 2 ]; then
    cp "$(cat "$ready")" "$serve_graph.tmp" && mv "$serve_graph.tmp" "$serve_graph"
  else
    # shellcheck disable=SC2046 # split on newlines only: one graph per line
    (IFS='
'; exec graphify merge-graphs $(cat "$ready") --out "$serve_graph") >/dev/null
  fi
}
signature() {
  while IFS= read -r g; do stat -c '%n %Y %s' "$g" 2>/dev/null || echo -; done < "$ready"
}
last="$(signature)"
merge
(
  while sleep 5; do
    now="$(signature)"
    [ "$now" = "$last" ] && continue
    last="$now"
    if merge; then
      echo "graphify: merged $(wc -l < "$ready") graphs"
    else
      echo "graphify: re-merging the graphs failed, serving the previous merge" >&2
    fi
  done
) &

exec python3 -m graphify.serve "$serve_graph" \
  --transport http --host 127.0.0.1 --port "$GRAPHIFY_PORT"
