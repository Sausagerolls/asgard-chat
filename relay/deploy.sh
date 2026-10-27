#!/usr/bin/env bash
# Deploys the Asgard push relay to Google Cloud Run (free tier).
# Safe to run again: it updates credentials you pass and never replaces the
# relay master key (replacing it would force every server to re-register).
#
#   PROJECT_ID=my-project APNS_KEY_FILE=~/keys/AuthKey_ABC123.p8 APNS_KEY_ID=ABC123DEF4 APNS_TEAM_ID=J4UJD4Z33J \
#   FCM_CREDENTIALS_FILE=~/keys/firebase-sa.json ./relay/deploy.sh
#
# Optional: REGION (default europe-west1), SERVICE (default asgard-push),
# DOMAIN (e.g. push.giantmushroom.studio), BILLING_ACCOUNT + BUDGET (e.g. 1GBP).
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID to your Google Cloud project id}"
REGION="${REGION:-europe-west1}"
SERVICE="${SERVICE:-asgard-push}"
APNS_TOPIC="${APNS_TOPIC:-com.giantmushroom.asgardchat}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SA="${SERVICE}@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/asgard/${SERVICE}:$(date +%Y%m%d%H%M%S)"
gc() { gcloud --project "$PROJECT_ID" --quiet "$@"; }

echo "▸ Enabling services"
gc services enable run.googleapis.com secretmanager.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com

echo "▸ Secrets"
secret() { # name [file]
  if ! gc secrets describe "$1" >/dev/null 2>&1; then
    gc secrets create "$1" --replication-policy=automatic >/dev/null
  fi
  if [ -n "${2:-}" ]; then gc secrets versions add "$1" --data-file="$2" >/dev/null; echo "  updated $1"; fi
}
if ! gc secrets describe relay-master-key >/dev/null 2>&1; then
  secret relay-master-key
  openssl rand -base64 32 | tr -d '\n' | gc secrets versions add relay-master-key --data-file=- >/dev/null
  echo "  created relay-master-key"
fi
SECRETS="RELAY_MASTER_KEY=relay-master-key:latest"
ENVS="APNS_TOPIC=${APNS_TOPIC}"
if [ -n "${APNS_KEY_FILE:-}" ]; then
  : "${APNS_KEY_ID:?Set APNS_KEY_ID (10 characters, from developer.apple.com › Keys)}"
  : "${APNS_TEAM_ID:?Set APNS_TEAM_ID}"
  secret apns-key "$APNS_KEY_FILE"
fi
if gc secrets describe apns-key >/dev/null 2>&1; then
  SECRETS="${SECRETS},APNS_KEY=apns-key:latest"
  [ -n "${APNS_KEY_ID:-}" ] && ENVS="${ENVS},APNS_KEY_ID=${APNS_KEY_ID},APNS_TEAM_ID=${APNS_TEAM_ID}"
fi
[ -n "${FCM_CREDENTIALS_FILE:-}" ] && secret fcm-credentials "$FCM_CREDENTIALS_FILE"
gc secrets describe fcm-credentials >/dev/null 2>&1 && SECRETS="${SECRETS},FCM_CREDENTIALS=fcm-credentials:latest"

echo "▸ Service account (can read only these secrets)"
gc iam service-accounts describe "$SA" >/dev/null 2>&1 || gc iam service-accounts create "$SERVICE" --display-name="Asgard push relay" >/dev/null
for s in relay-master-key apns-key fcm-credentials; do
  gc secrets describe "$s" >/dev/null 2>&1 && gc secrets add-iam-policy-binding "$s" --member="serviceAccount:${SA}" --role=roles/secretmanager.secretAccessor >/dev/null
done

echo "▸ Build permissions"
# New projects build with the default compute service account, which needs the Cloud Build role.
NUMBER="$(gc projects describe "$PROJECT_ID" --format='value(projectNumber)')"
BUILDER="serviceAccount:${NUMBER}-compute@developer.gserviceaccount.com"
if gc projects get-iam-policy "$PROJECT_ID" --flatten=bindings --filter="bindings.role=roles/cloudbuild.builds.builder AND bindings.members=${BUILDER}" \
     --format='value(bindings.role)' | grep -q builder; then
  echo "  already granted"
else
  gc projects add-iam-policy-binding "$PROJECT_ID" --member="$BUILDER" --role=roles/cloudbuild.builds.builder --condition=None >/dev/null
fi

echo "▸ Building image"
gc artifacts repositories describe asgard --location="$REGION" >/dev/null 2>&1 ||
  gc artifacts repositories create asgard --repository-format=docker --location="$REGION" >/dev/null
gc builds submit "$ROOT/server" --config="$ROOT/relay/cloudbuild.yaml" --substitutions=_IMAGE="$IMAGE"

echo "▸ Deploying (scales to zero; one instance at most, so it can never run up a bill)"
FLAGS=(--image="$IMAGE" --region="$REGION" --service-account="$SA" --allow-unauthenticated
  --min-instances=0 --max-instances=1 --concurrency=80 --cpu=1 --memory=256Mi --timeout=30
  --set-secrets="$SECRETS")
# Keep earlier env vars (e.g. APNS_KEY_ID) when they aren't passed this time.
[ -n "${APNS_KEY_ID:-}" ] && FLAGS+=(--update-env-vars="$ENVS") || FLAGS+=(--update-env-vars="APNS_TOPIC=${APNS_TOPIC}")
gc run deploy "$SERVICE" "${FLAGS[@]}"
URL="$(gc run services describe "$SERVICE" --region="$REGION" --format='value(status.url)')"
curl -fsS "$URL/health" >/dev/null && echo "  healthy: $URL"

if [ -n "${DOMAIN:-}" ]; then
  echo "▸ Custom domain $DOMAIN"
  gc beta run domain-mappings describe --domain="$DOMAIN" --region="$REGION" >/dev/null 2>&1 ||
    gc beta run domain-mappings create --service="$SERVICE" --domain="$DOMAIN" --region="$REGION"
  gc beta run domain-mappings describe --domain="$DOMAIN" --region="$REGION" --format='table(status.resourceRecords[].type,status.resourceRecords[].rrdata)'
  echo "  Add those DNS records at your DNS provider. HTTPS starts working a few minutes after they resolve."
fi

if [ -n "${BILLING_ACCOUNT:-}" ]; then
  echo "▸ Budget alert ${BUDGET:-1GBP}"
  # The budgets API needs a quota project; bill the call to this project.
  gcloud billing budgets create --billing-project="$PROJECT_ID" --billing-account="$BILLING_ACCOUNT" --display-name="Asgard push relay" \
    --budget-amount="${BUDGET:-1GBP}" --threshold-rule=percent=0.5 --threshold-rule=percent=1.0 \
    --filter-projects="projects/${PROJECT_ID}" >/dev/null && echo "  emails you if spend reaches 50% / 100%"
fi

echo
echo "Done. Servers use ${DOMAIN:+https://$DOMAIN}${DOMAIN:-$URL} as ASGARD_PUSH_RELAY."
