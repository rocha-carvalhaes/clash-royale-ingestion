#!/usr/bin/env bash
# Provisiona IP estático, VM e2-micro e bucket bronze. Idempotente o suficiente para reexecução.
# Uso: PROJECT=meu-projeto BUCKET=meu-bucket-bronze ./infra/provision.sh
set -euo pipefail

: "${PROJECT:?defina PROJECT}"
: "${BUCKET:?defina BUCKET}"
REGION=us-central1
ZONE=us-central1-a   # free tier e2-micro: us-west1, us-central1 ou us-east1
VM=clash-royale-ingestion-vm
IP_NAME=clash-royale-ingestion-ip

gcloud config set project "$PROJECT"

gcloud compute addresses describe "$IP_NAME" --region "$REGION" >/dev/null 2>&1 \
  || gcloud compute addresses create "$IP_NAME" --region "$REGION"
IP=$(gcloud compute addresses describe "$IP_NAME" --region "$REGION" --format='value(address)')

gcloud compute instances describe "$VM" --zone "$ZONE" >/dev/null 2>&1 \
  || gcloud compute instances create "$VM" --zone "$ZONE" \
       --machine-type e2-micro --boot-disk-size 30GB --boot-disk-type pd-standard \
       --image-family debian-12 --image-project debian-cloud \
       --address "$IP" --scopes storage-rw

gcloud storage buckets describe "gs://$BUCKET" >/dev/null 2>&1 \
  || gcloud storage buckets create "gs://$BUCKET" --location "$REGION" --uniform-bucket-level-access

cat > /tmp/lifecycle.json <<'EOF'
{"rule":[
 {"action":{"type":"SetStorageClass","storageClass":"NEARLINE"},"condition":{"age":30}},
 {"action":{"type":"SetStorageClass","storageClass":"COLDLINE"},"condition":{"age":180}}
]}
EOF
gcloud storage buckets update "gs://$BUCKET" --lifecycle-file=/tmp/lifecycle.json

echo "IP estático: $IP  -> cadastre em https://developer.clashroyale.com"
