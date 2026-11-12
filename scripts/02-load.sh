#!/usr/bin/env bash
# Send N requests to one frontend route, C at a time, and count status codes.
# Usage: ./scripts/02-load.sh [route=/] [N=20] [C=5]     e.g. ./scripts/02-load.sh /5xx 50 10
source "$(dirname "$0")/env.sh"
ROUTE="${1:-/}"; N="${2:-20}"; C="${3:-5}"
URL="$(service_url "$FRONTEND")"; HDR="$(auth_header)"; trap 'rm -f "$HDR"' EXIT

echo "== $N × GET $ROUTE, $C in parallel → $URL"
hit "$URL$ROUTE" "$N" "$C" "$ROUTE" | sort | uniq -c
