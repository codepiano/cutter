#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
app_dir="$project_dir/.build/Cutter.app"

"$project_dir/scripts/build-dev.sh" >/dev/null

mkdir -p "$app_dir/Contents/MacOS"
cp "$project_dir/.build/manual/CutterMac" "$app_dir/Contents/MacOS/CutterMac"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir" >/dev/null

print "$app_dir"
