# Incident Response in the AI Era

**Accelerating Root Cause Analysis on Google Cloud with Grafana Assistant**
Road to DevFest Cloud ’26 #2 · Surabaya · 90-minute workshop

You deploy a two-service shop (`frontend` → `backend`) to Cloud Run, connect **Grafana Cloud** to Cloud Monitoring
and Cloud Logging, then break the shop three times and use Grafana Assistant to find the root cause.
The Assistant reads and queries; **you** decide and run the fix. Nothing runs on your laptop except `gcloud`,
`terraform` and `curl`: no Docker.

- Slides: [slides/workshop.pptx](slides/workshop.pptx) · [slides/workshop.pdf](slides/workshop.pdf)
- Prompts to paste into the Assistant: [prompts/](prompts/)
- Docker images: [`nurulyakin/shop-frontend`](https://hub.docker.com/r/nurulyakin/shop-frontend), [`nurulyakin/shop-backend`](https://hub.docker.com/r/nurulyakin/shop-backend) (linux/amd64, see [Container images](#container-images-docker-hub))

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
   │                                                                               ├─ dashboard "Shop · Overview"
   │      both with a short-lived token of the read-only account grafana-reader    ├─ 2 alert rules
   │      (Cloud Run job "grafana-token-sync", every 10 min; no keys)              └─ Grafana Assistant
   └─► Logging API ◄─── "Google Cloud Logging"   Logging plugin ─────────────────┘
```

Terraform ([infra/main.tf](infra/main.tf)) creates the Google Cloud side.
**The Grafana Cloud side is disabled for now**: it is ready in
[infra/grafana.tf.disabled](infra/grafana.tf.disabled) (data sources, token sync job, dashboard, alert rules) and the
file header says how to turn it on.
One image is built from `app/` with Cloud Build + buildpacks; both services run it and the `APP` env var picks the
module via the `Procfile`. Region `asia-southeast2`.

**Why a Prometheus data source:** Grafana Assistant’s documented query languages are PromQL, LogQL, TraceQL and SQL,
and Cloud Monitoring answers PromQL. So the Assistant gets Cloud Monitoring as plain PromQL. Both Google data sources
authenticate with a 1-hour access token of the read-only account `grafana-reader`, renewed every 10 min by a small
Cloud Run job ([infra/tokensync.py](infra/tokensync.py)). No service-account keys: the organization forbids them
(`iam.disableServiceAccountKeyCreation`), and nobody generates tokens by hand.

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

| Resource | Name |
|---|---|
| APIs | run, cloudbuild, artifactregistry, compute, logging, monitoring, cloudresourcemanager, iam |
| Artifact Registry | `shop` (the app image, built by Cloud Build) |
| Cloud Run services | `frontend`, `backend` (private, 1 vCPU, 512 MiB, max 2 instances, concurrency 16) |
| Service accounts | `frontend-sa`, `backend-sa` (no project roles) |
| IAM | `frontend-sa` → `run.invoker` on `backend` |
| Log-based metrics | `app_requests`, `app_latency`, `app_errors` |
| Grafana’s identity | service account `grafana-reader` (`monitoring.viewer`, `logging.viewer`, `logging.viewAccessor`) and, unless `grafana_key = false`, its key file `grafana-reader.json` in the repo root (mode 0600, gitignored) |

When the Grafana side is turned on it adds: the `grafana-sa-token`, the Cloud Run job + Cloud Scheduler `grafana-token-sync`, and in Grafana Cloud the two data
sources, the folder `Workshop`, the dashboard and the rule group `shop`. Changing code in `app/` changes the image tag, so the next `terraform apply` rebuilds and redeploys.
A `terraform apply` also undoes the lab mitigations (env vars set with gcloud): handy to re-arm an incident.

## Prerequisites

| Need | Check |
|---|---|
| Google Cloud project **with billing enabled**; you are Owner | `gcloud billing projects describe <project-id>` shows `billingEnabled: true` |
| gcloud, logged in | `gcloud auth login && gcloud auth application-default login` |
| Terraform ≥ 1.5 | `terraform version` (Cloud Shell has it) |
| A Grafana Cloud stack with Grafana Assistant | grafana.com → your stack → open Grafana |
| The Cloud Logging plugin in that stack | Grafana → Administration → Plugins and data → Plugins → “Google Cloud Logging” → Install |
| Only when the Grafana side is on: a stack service account token, role **Admin** | Grafana → Administration → Users and access → Service accounts → Add → Add token |

## Deploy (Lab 0)

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars   # set project_id
terraform init
terraform apply                                  # review the plan, type yes (first run 5–8 min)
cd ..
./scripts/02-load.sh / 20                        # expect 20 × 200
```

## Connect Grafana Cloud (key file, by hand)

`terraform apply` writes the key of the read-only account `grafana-reader` to **`grafana-reader.json`** in the repo
root. That file is the “JWT” Grafana asks for. Terraform does not send it anywhere; you upload it:

1. Grafana → **Connections → Data sources → Add data source → Google Cloud Monitoring**
2. **Authentication: Google JWT File** → upload `grafana-reader.json` → **Save & test**
3. Same for **Google Cloud Logging** (install that plugin first), same file
4. Dashboards → New → Import → upload [infra/shop-overview.json](infra/shop-overview.json)

Keep the file secret and delete it after the workshop (`terraform destroy` also deletes the key itself). If your
organization forbids service-account keys (`iam.disableServiceAccountKeyCreation`), set `grafana_key = false` in
`terraform.tfvars`: the apply then succeeds without a key, and the keyless token route in
[infra/grafana.tf.disabled](infra/grafana.tf.disabled) is the way in.

## Container images (Docker Hub)

| Image | Docker Hub | Platform | Port | Runs as |
|---|---|---|---|---|
| `nurulyakin/shop-frontend:latest` | [hub.docker.com/r/nurulyakin/shop-frontend](https://hub.docker.com/r/nurulyakin/shop-frontend) | linux/amd64 | 8080 | uid 10001 (non-root) |
| `nurulyakin/shop-backend:latest` | [hub.docker.com/r/nurulyakin/shop-backend](https://hub.docker.com/r/nurulyakin/shop-backend) | linux/amd64 | 8080 | uid 10001 (non-root) |

Built from [app/Dockerfile.frontend](app/Dockerfile.frontend) and [app/Dockerfile.backend](app/Dockerfile.backend):
`python:3.12-slim`, gunicorn with 1 worker and 16 threads, as on Cloud Run.

**Run both locally** (frontend calls backend over a shared network; no auth outside Cloud Run):

```bash
docker network create shop
docker run -d --name backend  --network shop nurulyakin/shop-backend:latest
docker run -d --name frontend --network shop -p 8080:8080 \
  -e BACKEND_URL=http://backend:8080 nurulyakin/shop-frontend:latest

curl localhost:8080/            # 200
curl localhost:8080/5xx         # ~60% 502 (backend payment gateway timeout)
curl localhost:8080/queryslow   # slow (~1 s), backend logs "slow query"
curl localhost:8080/slow        # CPU-bound, frontend logs "slow render"
docker logs backend             # one JSON line per event
```

**Environment variables**

| Image | Variable | Default | Meaning |
|---|---|---|---|
| frontend | `BACKEND_URL` | `http://localhost:8081` | where the backend is (**set this**) |
| frontend | `RECO_ITEMS` / `RECO_CACHE` | `3000000` / `false` | work per `/slow` request / cache it (the `/slow` fix) |
| backend | `PAYMENT_GATEWAY` | `payment-gw.internal` | `payment-gw-backup.internal` = the `/5xx` fix |
| backend | `PAYMENT_FAILURE_RATE` / `PAYMENT_TIMEOUT_MS` | `0.6` / `1500` | how often and how long the gateway times out |
| backend | `ORDERS_INDEX` | `false` | `true` = the `/queryslow` fix |
| backend | `DB_POOL_SIZE` / `DB_POOL_TIMEOUT_MS` | `4` / `2000` | simulated database connection pool |
| both | `PORT` | `8080` | listen port |
| both | `PROJECT_ID` | – | adds `logging.googleapis.com/trace` to log lines (Cloud Run) |

**Build and push your own** (amd64 even on Apple silicon, with docker or nerdctl/colima):

```bash
./scripts/build-images.sh <dockerhub-user> [tag]
docker login
docker push <dockerhub-user>/shop-frontend:<tag>
docker push <dockerhub-user>/shop-backend:<tag>
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
| `app/Dockerfile.frontend`, `app/Dockerfile.backend`, `scripts/build-images.sh` | the two `linux/amd64` images for Docker Hub |
| `infra/main.tf` | Google Cloud: APIs, registry, image build, service accounts, both services, invoker binding, log-based metrics |
| `infra/variables.tf`, `infra/terraform.tfvars.example` | inputs: `project_id`, `region`, `grafana_key` |
| `infra/grafana-reader.tf` | read-only account for Grafana + its key file `grafana-reader.json` |
| `infra/grafana.tf.disabled`, `infra/tokensync.py` | Grafana Cloud side (off for now): read-only identity, 2 data sources, token sync job, dashboard, alert rules |
| `infra/shop-overview.json` | the “Shop · Overview” dashboard |
| `scripts/env.sh` | shared names: project, region, service names, `service_url`, `hit` |
| `scripts/02-load.sh` | `[route=/] [N=20] [C=5]` load + status-code count |
| `scripts/03-incident.sh` | `<5xx\|queryslow\|slow\|mystery> [minutes=8]` |
| `prompts/` | Assistant prompts per lab |
| `slides/workshop.pptx`, `slides/workshop.pdf` | the deck |

## Troubleshooting

| Problem | Fix |
|---|---|
| `Billing account … is not found` when enabling an API, or Cloud Run answers 500/503 | billing is off for the project: link a billing account (Console → Billing), then `terraform apply` again |
| `Google Cloud (PromQL)` / `Google Cloud Logging` data source: 401 / no data | run the token sync now: `gcloud run jobs execute grafana-token-sync --region asia-southeast2 --wait`, then check its logs in Cloud Run → Jobs |
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
