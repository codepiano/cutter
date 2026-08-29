#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
"$script_dir/stop.sh"
exec "$script_dir/start.sh"
