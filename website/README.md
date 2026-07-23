# LockMic website

Modern single-page marketing site for **LockMic**, published via **Firebase Hosting** and **Google Cloud Build**.

## Local preview

```bash
# from repo root
cd website/public
python3 -m http.server 8080
# open http://localhost:8080
```

Or with Firebase tools:

```bash
npm install -g firebase-tools
firebase serve --only hosting
```

## Structure

```
website/public/
  index.html      # landing page
  styles.css
  main.js
  assets/         # logo, icons, OG image
firebase.json     # hosting config (repo root)
.firebaserc       # default Firebase project id
cloudbuild.yaml   # CI deploy
```

## Deploy

### Why “No buildpack groups passed detection”?

That error means CI used **Node buildpacks** (auto-detect), not our static deploy.
This site is plain HTML/CSS/JS under `website/public` — **no `package.json`**, so
buildpacks correctly fail with exit **21**.

**Fix:** use one of the paths below (GitHub Actions recommended, or Cloud Build with
`cloudbuild.yaml` only — never “Autodetected / Buildpacks”).

Also use **Firebase Hosting**, not **Firebase App Hosting** (App Hosting expects
Next/Angular/etc. frameworks).

### Manual

```bash
# set project id in .firebaserc if needed
firebase login
firebase deploy --only hosting
```

### GitHub Actions (recommended for this repo)

1. Firebase project + Hosting enabled; set `.firebaserc`.
2. Create a service-account JSON (Firebase Console → Project settings → Service accounts),
   **or** run: `firebase init hosting:github`
3. GitHub → **Settings → Secrets and variables → Actions**
   - Secret `FIREBASE_SERVICE_ACCOUNT` = full JSON key
   - Optional variable `FIREBASE_PROJECT_ID` = your project id (default `lockmic-11c1a`)
4. Push to `main` (or run workflow **Deploy Firebase Hosting** manually).

Workflow file: [`.github/workflows/firebase-hosting.yml`](../.github/workflows/firebase-hosting.yml)

### Cloud Build (auto-deploy on push to `main`)

This is the supported CI path for this repo.

```bash
# One-time IAM/APIs (owner on lockmic-11c1a)
./Scripts/setup_cloudbuild_hosting.sh lockmic-11c1a
```

Then in **Google Cloud Console** (project **lockmic-11c1a**):

1. **Cloud Build → Repositories** → Connect repository → GitHub → `oochernyshev/lockmic`
2. **Cloud Build → Triggers → Create trigger**
   - Event: **Push to a branch**
   - Branch: `^main$`
   - Configuration: **Cloud Build configuration file**
   - File: **`cloudbuild.yaml`** (never Buildpacks / Autodetect)
3. Push to `main` or test:

```bash
gcloud config set project lockmic-11c1a
gcloud builds submit --config cloudbuild.yaml .
```

Live URL: `https://lockmic-11c1a.web.app`

GitHub Actions workflow is **manual-only** so it does not double-deploy with Cloud Build.

## Custom domain

In Firebase Console → Hosting → **Add custom domain** (e.g. `lockmic.wixee.ai` or your apex).

## Download links

- **DMG (direct file)**: `https://github.com/oochernyshev/lockmic/releases/download/vX.Y.Z/LockMic-X.Y.Z.dmg`  
  The landing page resolves the latest `.dmg` asset via the GitHub API (not the releases HTML page).
- **Homebrew**: `brew install --cask lockmic` (after the cask is published)

Publish a release with the DMG attached:

```bash
./Scripts/package_dmg.sh
gh release create v1.2.0 \
  build/dist/LockMic-1.2.0.dmg \
  build/dist/LockMic-1.2.0.zip \
  --title "LockMic 1.2.0" \
  --notes "System-wide mic mute for macOS."
```

Repo: https://github.com/oochernyshev/lockmic
