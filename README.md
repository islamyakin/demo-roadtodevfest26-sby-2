# Incident Response in the AI Era

**Accelerating Root Cause Analysis on Google Cloud with Grafana Assistant**
Road to DevFest Cloud ’26 #2 · Surabaya · 90-minute workshop

You deploy a two-service shop (`frontend` → `backend`) to Cloud Run, connect Grafana to Cloud Monitoring and
Cloud Logging, then break the shop three times and use Grafana Assistant to find the root cause.
The Assistant reads and queries; **you** decide and run the fix.

- Slides: [slides/index.html](slides/index.html) (open in a browser, ← → to navigate).
- Prompts to paste into the Assistant: [prompts/](prompts/).

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
   ├─► "Google Cloud (PromQL)"   uid gcp-promql  (via gmp-frontend container, signs with ADC)          ─┐
   │                                                                                                     ├─► Grafana OSS 13.3 (Docker, laptop)
   └─► "Google Cloud Logging"    (ADC)                                                                   ─┘     alert rules · Grafana Assistant
                                                                                                                (Quick connect → free Grafana Cloud stack)
```

Everything in Google Cloud is created by Terraform ([infra/main.tf](infra/main.tf)): one image is built from `app/`
with Cloud Build + buildpacks (no Docker needed for this), both services run it, and the `APP` env var picks the
module via the `Procfile`. Region `asia-southeast2`. No service-account keys: Grafana uses
your `gcloud` login: the ADC file is mounted read-only into Grafana and into `gmp-frontend`, Google’s Managed
Prometheus frontend that serves Cloud Monitoring’s PromQL API to Grafana. Nothing to generate or refresh.

| Signal | PromQL name | Labels | Answers |
|---|---|---|---|
| Cloud Run requests | `run_googleapis_com:request_count` | `service_name`, `revision_name`, `response_code_class` | which **service** fails |
| Cloud Run latency | `run_googleapis_com:request_latencies_bucket` | `service_name`, `le` | which **service** is slow |
| Cloud Run CPU | `run_googleapis_com:container_cpu_utilizations_bucket` | `service_name`, `le` | resource or code? |
| Cloud Run instances | `run_googleapis_com:container_instance_count` | `service_name`, `state` | is it scaling? |
| App requests (log-based) | `logging_googleapis_com:user_app_requests` | `service`, `route`, `status` | which **route** fails |
| App latency (log-based, ms) | `logging_googleapis_com:user_app_latency_bucket` | `service`, `route`, `le` | which **route** is slow |
| App errors (log-based) | `logging_googleapis_com:user_app_errors` | `service`, `error_type` | **what** error |

Cloud Run metrics have no route label; that is why the log-based metrics exist. In PromQL every log-based metric
selector needs `monitored_resource="cloud_run_revision"` (a log-based metric can belong to several resource types).

Dashboard **Shop · Overview** (`provisioning/dashboards/`, folder *Workshop*) is ready at start: per service (Cloud Run
metrics), per route (log-based metrics), errors by type, instances, and WARNING/ERROR logs from both services.

Alerts (`provisioning/alerting/services.yaml`, one instance per `service_name`): **5xx ratio above 5%** and
**p95 latency above 1s**. Cloud Run metrics arrive every 60 s with a 2–3 min delay and the rules wait `for: 2m`, so
alerts fire **4–6 min after the load starts**. Start asking the Assistant before that.

## What gets created in Google Cloud

All of it comes from `terraform apply` in [infra/main.tf](infra/main.tf):

| Resource | Name |
|---|---|
| APIs | run, cloudbuild, artifactregistry, compute, logging, monitoring, cloudresourcemanager, iam |
| Artifact Registry repo (container images) | `shop`, image `app:<hash of app/>` built by Cloud Build |
| Service accounts | `frontend-sa`, `backend-sa` (no project roles) |
| Cloud Run services | `frontend`, `backend` (private, 1 vCPU, 512 MiB, max 2 instances, concurrency 16) |
| IAM binding | `frontend-sa` → `roles/run.invoker` on `backend` |
| Log-based metrics | `app_requests`, `app_latency`, `app_errors` |
| Side effect of the build | Cloud Storage bucket `<project-id>_cloudbuild` for the source upload |

Nothing else: no VM, database, Pub/Sub or alert policies (alerts live in Grafana). `terraform destroy`
removes it. Changing code in `app/` changes the image tag, so the next `terraform apply` rebuilds and
redeploys. A `terraform apply` also undoes the lab mitigations (env vars set with gcloud): handy to re-arm an incident.

## Prerequisites

| Need | Check |
|---|---|
| Google Cloud project with billing; you are Owner (or Editor + Cloud Run Admin, needed for the invoker binding) | `gcloud config set project <project-id>` |
| gcloud, logged in (user + ADC, with quota project) | `gcloud auth login && gcloud auth application-default login && gcloud auth application-default set-quota-project <project-id>` |
| Terraform ≥ 1.5 | `terraform version` |
| Docker + Compose v2 (Grafana only) | `docker compose version` |
| Free Grafana Cloud stack (for the Assistant) | grafana.com → sign up → create stack |

Windows: use WSL and work in `~`. Cloud Shell works: Web Preview on port 3000.
Required: `cp .env.example .env` and set `GCP_PROJECT_ID` (docker compose needs it; the scripts fall back to `gcloud config`).

## Deploy (Lab 0)

Plain Terraform, no wrapper. The image is built by Cloud Build during `apply` (5–8 min the first time).

```bash
terraform -chdir=infra init
terraform -chdir=infra apply -var project_id=<project-id>    # review the plan, type yes
./scripts/02-load.sh / 20                                     # expect 20 × 200
```

## Labs

| Time | Lab | Run | Ask the Assistant | You should see |
|---|---|---|---|---|
| 0:00 | Talk (15′) | – | – | – |
| 0:15 | 0 · Deploy the shop (10′) | deploy (above), then try `./scripts/02-load.sh /5xx 10`, `/queryslow`, `/slow` | – | `20 200` on `/`; a mix of `200`/`502` on `/5xx` |
| 0:25 | 1 · Connect Grafana (10′) | `cp .env.example .env` (set `GCP_PROJECT_ID`; with colima/nerdctl also `GCP_ADC_FILE`) → `docker compose up -d` → http://localhost:3000 (admin/admin) → Plugins → Grafana Assistant → Connection → **Quick connect**; Connections → Data sources → each → **Save & test** | [lab1-orient.md](prompts/lab1-orient.md) | both Google Cloud data sources green; request rate per service; log lines from both services |
| 0:35 | 2 · Dashboard by prompt (10′) | keep traffic for ~5 min: `./scripts/02-load.sh / 6000 2` | [lab2-dashboard.md](prompts/lab2-dashboard.md) | your own “Shop · RED” built by the Assistant; compare it with the provisioned “Shop · Overview” |
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
| `infra/main.tf` | Terraform: APIs, registry, image build, service accounts, both services, invoker binding, log-based metrics |
| `scripts/env.sh` | shared names: project, region, service names, `service_url` |
| `scripts/02-load.sh` | `[route=/] [N=20] [C=5]` load + status-code count |
| `scripts/03-incident.sh` | `<5xx\|queryslow\|slow\|mystery> [minutes=8]` |
| `provisioning/datasources/google-cloud.yaml` | the 2 Google Cloud data sources |
| `provisioning/dashboards/` | the ready-made “Shop · Overview” dashboard + its loader |
| `provisioning/alerting/services.yaml` | the 2 alert rules |
| `docker-compose.yml`, `.env.example` | Grafana 13.3 + Assistant + Cloud Logging plugin, `gmp-frontend` (Google’s PromQL proxy), ADC mount |
| `prompts/` | Assistant prompts per lab |
| `slides/index.html` | the deck |

## Troubleshooting

| Problem | Fix |
|---|---|
| PromQL data source fails | `docker compose logs gmp-frontend`: usually ADC missing/expired (`gcloud auth application-default login`) or no quota project |
| `permission denied` on `/etc/gcp/adc.json` (Linux/WSL) | the ADC file is mode 600 and the containers run as non-root: add `user: "0"` to `grafana` and `gmp-frontend` in `docker-compose.yml` |
| Monitoring/Logging data source: auth or quota error | `gcloud auth application-default login` and `gcloud auth application-default set-quota-project <project-id>`, then `docker compose restart grafana` |
| `GCP_PROJECT_ID` required (compose) | `cp .env.example .env` and set `GCP_PROJECT_ID=<project-id>` |
| `02-load.sh` gets 401/403 | services are private: run `gcloud auth login` (the script sends your identity token); your user needs `roles/run.invoker` (Owner/Editor have it) |
| Cloud Logging data source: `could not find default credentials` | Grafana hides host env vars from external plugins: keep `GF_PLUGINS_FORWARD_HOST_ENV_VARS=googlecloud-logging-datasource` in `docker-compose.yml` |
| `is a directory` reading `/etc/gcp/adc.json` (colima/nerdctl) | compose runs inside the VM where `$HOME` is `/root`: set `GCP_ADC_FILE=/Users/<you>/.config/gcloud/application_default_credentials.json` in `.env` |
| Backend returns 403 to the frontend (backend `request_count` shows `4xx`, no backend `request` log lines) | invoker binding missing: `gcloud run services add-iam-policy-binding backend --region asia-southeast2 --member serviceAccount:frontend-sa@<project-id>.iam.gserviceaccount.com --role roles/run.invoker` |
| Image build (`gcloud builds submit`) fails on permissions | new projects: Cloud Build runs as the Compute Engine default service account; grant it once: `gcloud projects add-iam-policy-binding <project-id> --member serviceAccount:<project-number>-compute@developer.gserviceaccount.com --role roles/cloudbuild.builds.builder`, then run `terraform apply` again. Not in Terraform on purpose: `destroy` would revoke it from a shared project. |
| `terraform apply` fails right after enabling APIs | API enablement is eventually consistent: wait a minute and run `terraform apply` again |
| Log-based metric panels empty | they only count lines written after `terraform apply` created them, and lag 1–3 min; send load again |
| Assistant menu missing | Grafana must be ≥ 13.1; Quick connect expires after 5 min; one Cloud stack per Grafana instance |
| Assistant can’t query Cloud Logging directly | Explore → Google Cloud Logging, run the filter, then ask the Assistant about what is on screen; or use PromQL `logging_googleapis_com:user_app_errors{monitored_resource="cloud_run_revision"}` |
| Org policy blocks public services | already handled: both services are private |

## Guardrails

- The Assistant acts as your Grafana user; every Google data source here is read-only. It never changes Cloud Run: you do.
- Evidence first: ask for the query and result behind every claim, and read it before you act. No evidence, no claim.
- One safe, reversible mitigation at a time (an env var you can remove), then check the metrics recover.
- Prompts and query results go to the Assistant backend in Grafana Cloud: check your data policy before using it on production data.
- Self-managed Grafana + Assistant: no Investigations, no Slack integration.

## Cleanup

```bash
terraform -chdir=infra destroy -var project_id=<project-id>
docker compose down -v
rm -f .mystery-answer
```

`terraform destroy` deletes both services, both service accounts, the invoker binding, the three log-based metrics
and the `shop` registry with its images; `docker compose down -v` removes the local Grafana containers/volumes. Enabled APIs stay on (free). Then disconnect the Grafana Cloud stack under
Plugins → Grafana Assistant → Connection if you no longer need it. The Cloud Build source bucket
(`<project-id>_cloudbuild`) stays; delete it in Cloud Storage if you want a clean project.
