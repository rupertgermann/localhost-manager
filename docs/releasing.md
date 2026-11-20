# Build a macOS release

Build and package the app locally on a Mac with Xcode. Use GitHub CLI with access to `rupertgermann/localhost-manager` to upload the finished archive.

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
   lipo "$app/Contents/MacOS/LokalhostManager" -verify_arch arm64 x86_64
   codesign --verify --strict "$app"
   version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
   asset="Localhost-Manager-${version}-macOS.zip"
   ditto -c -k --norsrc --keepParent "$app" "build/$asset"
   (cd build && shasum -a 256 "$asset" > "$asset.sha256")
   ```

4. Expand the archive into a temporary directory. Verify the extracted app's signature and launch it to check the package.

   ```sh
   unpacked="$(mktemp -d)"
   ditto -x -k "build/$asset" "$unpacked"
   codesign --verify --strict "$unpacked/Localhost Manager.app"
   open "$unpacked/Localhost Manager.app"
   ```

Inspect the ZIP's file list and scan its extracted executable for build-machine paths before uploading. Keep private planning files, local app data, signing credentials, and build diagnostics out of release assets.

## Publish on GitHub

Push the commit and its version tag. Confirm that the destination is the public `rupertgermann/localhost-manager` repository before you create a public release.

```sh
repo="rupertgermann/localhost-manager"
tag="v$version"
gh repo view "$repo" --json visibility --jq .visibility | grep -qx PUBLIC &&
  gh release create "$tag" "build/$asset" "build/$asset.sha256" \
    --repo "$repo" --verify-tag --latest \
    --title "Localhost Manager $version" --notes-file /path/to/release-notes.md
```

Download the uploaded assets with `gh release download` and verify the archive with `shasum -a 256 -c`.

The current GitHub download uses an ad hoc signature. For future Developer ID builds, follow [Apple’s signing and notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
