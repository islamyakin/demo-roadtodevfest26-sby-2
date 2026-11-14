# Panduan Peserta · Incident Response in the AI Era

**Accelerating Root Cause Analysis on Google Cloud with Grafana Assistant**
Road to DevFest Cloud ’26 #2 · Surabaya · 90 menit

Kamu akan men-deploy toko kecil berisi dua service (`frontend` → `backend`) ke Cloud Run, menghubungkannya ke
Grafana Cloud, lalu merusak toko itu tiga kali dan memakai **Grafana Assistant** untuk menemukan akar masalahnya.
**Kamu** yang memutuskan dan menjalankan perbaikannya.

Semua perintah dijalankan di **Cloud Shell** (terminal bash di browser, sudah berisi `gcloud`, `git`, `curl`).
Tidak perlu install apa pun di laptop.

> **Pakai project milikmu sendiri.** Jangan menyalin project ID dari contoh atau dari layar orang lain: kamu tidak
> punya akses ke sana dan semua perintah akan gagal.
>
> **Setiap blok perintah aman dijalankan ulang.** Kalau ada yang gagal, perbaiki penyebabnya lalu jalankan lagi
> blok yang sama dari awal. Setiap blok diawali `source scripts/vars.sh`, jadi tab Cloud Shell baru pun langsung
> tahu project-mu.

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

### 1 · Klaim credit, buat project, hubungkan billing

1. **Klaim credit** dari link yang dibagikan panitia: login dengan akun Google-mu, terima syaratnya. Setelah itu
   muncul billing account baru bernama seperti **“GDP Event Credit: Road to DevFest Cloud Surabaya ’26 #2”**.
   Saldonya bisa dilihat di Console → **Billing** → **Credits**.
