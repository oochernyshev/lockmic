# Homebrew Cask for LockMic (must live at repo-root Casks/ for `brew tap`).
#
# Install (Homebrew 6+ needs brew trust for third-party casks):
#   brew tap oochernyshev/lockmic https://github.com/oochernyshev/lockmic
#   brew trust --cask oochernyshev/lockmic/lockmic
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
  version "1.4.13"
  # After first GitHub Release, set sha256 from:
  #   shasum -a 256 build/dist/LockMic-1.4.13.zip
  sha256 "d6fd744a972f92d88b1a3f1a7dc4d82710c52aa9f84d1bab37b1f29f4fd23d13"

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
