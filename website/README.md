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

### Manual

```bash
# set project id in .firebaserc if needed
firebase login
firebase deploy --only hosting
```

### Cloud Build

1. Create/link a Firebase project; enable Hosting.
2. Update `.firebaserc` → `projects.default`.
3. Create a CI token: `firebase login:ci`
4. Store as Secret Manager secret named `FIREBASE_TOKEN`.
5. Create a Cloud Build trigger on `main` using `cloudbuild.yaml`.
6. Grant the Cloud Build SA **Firebase Hosting Admin** + **Secret Manager Secret Accessor**.

```bash
gcloud builds submit --config cloudbuild.yaml .
```

## Custom domain

In Firebase Console → Hosting → **Add custom domain** (e.g. `lockmic.wixee.ai` or your apex).

## Download links

- **DMG**: GitHub Releases latest (`https://github.com/oochernyshev/lockmic/releases/latest`)
- **Homebrew**: `brew install --cask lockmic` (after the cask is published)

Repo: https://github.com/oochernyshev/lockmic
