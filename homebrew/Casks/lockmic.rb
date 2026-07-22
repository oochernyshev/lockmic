# Homebrew Cask for LockMic (direct / GitHub Releases).
#
# Local tap install (after publishing a release):
#   brew tap <your-github-user>/lockmic https://github.com/<your-github-user>/LockMic
#   brew install --cask lockmic
#
# Or install from a local path while developing:
#   brew install --cask --formula ./homebrew/Casks/lockmic.rb
# (prefer pointing url at a file:// or release artifact)
#
# Before publishing: set version, url, and sha256 from Scripts/package_dmg.sh output.

cask "lockmic" do
  version "1.1.2"
  # After first GitHub Release, set sha256 from:
  #   shasum -a 256 build/dist/LockMic-1.1.2.zip
  sha256 :no_check

  # Point this at your GitHub Releases asset (or a file:// path while testing):
  url "https://github.com/lockmic/LockMic/releases/download/v#{version}/LockMic-#{version}.zip"
  name "LockMic"
  desc "System-wide microphone mute from the menu bar"
  homepage "https://wixee.ai"

  depends_on macos: ">= :sonoma"

  app "LockMic.app"

  zap trash: [
    "~/Library/Preferences/com.lockmic.app.plist",
    "~/Library/Application Support/LockMic",
  ]
end
