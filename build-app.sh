#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build -c release "$@"
bin=$(swift build -c release "$@" --show-bin-path)
bundle="build/Localhost Manager.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp -X Resources/AppIcon.icns LICENSE "$bundle/Contents/Resources/"
cp -X "$bin/LokalhostManager" "$bundle/Contents/MacOS/"
cp -X Info.plist "$bundle/Contents/"
# Remove the debug map's absolute paths before signing the distributable.
xcrun strip -S "$bundle/Contents/MacOS/LokalhostManager"
if xcrun strings -a "$bundle/Contents/MacOS/LokalhostManager" | grep -Eq '/Users/|/home/|/private/tmp/|/var/folders/'; then
    echo "Build-machine paths remain in the executable." >&2
    exit 1
fi
codesign --force --options runtime --sign - "$bundle"
codesign --verify --strict "$bundle"
touch "$bundle"
echo "$PWD/$bundle"
