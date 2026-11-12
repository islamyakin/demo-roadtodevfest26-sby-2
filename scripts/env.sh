# Shared names for every script. Sourced, not run.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; [ -f "$ROOT/.env" ] && . "$ROOT/.env"; set +a

export GCP_PROJECT_ID="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
[ -n "$GCP_PROJECT_ID" ] || { echo "Set a project: gcloud config set project <id>"; exit 1; }
export CLOUDSDK_CORE_PROJECT="$GCP_PROJECT_ID"  # every gcloud call below uses this project
REGION="${REGION:-asia-southeast2}"
FRONTEND=frontend
BACKEND=backend

service_url() { gcloud run services describe "$1" --region "$REGION" --format 'value(status.url)'; }
# Your identity token in a private temp file (mktemp = mode 600); curl -H @file keeps it out of `ps`.
auth_header() {
  local t f; t="$(gcloud auth print-identity-token)" || { echo "gcloud login expired: gcloud auth login" >&2; return 1; }
  f="$(mktemp)"; echo "Authorization: Bearer $t" > "$f"; echo "$f"
}

# hit <url> <N> <C> <label>: N GETs, C in parallel, one "<label> <status>" line each.
# Needs $HDR from auth_header. A curl timeout must not stop the caller (set -e), hence || true.
hit() {
  seq "$2" | xargs -P "$3" -I{} curl -s -o /dev/null -w "$4 %{http_code}\n" --max-time 30 \
    -H @"$HDR" "$1" || true
}
