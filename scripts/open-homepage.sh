#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
source "$script_dir/service-common.sh"
ensure_app
open "$app_bundle"
