# Homebrew Cask for LockMic (must live at repo-root Casks/ for `brew tap`).
#
# Install:
#   brew tap oochernyshev/lockmic https://github.com/oochernyshev/lockmic
#   brew install --cask lockmic
#   xattr -dr com.apple.quarantine /Applications/LockMic.app
#   open /Applications/LockMic.app
#
# Or from a local clone (no tap):
#   brew install --cask ./Casks/lockmic.rb
#   xattr -dr com.apple.quarantine /Applications/LockMic.app
#
# xattr clears Gatekeeper quarantine until Developer ID + notarization.

cask "lockmic" do
  version "1.3.2"
  # After first GitHub Release, set sha256 from:
  #   shasum -a 256 build/dist/LockMic-1.3.2.zip
  sha256 "14c30c77a1466d4e496ff9f1d47399c20c34d832ea5695437b79ba9c6dc0b427"

  # Point this at your GitHub Releases asset (or a file:// path while testing):
  url "https://github.com/oochernyshev/lockmic/releases/download/v#{version}/LockMic-#{version}.zip"
  name "LockMic"
  desc "System-wide microphone mute from the menu bar"
  homepage "https://wixee.ai"

  depends_on macos: :sonoma

  app "LockMic.app"

  zap trash: [
    "~/Library/Preferences/com.lockmic.app.plist",
    "~/Library/Application Support/LockMic",
  ]
end
