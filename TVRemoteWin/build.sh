#!/bin/bash
# Builds dist/TV Remote.exe (the whole app, one file) and dist/TV-Remote-Setup-<version>.exe.
# Needs Go and makensis (brew install makensis); works from macOS, Linux or Windows (Git Bash).
set -euo pipefail
cd "$(dirname "$0")"
go test ./...
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -H windowsgui" -o "dist/TV Remote.exe" .
makensis -V2 installer.nsi
ls -la dist
