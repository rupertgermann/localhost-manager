# Localhost Manager

Localhost Manager is a native macOS app for discovering and managing local development services. See what's using a port, open a service in your browser, or jump to its working directory in Finder.

## Install

The private preview requires macOS 14 Sonoma or later. The release runs on Apple Silicon and Intel Macs.

1. Sign in to GitHub with an account that has access to this repository. Download the macOS ZIP from [Releases](https://github.com/rupertgermann/localhost-manager/releases).
2. Unzip the archive and move **Localhost Manager.app** to **Applications**.
3. Open **Localhost Manager**. The preview uses an ad hoc signature, so macOS may block the first launch. For the verified archive from this repository, use **System Settings → Privacy & Security → Open Anyway** after the first attempt. See [Apple’s instructions for opening an app](https://support.apple.com/en-us/102445).

## Use the app

- Click a category above the list to filter services such as Docker, Node.js, or Python. **All** clears the category filter. You can also search by name, port, or working directory.
- Choose **Add Project** and select a folder to group services by directory. Use **Edit** to assign a native service or **Assign** to assign a container.
- Click an address to open it in your browser. The app uses HTTP by default and HTTPS for port 443. Save a full web address on the service to use a different scheme or path.
- Click a local working directory to open it in Finder. Docker working directories can open in Finder when a bind mount maps them to a local folder.
- Add a working directory and **Start command** in **Edit** to let the app start and restart a native service. Jobs run under your macOS account and keep running when you quit the app. **Logs** shows captured output for managed jobs or a log file you specify for an external process.
- Run Docker locally to see containers, published ports, and logs. You can start, stop, or restart containers independently. The app connects to a local Docker daemon via a Unix socket.
- Click the sun or moon next to **Add Project** to change the appearance. The app remembers your choice.

## Build from source

Install Xcode or the Xcode Command Line Tools. From the repository root, run:

```sh
swift test
./build-app.sh
open "build/Localhost Manager.app"
```

The app stores its catalog and managed service logs under `~/Library/Application Support/Lokalhost Manager/`.

See the [release guide](docs/releasing.md) to build and verify the private distribution archive.
