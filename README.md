# LockMic

System-wide microphone mute for macOS — menu bar icon, global hotkey, on-screen HUD. Works in Zoom, Teams, Meet, and every other app by muting the input device via Core Audio.

**Homebrew-first** distribution (App Store planned later). See [ARCHITECTURE.md](./ARCHITECTURE.md).

## Features (v0.1)

- Mute / unmute default input at the **system** level
- **Menu bar** icon (click = toggle, right-click = menu)
- Global hotkeys **⌘⇧M** and **⌘F5**
- On-screen **HUD** when state changes
- Mutes **all input devices** by default (optional: default input only)
- Re-applies mute when devices change
- Customizable shortcuts: toggle / mute / unmute (each can be disabled)
- Preferences: HUD, sound, launch at login, devices, keyboard

## Requirements

- macOS 14 Sonoma or later
- Xcode 15+ (to build)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build & run (local / Homebrew package)

Start or restart (kills any running instance, builds if missing):

```bash
./Scripts/start.sh
```

Rebuild then restart:

```bash
./Scripts/start.sh --build
```

Or build only:

```bash
./Scripts/build_homebrew.sh
open build/LockMic.app
```

Optional zip/DMG for releases:

```bash
./Scripts/package_dmg.sh
# → build/dist/LockMic-1.1.2.zip (+ .dmg, sha256)
```

## Install via Homebrew (after a release exists)

Point the cask at your GitHub release, then:

```bash
# From a personal tap (example)
brew tap <you>/lockmic https://github.com/<you>/LockMic
brew install --cask lockmic
```

Cask template: [`homebrew/Casks/lockmic.rb`](./homebrew/Casks/lockmic.rb).

### Install a local build with Homebrew

```bash
./Scripts/build_homebrew.sh
./Scripts/package_dmg.sh
# Then either open the app directly, or host the zip and fill sha256 in the cask.
open build/LockMic.app
```

## Usage

| Action | How |
|--------|-----|
| Toggle mute | Click menu bar icon, or **⌘⇧M** / **⌘F5** |
| Menu / Preferences | Right-click (or Control-click) menu bar icon |
| Quit | Menu → Quit LockMic |

## Development in VS Code

1. Install Xcode + `xcodegen`
2. Optional: [SweetPad](https://marketplace.visualstudio.com/items?itemName=sweetpad.sweetpad) extension
3. Generate & build: `./Scripts/build_homebrew.sh`
4. Edit sources under `Sources/LockMic/`

## Project layout

```
Sources/LockMic/   Swift app (App, Core, UI)
Resources/         Info.plist, entitlements, assets
Scripts/           Homebrew build & package
homebrew/Casks/    Cask formula template
ARCHITECTURE.md    System design
```

## Privacy

Core mute uses Core Audio only and does **not** require microphone permission. A future “suggest unmute while speaking” feature will request mic access optionally and process audio on-device only.

## License

[MIT](./LICENSE) — Copyright © 2026 WIXEE.AI
