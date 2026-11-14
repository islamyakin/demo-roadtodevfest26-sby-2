# Incident Response in the AI Era

**Accelerating Root Cause Analysis on Google Cloud with Grafana Assistant**
Road to DevFest Cloud ’26 #2 · Surabaya · 90-minute workshop

You deploy a two-service shop (`frontend` → `backend`) to Cloud Run, connect **Grafana Cloud** to Cloud Monitoring
and Cloud Logging, then break the shop three times and use Grafana Assistant to find the root cause.
The Assistant reads and queries; **you** decide and run the fix. Nothing runs on your laptop except `gcloud`,
`terraform` and `curl`: no Docker.

- Slides: [slides/workshop.pptx](slides/workshop.pptx) · [slides/workshop.pdf](slides/workshop.pdf)
- Prompts to paste into the Assistant: [prompts/](prompts/)

## Architecture

```
 you (gcloud identity token)
   │
   ▼
 frontend  (Cloud Run, private, SA frontend-sa)      GET /  /5xx  /queryslow  /slow
   │  ID token from metadata server + traceparent / X-Cloud-Trace-Context forwarded
   ▼
 backend   (Cloud Run, private, only frontend-sa has roles/run.invoker)   GET /  POST /pay  GET /query
   │
   │  both: one JSON log line per event, same logging.googleapis.com/trace = one request end to end
   ▼
 Cloud Logging ──► log-based metrics app_requests · app_latency · app_errors   (per route + error_type)
 Cloud Monitoring ◄── Cloud Run built-ins: request_count · request_latencies · cpu · instances (per service)
   │
   │                                Grafana Cloud (your stack)
   ├─► PromQL API ◄──── "Google Cloud (PromQL)"  Prometheus data source, default ──┐
   │        ▲                                                                      ├─ dashboard "Shop · Overview"
   │        └── token refreshed by Cloud Run job "grafana-datasource-syncer"       ├─ 2 alert rules
   │            (Google's datasource-syncer, Cloud Scheduler every 10 min)         └─ Grafana Assistant
   └─► Logging API ◄─── "Google Cloud Logging"   Logging plugin, read-only key ──┘
```

Everything, on both sides, is created by one `terraform apply`:
[infra/main.tf](infra/main.tf) (Google Cloud) and [infra/grafana.tf](infra/grafana.tf) (Grafana Cloud).
One image is built from `app/` with Cloud Build + buildpacks; both services run it and the `APP` env var picks the
module via the `Procfile`. Region `asia-southeast2`.

**Why a Prometheus data source:** Grafana Assistant’s documented query languages are PromQL, LogQL, TraceQL and SQL,
and Cloud Monitoring answers PromQL. So the Assistant gets Cloud Monitoring as plain PromQL. That data source needs a
Google OAuth token, which Google’s own datasource-syncer renews every 10 min from a Cloud Run job: nobody generates
tokens by hand.

| Signal | PromQL name | Labels | Answers |
|---|---|---|---|
| Cloud Run requests | `run_googleapis_com:request_count` | `service_name`, `revision_name`, `response_code_class` | which **service** fails |
| Cloud Run latency | `run_googleapis_com:request_latencies_bucket` | `service_name`, `le` | which **service** is slow |
| Cloud Run CPU | `run_googleapis_com:container_cpu_utilizations_bucket` | `service_name`, `le` | resource or code? |
| Cloud Run instances | `run_googleapis_com:container_instance_count` | `service_name`, `state` | is it scaling? |
| App requests (log-based) | `logging_googleapis_com:user_app_requests` | `service`, `route`, `status` | which **route** fails |
| App latency (log-based, ms) | `logging_googleapis_com:user_app_latency_bucket` | `service`, `route`, `le` | which **route** is slow |
| App errors (log-based) | `logging_googleapis_com:user_app_errors` | `service`, `error_type` | **what** error |

Cloud Run metrics have no route label; that is why the log-based metrics exist. In PromQL every selector needs
`monitored_resource="cloud_run_revision"` (these metrics can belong to several resource types).

