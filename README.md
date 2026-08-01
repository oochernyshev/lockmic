# LockMic

System-wide microphone mute for macOS — menu bar icon, global hotkeys, and an on-screen HUD. Works in Zoom, Teams, Meet, FaceTime, browsers, and every other app by muting input devices via Core Audio.

**Owner:** [WIXEE.AI](https://wixee.ai) · **License:** [MIT](./LICENSE) · **Version:** 1.3.1

**Homebrew-first** distribution (App Store planned later). See [ARCHITECTURE.md](./ARCHITECTURE.md) for design details.

## Features

- **System-level mute** via Core Audio (not app-specific mute buttons)
- **Mute all input devices** by default (optional: default input only)
- Virtual devices (`transportType == Virtual`) are listed but **ignored** for mute control
- **Menu bar** icon — click to toggle, right-click for menu
- Global hotkeys (customizable):
  - **Toggle:** ⌘⇧M (and optional ⌘F5)
  - **Mute only / Unmute only** (off by default)
  - **Push to flip:** hold to invert mute, release to restore (off by default; default ⌥Space)
  - **Push to talk:** hold to unmute, release to restore (off by default; default ⇧Space)
  - **Push to mute:** hold to mute, release to restore (off by default; default ⇧⌥Space)
  - **Conflict warnings** when two enabled shortcuts share the same keys
- **On-screen HUD** on mute/unmute (optional toast)
- **Floating HUD** (optional): always visible on each display
  - Drag to reposition (per display, remembered)
  - Click to toggle mute
  - Right-click to hide/show on a display (also in menu bar)
- Sound feedback on mute/unmute (optional)
- Launch at login (optional)
- Preferences: General, Devices, Keyboard, About
- Re-applies mute when devices or the default input change

## Requirements

- macOS 14 Sonoma or later
- Xcode 15+ (to build)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Languages

UI follows the macOS system language. Bundled localizations:

**23 languages** — English (default) plus Czech, Danish, German, Greek, Spanish, Finnish, French, Hungarian, Italian, Japanese, Korean, Norwegian (Bokmål), Dutch, Polish, Portuguese, Romanian, Russian, Serbian (Latinica), Swedish, Turkish, Ukrainian, Chinese (Simplified).

One file per language under [`Resources/Localization/`](./Resources/Localization/) (`xx.lproj/Localizable.strings`). See that folder’s README for the full table.

Code looks up keys via `L10n` (`Sources/LockMic/Util/L10n.swift`). To test: Xcode scheme → **Options → App Language**, or **System Settings → Language & Region**.

## Website

Marketing site lives in [`website/public/`](./website/public/) and deploys to **Firebase Hosting** via **Cloud Build** (`cloudbuild.yaml`, `firebase.json`).

```bash
# Local preview
cd website/public && python3 -m http.server 8080
```

See [`website/README.md`](./website/README.md) for Firebase setup and CI deploy.

## Build & run

Start or restart (kills any running instance; builds if the app is missing):

```bash
./Scripts/start.sh
```

Rebuild then restart:

```bash
./Scripts/start.sh --build
```

Build only:

```bash
./Scripts/build_homebrew.sh
open build/LockMic.app
```

Package a release zip/DMG:

```bash
./Scripts/package_dmg.sh
# → build/dist/LockMic-1.3.1.zip (+ .dmg, sha256)
```

## Install via Homebrew

LockMic is **not** in the official Homebrew core cask list yet. Install from this repo’s tap:

```bash
brew tap oochernyshev/lockmic https://github.com/oochernyshev/lockmic
brew install --cask lockmic
xattr -dr com.apple.quarantine /Applications/LockMic.app
open /Applications/LockMic.app
```

From a local clone (no tap):

```bash
brew install --cask ./Casks/lockmic.rb
xattr -dr com.apple.quarantine /Applications/LockMic.app
```

Cask: [`Casks/lockmic.rb`](./Casks/lockmic.rb) (must stay under root `Casks/` for the tap to work).

`xattr` clears Gatekeeper quarantine until the app is Developer ID–notarized.
### Local build without a public release

```bash
./Scripts/build_homebrew.sh
open build/LockMic.app
```

## Usage

| Action | How |
|--------|-----|
| Toggle mute | Click menu bar icon, **⌘⇧M**, **⌘F5**, or click the floating HUD |
| Push to talk | Hold PTT shortcut (Preferences → Keyboard; off by default) |
| Push to mute | Hold PTM shortcut (Preferences → Keyboard; off by default) |
| Push to flip | Hold to invert mute, release restores (off by default) |
| Menu / Preferences | Right-click (or Control-click) the menu bar icon |
| Menu bar icon hidden | Dock appears automatically · left-click toggles mute · right-click opens the same menu (Preferences, floating HUD, …) |
| Floating HUD move | Drag the indicator (each display is independent) |
| Floating HUD hide/show | Right-click the indicator, menu bar / Dock menu → **Floating HUD** |
| Quit | Menu → Quit LockMic |

### Preferences

| Section | Options |
|---------|---------|
| **General** | Status, HUD toast, floating HUD, sound, launch at login, show in Dock |
| **Devices** | Mute-all vs default-only, live input list (virtual = ignored) |
| **Keyboard** | Toggle / mute / unmute / flip / PTT / PTM; optional ⌘F5; conflicts; reset |
| **About** | Logo, version, WIXEE.AI, website, MIT license |

## Development in VS Code

1. Install Xcode + `xcodegen`
2. Optional: [SweetPad](https://marketplace.visualstudio.com/items?itemName=sweetpad.sweetpad)
3. Generate & build: `./Scripts/build_homebrew.sh` or `./Scripts/start.sh --build`
4. Edit sources under `Sources/LockMic/`

## Project layout

```
Sources/LockMic/     Swift app (App, Core, UI)
Resources/           Info.plist, entitlements, Assets (AppIcon, AppLogo)
Scripts/             start, build, package
homebrew/Casks/      Cask formula template
LICENSE              MIT
ARCHITECTURE.md      System design
logo.png             Source artwork (generates icon sizes)
```

## Privacy

LockMic mutes devices through Core Audio only. It does **not** record audio and does **not** require microphone permission.

## License

[MIT](./LICENSE) — Copyright © 2026 [WIXEE.AI](https://wixee.ai)

Open-core: this free app is MIT-licensed. Future Pro features may be offered separately by WIXEE.AI under different terms.