2. **Buat project baru**: [console.cloud.google.com](https://console.cloud.google.com) → pemilih project (kiri atas)
   → **New project**. Catat **Project ID**-nya (huruf kecil, angka, tanda minus; *bukan* nama project).
3. Buka **Cloud Shell** (ikon `>_` kanan atas Console). Ganti `<project-id-kamu>` dengan Project ID dari langkah 2:
   ```bash
   gcloud config set project <project-id-kamu>
   gcloud services enable cloudbilling.googleapis.com cloudresourcemanager.googleapis.com
   gcloud billing accounts list --filter='open=true'
   ```
   Contoh hasil (ACCOUNT_ID milikmu berbeda):
   ```text
   ACCOUNT_ID            NAME                                                     OPEN
   01XXXX-XXXXXX-XXXXXX  GDP Event Credit: Road to DevFest Cloud Surabaya '26 #2  True
   ```
4. **Hubungkan** billing account credit itu ke project-mu (ganti `<ACCOUNT_ID>`):
   ```bash
   gcloud billing projects link "$(gcloud config get-value project)" --billing-account <ACCOUNT_ID>
   gcloud billing projects describe "$(gcloud config get-value project)" --format='value(billingEnabled)'
   ```
   Baris terakhir harus mencetak **`True`**. Lewat UI juga bisa: Console → **Billing** → **My projects** → titik tiga
   di project-mu → **Change billing** → pilih billing account credit.

### 2 · Grafana Cloud

1. **Akun Grafana Cloud** (gratis) di [grafana.com](https://grafana.com) → buat *stack* → buka Grafana-nya.
2. **Plugin Google Cloud Logging**: Administration → Plugins and data → Plugins → cari *Google Cloud Logging* →
   **Install**.

---

## Lab 0 · Deploy ke Cloud Run (10 menit)

**0.0 · Ambil kode** (sekali saja; ganti `<project-id-kamu>`)

```bash
cd ~ && git clone https://github.com/islamyakin/demo-roadtodevfest26-sby-2.git
cd ~/demo-roadtodevfest26-sby-2
gcloud config set project <project-id-kamu>
source scripts/vars.sh
```

Harus tercetak `project=<project-id-kamu>  region=asia-southeast2`. Kalau `git clone` bilang foldernya sudah ada,
tidak apa-apa: lanjutkan dari baris `cd`.

**0.1 · Aktifkan API** (1–2 menit)

```bash
cd ~/demo-roadtodevfest26-sby-2 && source scripts/vars.sh
gcloud services enable run.googleapis.com artifactregistry.googleapis.com logging.googleapis.com \
  monitoring.googleapis.com iam.googleapis.com cloudresourcemanager.googleapis.com
```

**0.2 · Identitas (IAM)**: satu service account per service, plus satu akun *read-only* untuk Grafana

```bash
cd ~/demo-roadtodevfest26-sby-2 && source scripts/vars.sh
for sa in frontend-sa backend-sa grafana-reader; do
  gcloud iam service-accounts describe "$sa@$PROJECT_ID.iam.gserviceaccount.com" >/dev/null 2>&1 \
    || gcloud iam service-accounts create "$sa" --display-name "workshop $sa"
done
for r in roles/monitoring.viewer roles/logging.viewer roles/logging.viewAccessor; do
  for i in 1 2 3 4 5; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member "serviceAccount:$GRAFANA_SA" \
      --role "$r" --condition=None >/dev/null && { echo "OK $r"; break; }
    echo "  ulangi $r ($i/5)..."; sleep 5
  done
done
```

Harus tercetak `OK roles/monitoring.viewer`, `OK roles/logging.viewer`, `OK roles/logging.viewAccessor`.
Baris `ulangi …` sesekali itu normal (IAM sibuk / akun baru belum tersebar).

**0.3 · Image dari Docker Hub lewat Artifact Registry** (Cloud Run tidak bisa menarik image Docker Hub biasa langsung)

```bash
cd ~/demo-roadtodevfest26-sby-2 && source scripts/vars.sh
gcloud artifacts repositories describe dockerhub --location "$REGION" >/dev/null 2>&1 \
  || gcloud artifacts repositories create dockerhub --location "$REGION" --repository-format docker \
       --mode remote-repository --remote-docker-repo docker-hub --remote-repo-config-desc "Docker Hub"
echo "$HUB"
```

**0.4 · Deploy kedua service** (keduanya private; hanya `frontend-sa` yang boleh memanggil `backend`; ±2 menit)

```bash
cd ~/demo-roadtodevfest26-sby-2 && source scripts/vars.sh
gcloud run deploy backend --image "$HUB/nurulyakin/shop-backend:latest" \
  --region "$REGION" --no-allow-unauthenticated \
  --service-account "backend-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --cpu 1 --memory 512Mi --concurrency 16 --max-instances 2 --set-env-vars "PROJECT_ID=$PROJECT_ID"

gcloud run services add-iam-policy-binding backend --region "$REGION" \
  --member "serviceAccount:frontend-sa@$PROJECT_ID.iam.gserviceaccount.com" --role roles/run.invoker >/dev/null \
  && echo "OK frontend-sa boleh memanggil backend"

BACKEND_URL=$(gcloud run services describe backend --region "$REGION" --format 'value(status.url)')
gcloud run deploy frontend --image "$HUB/nurulyakin/shop-frontend:latest" \
  --region "$REGION" --no-allow-unauthenticated \
  --service-account "frontend-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --cpu 1 --memory 512Mi --concurrency 16 --max-instances 2 \
  --set-env-vars "PROJECT_ID=$PROJECT_ID,BACKEND_URL=$BACKEND_URL"
```

**0.5 · Smoke test**

```bash
cd ~/demo-roadtodevfest26-sby-2 && source scripts/vars.sh
./scripts/02-load.sh / 20
```

Harus tercetak `20 / 200`. Kalau `502`: izin di 0.4 belum tersebar, tunggu 1 menit lalu ulangi blok ini.

**0.6 · Metrik per route** (Cloud Run sendiri tidak tahu route mana yang dipanggil)

```bash
cd ~/demo-roadtodevfest26-sby-2 && source scripts/vars.sh
for m in app_requests app_latency app_errors; do
  gcloud logging metrics describe "$m" >/dev/null 2>&1 \
    && gcloud logging metrics update "$m" --config-from-file="manual/metrics/$m.yaml" \
    || gcloud logging metrics create "$m" --config-from-file="manual/metrics/$m.yaml"
done
```

**0.7 · File kunci untuk Grafana** (“Google JWT File”)

```bash
cd ~/demo-roadtodevfest26-sby-2 && source scripts/vars.sh
[ -f grafana-reader.json ] || (umask 077; gcloud iam service-accounts keys create grafana-reader.json --iam-account "$GRAFANA_SA")
cloudshell download grafana-reader.json
```

`cloudshell download` mengunduh file ke laptopmu (izinkan pop-up download di browser). File ini kunci akun
*read-only*: jangan dibagikan atau di-commit, hapus setelah workshop.

✅ **Selesai kalau:** `02-load.sh / 20` memberi `20 / 200` dan `grafana-reader.json` ada di laptopmu.

---

## Lab 1 · Hubungkan Grafana Cloud (10 menit)

Di Grafana stack-mu:

1. **Connections → Data sources → Add new data source → Google Cloud Monitoring**
   → Authentication: **Google JWT File** → upload `grafana-reader.json` (field *Project ID* terisi otomatis)
   → **Save & test** (harus hijau).
2. **Add new data source → Google Cloud Logging** → **Google JWT File** → file yang sama → **Save & test**.
   Kalau muncul `Permission denied for all log views`: IAM belum tersebar, tunggu 1 menit lalu Save & test lagi.
3. **Dashboard**: unduh `manual/shop-overview.json` (Cloud Shell: `cloudshell download ~/demo-roadtodevfest26-sby-2/manual/shop-overview.json`)
   → Grafana: **Dashboards → New → New folder** `Workshop` → **New → Import** → upload file itu → pilih kedua data
   source tadi, isi **Project ID**-mu → **Import**.
4. **Dua alert rule**: Alerting → Alert rules → **New alert rule**. Untuk masing-masing:
   - Query A: data source **Google Cloud Monitoring**, query type **PromQL**, tempel query di bawah.
   - Expressions: **Reduce** (Last) dari A → **Threshold** (is above, angka di bawah), jadikan alert condition.
   - Folder `Workshop`, evaluation group `shop` (every **1m**), pending period **2m**,
     **No data → Normal** (sebelum ada error, query 5xx memang kosong).

   **Rule 1 · `5xx ratio above 5%`** · threshold **0.05**
   ```promql
   sum by (service_name) (rate(run_googleapis_com:request_count{monitored_resource="cloud_run_revision",service_name=~"frontend|backend",response_code_class="5xx"}[5m]))
   / sum by (service_name) (rate(run_googleapis_com:request_count{monitored_resource="cloud_run_revision",service_name=~"frontend|backend"}[5m]))
   ```
   **Rule 2 · `p95 latency above 1s`** · threshold **1000**
   ```promql
   histogram_quantile(0.95, sum by (le, service_name) (rate(run_googleapis_com:request_latencies_bucket{monitored_resource="cloud_run_revision",service_name=~"frontend|backend"}[5m])))
   ```
5. Buka **Assistant** (ikon kanan atas) dan tempel prompt dari [`prompts/lab1-orient.md`](../prompts/lab1-orient.md),
   satu per satu.

> **Cara kerja dengan Assistant di workshop ini.** Data kita ada di *Google Cloud Monitoring* dan *Google Cloud
> Logging*, dua data source yang **tidak** ada di daftar resmi yang bisa di-query sendiri oleh Assistant. Kalau
> Assistant bilang tidak bisa menjalankan query-nya:
> 1. minta ia **menuliskan** query-nya (PromQL atau filter log);
> 2. jalankan sendiri di **Explore** → *Google Cloud Monitoring* (query type **PromQL**) atau *Google Cloud Logging*;
> 3. tanya Assistant tentang hasil yang ada di layar (“jelaskan grafik ini”, “apa arti log ini”).

✅ **Selesai kalau:** kedua data source hijau dan dashboard **Shop · Overview** terisi angka.

---

## Lab 2 · Dashboard lewat prompt (10 menit)

Buka tab Cloud Shell kedua (ikon `+`) dan biarkan traffic berjalan ±5 menit:

```bash
cd ~/demo-roadtodevfest26-sby-2 && source scripts/vars.sh
./scripts/02-load.sh / 6000 2
```

Di Assistant, tempel [`prompts/lab2-dashboard.md`](../prompts/lab2-dashboard.md). Buka satu panel yang dibuatnya dan
pastikan kamu bisa menjelaskan query-nya dalam satu kalimat. Bandingkan dengan **Shop · Overview**.

---

## Lab 3–5 · Tiga insiden (34 menit)

Ulangi untuk `5xx`, lalu `queryslow`, lalu `slow`. Rusak dulu (tab Cloud Shell kedua, berjalan 8 menit):

```bash
cd ~/demo-roadtodevfest26-sby-2 && source scripts/vars.sh
./scripts/03-incident.sh 5xx
```

| Langkah | Apa yang dilakukan |
|---|---|
| 1 · Tanya sejak awal | Assistant: [`prompts/lab3-rca.md`](../prompts/lab3-rca.md), mulai dari *Ground rules*, lalu langkah 1–4. Jalankan query yang ia tulis di Explore kalau ia tidak bisa menjalankannya sendiri |
| 2 · Alert | Alerting → Alert rules → folder `Workshop`: alert menyala **4–6 menit** setelah mulai (metrik Cloud Run telat 2–3 menit) |
| 3 · Buktikan | jangan terima jawaban tanpa query. Buka query-nya, cek angkanya |
| 4 · Perbaiki | **baru setelah** akar masalah ketemu dengan bukti: bagian *Act* di `prompts/lab3-rca.md` |
| 5 · Verifikasi | `./scripts/03-incident.sh <kasus> 4` lagi, tunggu 3 menit: alert kembali Normal, metrik pulih |

Pertanyaan yang membantu: *Service mana yang alert? Route mana? Gagal sendiri atau karena service lain?
CPU tinggi atau aplikasinya yang menunggu sesuatu?*

---

## Wrap-up (11 menit)

1. **Reset** (hapus semua perbaikanmu supaya insiden bisa muncul lagi):
   ```bash
   cd ~/demo-roadtodevfest26-sby-2 && source scripts/vars.sh
   gcloud run services update backend  --region "$REGION" --remove-env-vars PAYMENT_GATEWAY,ORDERS_INDEX
   gcloud run services update frontend --region "$REGION" --remove-env-vars RECO_CACHE
   ```
2. **Mystery round**: `./scripts/03-incident.sh mystery 5`. Satu dari tiga insiden dipilih acak dan route-nya
   disembunyikan (`/???`). Temukan **route, service, dan akar masalahnya** dengan Assistant, lengkap dengan bukti.
   Cek jawaban: `cat .mystery-answer`.
3. **Postmortem**: tempel [`prompts/wrapup-postmortem.md`](../prompts/wrapup-postmortem.md) ke Assistant.
4. **Clean up** (supaya credit tidak terpakai terus; aman dijalankan ulang):
   ```bash
   cd ~/demo-roadtodevfest26-sby-2 && source scripts/vars.sh
   for s in frontend backend; do gcloud run services delete "$s" --region "$REGION" --quiet; done
   for m in app_requests app_latency app_errors; do gcloud logging metrics delete "$m" --quiet; done
   gcloud artifacts repositories delete dockerhub --location "$REGION" --quiet
   for r in roles/monitoring.viewer roles/logging.viewer roles/logging.viewAccessor; do
     gcloud projects remove-iam-policy-binding "$PROJECT_ID" --member "serviceAccount:$GRAFANA_SA" \
       --role "$r" --condition=None --quiet >/dev/null && echo "removed $r"
   done
   for sa in frontend-sa backend-sa grafana-reader; do
     gcloud iam service-accounts delete "$sa@$PROJECT_ID.iam.gserviceaccount.com" --quiet
   done
   rm -f grafana-reader.json .mystery-answer
   ```
   Error `NOT_FOUND` di sini artinya sudah terhapus: aman. Hapus juga `grafana-reader.json` dari folder Downloads
   laptopmu, dan di Grafana: kedua data source, dashboard, folder `Workshop`.

---

## Kalau ada masalah

| Masalah | Solusi |
|---|---|
| `BELUM ADA PROJECT` saat `source scripts/vars.sh` | `gcloud config set project <project-id-kamu>` lalu ulangi blok |
| `No such file or directory: scripts/vars.sh` | kode belum di-clone: jalankan 0.0 |
| `Permission denied` / `does not have permission` | project yang dipakai bukan milikmu: cek `gcloud config get-value project` |
| `Billing account … not found` / `requires billing to be enabled` | billing belum terhubung: Persiapan 1 langkah 4 |
| `Image 'mirror.gcr.io/…' not found` | jangan pakai `docker.io/…`; pakai `$HUB/…` dari 0.3 |
| `02-load.sh` memberi `401`/`403` | jalankan `gcloud auth login`, lalu ulangi |
| `02-load.sh` memberi `502` di `/` | izin `frontend-sa` → `backend` belum tersebar: tunggu 1 menit |
| Save & test Cloud Logging: `Permission denied for all log views` | IAM belum tersebar: tunggu 1 menit, Save & test lagi |
| Panel per route kosong | metrik di 0.6 hanya menghitung log baru: kirim traffic, tunggu 2–3 menit |
| Alert belum menyala | normal sampai 6 menit; mulai tanya Assistant sebelum itu |
| Assistant tidak bisa menjalankan query | wajar untuk data source Google Cloud: minta ia menulis query-nya, jalankan di **Explore**, lalu tanya tentang hasil di layar |
