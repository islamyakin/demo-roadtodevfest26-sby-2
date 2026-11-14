# Grafana Cloud side: how your stack reads Google Cloud, plus the dashboard and alert rules.
#
#   "Google Cloud (PromQL)"  Prometheus data source -> Cloud Monitoring's PromQL API. Grafana Assistant
#                            speaks PromQL natively. Its OAuth token is kept fresh by Google's own
#                            datasource-syncer, run as a Cloud Run job every 10 min (nobody generates tokens).
#   "Google Cloud Logging"   Google's Cloud Logging plugin with a read-only service account.

variable "grafana_url" {
  type        = string
  description = "Your Grafana Cloud stack, e.g. https://<stack>.grafana.net"
}
variable "grafana_token" {
  type        = string
  sensitive   = true
  description = "Token of a stack service account with role Admin (Administration > Users and access > Service accounts)"
}

provider "grafana" {
  url  = var.grafana_url
  auth = var.grafana_token
}

# ---------- The identity Grafana Cloud uses on Google Cloud: read-only ----------

resource "google_service_account" "grafana" {
  account_id   = "grafana-reader"
  display_name = "Grafana Cloud reader (workshop)"
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "grafana" {
  for_each = toset(["roles/monitoring.viewer", "roles/logging.viewer"])
  project  = var.project_id
  role     = each.key
  member   = "serviceAccount:${google_service_account.grafana.email}"
}

# ---------- Data sources ----------

resource "grafana_data_source" "promql" {
  type       = "prometheus"
  name       = "Google Cloud (PromQL)"
  uid        = "gcp-promql"
  is_default = true
  url        = "https://monitoring.googleapis.com/v1/projects/${var.project_id}/location/global/prometheus/"
  json_data_encoded = jsonencode({
    httpMethod   = "GET"
    timeInterval = "60s"
    manageAlerts = false # Cloud Monitoring has no rules API; the alert rules live in Grafana
  })
  # The syncer owns the URL and the Authorization header from here on.
  lifecycle { ignore_changes = [url, json_data_encoded, secure_json_data_encoded, http_headers] }
}

# The Cloud Logging plugin cannot use a refreshed token, so it gets a read-only key. The key lives
# in Grafana Cloud and in local Terraform state only (never in git).
resource "google_service_account_key" "grafana" {
  service_account_id = google_service_account.grafana.name
}

locals {
  grafana_key = jsondecode(base64decode(google_service_account_key.grafana.private_key))
}

resource "grafana_data_source" "logging" {
  type = "googlecloud-logging-datasource" # install the plugin once in your stack first (README)
  name = "Google Cloud Logging"
  uid  = "gcp-logging"
  json_data_encoded = jsonencode({
    authenticationType = "jwt"
    clientEmail        = local.grafana_key.client_email
    defaultProject     = var.project_id
    tokenUri           = local.grafana_key.token_uri
  })
  secure_json_data_encoded = jsonencode({ privateKey = local.grafana_key.private_key })
}

# ---------- Token sync: Google's datasource-syncer as a Cloud Run job, every 10 min ----------

resource "google_secret_manager_secret" "grafana_token" {
  secret_id = "grafana-sa-token"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "grafana_token" {
  secret      = google_secret_manager_secret.grafana_token.id
  secret_data = var.grafana_token
}

resource "google_secret_manager_secret_iam_member" "syncer" {
  secret_id = google_secret_manager_secret.grafana_token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.grafana.email}"
}

# Cloud Run pulls only from Artifact Registry / Docker Hub / GHCR, so Google's public image on
# gke.gcr.io comes in through an Artifact Registry remote repository (a pull-through proxy).
resource "google_artifact_registry_repository" "gke" {
  repository_id = "gke-gcr"
  location      = var.region
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  remote_repository_config {
    description = "pull-through proxy for gke.gcr.io"
    docker_repository {
      custom_repository {
        uri = "https://gke.gcr.io"
      }
    }
  }
  depends_on = [google_project_service.apis]
}

resource "google_cloud_run_v2_job" "syncer" {
  name                = "grafana-datasource-syncer"
  location            = var.region
  deletion_protection = false

  template {
    template {
      service_account = google_service_account.grafana.email # mints the token Grafana will use
      max_retries     = 1
      timeout         = "300s"
      containers {
        image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.gke.repository_id}/prometheus-engine/datasource-syncer:v0.19.5-gke.0"
        args = [
          "--datasource-uids=${grafana_data_source.promql.uid}",
          "--grafana-api-endpoint=${var.grafana_url}",
          "--project-id=${var.project_id}",
        ]
        env {
          name = "GRAFANA_SERVICE_ACCOUNT_TOKEN"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.grafana_token.secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }
  depends_on = [google_secret_manager_secret_version.grafana_token, google_secret_manager_secret_iam_member.syncer]
}

resource "google_cloud_run_v2_job_iam_member" "scheduler" {
  name     = google_cloud_run_v2_job.syncer.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.grafana.email}"
}

resource "google_cloud_scheduler_job" "syncer" {
  name     = "grafana-datasource-syncer"
  region   = var.region
  schedule = "*/10 * * * *" # Google access tokens live 1 h; the syncer renews when < 10 min are left
  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/${google_cloud_run_v2_job.syncer.id}:run"
    oauth_token {
      service_account_email = google_service_account.grafana.email
    }
  }
  depends_on = [google_cloud_run_v2_job_iam_member.scheduler]
}

# Run the syncer once right away, so the data source works before the first schedule tick.
resource "terraform_data" "first_sync" {
  triggers_replace = [google_cloud_run_v2_job.syncer.id, grafana_data_source.promql.id, google_secret_manager_secret_version.grafana_token.id]
  provisioner "local-exec" {
    command = "gcloud run jobs execute ${google_cloud_run_v2_job.syncer.name} --region ${var.region} --project ${var.project_id} --wait"
  }
  depends_on = [google_project_iam_member.grafana]
}

# ---------- Dashboard + alert rules ----------

resource "grafana_folder" "workshop" {
  title = "Workshop"
  uid   = "workshop"
}

resource "grafana_dashboard" "shop" {
  folder      = grafana_folder.workshop.uid
  config_json = file("${path.module}/shop-overview.json")
  overwrite   = true
}

locals {
  run = "monitored_resource=\"cloud_run_revision\",service_name=~\"frontend|backend\""
  alerts = {
    "5xx ratio above 5%" = {
      expr      = "sum by (service_name) (rate(run_googleapis_com:request_count{${local.run},response_code_class=\"5xx\"}[5m])) / sum by (service_name) (rate(run_googleapis_com:request_count{${local.run}}[5m]))"
      threshold = 0.05
      summary   = "{{ $labels.service_name }}: more than 5% of requests fail with 5xx."
    }
    "p95 latency above 1s" = {
      expr      = "histogram_quantile(0.95, sum by (le, service_name) (rate(run_googleapis_com:request_latencies_bucket{${local.run}}[5m])))"
      threshold = 1000
      summary   = "{{ $labels.service_name }}: p95 latency is above 1000 ms."
    }
  }
}

# Symptom alerts on Cloud Run's built-in metrics, one instance per service. They say WHERE it hurts;
# the Assistant and you find WHY.
resource "grafana_rule_group" "shop" {
  name             = "shop"
  folder_uid       = grafana_folder.workshop.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = local.alerts
    content {
      name           = rule.key
      condition      = "C"
      for            = "2m"
      no_data_state  = "OK"
      exec_err_state = "Error"
      labels         = { severity = "page" }
      annotations    = { summary = rule.value.summary, runbook = "Ask Grafana Assistant: prompts/lab3-rca.md" }
      data {
        ref_id         = "A"
        datasource_uid = grafana_data_source.promql.uid
        relative_time_range {
          from = 600
          to   = 0
        }
        model = jsonencode({ refId = "A", instant = true, expr = rule.value.expr })
      }
      data {
        ref_id         = "C"
        datasource_uid = "__expr__"
        relative_time_range {
          from = 0
          to   = 0
        }
        model = jsonencode({
          refId      = "C", type = "threshold", expression = "A",
          conditions = [{ evaluator = { type = "gt", params = [rule.value.threshold] } }]
        })
      }
    }
  }
}

output "grafana_dashboard_url" { value = "${var.grafana_url}/d/${grafana_dashboard.shop.uid}" }
