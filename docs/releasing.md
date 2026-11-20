# Build a private macOS release

Use macOS with Xcode installed to build both architectures. Use GitHub CLI with access to `rupertgermann/localhost-manager` to publish the release.

## Build and verify

1. Set `CFBundleShortVersionString` and `CFBundleVersion` in [Info.plist](../Info.plist) before building. Use a new build number for each release.
2. Run the tests from the repository root. The environment flag enables the user-session `launchd` tests.

   ```sh
   env LOKALHOST_TEST_LAUNCHD=1 swift test
   ```

3. Build and verify a universal app. Read the version from the signed bundle and include it in the filename.

   ```sh
   ./build-app.sh --arch arm64 --arch x86_64
   app="build/Localhost Manager.app"
   lipo -verify_arch arm64 x86_64 "$app/Contents/MacOS/LokalhostManager"
   codesign --verify --strict "$app"
   version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
   asset="Localhost-Manager-${version}-macOS.zip"
   ditto -c -k --sequesterRsrc --keepParent "$app" "build/$asset"
   (cd build && shasum -a 256 "$asset" > "$asset.sha256")
   ```

4. Expand the archive into a temporary directory. Verify the extracted app's signature and launch it to check the package.

   ```sh
   unpacked="$(mktemp -d)"
   ditto -x -k "build/$asset" "$unpacked"
   codesign --verify --strict "$unpacked/Localhost Manager.app"
   open "$unpacked/Localhost Manager.app"
   ```

## Upload to the private repository

Push the commit and its version tag. Confirm that GitHub reports `PRIVATE` before you create the release. Keep the GitHub release as a prerelease during private testing.

```sh
repo="rupertgermann/localhost-manager"
tag="v$version"
gh repo view "$repo" --json visibility --jq .visibility | grep -qx PRIVATE &&
  gh release create "$tag" "build/$asset" "build/$asset.sha256" \
    --repo "$repo" --verify-tag --prerelease \
    --title "Localhost Manager $version" --notes-file /path/to/release-notes.md
```

Download the uploaded assets with `gh release download` and verify the archive with `shasum -a 256 -c`.

The private preview uses an ad hoc signature. For public distribution outside the Mac App Store, prepare a Developer ID signature and follow [Apple’s notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
