#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
source "$script_dir/service-common.sh"
if pid="$(read_pid 2>/dev/null)" && is_owned_process "$pid"; then
  print "Cutter 已在运行 (pid $pid)。"
  exit 0
fi
if pids="$(owned_pids)" && [[ -n "$pids" ]]; then
  pid="${pids%%$'\n'*}"
  print -r -- "$pid" >"$pid_file"
  print "Cutter 已在运行 (pid $pid)。"
  exit 0
fi
clear_pid
ensure_app
open "$app_bundle" >>"$log_file" 2>&1
for _ in {1..40}; do
  if pids="$(owned_pids)" && [[ -n "$pids" ]]; then
    pid="${pids%%$'\n'*}"
    print -r -- "$pid" >"$pid_file"
    print "Cutter 已启动 (pid $pid)。"
    exit 0
  fi
  sleep 0.25
done
clear_pid
print "Cutter 启动失败。请查看 $log_file。" >&2
exit 1
