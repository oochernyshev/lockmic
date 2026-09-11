# Release checklist

Use **[Scripts/release.sh](./Scripts/release.sh)**. Details: [BUILD_AND_DEPLOY.md](./BUILD_AND_DEPLOY.md).

```bash
# On main, working tree clean, product work already committed.
./Scripts/release.sh X.Y.Z -m "one-line summary"
```

```text
[ ] Product changes committed on main
[ ] gh auth login && brew install xcodegen gh
[ ] ./Scripts/release.sh X.Y.Z -m "…"   # or --notes-file / --no-push
[ ] GitHub release has dmg + zip + both checksums
[ ] lockmic.com heading matches X.Y.Z
[ ] brew reinstall --cask --yes lockmic && xattr -dr com.apple.quarantine /Applications/LockMic.app
```

Do not bump version files by hand unless the script cannot run. Builds are ad-hoc signed; users still need `xattr`.