Dashboard **Shop · Overview** (folder *Workshop*): per service (Cloud Run metrics), per route (log-based metrics),
errors by type, instances, and WARNING/ERROR logs from both services.
Alerts (one instance per `service_name`): **5xx ratio above 5%** and **p95 latency above 1s**. Cloud Run metrics
arrive every 60 s with a 2–3 min delay and the rules wait 2 min, so alerts fire **4–6 min after the load starts**.
Start asking the Assistant before that.

## What gets created

| Where | Resource | Name |
|---|---|---|
| Google Cloud | APIs | run, cloudbuild, artifactregistry, compute, logging, monitoring, cloudresourcemanager, iam, secretmanager, cloudscheduler |
| Google Cloud | Artifact Registry | `shop` (the app image, built by Cloud Build) and `gke-gcr` (pull-through proxy for Google’s syncer image on gke.gcr.io: Cloud Run cannot pull from gke.gcr.io directly) |
| Google Cloud | Cloud Run services | `frontend`, `backend` (private, 1 vCPU, 512 MiB, max 2 instances, concurrency 16) |
| Google Cloud | Service accounts | `frontend-sa`, `backend-sa` (no project roles); `grafana-reader` (`monitoring.viewer`, `logging.viewer`) |
| Google Cloud | IAM | `frontend-sa` → `run.invoker` on `backend` |
| Google Cloud | Log-based metrics | `app_requests`, `app_latency`, `app_errors` |
| Google Cloud | Token sync | Secret `grafana-sa-token`, Cloud Run job + Cloud Scheduler `grafana-datasource-syncer` |
| Grafana Cloud | Data sources | `Google Cloud (PromQL)` (default), `Google Cloud Logging` |
| Grafana Cloud | Dashboard, alerts | folder `Workshop`, `Shop · Overview`, rule group `shop` |

The `Google Cloud Logging` data source uses a key of the read-only `grafana-reader` account (that plugin cannot use a
refreshed token). The key goes straight from Terraform into Grafana Cloud and into your local Terraform state, never
into git. Changing code in `app/` changes the image tag, so the next `terraform apply` rebuilds and redeploys.
A `terraform apply` also undoes the lab mitigations (env vars set with gcloud): handy to re-arm an incident.

## Prerequisites

| Need | Check |
|---|---|
| Google Cloud project **with billing enabled**; you are Owner | `gcloud billing projects describe <project-id>` shows `billingEnabled: true` |
| gcloud, logged in | `gcloud auth login && gcloud auth application-default login` |
| Terraform ≥ 1.5 | `terraform version` (Cloud Shell has it) |
| A Grafana Cloud stack with Grafana Assistant | grafana.com → your stack → open Grafana |
| The Cloud Logging plugin in that stack | Grafana → Administration → Plugins and data → Plugins → “Google Cloud Logging” → Install |
| A stack service account token, role **Admin** | Grafana → Administration → Users and access → Service accounts → Add → Add token |

