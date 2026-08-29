#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
app_dir="$project_dir/.build/Cutter.app"
signing_identity=${CUTTER_SIGNING_IDENTITY:-"Cutter Local Development"}

if ! security find-identity -v -p codesigning | rg -F "\"$signing_identity\"" >/dev/null; then
  print -u2 "Missing code-signing identity: $signing_identity"
  print -u2 "Run ./scripts/create-local-signing-identity.sh first, or set CUTTER_SIGNING_IDENTITY."
  exit 1
fi
identity_hash=$(security find-identity -v -p codesigning \
  | rg -F "\"$signing_identity\"" \
  | rg -o '[A-F0-9]{40}' \
  | head -1)

if [[ -z "$identity_hash" ]]; then
  print -u2 "Could not resolve a unique signing hash for: $signing_identity"
  exit 1
fi

"$project_dir/scripts/build-dev.sh" >/dev/null

mkdir -p "$app_dir/Contents/MacOS"
cp "$project_dir/.build/manual/CutterMac" "$app_dir/Contents/MacOS/CutterMac"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --sign "$identity_hash" "$app_dir" >/dev/null

print "$app_dir"
