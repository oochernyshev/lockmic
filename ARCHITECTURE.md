# LockMic Architecture

LockMic is a native macOS menu-bar utility that mutes system microphone input at the Core Audio level so mute works in every app (Zoom, Teams, Meet, FaceTime, browsers, etc.).

**Owner:** [WIXEE.AI](https://wixee.ai) · **License:** MIT · **Current version:** 1.1.2

**Distribution priority:** Homebrew (Developer ID / notarized `.app`) first; Mac App Store later with the same codebase and a sandboxed flavor.

---

## Goals

| Goal | Approach |
|------|----------|
| Global mute | Core Audio HAL mute on scoped input device(s) |
| Fast toggle | Global hotkeys + menu bar click + floating HUD click |
| Push to talk | Momentary hotkey: hold unmute, release restore |
| Push to mute | Momentary hotkey: hold mute, release restore |
| Always know state | Menu bar icon + toast HUD and/or floating HUD |
| Multi-display | HUD on every screen; independent position and visibility |
| Homebrew install | Signed app in GitHub Releases → Cask |

**Explicit non-goals (current product):** speech-while-muted detection, soft-mute, device hogging, per-app mute.

---

## High-level diagram

```
┌──────────────────────────────────────────────────────────────┐
│                    LockMic.app (LSUIElement)                  │
│                                                              │
│  ┌──────────────┐  ┌──────────────────┐  ┌────────────────┐  │
│  │ HotkeyManager│  │ StatusItem       │  │ Preferences    │  │
│  │ (Carbon)     │  │ Controller       │  │ Store + View   │  │
│  └──────┬───────┘  └────────┬─────────┘  └───────┬────────┘  │
│         │                   │                    │           │
│         │                   ▼                    │           │
│         │          ┌─────────────────┐           │           │
│         └─────────►│ MicController   │◄──────────┘           │
│                    │ desired vs HAL  │                       │
│                    └────────┬────────┘                       │
│                             │                                │
│               ┌─────────────┼─────────────┐                  │
│               ▼             ▼             ▼                  │
│      ┌──────────────┐ ┌───────────┐ ┌──────────────┐         │
│      │ AudioDevice  │ │ HUDOverlay│ │ SoundFeedback│         │
│      │ Service (HAL)│ │ toast /   │ │              │         │
│      │              │ │ floating  │ │              │         │
│      └──────┬───────┘ └───────────┘ └──────────────┘         │
│             │                                                │
└─────────────┼────────────────────────────────────────────────┘
              ▼
       Core Audio HAL
       (mute / devices / listeners)
```

---

## Modules

### 1. `AudioDeviceService` (Core Audio)

- Resolve **default input device** (`kAudioHardwarePropertyDefaultInputDevice`)
- Get/set **mute** (`kAudioDevicePropertyMute`, input scope)
- Enumerate inputs; detect mute support and virtual devices
- Listen for **device list / default device** changes via property listeners
- Never records audio → no microphone TCC for mute alone

### 2. `MicController` (state machine)

Single source of truth for mute:

```
enum MicState: muted | unmuted | unknown | unsupported(deviceName)
```

- Holds **desired** mute state (sticky user intent, re-applied on device change)
- Reads **actual** hardware state after changes into `state`
- **`effectiveMuted`** (alias `isMuted`): one notion for UI / hotkeys / HUD  
  - `.muted` → true, `.unmuted` → false  
  - `.unknown` / `.unsupported` → `desiredMuted`
- Scope: **all controllable inputs** or **default only** (preference)
- Skips **virtual** devices (loopbacks, etc.)
- On device change: re-apply desired state to devices in scope
- Publishes `InputDeviceRow` list for Preferences → Devices
- API: `toggle()`, `setMuted(_:)`, `refreshFromHardware`, `preferenceMuteScopeChanged()`

### 3. `HotkeyManager`

- Registers global shortcuts via Carbon `RegisterEventHotKey` + event handler on the dispatcher target
- Listens for **both** `kEventHotKeyPressed` and `kEventHotKeyReleased` (release used for push-to-talk)
- Fallback `NSEvent` local/global monitors for keyDown/keyUp
- Bindings: toggle, mute-only, unmute-only, push-to-talk, push-to-mute, optional ⌘F5 toggle alias
- Forwards `(HotkeyAction, HotkeyPhase)` to `StatusItemController` → `MicController`
- Preferences surfaces **shortcut conflicts** when two enabled bindings share a chord

#### Momentary hotkeys

| Action | Press | Release |
|--------|-------|---------|
| **Push to talk** | If muted → unmute | Restore prior mute |
| **Push to mute** | If unmuted → mute | Restore prior unmute |
| **Push to toggle** | Invert current mute | Restore prior state |

Only one momentary hold is active at a time; latching shortcuts are ignored while held.

### 4. UI layer

| Piece | Role |
|-------|------|
| `StatusItemController` | Menu bar icon, left-click toggle, right-click menu, owns HUD + hotkeys + prefs window |
| `HUDOverlay` | Multi-display panels: toast (auto-hide) or floating (persistent) |
| `PreferencesView` | System Settings–style sidebar: General, Devices, Keyboard, About |
| `HotkeyRecorderButton` | Capture custom shortcut chords |
| `SoundFeedback` | Optional mute/unmute system sounds |

Menu bar app: `LSUIElement = true` (no Dock icon).

#### Floating HUD behavior

When **Keep HUD indicator floating** is enabled:

| Interaction | Effect |
|-------------|--------|
| Click | Toggle mute |
| Drag | Move indicator; position stored **per display** |
| Right-click | Hide this display; show hidden displays; show all |
| Menu bar → Floating HUD | Checkbox per display + show all |

Toast mode (`Show on-screen HUD when muting`) is disabled while floating is on. Toast panels ignore mouse events; floating panels do not.

Preferences window: resizable, frosted material background (`regularMaterial` / clear window).

### 5. `PreferencesStore`

`UserDefaults`-backed `@Published` settings:

- HUD toast, floating HUD, sound, launch at login, mute-all
- Shortcut enable flags + chords (toggle / mute / unmute / F5)
- Defaults: mute-all on; toast + sound on; floating off; mute/unmute shortcuts off

Floating HUD also stores (via `HUDOverlay` / UserDefaults):

- Relative positions per `NSScreenNumber`
- Hidden display IDs

### 6. Launch at login

- `SMAppService.mainApp` (macOS 13+)

### 7. Branding & assets

- `Resources/Assets.xcassets/AppIcon` — macOS app icon sizes from `logo.png`
- `AppLogo` — About page image
- `NSHumanReadableCopyright` — © WIXEE.AI
- XcodeGen includes the asset catalog via `sources` + `buildPhase: resources`

---

## Process & permissions

| Feature | TCC / entitlement |
|---------|-------------------|
| HAL mute | None |
| Global hotkey | Carbon hotkeys (no Accessibility required for current design) |
| Launch at login | `SMAppService` registration |
| Floating HUD | None (non-activating panels) |

**Homebrew (direct) entitlements:** Hardened Runtime; App Sandbox **off** for device compatibility. MAS build will re-enable sandbox later and re-validate mute.

---

## Data flow (toggle)

```
User: hotkey / menu click / floating HUD click
        │
        ▼
 MicController.toggle() / setMuted
        │
        ▼
 AudioDeviceService.setMuted on each device in scope
        │
        ├── success → update MicState → menu bar icon
        │              + toast HUD (if enabled) and/or floating HUD update
        │              + optional sound
        └── failure → unsupported / lastError surfaced in Preferences
```

Device unplug / default input change:

```
HAL property listener
        │
        ▼
 MicController re-applies desired mute to in-scope devices
        │
        ▼
 Refresh icon, device list, floating HUD caption
```

---

## Project layout

```
LockMic/
├── ARCHITECTURE.md
├── README.md
├── LICENSE                    # MIT
├── logo.png                   # Source icon artwork
├── project.yml                # XcodeGen
├── LockMic.xcodeproj/
├── Sources/LockMic/
│   ├── App/
│   │   ├── LockMicApp.swift
│   │   └── AppDelegate.swift
│   ├── Core/
│   │   ├── AudioDeviceService.swift
│   │   ├── MicController.swift
│   │   ├── HotkeyManager.swift
│   │   ├── PreferencesStore.swift
│   │   └── SoundFeedback.swift
│   └── UI/
│       ├── StatusItemController.swift
│       ├── HUDOverlay.swift
│       ├── PreferencesView.swift
│       └── HotkeyRecorderButton.swift
├── Resources/
│   ├── Info.plist
│   ├── LockMic.entitlements
│   └── Assets.xcassets/       # AppIcon + AppLogo
├── Scripts/
│   ├── start.sh               # Build if needed + launch
│   ├── build_homebrew.sh      # xcodegen + xcodebuild Release
│   └── package_dmg.sh
└── homebrew/Casks/
    └── lockmic.rb
```

---

## Build flavors

| Flavor | Sandbox | Updates | Use |
|--------|---------|---------|-----|
| **Homebrew / direct** | Off | Cask upgrade / reinstall | Primary (now) |
| **App Store** (later) | On | App Store | Secondary |

Shared sources; different entitlements via future Xcode configurations.

---

## Homebrew delivery

1. `Scripts/build_homebrew.sh` → `build/LockMic.app`
2. `Scripts/package_dmg.sh` → zip/DMG + sha256 under `build/dist/`
3. Upload to GitHub Releases (`vX.Y.Z`)
4. Cask: version, URL, sha256 → `brew install --cask lockmic`

Local:

```bash
./Scripts/start.sh --build
# or
./Scripts/build_homebrew.sh && open build/LockMic.app
```

---

## Phase map

| Phase | Scope | Status |
|-------|--------|--------|
| **HB-1** | HAL mute, menu bar, hotkeys, toast HUD, prefs, Homebrew scripts | Done |
| **HB-1.x** | Mute-all, devices list, custom shortcuts, branding, floating HUD (drag / click / per-screen hide) | Done (v1.1.2) |
| **HB-1.x** | Push-to-talk / push-to-mute, shortcut conflict warnings | Done |
| **HB-2** | Richer status, polish, notarized releases | Planned |
| **Pro** (optional) | Paid add-ons in separate closed modules (open core remains MIT) | Future |
| **MAS** | Sandbox spike, Store assets | Later |

---

## Abandoned approaches (for history)

Speech-while-muted and soft-mute were prototyped and removed:

- HAL mute blocks usable capture for speech detection on the muted device
- Soft-mute is defeated by app AGC (e.g. Meet)
- Device hogging caused default-device thrash and virtual-device churn

Current product is **stable hard mute only**.

---

## Non-goals (current)

- Stream Deck / AirPods stem hardware keys
- Recording or cloud features
- Windows / Linux
- Muting per-app instead of system input
- Built-in speech detection

---

## Risks

1. **Some USB interfaces ignore mute** — surface “not controllable” in Devices; document  
2. **Hardware state lies** — re-read after set; desired-state re-apply on device change  
3. **Bluetooth edge cases** — re-test headsets on current macOS  
4. **Floating HUD under full-screen apps** — panel level and collection behavior tuned; rare edge cases remain  

---

## Testing strategy

- Manual: built-in mic, USB mic, Bluetooth headset, multi-monitor HUD drag/hide, Zoom/browser call  
- Preferences: mute-all vs default-only, shortcut record/reset, floating on/off  
- Smoke: `./Scripts/start.sh --build` launches a working menu-bar app  
- Unit (future): pure helpers (chord formatting, relative position clamp) isolated from HAL  
