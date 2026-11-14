# Rencana manual (tanpa Terraform): IAM, Cloud Run, Grafana

Semua langkah memakai `gcloud` dan UI Grafana Cloud. Jalankan dari root repo ini. Fase 0–7 sudah dijalankan
sungguhan di project `devfest-514313` pada 14 Nov 2026 dan berhasil; output yang diharapkan ditulis di tiap langkah.

| Fase | Isi |
|---|---|
| 0 | Variabel, billing, prasyarat |
| 1 | Aktifkan API |
| 2 | **IAM**: semua identitas dan role |
| 3 | Artifact Registry: proxy ke Docker Hub |
| 4 | **Cloud Run**: deploy `backend`, izin invoker, deploy `frontend` |
| 5 | Smoke test |
| 6 | Log-based metrics |
| 7 | File JWT untuk Grafana + cek aksesnya |
| 8 | Grafana Cloud (UI): data source, dashboard, alert |
| 9 | Dry run Grafana Assistant (wajib sebelum hari H) |
| 10 | Selama workshop: insiden, mitigasi, reset |
| 11 | Clean up |

---

## 0 · Variabel, billing, prasyarat

```bash
export PROJECT_ID=devfest-514313
export REGION=asia-southeast2
gcloud config set project "$PROJECT_ID"
gcloud services enable cloudbilling.googleapis.com cloudresourcemanager.googleapis.com   # gratis; dibutuhkan cek di bawah
```

Billing harus aktif:

```bash
gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)'     # harus: True

# kalau False: cari billing account yang OPEN lalu hubungkan
gcloud billing accounts list --filter='open=true'
gcloud billing projects link "$PROJECT_ID" --billing-account <ACCOUNT_ID>
```

Akun kamu perlu **Owner** di project (cek: `gcloud projects get-iam-policy "$PROJECT_ID" --flatten='bindings[].members'
--filter="bindings.members:user:$(gcloud config get-value account)" --format='value(bindings.role)'`).

## 1 · Aktifkan API

```bash
gcloud services enable run.googleapis.com artifactregistry.googleapis.com logging.googleapis.com \
  monitoring.googleapis.com iam.googleapis.com cloudresourcemanager.googleapis.com
```

## 2 · IAM: semua identitas dan role

Ringkasan siapa boleh apa:

| Identitas | Dipakai oleh | Role | Di mana |
|---|---|---|---|
| `frontend-sa` | service Cloud Run `frontend` | `roles/run.invoker` | **hanya** di service `backend` (dibuat di Fase 4) |
| `backend-sa` | service Cloud Run `backend` | – (tidak butuh role apa pun) | – |
| `grafana-reader` | Grafana Cloud (lewat file JWT) | `roles/monitoring.viewer`, `roles/logging.viewer`, `roles/logging.viewAccessor` | project |
| akun kamu (user) | menjalankan `gcloud`, memanggil `frontend` lewat skrip | Owner (sudah termasuk `run.invoker`) | project |

Tidak ada service yang publik: `frontend` dan `backend` keduanya `--no-allow-unauthenticated`.

```bash
gcloud iam service-accounts create frontend-sa    --display-name "workshop frontend"
gcloud iam service-accounts create backend-sa     --display-name "workshop backend"
gcloud iam service-accounts create grafana-reader --display-name "Grafana reader (workshop)"

GRAFANA_SA="grafana-reader@$PROJECT_ID.iam.gserviceaccount.com"
for r in roles/monitoring.viewer roles/logging.viewer roles/logging.viewAccessor; do
  for i in 1 2 3 4 5; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member "serviceAccount:$GRAFANA_SA" \
      --role "$r" --condition=None >/dev/null && { echo "granted $r"; break; }
    echo "  retry $r ($i/5)..."; sleep 5
  done
done
```

Yang diharapkan: tiga baris `Service account email: …` lalu tiga baris `granted roles/…`. Grant yang gagal diulang
maksimal 5 kali (tiga perubahan IAM berturut-turut kadang bentrok, *concurrent policy changes*). Kalau `$PROJECT_ID`
kosong, semua percobaan gagal dengan `grafana-reader@.iam…`: jalankan lagi baris `export` di Fase 0.

