#!/bin/zsh

set -euo pipefail

identity_name=${CUTTER_SIGNING_IDENTITY:-"Cutter Local Development"}
login_keychain=/Users/codepiano/Library/Keychains/login.keychain-db
signing_tmp=$(mktemp -d /tmp/cutter-signing.XXXXXX)

cleanup() {
  unlink "$signing_tmp/cutter-local.key" 2>/dev/null || true
  unlink "$signing_tmp/cutter-local.crt" 2>/dev/null || true
  unlink "$signing_tmp/cutter-local.p12" 2>/dev/null || true
  rmdir "$signing_tmp" 2>/dev/null || true
}
trap cleanup EXIT

openssl req -new -x509 -newkey rsa:2048 -nodes \
  -keyout "$signing_tmp/cutter-local.key" \
  -out "$signing_tmp/cutter-local.crt" \
  -days 1825 \
  -subj "/CN=$identity_name/O=codepiano/OU=Local Development" \
  -addext 'basicConstraints=critical,CA:FALSE' \
  -addext 'keyUsage=critical,digitalSignature' \
  -addext 'extendedKeyUsage=codeSigning' \
  >/dev/null 2>&1

openssl pkcs12 -export -legacy \
  -out "$signing_tmp/cutter-local.p12" \
  -inkey "$signing_tmp/cutter-local.key" \
  -in "$signing_tmp/cutter-local.crt" \
  -passout pass:cutter-local \
  -macalg sha1 \
  -keypbe PBE-SHA1-3DES \
  -certpbe PBE-SHA1-3DES

security import "$signing_tmp/cutter-local.p12" \
  -k "$login_keychain" \
  -P cutter-local \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null

security add-trusted-cert -r trustRoot -p codeSign \
  -k "$login_keychain" \
  "$signing_tmp/cutter-local.crt"

if security find-identity -v -p codesigning | rg -F "\"$identity_name\"" >/dev/null; then
  print "Created signing identity: $identity_name"
else
  print -u2 "The certificate was imported but is not a valid code-signing identity."
  exit 1
fi
