#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build -c release
bin=$(swift build -c release --show-bin-path)
bundle="build/Lokalhost Manager.app"
mkdir -p "$bundle/Contents/MacOS"
cp "$bin/LokalhostManager" "$bundle/Contents/MacOS/"
cp Info.plist "$bundle/Contents/"
codesign --force --options runtime --sign - "$bundle"
codesign --verify --strict "$bundle"
echo "$PWD/$bundle"
