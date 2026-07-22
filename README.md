# LockMic

System-wide microphone mute for macOS — menu bar icon, global hotkeys, and an on-screen HUD. Works in Zoom, Teams, Meet, FaceTime, browsers, and every other app by muting input devices via Core Audio.

**Owner:** [WIXEE.AI](https://wixee.ai) · **License:** [MIT](./LICENSE) · **Version:** 1.2.0

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
# → build/dist/LockMic-1.2.0.zip (+ .dmg, sha256)
```

## Install via Homebrew (after a release exists)

Point the cask at your GitHub release, then:

```bash
brew tap <you>/lockmic https://github.com/<you>/LockMic
brew install --cask lockmic
```

Cask template: [`homebrew/Casks/lockmic.rb`](./homebrew/Casks/lockmic.rb)  
Homepage in the cask: [https://wixee.ai](https://wixee.ai)

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
| Floating HUD move | Drag the indicator (each display is independent) |
| Floating HUD hide/show | Right-click the indicator, or menu bar → **Floating HUD** |
| Quit | Menu → Quit LockMic |

### Preferences

| Section | Options |
|---------|---------|
| **General** | Status, HUD toast, floating HUD, sound, launch at login |
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
