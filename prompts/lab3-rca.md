# Labs 3–5 + mystery · Root cause playbook (paste into Grafana Assistant)

Same four steps for every incident. Paste them one at a time and read the answer before the next.
Start right after `./scripts/03-incident.sh <case>`; don't wait for the alert (it fires 4–6 min later).

---

**0 · Ground rules (paste once)**

You are an SRE helping me investigate an incident on two Cloud Run services in asia-southeast2:
`frontend` (routes /, /5xx, /queryslow, /slow) calls `backend` (routes /, /pay, /query).
Data sources: "Google Cloud (PromQL)" (Cloud Run metrics `run_googleapis_com:*` per service_name; log-based metrics
`logging_googleapis_com:user_app_requests{service,route,status}`, `logging_googleapis_com:user_app_latency_bucket{service,route}`,
`logging_googleapis_com:user_app_errors{service,error_type}`, each needs the matcher `monitored_resource="cloud_run_revision"`) and
"Google Cloud Logging" (frontend and backend lines of one request share `trace`). If you cannot query Google Cloud
Logging yourself, say so and give me the exact log filter: I will run it in Explore and paste the result.
Rules: for every claim show the query and the result. If you have no evidence, say "unknown". Don't change anything.

---

**1 · Scope the symptom**

What is wrong right now, in the last 15 minutes? Which service and which route: 5xx ratio and p95 latency per
service_name (Cloud Run) and per service+route (log-based). Since when (first minute it went bad)?
Is `/` affected too, or only one route?

---

**2 · Follow the dependency**

Is `frontend` failing on its own, or because of `backend`? Compare their 5xx and p95 side by side for the same window.
Then in "Google Cloud Logging", take one frontend ERROR or WARNING line, read its `trace` field and query
`trace="<that trace>"` to show every log line of that one request in both services. What happened downstream?

---

**3 · Resource or code?**

For the service that is the culprit: show CPU (`run_googleapis_com:container_cpu_utilizations_bucket{monitored_resource="cloud_run_revision"}`, p95) and
instances (`run_googleapis_com:container_instance_count{monitored_resource="cloud_run_revision"}`). Then show its top error_type
(`logging_googleapis_com:user_app_errors{monitored_resource="cloud_run_revision"}`) and its most frequent WARNING/ERROR messages in Cloud Logging.
Is this capacity (CPU/instances maxed out), a slow dependency, or code doing too much work? Would adding instances help?

---

**4 · Root cause**

Give me: root cause in one sentence, which service it lives in, confidence (low/medium/high),
the 3 strongest pieces of evidence (query + result each), what would prove you wrong,
and ONE safe, reversible mitigation. No evidence, no claim.

---

## Per-case follow-ups (only if steps 1–4 stall)

- **`/5xx`**: The frontend logs `backend POST /pay returned 503 after …ms` (`UpstreamError`). What does the backend log
  for the same trace? Which dependency does it name, how often does it fail, and after how many ms?
- **`/queryslow`**: Is backend CPU high or low? Show the backend WARNING `slow query …ms` lines: what query, how many
  rows examined, which index? How does that relate to `ConnectionPoolTimeout` and the pool size? Would scaling help?
- **`/slow`**: Which routes on `frontend` are slow, and is `backend` slow at all? Which route actually burns CPU
  (look for `slow render`)? Which route is the victim and which is the culprit?

---

## Act (you, not the Assistant)

Run only the command your evidence supports. Then send fresh traffic to the same route (`./scripts/03-incident.sh <case> 4` with the case you found, never `mystery`: that picks a new one),
wait 3 minutes (Cloud Run metrics lag), and ask: "Did the 5xx ratio / p95 recover in the last 5 minutes? Show the query."

| Case | Mitigation |
|---|---|
| `/5xx` | `gcloud run services update backend --region asia-southeast2 --update-env-vars PAYMENT_GATEWAY=payment-gw-backup.internal` |
| `/queryslow` | `gcloud run services update backend --region asia-southeast2 --update-env-vars ORDERS_INDEX=true` |
| `/slow` | `gcloud run services update frontend --region asia-southeast2 --update-env-vars RECO_CACHE=true` |

Mystery round: reset first (README, “Reset before the mystery round”), run `./scripts/03-incident.sh mystery`,
solve it with steps 1–4, then check `cat .mystery-answer`.
