# BW Autofill

A native macOS Bitwarden autofill tool.
Brings the 1Password `Cmd+\` Quick Access experience to Bitwarden.

*한국어: [README.ko.md](README.ko.md)*

## Requirements

- macOS 13 (Ventura) or later
- Bitwarden CLI (`bw`)

```bash
brew install bitwarden-cli
```

## Installation

### Build script (recommended)

```bash
git clone https://github.com/turtlesoup0/bitwarden_autofill.git
cd bitwarden_autofill
./scripts/build.sh
```

The bundle is produced at `dist/BW Autofill.app`.

```bash
# Install to /Applications
cp -r "dist/BW Autofill.app" /Applications/
```

### Manual build

```bash
swift build -c release
# Binary: .build/release/BWAutofill
```

## Usage

### First-time setup

1. **Log in from the terminal** (login runs in the CLI to avoid 2FA/interactive-prompt issues)
   ```bash
   bw login
   ```
2. Launch the app — a key icon appears in the menu bar.
3. Menu → **Unlock Vault** (`⌘U`) → enter the master password.
   - The session token is then stored encrypted in the Keychain and **auto-restored on the next `Cmd+\`**.

### Day-to-day

1. In any app or browser that needs a login, press `Cmd+\`.
2. Pick an entry from the search panel (Enter to expand).
3. Click ID or Password → copied to the clipboard → paste.

### Search panel shortcuts

| Key | Action |
|-----|--------|
| ↑ ↓ | Move selection |
| Enter | Expand / collapse entry |
| Cmd+R | Refresh (Bitwarden sync) |
| ESC | Close panel |

### App-context auto-detect

Pressing `Cmd+\` while Slack is focused auto-fills the search with "slack".
Supported apps include Slack, Spotify, Figma, Linear, Notion, GitHub, Teams, Discord, Zoom, and more.

### Result ranking

Results are sorted by match quality score:

| Match type | Score |
|---|---|
| Exact name match | 1000 |
| Name prefix match | 500 |
| Name substring match | 300 |
| Username or URL only | 100 |

Ties preserve the original order (Swift stable sort).

### Error feedback

The search panel distinguishes connection and parsing failures:

- **Vault not connected — unlock required**: `bw serve` is not running
- **bw serve no response**: server is up but the HTTP call failed
- **Failed to parse response**: JSON parsing error

All errors can be retried with `⌘R`.

### Hotkey registration failure

If another app has already claimed `⌘\`, the menu-bar icon switches to `key.slash` and a warning item appears in the menu.

## Permissions

On first launch the app needs **Accessibility** permission:

**System Settings → Privacy & Security → Accessibility** → enable the app.

Restart the app after granting permission.

## Security

- Passwords are never exposed as process arguments (they go through the `BW_PASSWORD` environment variable, invisible to `ps`).
- `bw serve` binds only to `127.0.0.1` (no external access).
- Session tokens are stored encrypted in the macOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
- Password copies are flagged with `org.nspasteboard.ConcealedType` so clipboard managers skip them.
- The clipboard is auto-cleared 10 seconds after a copy.
- **When the app quits, anything we copied that's still on the clipboard is cleared immediately** (matched by `changeCount`).
- Only a minimal environment is passed to subprocesses (`PATH`, `HOME`, `BW_SESSION`, and `BW_PASSWORD` when needed).

## How it works

```
            Cmd+\
              │
      HotkeyManager (Carbon)
              │
         AppDelegate
              │
   ┌──────────┼──────────┐
   ▼          ▼          ▼
BitwardenAPI SearchPanel AppContext
(bw serve    (NSPanel    Detector
 REST API)   + SwiftUI)
              │
              ▼ (on selection)
          Clipboard copy
  (Concealed + 10s auto-clear
   + cleared on app exit)
```

### Concurrency model

- `BitwardenAPI` is a Swift `actor` — internal state (`serveProcess`, `cachedItems`, `sessionToken`) is serialized.
- All HTTP calls use the async `URLSession.data(for:)` API (no actor-thread blocking).
- Subprocess waits use `Process.terminationHandler` + `withCheckedContinuation`.
- App quit uses `applicationShouldTerminate` + `.terminateLater` to avoid UI freezes.

## Project layout

```
bitwarden_autofill/
├── Package.swift
├── Info.plist
├── scripts/build.sh          # .app bundle build script
└── Sources/BWAutofill/
    ├── App.swift              # SwiftUI app entry point
    ├── AppDelegate.swift      # Menu bar + event orchestration
    ├── HotkeyManager.swift    # Global Cmd+\ hotkey (Carbon)
    ├── BitwardenAPI.swift     # bw serve REST client (actor)
    ├── AppContextDetector.swift # Frontmost-app detection
    ├── SearchPanel.swift      # Floating search UI (NSPanel + SwiftUI)
    └── SecurityManager.swift  # Keychain + clipboard security
```

## Design notes

### Why does login happen in the terminal?

`bw login` prompts for 2FA via an `inquirer.js` interactive prompt that is hard to drive reliably from a macOS app (you hit `ERR_USE_AFTER_CLOSE` and similar issues). `bw unlock` supports the non-interactive `--passwordenv` flag, so the app handles unlock itself.

### Why `--passwordenv` instead of stdin?

stdin injection is flaky across some `bw` versions (broken pipe on early close). The officially supported `BW_PASSWORD` environment variable is more reliable.
