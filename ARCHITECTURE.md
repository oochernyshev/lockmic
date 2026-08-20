# LockMic Architecture

LockMic is a native macOS menu-bar utility that mutes system microphone input at the Core Audio level so mute works in every app (Zoom, Teams, Meet, FaceTime, browsers, etc.).

**Owner:** [WIXEE.AI](https://wixee.ai) · **License:** MIT · **Current version:** 1.4.11

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

One instance is shared by `MicController` and `SessionRecorder`.

- Resolve **default input device** (`kAudioHardwarePropertyDefaultInputDevice`)
- Get/set **mute** (`kAudioDevicePropertyMute`, input scope)
- Enumerate inputs; detect mute support and **virtual devices**
  - Only `kAudioDevicePropertyTransportType == Virtual` (no name/UID heuristics)
- Listen for **device list / default device** changes via property listeners
- Mute alone does not record → no microphone TCC until Recording starts

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
- Skips **virtual** devices (`transportType == Virtual`)
- On device change: re-apply desired state to devices in scope
- Publishes `InputDeviceRow` list for Preferences → Devices
- API: `toggle()`, `setMuted(_:)`, `refreshFromHardware`, `preferenceMuteScopeChanged()`

### 3. `HotkeyManager`

- Registers global shortcuts via Carbon `RegisterEventHotKey` + event handler on the dispatcher target
- Listens for **both** `kEventHotKeyPressed` and `kEventHotKeyReleased` (release used for push-to-talk)
- Fallback `NSEvent` local/global monitors for keyDown/keyUp
- Bindings: toggle, mute-only, unmute-only, start/stop recording, push-to-talk, push-to-mute, optional ⌘F5 toggle alias
- Forwards `(HotkeyAction, HotkeyPhase)` to `HotkeyCoordinator` → `MicController` / `RecordingCoordinator`
- Shortcut prefs are one `HotkeyPref` row per binding (enable + chord)
- Preferences surfaces **shortcut conflicts** when two enabled bindings share a chord

#### Momentary hotkeys

| Action | Press | Release |
|--------|-------|---------|
| **Push to talk** | If muted → unmute | Restore prior mute |
| **Push to mute** | If unmuted → mute | Restore prior unmute |
| **Push to flip** | Invert current mute | Restore prior state |

Only one momentary hold is active at a time; latching shortcuts are ignored while held.

### 4. UI layer

| Piece | Role |
|-------|------|
| `StatusItemController` | Menu bar icon, click, menu, prefs window; wires coordinators |
| `HotkeyCoordinator` | Global hotkey registration and momentary hold/restore |
| `HUDPresenter` | Chooses toast vs floating |
| `RecordingCoordinator` | Start/stop capture, TCC retry, monitor, mix-on-quit |
| `UpdateChecker` | Daily GitHub release check; badges + Preferences About update section (Homebrew vs DMG) |
| `HUDOverlay` | `showToast` / `showFloating` — one pill per display |
| `PreferencesView` | System Settings–style sidebar: General, Devices, Recording, Keyboard, About |
| `SessionRecorder` | Selected mic (HAL, retargetable) + system playback tap → dated AAC mix |
| `RecordingMonitorWindow` | AppKit monitor: input/output list, levels, mute, stop, permission retry |
| `HotkeyRecorderButton` | Capture custom shortcut chords |
| `SoundFeedback` | Optional mute/unmute system sounds |

Menu bar app: `LSUIElement = true` (no Dock icon by default).

When the status item is not in the usable menu bar (camera housing / overcrowding), LockMic shows a Dock tile automatically (`StatusItemVisibility` + activation policy). Dock left-click toggles mute; right-click reuses the status menu. Optional **Show in Dock** keeps the tile always.

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

- HUD toast, floating HUD, sound, launch at login, show in Dock, mute-all
- Recording folder, bitrate, all-playback vs default output, keep stem files
- Shortcut enable flags + chords (toggle / mute / unmute / F5 / flip / talk / mute-hold)
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
| Recording (mic) | `NSMicrophoneUsageDescription` |
| Recording (playback) | `NSAudioCaptureUsageDescription` + audio-input entitlement |
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
│   ├── App/          LockMicApp, AppDelegate
│   ├── Core/         AudioDeviceService, MicController, HotkeyTypes,
│   │                 HotkeyManager, PreferencesStore, SoundFeedback,
│   │                 SessionRecorder, SessionMix, PlaybackTap,
│   │                 RecordingTypes, RecordingBitRate, RecordingDSP,
│   │                 CompressedStemWriter, InputDeviceCapture,
│   │                 SystemAudioAccess
│   ├── Util/         Comparable+Clamped, L10n
│   └── UI/
│       ├── StatusItemController, HotkeyCoordinator, HUDPresenter,
│       │   RecordingCoordinator, EscapeToCloseWindow
│       ├── HUDHoldKind, HUDContentView, HUDOverlay
│       ├── PreferencesView, PreferencesTab, PreferencesChrome,
│       │   PreferencesGeneral/Devices/Recording/Keyboard/AboutPage
│       ├── RecordingMonitorWindow, RecordingMonitorViews
│       └── HotkeyRecorderButton
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
| **HB-1.x** | Mute-all, devices list, custom shortcuts, branding, floating HUD (drag / click / per-screen hide) | Done |
| **1.2.0** | Momentary hotkeys (flip/talk/mute), hold HUD, prefs polish, virtual transport detection | Done |
| **1.2.1** | About feedback (GitHub issues), localization for feedback strings | Done |
| **1.3.0** | Auto Dock when menu bar icon is hidden (camera housing / overcrowding); Dock mute toggle + HUD-style icon; Show in Dock preference | Done |
| **1.3.1** | Re-assert system mute every 2s while intent is muted (fixes Meet/Chrome starting capture after mute) | Done |
| **1.3.2** | Floating HUD: clicks outside the rounded pill pass through to apps underneath | Done |
| **1.3.3** | On open/install: take over from older running instance; relaunch when the .app on disk is replaced | Done |
| **1.3.4** | New app and website icon/logo artwork | Done |
| **1.3.5** | In-app update check (GitHub), badges, Preferences update flow (Homebrew vs DMG) | Done |
| **1.3.6** | Devices list: clearer status badges; label Unmuted (not On) | Done |
| **1.3.7** | GA4 app events send country (system Region, timezone fallback); no city | Done |
| **1.3.8** | Usage reports use website-style GA collect so Realtime can show location | Done |
| **1.4.0** | Record default mic + system playback to a dated AAC mix; live monitor | Done |
| **1.4.1** | Lower CPU while recording (batch encode, tap-only playback, cheaper meters) | Done |
| **1.4.2** | Recording monitor undims Inputs as soon as microphone access is granted | Done |
| **1.4.3** | Frosted recording monitor, live muted badges, recording names without seconds | Done |
| **1.4.4** | Menu record/mute icons, monitor mute button, mix writes to a temp file first | Done |
| **1.4.5** | Mix temp file keeps .m4a so Finder Space preview plays | Done |
| **1.4.6** | Anonymous usage includes recording start/stop (no audio or files) | Done |
| **1.4.7** | Visible mix progress filename (`… mixing 37%.m4a`) | Done |
| **1.4.8** | Recording shortcuts; switch mic mid-session; simpler two-file mix | Done |
| **1.4.9** | Recording monitor cards + layout; default badge follows System Settings; unmute/PTT fixes; AAC start on 16 kHz mics | Done |
| **1.4.10** | Waveform chips; device lists scroll after 5 rows | Done |
| **1.4.11** | Live mix while recording; 48/64 kbps AAC honors those rates | Done |
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