Cek:

```bash
gcloud projects get-iam-policy "$PROJECT_ID" --flatten='bindings[].members' \
  --filter="bindings.members:serviceAccount:$GRAFANA_SA" --format='value(bindings.role)'
# roles/logging.viewAccessor  roles/logging.viewer  roles/monitoring.viewer
```

## 3 · Artifact Registry: proxy ke Docker Hub

Cloud Run **tidak bisa** menarik `docker.io/nurulyakin/…` langsung: ia mengambil Docker Hub lewat cache Google
`mirror.gcr.io`, yang hanya berisi image populer (`ERROR: Image 'mirror.gcr.io/nurulyakin/shop-backend:latest' not
found`). Solusinya repository Artifact Registry mode *remote* dengan upstream Docker Hub:

```bash
gcloud artifacts repositories create dockerhub --location "$REGION" --repository-format docker \
  --mode remote-repository --remote-docker-repo docker-hub --remote-repo-config-desc "Docker Hub" \
  --description "Docker Hub pull-through cache for the workshop images"

export HUB="$REGION-docker.pkg.dev/$PROJECT_ID/dockerhub"
```

Image `nurulyakin/shop-backend:latest` di Docker Hub kini bisa dipakai sebagai `$HUB/nurulyakin/shop-backend:latest`.

## 4 · Cloud Run

Setting sama dengan versi yang teruji: 1 vCPU, 512 MiB, concurrency 16, maksimal 2 instance, private.

```bash
# 4a · backend
gcloud run deploy backend \
  --image "$HUB/nurulyakin/shop-backend:latest" \
  --region "$REGION" --no-allow-unauthenticated \
  --service-account "backend-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --cpu 1 --memory 512Mi --concurrency 16 --max-instances 2 \
  --set-env-vars "PROJECT_ID=$PROJECT_ID"

# 4b · IAM: hanya frontend-sa yang boleh memanggil backend
gcloud run services add-iam-policy-binding backend --region "$REGION" \
  --member "serviceAccount:frontend-sa@$PROJECT_ID.iam.gserviceaccount.com" --role roles/run.invoker

# 4c · frontend (BACKEND_URL juga dipakai sebagai audience ID token)
BACKEND_URL=$(gcloud run services describe backend --region "$REGION" --format 'value(status.url)')
gcloud run deploy frontend \
  --image "$HUB/nurulyakin/shop-frontend:latest" \
  --region "$REGION" --no-allow-unauthenticated \
  --service-account "frontend-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --cpu 1 --memory 512Mi --concurrency 16 --max-instances 2 \
  --set-env-vars "PROJECT_ID=$PROJECT_ID,BACKEND_URL=$BACKEND_URL"
```

Yang diharapkan: `Service [backend] revision [backend-0000N-…] has been deployed and is serving 100 percent of
traffic`, lalu `Updated IAM policy for service [backend]`, lalu hal yang sama untuk `frontend`.
`PROJECT_ID` membuat setiap baris log membawa `logging.googleapis.com/trace`, sehingga log frontend dan backend dari
satu request bisa disambungkan.

## 5 · Smoke test

```bash
for r in / /5xx /queryslow /slow; do ./scripts/02-load.sh "$r" 20 5; done
```

Hasil di uji coba: `/` 20 × 200 (berarti izin frontend → backend jalan) · `/5xx` 8 × 200 + 12 × 502 (itu memang
insidennya) · `/queryslow` 20 × 200 · `/slow` 20 × 200.
Kalau `/` mengembalikan 502: izin invoker (4b) belum tersebar, tunggu 1–2 menit.

## 6 · Log-based metrics (per route; metrik Cloud Run tidak punya label route)

```bash
for m in app_requests app_latency app_errors; do
  gcloud logging metrics create "$m" --config-from-file="manual/metrics/$m.yaml"
done
```

Yang diharapkan: `Created [app_requests]`, `Created [app_latency]`, `Created [app_errors]`. Metrik ini hanya menghitung
log yang masuk **setelah** dibuat: kirim load lagi dan tunggu 2–3 menit sebelum melihat grafiknya.

