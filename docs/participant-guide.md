# Panduan Peserta · Incident Response in the AI Era

**Accelerating Root Cause Analysis on Google Cloud with Grafana Assistant**
Road to DevFest Cloud ’26 #2 · Surabaya · 90 menit

Kamu akan men-deploy toko kecil berisi dua service (`frontend` → `backend`) ke Cloud Run, menghubungkannya ke
Grafana Cloud, lalu merusak toko itu tiga kali dan memakai **Grafana Assistant** untuk menemukan akar masalahnya.
Assistant membaca dan menjalankan query; **kamu** yang memutuskan dan menjalankan perbaikannya.

Semua perintah dijalankan di **Cloud Shell** (terminal di browser, sudah berisi `gcloud`, `git`, `curl`):
tidak perlu install apa pun di laptop.

| Waktu | Bagian |
|---|---|
| sebelum hari H | Persiapan (±15 menit) |
| 0:15 | Lab 0 · Deploy ke Cloud Run (10′) |
| 0:25 | Lab 1 · Hubungkan Grafana Cloud (10′) |
| 0:35 | Lab 2 · Dashboard lewat prompt (10′) |
| 0:45 | Lab 3–5 · Tiga insiden (34′) |
| 1:19 | Wrap-up · Mystery round, postmortem, clean up (11′) |

---

## Persiapan (sebelum hari H)

### 1 · Klaim credit dan hubungkan ke project

1. **Klaim credit** dari link yang dibagikan panitia: login dengan akun Google-mu, terima syaratnya. Setelah itu
   muncul billing account baru bernama seperti **“GDP Event Credit: Road to DevFest Cloud Surabaya ’26 #2”**.
   Saldo credit bisa dilihat di Console → **Billing** → **Credits**.
