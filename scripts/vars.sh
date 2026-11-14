# Names every workshop step uses, derived from your gcloud project. Usage: source scripts/vars.sh
# Safe to source again in every new Cloud Shell tab.
export PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
export REGION=asia-southeast2
export HUB="$REGION-docker.pkg.dev/$PROJECT_ID/dockerhub"
export GRAFANA_SA="grafana-reader@$PROJECT_ID.iam.gserviceaccount.com"
if [ -z "$PROJECT_ID" ]; then
  echo "BELUM ADA PROJECT. Jalankan dulu: gcloud config set project <project-id-kamu>"
else
  echo "project=$PROJECT_ID  region=$REGION"
fi