## 7 · File JWT untuk Grafana

```bash
(umask 077; gcloud iam service-accounts keys create grafana-reader.json --iam-account "$GRAFANA_SA")
```

`grafana-reader.json` (root repo, mode 0600, sudah di-gitignore) adalah “JWT” yang diminta Grafana. Jangan di-commit.
Organisasi dengan policy `iam.disableServiceAccountKeyCreation` menolak langkah ini.

**Cek aksesnya sebelum ke Grafana** (memakai konfigurasi gcloud terpisah, akun gcloud-mu tidak berubah):

```bash
export CLOUDSDK_CONFIG="$(mktemp -d)"
gcloud auth activate-service-account --key-file grafana-reader.json
T=$(gcloud auth print-access-token)

# Cloud Monitoring (PromQL)
curl -s -H "Authorization: Bearer $T" -G \
  "https://monitoring.googleapis.com/v1/projects/$PROJECT_ID/location/global/prometheus/api/v1/query" \
  --data-urlencode 'query=sum by (service_name) (increase(run_googleapis_com:request_count{monitored_resource="cloud_run_revision"}[15m]))'

# Cloud Logging
curl -s -H "Authorization: Bearer $T" -H "Content-Type: application/json" https://logging.googleapis.com/v2/entries:list \
  -d "{\"resourceNames\":[\"projects/$PROJECT_ID\"],\"filter\":\"severity>=ERROR AND jsonPayload.error_type:*\",\"pageSize\":2}"

rm -rf "$CLOUDSDK_CONFIG"; unset CLOUDSDK_CONFIG
```

Yang diharapkan: PromQL `"status":"success"` dengan angka per `service_name`; Logging berisi `entries` (di uji coba:
`UpstreamError` di frontend dan `PaymentGatewayTimeout` di backend dengan **trace yang sama**).
`403 Permission denied for all log views` tepat setelah Fase 2 = IAM belum tersebar; ulangi 20–60 detik kemudian.

## 8 · Grafana Cloud (UI)

1. **Plugin** · Administration → Plugins and data → Plugins → **Google Cloud Logging** → Install.
2. **Data source Cloud Monitoring** · Connections → Data sources → Add new data source → **Google Cloud Monitoring**
   → Authentication: **Google JWT File** → upload `grafana-reader.json` (field *Project ID* terisi otomatis dari file)
   → **Save & test** (harus hijau).
3. **Data source Cloud Logging** · Add new data source → **Google Cloud Logging** → **Google JWT File** → file yang
   sama → **Save & test**.
4. **Dashboard** · Dashboards → New → **Import** → upload [`manual/shop-overview.json`](../manual/shop-overview.json)
   → pilih kedua data source, isi project ID (dipakai variabel dashboard `$project`) → folder **Workshop** → Import.
5. **Alert rules** · Alerting → Alert rules → **New alert rule**, dua kali:

| Field | Rule 1 | Rule 2 |
|---|---|---|
| Name | `5xx ratio above 5%` | `p95 latency above 1s` |
| Query A | **Google Cloud Monitoring**, query type **PromQL**, project `devfest-514313`, expr di bawah | sama, expr di bawah |
| Expressions | B = **Reduce** (Last) dari A · C = **Threshold**: B **is above 0.05** (alert condition) | sama, **is above 1000** |
| Folder / group | `Workshop` / `shop`, evaluate every **1m** | sama |
| Pending period | **2m** | **2m** |
| No data handling | **Normal** (tanpa error 5xx, query rule 1 memang kosong) | **Normal** |
| Labels / summary | `severity=page` · `{{ $labels.service_name }}: more than 5% of requests fail with 5xx.` | `severity=page` · `{{ $labels.service_name }}: p95 latency is above 1000 ms.` |

```promql
# Rule 1: 5xx ratio per service
sum by (service_name) (rate(run_googleapis_com:request_count{monitored_resource="cloud_run_revision",service_name=~"frontend|backend",response_code_class="5xx"}[5m]))
/ sum by (service_name) (rate(run_googleapis_com:request_count{monitored_resource="cloud_run_revision",service_name=~"frontend|backend"}[5m]))

# Rule 2: p95 latency per service (ms)
histogram_quantile(0.95, sum by (le, service_name) (rate(run_googleapis_com:request_latencies_bucket{monitored_resource="cloud_run_revision",service_name=~"frontend|backend"}[5m])))
```