2. **Buat project** baru di [console.cloud.google.com](https://console.cloud.google.com) → pemilih project
   (kiri atas) → **New project**. Catat **Project ID**-nya (bukan nama project), contoh `devfest-514313`.
3. Buka **Cloud Shell** (ikon `>_` kanan atas Console), pilih project-mu, aktifkan API billing (gratis), lalu cari
   billing account credit yang aktif:
   ```bash
   gcloud config set project <project-id>
   gcloud services enable cloudbilling.googleapis.com cloudresourcemanager.googleapis.com
   gcloud billing accounts list --filter='open=true'
   ```
   ```text
   ACCOUNT_ID            NAME                                                     OPEN
   01D623-84CDFA-4AE3C0  GDP Event Credit: Road to DevFest Cloud Surabaya '26 #2  True
   ```
4. **Hubungkan** billing account itu ke project-mu (ganti dengan Project ID dan ACCOUNT_ID milikmu):
   ```bash
   gcloud billing projects link <project-id> --billing-account <ACCOUNT_ID>
   gcloud billing projects describe <project-id> --format='value(billingEnabled)'   # harus: True
   ```
   Lewat UI juga bisa: Console → **Billing** → **My projects** → titik tiga di project-mu → **Change billing** →
   pilih billing account credit.

Tanpa billing aktif, Cloud Run dan Artifact Registry menolak dipakai (`requires billing to be enabled`).

### 2 · Grafana Cloud

1. **Akun Grafana Cloud** (gratis) di [grafana.com](https://grafana.com) → buat *stack* → buka Grafana-nya.
   Pastikan ikon **Assistant** ada di pojok kanan atas.
2. **Plugin Google Cloud Logging** di stack-mu: Administration → Plugins and data → Plugins → cari
   *Google Cloud Logging* → **Install**.

---

## Lab 0 · Deploy ke Cloud Run (10 menit)

Buka [Cloud Shell](https://shell.cloud.google.com) (ikon `>_` di Console), lalu:

```bash
git clone https://github.com/islamyakin/demo-roadtodevfest26-sby-2.git
cd demo-roadtodevfest26-sby-2

export PROJECT_ID=<project-id-kamu>
export REGION=asia-southeast2
gcloud config set project "$PROJECT_ID"
```

**0.1 · Aktifkan API** (1–2 menit)

```bash
gcloud services enable run.googleapis.com artifactregistry.googleapis.com logging.googleapis.com \
  monitoring.googleapis.com iam.googleapis.com cloudresourcemanager.googleapis.com
```

**0.2 · Identitas (IAM)**: satu service account per service, plus satu akun *read-only* untuk Grafana

```bash
gcloud iam service-accounts create frontend-sa    --display-name "workshop frontend"
gcloud iam service-accounts create backend-sa     --display-name "workshop backend"
gcloud iam service-accounts create grafana-reader --display-name "Grafana reader (workshop)"

GRAFANA_SA="grafana-reader@$PROJECT_ID.iam.gserviceaccount.com"
for r in roles/monitoring.viewer roles/logging.viewer roles/logging.viewAccessor; do
  until gcloud projects add-iam-policy-binding "$PROJECT_ID" --member "serviceAccount:$GRAFANA_SA" \
        --role "$r" --condition=None >/dev/null; do sleep 5; done
  echo "granted $r"
done
```

**0.3 · Image dari Docker Hub lewat Artifact Registry** (Cloud Run tidak bisa menarik image Docker Hub biasa langsung)

```bash
gcloud artifacts repositories create dockerhub --location "$REGION" --repository-format docker \
  --mode remote-repository --remote-docker-repo docker-hub --remote-repo-config-desc "Docker Hub"
export HUB="$REGION-docker.pkg.dev/$PROJECT_ID/dockerhub"
```

**0.4 · Deploy kedua service** (keduanya private; hanya `frontend-sa` yang boleh memanggil `backend`)

```bash
gcloud run deploy backend --image "$HUB/nurulyakin/shop-backend:latest" \
  --region "$REGION" --no-allow-unauthenticated \
  --service-account "backend-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --cpu 1 --memory 512Mi --concurrency 16 --max-instances 2 --set-env-vars "PROJECT_ID=$PROJECT_ID"

gcloud run services add-iam-policy-binding backend --region "$REGION" \
  --member "serviceAccount:frontend-sa@$PROJECT_ID.iam.gserviceaccount.com" --role roles/run.invoker

BACKEND_URL=$(gcloud run services describe backend --region "$REGION" --format 'value(status.url)')
gcloud run deploy frontend --image "$HUB/nurulyakin/shop-frontend:latest" \
  --region "$REGION" --no-allow-unauthenticated \
  --service-account "frontend-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --cpu 1 --memory 512Mi --concurrency 16 --max-instances 2 \
  --set-env-vars "PROJECT_ID=$PROJECT_ID,BACKEND_URL=$BACKEND_URL"
```

**0.5 · Smoke test**

```bash
./scripts/02-load.sh / 20      # harus: 20 200
```

Kalau keluar `502`: izin di 0.4 belum tersebar. Tunggu 1 menit, ulangi.

**0.6 · Metrik per route** (Cloud Run sendiri tidak tahu route mana yang dipanggil)

```bash
for m in app_requests app_latency app_errors; do
  gcloud logging metrics create "$m" --config-from-file="manual/metrics/$m.yaml"
done
```

**0.7 · File kunci untuk Grafana** (“Google JWT File”)

```bash
(umask 077; gcloud iam service-accounts keys create grafana-reader.json --iam-account "$GRAFANA_SA")
cloudshell download grafana-reader.json      # unduh ke laptop untuk di-upload ke Grafana
```

File ini adalah kunci akun *read-only*. Jangan dibagikan atau di-commit; hapus setelah workshop.

✅ **Selesai kalau:** `02-load.sh / 20` memberi `20 200` dan `grafana-reader.json` sudah ada di laptopmu.

---

## Lab 1 · Hubungkan Grafana Cloud (10 menit)

Di Grafana stack-mu:

1. **Connections → Data sources → Add new data source → Google Cloud Monitoring**
   → Authentication: **Google JWT File** → upload `grafana-reader.json` (field *Project ID* terisi otomatis)
   → **Save & test** (harus hijau).
2. **Add new data source → Google Cloud Logging** → **Google JWT File** → file yang sama → **Save & test**.
3. **Dashboards → New → New folder** `Workshop`, lalu **New → Import** → upload `manual/shop-overview.json`
   (unduh dari repo, atau `cloudshell download manual/shop-overview.json`) → pilih kedua data source tadi, isi
   project ID-mu → **Import**. Kamu sekarang punya dashboard **Shop · Overview**.
4. **Alert rules** (Alerting → Alert rules → New alert rule), dua kali. Query: data source **Google Cloud
   Monitoring**, query type **PromQL**. Expressions: Reduce (Last) → Threshold. Folder `Workshop`, group `shop`,
   evaluate every **1m**, pending period **2m**, **No data handling: Normal** (sebelum ada error, query 5xx memang
   kosong).

   | Name | PromQL | Threshold |
   |---|---|---|
   | `5xx ratio above 5%` | `sum by (service_name) (rate(run_googleapis_com:request_count{monitored_resource="cloud_run_revision",service_name=~"frontend\|backend",response_code_class="5xx"}[5m])) / sum by (service_name) (rate(run_googleapis_com:request_count{monitored_resource="cloud_run_revision",service_name=~"frontend\|backend"}[5m]))` | is above `0.05` |
   | `p95 latency above 1s` | `histogram_quantile(0.95, sum by (le, service_name) (rate(run_googleapis_com:request_latencies_bucket{monitored_resource="cloud_run_revision",service_name=~"frontend\|backend"}[5m])))` | is above `1000` |

   (Di tabel, `\|` ditulis karena Markdown; di query aslinya cukup `|`.)
5. Buka **Assistant** (ikon kanan atas) dan tempel prompt dari [`prompts/lab1-orient.md`](../prompts/lab1-orient.md),
   satu per satu.

> **Cara kerja dengan Assistant di workshop ini.** Data kita ada di *Google Cloud Monitoring* dan *Google Cloud
> Logging*, dua data source yang **tidak** ada di daftar resmi yang bisa di-query sendiri oleh Assistant. Kalau
> Assistant bilang tidak bisa menjalankan query-nya:
> 1. minta ia **menuliskan** query-nya (PromQL atau filter log);
> 2. jalankan sendiri di **Explore** → *Google Cloud Monitoring* (query type **PromQL**) atau *Google Cloud Logging*;
> 3. tanya Assistant tentang hasil yang ada di layar (“jelaskan grafik ini”, “apa arti log ini”).
>
> Jadi Assistant tetap jadi partner analisis; kamu yang menekan *Run query*.

✅ **Selesai kalau:** kedua data source hijau, dashboard terisi angka, dan Assistant menjawab dengan query + hasilnya.

---

## Lab 2 · Dashboard lewat prompt (10 menit)

Buka tab Cloud Shell kedua (ikon `+`) dan biarkan traffic berjalan ±5 menit:

```bash
cd demo-roadtodevfest26-sby-2 && ./scripts/02-load.sh / 6000 2
```

Di Assistant, tempel [`prompts/lab2-dashboard.md`](../prompts/lab2-dashboard.md). Buka satu panel yang dibuatnya dan
pastikan kamu bisa menjelaskan query-nya dalam satu kalimat. Bandingkan dengan **Shop · Overview**.

---

## Lab 3–5 · Tiga insiden (34 menit)

Ulangi untuk `5xx`, lalu `queryslow`, lalu `slow`:

| Langkah | Apa yang dilakukan |
|---|---|
| 1 · Rusak | tab Cloud Shell kedua: `./scripts/03-incident.sh 5xx` (berjalan 8 menit) |
| 2 · Tanya sejak awal | Assistant: [`prompts/lab3-rca.md`](../prompts/lab3-rca.md), mulai dari *Ground rules*, lalu langkah 1–4. Jalankan query yang ia tulis di Explore kalau ia tidak bisa menjalankannya sendiri |
| 3 · Alert | Alerting → Alert rules → folder `Workshop`: alert menyala **4–6 menit** setelah mulai (metrik Cloud Run telat 2–3 menit) |
| 4 · Buktikan | jangan terima jawaban tanpa query. Buka query-nya, cek angkanya |
| 5 · Perbaiki | **baru setelah** akar masalah ketemu dengan bukti: bagian *Act* di `prompts/lab3-rca.md` |
| 6 · Verifikasi | `./scripts/03-incident.sh <kasus> 4` lagi, tunggu 3 menit: alert kembali Normal, metrik pulih |

Pertanyaan yang membantu: *Service mana yang alert? Route mana? Gagal sendiri atau karena service lain?
CPU tinggi atau aplikasinya yang menunggu sesuatu?*

---

## Wrap-up (11 menit)

1. **Reset** (hapus semua perbaikanmu supaya insiden bisa muncul lagi):
   ```bash
   gcloud run services update backend  --region "$REGION" --remove-env-vars PAYMENT_GATEWAY,ORDERS_INDEX
   gcloud run services update frontend --region "$REGION" --remove-env-vars RECO_CACHE
   ```
2. **Mystery round**: `./scripts/03-incident.sh mystery 5`. Satu dari tiga insiden dipilih acak dan route-nya
   disembunyikan (`/???`). Temukan **route, service, dan akar masalahnya** dengan Assistant, lengkap dengan bukti.
   Cek jawaban: `cat .mystery-answer`.
3. **Postmortem**: tempel [`prompts/wrapup-postmortem.md`](../prompts/wrapup-postmortem.md) ke Assistant.
4. **Clean up** (supaya credit tidak terpakai terus):
   ```bash
   for s in frontend backend; do gcloud run services delete "$s" --region "$REGION" --quiet; done
   for m in app_requests app_latency app_errors; do gcloud logging metrics delete "$m" --quiet; done
   gcloud artifacts repositories delete dockerhub --location "$REGION" --quiet
   for r in roles/monitoring.viewer roles/logging.viewer roles/logging.viewAccessor; do
     gcloud projects remove-iam-policy-binding "$PROJECT_ID" --member "serviceAccount:$GRAFANA_SA" \
       --role "$r" --condition=None --quiet >/dev/null
   done
   for sa in frontend-sa backend-sa grafana-reader; do
     gcloud iam service-accounts delete "$sa@$PROJECT_ID.iam.gserviceaccount.com" --quiet
   done
   rm -f grafana-reader.json .mystery-answer
   ```
   Hapus juga `grafana-reader.json` dari folder Downloads laptopmu, dan di Grafana: kedua data source, dashboard,
   folder `Workshop`.

---

## Kalau ada masalah

| Masalah | Solusi |
|---|---|
| `Billing account … not found` / `requires billing to be enabled` | billing belum terhubung: lihat Persiapan 1 |
| `Image 'mirror.gcr.io/…' not found` | kamu memakai `docker.io/…`; pakai `$HUB/…` dari langkah 0.3 |
| `$HUB` / `$PROJECT_ID` kosong (Cloud Shell sempat terputus) | jalankan lagi baris `export` di awal Lab 0 dan 0.3 |
| `02-load.sh` memberi `401`/`403` | jalankan `gcloud auth login`, lalu ulangi |
| `02-load.sh` memberi `502` di `/` | izin `frontend-sa` → `backend` belum tersebar: tunggu 1 menit |
| Grant IAM gagal (*concurrent policy changes*) | loop `until` di 0.2 sudah mengulang otomatis; kalau terhenti, jalankan blok itu lagi |
| Save & test Cloud Logging gagal (`Permission denied for all log views`) | IAM belum tersebar: tunggu 1 menit, Save & test lagi |
| Panel per route kosong | metrik di 0.6 hanya menghitung log baru: kirim traffic, tunggu 2–3 menit |
| Alert belum menyala | normal sampai 6 menit; mulai tanya Assistant sebelum itu |
| Assistant tidak bisa menjalankan query | wajar untuk data source Google Cloud: minta ia menulis query-nya, jalankan di **Explore**, lalu tanya tentang hasil di layar |
