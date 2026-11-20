zmodload zsh/datetime
autoload -Uz add-zsh-hook

# width of p10k's transient prompt `❯ `: must match POWERLEVEL9K_PROMPT_CHAR_* in p10k.zsh
typeset -gi _CMD_TIMING_PROMPT_WIDTH=2
typeset -g _CMD_TIMING_GREY=$'\e[38;5;242m'

_cmd_timing_preexec() {
  typeset -gF _cmd_timing_start=$EPOCHREALTIME

  local stamp
  strftime -s stamp '%H:%M:%S' $EPOCHSECONDS

  # p10k has redrawn the line as `❯ <cmd>` and the cursor sits on the row below
  local cmd=${1:-$2}
  local last=${cmd##*$'\n'}
  local -i width=${(m)#last}
  [[ $cmd == *$'\n'* ]] || (( width += _CMD_TIMING_PROMPT_WIDTH ))
  local -i col=$(( width % COLUMNS ))

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

  # zsh's PROMPT_SP trick: COLUMNS-1 spaces then \r lands on column 1 of an empty row or of a fresh one
  printf '%*s\r' $(( COLUMNS - 1 )) ''
  print -r -- $'\e['$(( COLUMNS - ${#msg} + 1 ))'G'"$_CMD_TIMING_GREY$msg"$'\e[0m'
}

add-zsh-hook preexec _cmd_timing_preexec
add-zsh-hook precmd _cmd_timing_precmd
