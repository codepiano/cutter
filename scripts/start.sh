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
if ! ensure_app; then
  print -u2 "Cutter 构建失败。日志：${log_file}"
  tail -n 40 "$log_file" >&2 || true
  exit 1
fi
if ! open "$app_bundle" >>"$log_file" 2>&1; then
  print -u2 "Cutter 打开失败。日志：${log_file}"
  tail -n 40 "$log_file" >&2 || true
  exit 1
fi
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
