# Install the unnotarized preview

This preview is ad-hoc signed. It has no Apple Developer ID signature and has
not been notarized by Apple. It is intended for testers who trust this project.

## Requirements

- macOS 14 or later
- Apple Silicon or Intel Mac
- Codex CLI installed and signed in with your own ChatGPT account

Xcode, XcodeGen, and an Apple Developer account are not required to use the
prebuilt app. The package does not include Codex CLI or any account credentials.

## Install

1. Extract the ZIP and move `CodexUsage.app` into `/Applications`.
2. Confirm that `codex --version` works, and run `codex login` if needed.
3. Open `CodexUsage.app`. It appears in the menu bar, not the Dock.
4. If macOS blocks it because the developer cannot be verified, open
   **System Settings → Privacy & Security** and choose **Open Anyway** for
   Codex Usage, provided you trust the downloaded package. Managed Macs may
   disallow this. See [Apple's instructions](https://support.apple.com/102445).
5. If CLI discovery fails, use **Select Codex CLI…** in the menu bar.
6. Right-click the desktop, select **Edit Widgets**, search for **Codex Usage**,
   and add the small or medium widget.

Keep the menu bar app running to update the widget. If an old widget remains
after replacing the app, remove the widget and add it again. Quit the existing
Codex Usage app before installing an update.

## Preview limitations

- Gatekeeper will not recognize this build as a notarized app.
- Widget discovery, shared-container access, and launch at login need testing
  on each supported macOS version. Building both architectures does not prove
  runtime compatibility on Intel or macOS 14.
- macOS may ask for permission to access the preview's shared container.
- The preview uses `com.local.CodexUsage.shared` as its shared container. It
  does not reuse the Team ID-prefixed cache of a development-signed source build.
- Codex CLI protocol changes may require an app update.
- Updates are installed manually by replacing the app.

## Verify the download

Download the adjacent `.zip.sha256` file and run this command in the directory
containing both files:

```bash
shasum -a 256 -c CodexUsage-0.1.0-unnotarized-universal.zip.sha256
```

Use the matching filename when installing a different version. The checksum
checks file integrity; it does not replace a Developer ID signature.