## 9 · Dry run Grafana Assistant (wajib)

**Keputusan: jalur JWT saja.** Tabel *Supported data sources* Grafana Assistant memuat Prometheus, BigQuery, Infinity,
dan lain-lain, tetapi **tidak** Google Cloud Monitoring maupun Google Cloud Logging. Jadi Assistant kemungkinan tidak
bisa menjalankan query sendiri ke kedua data source ini. Uji supaya tahu pasti apa yang akan dialami peserta:

1. Kirim load: `./scripts/02-load.sh /5xx 200 8`, tunggu 3 menit.
2. Tanya Assistant: *“Using the Google Cloud Monitoring data source and a PromQL query, show requests per second per
   service_name for the Cloud Run services frontend and backend over the last 30 minutes. Show the query and the
   result.”*
3. Tanya: *“Using Google Cloud Logging, find the last 5 ERROR entries from service backend.”*

| Hasil | Yang diberitahukan ke peserta |
|---|---|
| Assistant menjalankan query dan menjawab dengan angka/log nyata | Pakai prompt di `prompts/` apa adanya |
| Assistant tidak bisa menjalankan query | Alur di panduan peserta: Assistant **menulis** query → peserta menjalankannya di **Explore** → tanya Assistant tentang hasil di layar |

## 10 · Selama workshop

```bash
./scripts/03-incident.sh 5xx          # atau: queryslow · slow · mystery 5
```

| Insiden | Mitigasi (dijalankan peserta) |
|---|---|
| `/5xx` | `gcloud run services update backend --region $REGION --update-env-vars PAYMENT_GATEWAY=payment-gw-backup.internal` |
| `/queryslow` | `gcloud run services update backend --region $REGION --update-env-vars ORDERS_INDEX=true` |
| `/slow` | `gcloud run services update frontend --region $REGION --update-env-vars RECO_CACHE=true` |

**Reset** (kembali ke kondisi rusak, mis. sebelum mystery round):

```bash
gcloud run services update backend  --region "$REGION" --remove-env-vars PAYMENT_GATEWAY,ORDERS_INDEX
gcloud run services update frontend --region "$REGION" --remove-env-vars RECO_CACHE
```

## 11 · Clean up

```bash
for s in frontend backend; do gcloud run services delete "$s" --region "$REGION" --quiet; done
for m in app_requests app_latency app_errors; do gcloud logging metrics delete "$m" --quiet; done
gcloud artifacts repositories delete dockerhub --location "$REGION" --quiet
for r in roles/monitoring.viewer roles/logging.viewer roles/logging.viewAccessor; do
  gcloud projects remove-iam-policy-binding "$PROJECT_ID" --member "serviceAccount:$GRAFANA_SA" \
    --role "$r" --condition=None --quiet >/dev/null
done
for sa in frontend-sa backend-sa grafana-reader; do
  gcloud iam service-accounts delete "$sa@$PROJECT_ID.iam.gserviceaccount.com" --quiet   # key ikut terhapus
done
rm -f grafana-reader.json .mystery-answer
```

Binding IAM dihapus **sebelum** akunnya, supaya tidak tertinggal binding `deleted:serviceAccount:…`.
Di Grafana Cloud: hapus kedua data source, dashboard, dan folder **Workshop** (beserta alert rules di dalamnya).

---

## Lampiran A · Padanan dengan Terraform (`infra/`)

| Terraform | Manual |
|---|---|
| `google_project_service.apis` | Fase 1 |
| `google_artifact_registry_repository.shop` + `terraform_data.image` (Cloud Build) | Fase 3: image dari Docker Hub lewat repo remote `dockerhub` |
| `google_service_account.svc`, `google_service_account.grafana`, `google_project_iam_member.grafana` | Fase 2 |
| `google_cloud_run_v2_service.*`, `google_cloud_run_v2_service_iam_member` | Fase 4 |
| `google_logging_metric.*` | Fase 6 (`manual/metrics/*.yaml`) |
| `google_service_account_key.grafana` → `grafana-reader.json` | Fase 7 |
| `grafana.tf.disabled` (data source, dashboard, alert) | Fase 8 (UI) |

