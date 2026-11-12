#!/usr/bin/env bash
# Start an incident: steady normal traffic on / plus heavy traffic on one broken route.
# Usage: ./scripts/03-incident.sh <5xx|queryslow|slow|mystery> [minutes=8]
#   mystery = a random case; the answer is written to .mystery-answer (don't peek).
source "$(dirname "$0")/env.sh"
CASE="${1:?usage: 03-incident.sh <5xx|queryslow|slow|mystery> [minutes]}"; MINUTES="${2:-8}"

if [ "$CASE" = mystery ]; then
  CASES=(5xx queryslow slow); CASE="${CASES[RANDOM % 3]}"
  echo "/$CASE" > "$ROOT/.mystery-answer"; LABEL="/???"
  echo "== Mystery incident for $MINUTES min. Find the route, the service and the root cause."
else
  LABEL="/$CASE"
  echo "== Incident /$CASE for $MINUTES min (plus normal traffic on /)"
fi
case "$CASE" in
  5xx) C=8 ;; queryslow) C=20 ;; slow) C=16 ;;  # slow: 16 keeps p95 > 1 s (C=10 peaked at 1.1 s)
  *) echo "unknown case: $CASE"; exit 1 ;;
esac

URL="$(service_url "$FRONTEND")"; HDR="$(auth_header)"
OUT="$(mktemp)"; END=$((SECONDS + MINUTES * 60))
trap 'rm -f "$HDR" "$OUT"' EXIT
while [ "$SECONDS" -lt "$END" ]; do
  hit "$URL/" 20 2 / >> "$OUT" &
  hit "$URL/$CASE" 100 "$C" "$LABEL" >> "$OUT"
  wait
  echo "$(date +%H:%M:%S) $(wc -l < "$OUT" | tr -d ' ') requests sent"
done
echo "== Status codes (route, code):"
sort "$OUT" | uniq -c
