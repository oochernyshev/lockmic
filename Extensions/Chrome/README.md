# LockMic for Google Meet (Chrome extension)

Manifest V3, active only on `meet.google.com`. Talks to LockMic through Native Messaging
(`LockMicNativeHost`, shipped inside LockMic.app). Only the mute state is exchanged.

- Load unpacked from this folder for development (`manifest.json` pins the extension ID via `key`,
  which LockMic's native-host manifest allows).
- For the Chrome Web Store, zip this folder. The store assigns its own ID: set it in
  `MeetBridge.extensionID` (or add the store ID to `allowed_origins`).
- LockMic writes the native-host manifest for Chrome, Chromium, Edge, Brave and Arc when the
  Google Meet integration is enabled in Preferences → Calls.