## Deploy (Lab 0)

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars   # set project_id, grafana_url, grafana_token
terraform init
terraform apply                                  # review the plan, type yes (first run 5–8 min)
cd ..
./scripts/02-load.sh / 20                        # expect 20 × 200
```

## Labs

| Time | Lab | Run | Ask the Assistant | You should see |
|---|---|---|---|---|
| 0:00 | Talk (15′) | – | – | – |
| 0:15 | 0 · Deploy the shop (10′) | deploy (above), then try `./scripts/02-load.sh /5xx 10`, `/queryslow`, `/slow` | – | `20 200` on `/`; a mix of `200`/`502` on `/5xx` |
| 0:25 | 1 · Explore Grafana Cloud (10′) | open your stack → Dashboards → Workshop → **Shop · Overview**; Explore with both data sources; open the Assistant (sidebar) | [lab1-orient.md](prompts/lab1-orient.md) | request rate per service; log lines from both services |
| 0:35 | 2 · Dashboard by prompt (10′) | keep traffic for ~5 min: `./scripts/02-load.sh / 6000 2` | [lab2-dashboard.md](prompts/lab2-dashboard.md) | your own “Shop · RED” built by the Assistant; compare it with “Shop · Overview” |
| 0:45 | 3 · Incident `/5xx` (12′) | `./scripts/03-incident.sh 5xx` | [lab3-rca.md](prompts/lab3-rca.md) | both alerts on **both** services (≈50% 5xx, p95 ≈ 1.5 s from the gateway timeout); follow the trace from the frontend 502 to the backend `PaymentGatewayTimeout` |
| 0:57 | 4 · Incident `/queryslow` (12′) | `./scripts/03-incident.sh queryslow` | [lab3-rca.md](prompts/lab3-rca.md) | alert **p95 latency above 1s**, later some 5xx; CPU stays low |
| 1:09 | 5 · Incident `/slow` (10′) | `./scripts/03-incident.sh slow` | [lab3-rca.md](prompts/lab3-rca.md) | frontend p95 high on **every** route, backend healthy |
| 1:19 | Wrap-up (11′) | reset (below) → `./scripts/03-incident.sh mystery 5` → `cat .mystery-answer`; then cleanup (below) | [lab3-rca.md](prompts/lab3-rca.md), [wrapup-postmortem.md](prompts/wrapup-postmortem.md) | mystery solved, postmortem draft, everything deleted |

`03-incident.sh <case> [minutes=8]` sends steady normal traffic to `/` plus heavy traffic to the broken route, and
prints the status codes per route at the end. Each lab ends with **you** running one mitigation command
(in [lab3-rca.md](prompts/lab3-rca.md), section “Act”).

**Reset before the mystery round** (mitigations are env vars and stay on):

```bash
gcloud run services update backend  --region asia-southeast2 --remove-env-vars PAYMENT_GATEWAY,ORDERS_INDEX
gcloud run services update frontend --region asia-southeast2 --remove-env-vars RECO_CACHE
```

Try it locally (no auth, no trace), in two terminals inside `app/` after `pip install -r requirements.txt`:
`PORT=8082 python backend.py` and `BACKEND_URL=http://localhost:8082 python frontend.py`, then `curl localhost:8080/5xx`.

## Incident cases (facilitator section)

> **Participants: skip this until after the labs.** Finding this with the Assistant is the exercise.

| Route | Symptom | Root cause (where it lives) | Mitigation (you run it) | Fix for good |
|---|---|---|---|---|
| `/5xx` | frontend 502; frontend ERROR `backend POST /pay returned 503 after …ms`, `error_type=UpstreamError` | **backend**: dependency `payment-gw.internal` times out on ~60% of calls after 1500 ms → ERROR `PaymentGatewayTimeout`, 503. The service that alerts is not always the broken one: follow the trace downstream. | `gcloud run services update backend --region asia-southeast2 --update-env-vars PAYMENT_GATEWAY=payment-gw-backup.internal` | timeouts, circuit breaker, retries with a budget; gateway SLO with the provider; failover automation |
| `/queryslow` | high latency on frontend and backend, then some 502 (frontend) / 503 (backend); frontend WARNING `backend GET /query slow: …ms` | **backend**: order search is a full table scan (`SELECT * FROM orders WHERE customer_email = ?`, `rows_examined=1200000`, no index on `orders.customer_email`), 800–1600 ms while holding 1 of 4 pool connections → WARNING `slow query …ms`, then ERROR `ConnectionPoolTimeout`. Trap: “just scale the backend”: CPU is low, the query is slow; more instances would only add database load. | `gcloud run services update backend --region asia-southeast2 --update-env-vars ORDERS_INDEX=true` (stands in for `CREATE INDEX`) | the index; slow-query log + alert; query review |
| `/slow` | frontend p95 high for **all** routes, including `/` (the victim); backend healthy | **frontend**: recommendations scores 3,000,000 items on every request with no cache (CPU-bound, holds the CPU and Python’s GIL) → WARNING `slow render: recommendations scored … items in …ms CPU`; `container_cpu_utilizations` high. Victim vs culprit. | `gcloud run services update frontend --region asia-southeast2 --update-env-vars RECO_CACHE=true` | cache/precompute; profiling; CPU alert |
| `mystery` | route hidden as `/???` | one of the three at random; answer in `.mystery-answer` | as above | – |

## Repo map