## Lampiran B · (tidak dipakai) Data source Prometheus + token sync

**Tidak dipakai: keputusan workshop adalah jalur JWT saja.** Disimpan sebagai referensi kalau suatu saat Assistant
harus bisa menjalankan PromQL sendiri. Data source Prometheus
tidak bisa memakai JWT; ia butuh header `Authorization: Bearer <token>` berumur 1 jam, yang diperbarui tiap 10 menit
oleh Cloud Run job [`infra/tokensync.py`](../infra/tokensync.py).

1. **Grafana** · Add new data source → **Prometheus** → Name `Google Cloud (PromQL)` → URL
   `https://monitoring.googleapis.com/v1/projects/devfest-514313/location/global/prometheus/` → HTTP method **GET**
   → Save. Catat UID-nya (bagian akhir URL halaman edit data source).
2. **Grafana** · Administration → Users and access → Service accounts → Add (role **Admin**) → Add token.
3. **Google Cloud**:

```bash
PROMQL_UID=<uid dari langkah 1>
GRAFANA_URL=https://<stack>.grafana.net
gcloud services enable secretmanager.googleapis.com cloudscheduler.googleapis.com iamcredentials.googleapis.com

# job membuat token 1 jam untuk dirinya sendiri
gcloud iam service-accounts add-iam-policy-binding "$GRAFANA_SA" --member "serviceAccount:$GRAFANA_SA" \
  --role roles/iam.serviceAccountTokenCreator

# token Grafana dan skripnya di Secret Manager (skrip di-mount sebagai file)
printf 'Grafana service account token: '; read -rs GT; echo       # jalan di bash dan zsh
[ -n "$GT" ] && printf '%s' "$GT" | gcloud secrets create grafana-sa-token --data-file=- || echo "TOKEN KOSONG, ulangi"
gcloud secrets create tokensync-script --data-file=infra/tokensync.py
for s in grafana-sa-token tokensync-script; do
  gcloud secrets add-iam-policy-binding "$s" --member "serviceAccount:$GRAFANA_SA" --role roles/secretmanager.secretAccessor
done

gcloud run jobs create grafana-token-sync --region "$REGION" \
  --image "$HUB/library/python:3.12-slim" \
  --service-account "$GRAFANA_SA" --max-retries 1 --task-timeout 120s \
  --set-secrets "/scripts/tokensync.py=tokensync-script:latest,GRAFANA_TOKEN=grafana-sa-token:latest" \
  --set-env-vars "PROJECT_ID=$PROJECT_ID,SA_EMAIL=$GRAFANA_SA,GRAFANA_URL=$GRAFANA_URL,PROMQL_UID=$PROMQL_UID,LOGGING_UID=" \
  --command python --args /scripts/tokensync.py

gcloud run jobs add-iam-policy-binding grafana-token-sync --region "$REGION" \
  --member "serviceAccount:$GRAFANA_SA" --role roles/run.invoker
gcloud scheduler jobs create http grafana-token-sync --location "$REGION" --schedule "*/10 * * * *" \
  --uri "https://run.googleapis.com/v2/projects/$PROJECT_ID/locations/$REGION/jobs/grafana-token-sync:run" \
  --http-method POST --oauth-service-account-email "$GRAFANA_SA"

gcloud run jobs execute grafana-token-sync --region "$REGION" --wait   # sekali sekarang
```

4. **Grafana** · data source `Google Cloud (PromQL)` → **Save & test** harus hijau. `LOGGING_UID=` kosong berarti
   Cloud Logging tetap memakai JWT.

Clean up tambahan: `gcloud scheduler jobs delete grafana-token-sync --location $REGION`, `gcloud run jobs delete
grafana-token-sync --region $REGION`, `gcloud secrets delete grafana-sa-token`, `gcloud secrets delete
tokensync-script`.
