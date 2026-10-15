#!/bin/bash
# Builds dist/TV Remote.exe (the whole app, one file) and dist/TV-Remote-Setup-<version>.exe.
# Needs Go and makensis (brew install makensis); works from macOS, Linux or Windows (Git Bash).
set -euo pipefail
cd "$(dirname "$0")"
go test ./...
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -H windowsgui" -o "dist/TV Remote.exe" .
makensis -V2 installer.nsi
# Release files: installer + portable exe, each with the .sha256 the in-app updater checks.
v=$(sed -n 's/^const version_ = "\(.*\)"/\1/p' main.go)
cp "dist/TV Remote.exe" "dist/TV-Remote-$v-portable.exe"
(cd dist && for f in "TV-Remote-Setup-$v.exe" "TV-Remote-$v-portable.exe"; do shasum -a 256 "$f" > "$f.sha256"; done)
ls -la dist