| Path | What |
|---|---|
| `app/common.py` | Flask app factory, JSON logging, trace id, per-request `request` log line |
| `app/frontend.py` | routes `/`, `/5xx`, `/queryslow`, `/slow`; env `BACKEND_URL`, `RECO_ITEMS`, `RECO_CACHE` |
| `app/backend.py` | routes `/`, `/pay`, `/query`; env `PAYMENT_GATEWAY`, `PAYMENT_FAILURE_RATE`, `PAYMENT_TIMEOUT_MS`, `DB_POOL_SIZE`, `DB_POOL_TIMEOUT_MS`, `ORDERS_INDEX` |
| `app/Procfile`, `app/requirements.txt` | one image, `APP=frontend\|backend` picks the module |
| `infra/main.tf` | Google Cloud: APIs, registry, image build, service accounts, both services, invoker binding, log-based metrics |
| `infra/grafana.tf` | Grafana Cloud: read-only identity, 2 data sources, token syncer job + schedule, dashboard, alert rules |
| `infra/shop-overview.json` | the “Shop · Overview” dashboard |
| `infra/terraform.tfvars.example` | your project id, stack URL and token (copy to `terraform.tfvars`, gitignored) |
| `scripts/env.sh` | shared names: project, region, service names, `service_url`, `hit` |
| `scripts/02-load.sh` | `[route=/] [N=20] [C=5]` load + status-code count |
| `scripts/03-incident.sh` | `<5xx\|queryslow\|slow\|mystery> [minutes=8]` |
| `prompts/` | Assistant prompts per lab |
| `slides/workshop.pptx`, `slides/workshop.pdf` | the deck |

## Troubleshooting

| Problem | Fix |
|---|---|
| `Billing account … is not found` when enabling an API, or Cloud Run answers 500/503 | billing is off for the project: link a billing account (Console → Billing), then `terraform apply` again |
| `Google Cloud (PromQL)` data source: 401 / no data | run the syncer now: `gcloud run jobs execute grafana-datasource-syncer --region asia-southeast2 --wait`, then check its logs in Cloud Run → Jobs |
| `terraform apply` fails on `grafana_data_source.logging` | the Cloud Logging plugin is not installed in your stack yet (Prerequisites) |
| `02-load.sh` gets 401/403 | services are private: run `gcloud auth login` (the script sends your identity token); your user needs `roles/run.invoker` (Owner has it) |
| Backend returns 403 to the frontend | invoker binding missing: `terraform apply` again, or wait a minute for IAM to propagate |
| Image build (`gcloud builds submit`) fails on permissions | new projects: Cloud Build runs as the Compute Engine default service account; grant it once: `gcloud projects add-iam-policy-binding <project-id> --member serviceAccount:<project-number>-compute@developer.gserviceaccount.com --role roles/cloudbuild.builds.builder`, then `terraform apply` again. Not in Terraform on purpose: `destroy` would revoke it from a shared project. |
| `terraform apply` fails right after enabling APIs | API enablement is eventually consistent: wait a minute and run `terraform apply` again |
| Log-based metric panels empty | they only count lines written after `terraform apply` created them, and lag 1–3 min; send load again |
| Assistant can’t query Cloud Logging directly | Explore → Google Cloud Logging, run the filter, then ask the Assistant about what is on screen; or use PromQL `logging_googleapis_com:user_app_errors{monitored_resource="cloud_run_revision"}` |

## Guardrails

- The Assistant acts as your Grafana user; every Google data source here is read-only. It never changes Cloud Run: you do.
- Evidence first: ask for the query and result behind every claim, and read it before you act. No evidence, no claim.
- One safe, reversible mitigation at a time (an env var you can remove), then check the metrics recover.
- Prompts and query results go to the Assistant backend in Grafana Cloud: check your data policy before using it on production data.
- In Grafana Cloud you can also try **Investigations** (multi-agent RCA) on top of the prompts here.

## Cleanup

```bash
terraform -chdir=infra destroy
rm -f .mystery-answer
```

`terraform destroy` deletes everything in the table under “What gets created”, on both sides. Enabled APIs stay on
(free). The Cloud Build source bucket (`<project-id>_cloudbuild`) stays; delete it in Cloud Storage if you want a clean
project. Your Grafana Cloud stack itself is not touched.
