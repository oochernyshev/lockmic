# Homebrew Cask for LockMic (must live at repo-root Casks/ for `brew tap`).
#
# Install, update, or restore (Homebrew 6+ needs brew trust for third-party casks):
#   brew tap oochernyshev/lockmic https://github.com/oochernyshev/lockmic
#   brew trust --cask oochernyshev/lockmic/lockmic
#   brew update
#   brew reinstall --cask --yes lockmic || brew install --cask lockmic
#   open /Applications/LockMic.app
#
# Uninstall:
#   brew uninstall --cask lockmic
#
# Or from a local clone (no tap):
#   brew reinstall --cask --yes --force ./Casks/lockmic.rb || brew install --cask ./Casks/lockmic.rb
#
# Release archives are Developer ID signed and notarized.

cask "lockmic" do
  version "1.4.47"
  # After first GitHub Release, set sha256 from:
  #   shasum -a 256 build/dist/LockMic-1.4.47.zip
  sha256 "9ad293036679fa31b7cc3b1707326445d5441cbcb32fb95f4a580b28f8a1d990"

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
