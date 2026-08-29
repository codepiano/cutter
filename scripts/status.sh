#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
source "$script_dir/service-common.sh"
if pid="$(read_pid 2>/dev/null)" && is_owned_process "$pid"; then
  print "Cutter 运行中 (pid $pid)。"
  exit 0
fi
if pids="$(owned_pids)" && [[ -n "$pids" ]]; then
  pid="${pids%%$'\n'*}"
  print -r -- "$pid" >"$pid_file"
  print "Cutter 运行中 (pid $pid)。"
  exit 0
fi
clear_pid
print "Cutter 未运行。"
exit 1
