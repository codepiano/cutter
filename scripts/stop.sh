#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
source "$script_dir/service-common.sh"
pids="$(owned_pids)"
if [[ -z "$pids" ]]; then
  clear_pid
  print "Cutter 未运行。"
  exit 0
fi
while read -r pid; do
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
done <<< "$pids"
for _ in {1..20}; do
  [[ -z "$(owned_pids)" ]] && break
  sleep 0.25
done
while read -r pid; do
  [[ -n "$pid" ]] || continue
  if is_owned_process "$pid"; then
    kill -9 "$pid" 2>/dev/null || true
  fi
done <<< "$(owned_pids)"
clear_pid
print "Cutter 已停止。"
