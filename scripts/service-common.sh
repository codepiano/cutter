#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
state_dir="$project_dir/.control-panel"
pid_file="$state_dir/cutter.pid"
log_file="$state_dir/logs/cutter.log"
app_bundle="$project_dir/.build/Cutter.app"
executable="$app_bundle/Contents/MacOS/CutterMac"
mkdir -p "$state_dir/logs"
read_pid() {
  [[ -f "$pid_file" ]] || return 1
  local pid
  pid="$(tr -d '[:space:]' < "$pid_file")"
  [[ "$pid" == <-> && "$pid" != 0 ]] || return 1
  print -r -- "$pid"
}
process_command() { ps -p "$1" -o command= 2>/dev/null | sed 's/^[[:space:]]*//'; }
is_owned_process() { local pid="$1"; kill -0 "$pid" 2>/dev/null || return 1; [[ "$(process_command "$pid")" == *"$executable"* ]]; }
owned_pids() {
  ps -axo pid=,command= 2>/dev/null | awk -v executable="$executable" \
    'index($0, executable) && $0 !~ /awk -v executable/ { print $1 }'
}
clear_pid() { rm -f "$pid_file"; }
ensure_app() { [[ -x "$executable" ]] || "$project_dir/scripts/build-app.sh" >>"$log_file" 2>&1; }
