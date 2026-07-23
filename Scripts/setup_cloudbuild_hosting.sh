#!/usr/bin/env bash
# One-time IAM + API setup for Cloud Build → Firebase Hosting.
# Run as a project owner on project lockmic-11c1a.
set -euo pipefail

PROJECT_ID="${1:-lockmic-11c1a}"

echo "==> Project: $PROJECT_ID"
gcloud config set project "$PROJECT_ID"

echo "==> Enable APIs"
gcloud services enable \
  cloudbuild.googleapis.com \
  secretmanager.googleapis.com \
  firebase.googleapis.com \
  firebasehosting.googleapis.com \
  --project="$PROJECT_ID"

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
CB_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
echo "==> Cloud Build SA: $CB_SA"

for ROLE in \
  roles/firebasehosting.admin \
  roles/firebase.admin \
  roles/serviceusage.serviceUsageConsumer
do
  echo "    bind $ROLE"
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${CB_SA}" \
    --role="$ROLE" \
    --condition=None \
    --quiet >/dev/null
done

echo ""
echo "==> Done. Next (console or gcloud):"
echo "    1. Cloud Build → Repositories → connect GitHub: oochernyshev/lockmic"
echo "    2. Triggers → Create:"
echo "         event: push to branch ^main\$"
echo "         config: cloudbuild.yaml (NOT buildpacks)"
echo "    3. Test:  gcloud builds submit --config cloudbuild.yaml ."
echo "    4. Site:  https://${PROJECT_ID}.web.app"
