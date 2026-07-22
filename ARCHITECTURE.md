# LockMic Architecture

LockMic is a native macOS menu-bar utility that mutes the system microphone at the Core Audio level, so mute works in every app (Zoom, Teams, Meet, FaceTime, browsers, etc.).

**Distribution priority:** Homebrew (Developer ID / notarized `.app`) first; Mac App Store later with the same codebase and a sandboxed flavor.

---

## Goals

| Goal | Approach |
|------|----------|
| Global mute | Core Audio HAL on the default (or all) input device(s) |
| Fast toggle | Global hotkey + menu bar click |
| Always know state | Menu bar icon + on-screen HUD |
| Optional “you’re talking while muted” | Local VAD / energy gate (mic permission; opt-in) |
| Homebrew install | Notarized app in GitHub Releases → Cask |

---

## High-level diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     LockMic.app (LSUIElement)                 │
│                                                             │
│  ┌──────────────┐   ┌─────────────────┐   ┌──────────────┐ │
│  │ HotkeyManager│   │ StatusItem /    │   │ Preferences  │ │
│  │ (Carbon /    │   │ MenuBar UI      │   │ (UserDefaults)│ │
│  │  NSEvent)    │   └────────┬────────┘   └──────┬───────┘ │
│  └──────┬───────┘            │                   │         │
│         │                    ▼                   │         │
│         │           ┌─────────────────┐          │         │
│         └──────────►│ MicController   │◄─────────┘         │
│                     │ (desired vs     │                    │
│                     │  actual state)  │                    │
│                     └────────┬────────┘                    │
│                              │                             │
│              ┌───────────────┼───────────────┐             │
│              ▼               ▼               ▼             │
│     ┌────────────────┐ ┌───────────┐ ┌──────────────────┐ │
│     │ AudioDevice    │ │ HUDOverlay│ │ SpeechDetector   │ │
│     │ Service (HAL)  │ │ StatusWin │ │ (opt-in, later)  │ │
│     └────────┬───────┘ └───────────┘ └────────┬─────────┘ │
│              │                                 │           │
└──────────────┼─────────────────────────────────┼───────────┘
               ▼                                 ▼
        Core Audio HAL                    AVAudioEngine
        (mute / devices)                  (levels / VAD)
```

---

## Modules

### 1. `AudioDeviceService` (Core Audio)

- Resolve **default input device** (`kAudioHardwarePropertyDefaultInputDevice`)
- Get/set **mute** (`kAudioDevicePropertyMute`, input scope)
- Fallback: set input volume to 0 when mute property is unsupported
- Enumerate input devices; report **mute capability**
- Listen for **device list / default device** changes via property listeners
- Never records audio; no microphone TCC prompt for mute alone

### 2. `MicController` (state machine)

Single source of truth for mute:

```
enum MicState: muted | unmuted | unknown | unsupported
```

- Holds **desired** mute state (what the user asked for)
- Reads **actual** hardware state after each change
- On device change: re-apply desired state
- Publishes changes to UI (`@Observable` / `ObservableObject`)
- API: `toggle()`, `setMuted(_:)`, `pushToTalk(pressed:)`, etc.

### 3. `HotkeyManager`

- Global shortcut registration (toggle; later PTT / PTM)
- Default: configurable; ship with `⌘⇧M`
- Forwards events to `MicController`
- Homebrew build: no App Sandbox constraints on hotkeys

### 4. UI layer

| Piece | Role |
|-------|------|
| `StatusItemController` | Menu bar icon (template), left-click toggle, config menu |
| `HUDOverlay` | Brief non-activating panel on mute/unmute |
| `StatusWindow` (phase 2) | Optional always-on-top indicator |
| `PreferencesView` | Shortcuts, launch at login, HUD, speech suggest |
| `SuggestUnmuteBanner` (phase 2) | Speech-while-muted prompt |

Menu bar app: `LSUIElement = true` (no Dock icon by default).

### 5. `SpeechDetector` (phase 2, opt-in)

- Only while muted and preference enabled
- `AVAudioEngine` → RMS / VAD → sustained speech → suggest unmute
- Requires `NSMicrophoneUsageDescription`
- No network, no audio persistence

### 6. `PreferencesStore`

- `UserDefaults` / `@AppStorage`
- Hotkey combo, HUD on/off, launch at login, speech suggest, device policy

### 7. Launch at login

- `SMAppService.mainApp` (macOS 13+)

---

## Process & permissions

| Feature | TCC / entitlement |
|---------|-------------------|
| HAL mute | None |
| Speech suggest / level meter | Microphone usage string + runtime grant |
| Global hotkey | Standard hotkey APIs (no Accessibility for v1) |
| Launch at login | `SMAppService` registration |

**Homebrew (direct) entitlements:** Hardened Runtime + Developer ID; App Sandbox **off** for first release to maximize device compatibility. MAS build will re-enable sandbox later and re-validate mute.

---

## Data flow (toggle)

```
User hotkey / menu click
        │
        ▼
 MicController.toggle()
        │
        ▼
 AudioDeviceService.setMuted(!current)
        │
        ├── success → update state → StatusItem icon + HUD
        └── failure → state = unsupported → warning in menu / notification
