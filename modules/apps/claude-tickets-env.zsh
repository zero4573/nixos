# ct with this shell's CLAUDE_SANDBOX_* variables for the one session it
# starts, e.g.
#
#   CLAUDE_SANDBOX_PORTS=3000,5173 ct start PROJ-12
#
# A ticket window gets its environment from the tmux server, not from this
# shell, so exported variables don't reach the sandbox. ct does put
# $CLAUDE_TICKETS_CLAUDE on the window's command line, so they go there as
# `env VAR=value claude`: per session, nothing shared through the server.
# ct splits that variable on whitespace, so values containing any are
# skipped.
ct() {
  local v
  local -a kv
  for v in ${(M)${(k)parameters}:#CLAUDE_SANDBOX_*}; do
    if [[ ${(P)v} == *[[:space:]]* ]]; then
      print -u2 "ct: not passing $v to the session (its value contains whitespace)"
      continue
    fi
    kv+=("$v=${(P)v}")
  done
  (( $#kv )) && local -x CLAUDE_TICKETS_CLAUDE="env $kv ${CLAUDE_TICKETS_CLAUDE:-claude}"
  command ct "$@"
}
