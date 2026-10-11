# Per-command timing in grey: the start time right-aligned on the (transient)
# command line, and a right-aligned `took <duration>` line under its output.
#
#   ❯ make build                     14:02:11
#   ...build output...
#                                     took 3.2s
#
# Plain preexec/precmd hooks, independent of p10k internals -- the only
# coupling is _CMD_TIMING_PROMPT_WIDTH below.

zmodload zsh/datetime
autoload -Uz add-zsh-hook

# Display width of the transient prompt `❯ ` that p10k leaves in front of each
# accepted command; must match POWERLEVEL9K_PROMPT_CHAR_* in p10k.zsh.
typeset -gi _CMD_TIMING_PROMPT_WIDTH=2
# Same 256-colour grey as p10k's $grey.
typeset -g _CMD_TIMING_GREY=$'\e[38;5;242m'

_cmd_timing_preexec() {
  typeset -gF _cmd_timing_start=$EPOCHREALTIME

  local stamp
  strftime -s stamp '%H:%M:%S' $EPOCHSECONDS

  # By now p10k has redrawn the line as `❯ <cmd>` and the cursor sits on the
  # row below. Work out how much of the command's last row is used.
  local cmd=${1:-$2}
  local last=${cmd##*$'\n'}
  local -i width=${(m)#last}
  [[ $cmd == *$'\n'* ]] || (( width += _CMD_TIMING_PROMPT_WIDTH ))
  local -i col=$(( width % COLUMNS ))

  # Skip the stamp rather than overwrite the command when the row is full.
  (( width > 0 && col == 0 )) && return
  (( col + 1 + ${#stamp} > COLUMNS )) && return

  print -nr -- $'\e[1A\e['$(( COLUMNS - ${#stamp} + 1 ))'G'"$_CMD_TIMING_GREY$stamp"$'\e[0m\e[1B\r'
}

_cmd_timing_precmd() {
  (( ${+_cmd_timing_start} )) || return
  local -F elapsed=$(( EPOCHREALTIME - _cmd_timing_start ))
  unset _cmd_timing_start

  local dur
  if (( elapsed < 1 )); then
    printf -v dur '%.0fms' $(( elapsed * 1000 ))
  elif (( elapsed < 60 )); then
    printf -v dur '%.1fs' $elapsed
  else
    local -i s=$elapsed
    if (( s < 3600 )); then
      printf -v dur '%dm %02ds' $(( s / 60 )) $(( s % 60 ))
    else
      printf -v dur '%dh %02dm %02ds' $(( s / 3600 )) $(( s % 3600 / 60 )) $(( s % 60 ))
    fi
  fi
  local msg="took $dur"

  # zsh's PROMPT_SP trick: COLUMNS-1 spaces then \r lands on column 1 of the
  # current row if it was empty, or of a fresh row if the output didn't end
  # with a newline -- either way nothing gets overwritten.
  printf '%*s\r' $(( COLUMNS - 1 )) ''
  print -r -- $'\e['$(( COLUMNS - ${#msg} + 1 ))'G'"$_CMD_TIMING_GREY$msg"$'\e[0m'
}

add-zsh-hook preexec _cmd_timing_preexec
add-zsh-hook precmd _cmd_timing_precmd