```

Device unplug / default input change:

```
HAL property listener
        │
        ▼
 AudioDeviceService notifies MicController
        │
        ▼
 Re-apply desired mute on new default input
        │
        ▼
 Refresh menu + icon
```

---

## Project layout

```
LockMic/
├── ARCHITECTURE.md          ← this file
├── README.md
├── LockMic.xcodeproj/
├── Sources/
│   └── LockMic/
│       ├── App/
│       │   ├── LockMicApp.swift
│       │   └── AppDelegate.swift
│       ├── Core/
│       │   ├── AudioDeviceService.swift
│       │   ├── MicController.swift
│       │   ├── HotkeyManager.swift
│       │   └── PreferencesStore.swift
│       └── UI/
│           ├── StatusItemController.swift
│           ├── HUDOverlay.swift
│           └── PreferencesView.swift
├── Resources/
│   ├── Info.plist
│   ├── LockMic.entitlements
│   └── Assets.xcassets/
├── Scripts/
│   ├── build_homebrew.sh    # Release .app for cask
│   └── package_dmg.sh
└── homebrew/
    └── Casks/
        └── lockmic.rb       # Cask template (tap or upstream)
```

---

## Build flavors

| Flavor | Sandbox | Updates | Use |
|--------|---------|---------|-----|
| **Homebrew / direct** | Off | Cask upgrade / reinstall | Primary (now) |
| **App Store** (later) | On | App Store | Secondary |

Shared sources; different entitlements and bundle settings via Xcode configurations (`Debug`, `Release`, future `AppStore`).

---

## Homebrew delivery

1. CI (or local `Scripts/build_homebrew.sh`) produces a signed + notarized `LockMic.app`
2. Zip or DMG uploaded to **GitHub Releases** (`vX.Y.Z`)
3. Cask points at the release URL + `sha256`
4. Users: `brew install --cask lockmic` (from personal tap first, then `homebrew/cask` when ready)

Local / dev:

```bash
./Scripts/build_homebrew.sh
# → build/LockMic.app
open build/LockMic.app
```

---

## Phase map

| Phase | Scope |
|-------|--------|
| **HB-1 (now)** | HAL mute, menu bar, hotkey, HUD, prefs skeleton, Homebrew build + cask |
| **HB-2** | PTT/PTM, device picker, status window, speech suggest |
| **MAS** | Sandbox spike, Store assets, dual channel |

---

## Non-goals (v1 Homebrew)

- Stream Deck / AirPods stem
- Recording or cloud features
- Windows / Linux
- Muting per-app instead of system input

---

## Risks

1. **Some USB interfaces ignore mute** — detect, warn, document  
2. **False “muted” UI if hardware lies** — re-read state after set; optional volume-0 fallback  
3. **Bluetooth edge cases** — re-test AirPods on current macOS  

---

## Testing strategy

- Manual: built-in mic, one USB mic, Bluetooth headset, Zoom/browser call  
- Unit: pure helpers (state reconcile, hotkey parsing) where isolated from HAL  
- Smoke: `build_homebrew.sh` produces a launchable `.app`
