#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build -c release "$@"
bin=$(swift build -c release "$@" --show-bin-path)
bundle="build/Localhost Manager.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp Resources/AppIcon.icns "$bundle/Contents/Resources/"
cp "$bin/LokalhostManager" "$bundle/Contents/MacOS/"
cp Info.plist "$bundle/Contents/"
codesign --force --options runtime --sign - "$bundle"
codesign --verify --strict "$bundle"
touch "$bundle"
echo "$PWD/$bundle"
