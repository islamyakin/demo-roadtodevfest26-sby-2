# Everything the workshop creates in Google Cloud. One `terraform apply` builds the image and deploys:
#   frontend (Cloud Run, private) -> backend (Cloud Run, private, only frontend-sa may call it)
# plus three log-based metrics that give per-route RED data (Cloud Run metrics have no route label).
#
# Mitigations during the labs are done by hand with `gcloud run services update ... --update-env-vars`.
# A later `terraform apply` puts the services back in their broken state: handy to re-run an incident.

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = { source = "hashicorp/google", version = ">= 6.0" }
  }
}

variable "project_id" { type = string }
variable "region" {
  type    = string
  default = "asia-southeast2"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  apis = ["run", "cloudbuild", "artifactregistry", "compute", "logging", "monitoring",
  "cloudresourcemanager", "iam"]

  # Image tag = hash of the app source, so a code change rebuilds and redeploys.
  app_dir   = "${path.module}/../app"
  app_files = [for f in fileset(local.app_dir, "**") : f if !strcontains(f, "__pycache__") && !startswith(f, ".") && !strcontains(f, "/.")]
  app_hash  = substr(sha1(join("", [for f in local.app_files : "${f}:${filesha1("${local.app_dir}/${f}")}"])), 0, 12)
  image     = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.shop.repository_id}/app:${local.app_hash}"

  app_logs = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=(\"frontend\" OR \"backend\")"
}

resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  service            = "${each.key}.googleapis.com"
  disable_on_destroy = false
}

# ---------- Build: Cloud Build + buildpacks (no Docker needed on your laptop) ----------

resource "google_artifact_registry_repository" "shop" {
  repository_id = "shop"
  location      = var.region
  format        = "DOCKER"
  depends_on    = [google_project_service.apis]
}

# Cloud Build runs as the Compute Engine default service account in new projects. It needs
# roles/cloudbuild.builds.builder; that grant is NOT managed here, because `terraform destroy` would
# revoke it from a shared project. Grant it once by hand if the build fails (see README).

resource "terraform_data" "image" {
  triggers_replace = [local.image]
  provisioner "local-exec" {
    command = "gcloud builds submit '${local.app_dir}' --pack image=${local.image} --project ${var.project_id} --quiet"
  }
  depends_on = [google_artifact_registry_repository.shop]
}

# ---------- Identities: one service account per service, no project roles ----------

resource "google_service_account" "svc" {
  for_each     = toset(["frontend", "backend"])
  account_id   = "${each.key}-sa"
  display_name = "workshop ${each.key}"
  depends_on   = [google_project_service.apis]
}

# ---------- The two services (same image; APP picks the module, see app/Procfile) ----------

resource "google_cloud_run_v2_service" "backend" {
  name                = "backend"
  location            = var.region
  deletion_protection = false

  template {
    service_account                  = google_service_account.svc["backend"].email
    max_instance_request_concurrency = 16
    scaling { max_instance_count = 2 }
    containers {
      image = local.image
      resources { limits = { cpu = "1", memory = "512Mi" } }
      env {
        name  = "APP"
        value = "backend"
      }
      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
    }
  }
  lifecycle { ignore_changes = [client, client_version] } # set by gcloud during the labs
  depends_on = [terraform_data.image]
}

resource "google_cloud_run_v2_service" "frontend" {
  name                = "frontend"
  location            = var.region
  deletion_protection = false

  template {
    service_account                  = google_service_account.svc["frontend"].email
    max_instance_request_concurrency = 16
    scaling { max_instance_count = 2 }
    containers {
      image = local.image
      resources { limits = { cpu = "1", memory = "512Mi" } }
      env {
        name  = "APP"
        value = "frontend"
      }
      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "BACKEND_URL"
        value = google_cloud_run_v2_service.backend.uri
      }
    }
  }
  lifecycle { ignore_changes = [client, client_version] }
  depends_on = [terraform_data.image]
}

# Only the frontend may call the backend. Nobody gets public access; you call the frontend
# with your own identity token (project Owners/Editors already have run.invoker).
resource "google_cloud_run_v2_service_iam_member" "frontend_calls_backend" {
  name     = google_cloud_run_v2_service.backend.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.svc["frontend"].email}"
}

# ---------- Log-based metrics: per-route RED + errors by type, queryable with PromQL ----------
#   logging_googleapis_com:user_app_requests, ..._user_app_latency_bucket, ..._user_app_errors

resource "google_logging_metric" "app_requests" {
  name        = "app_requests"
  description = "Requests per service, route and status, from the app's \"request\" log line"
  filter      = "${local.app_logs} AND jsonPayload.message=\"request\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    labels { key = "service" }
    labels { key = "route" }
    labels { key = "status" }
  }
  label_extractors = {
    service = "EXTRACT(jsonPayload.service)"
    route   = "EXTRACT(jsonPayload.route)"
    status  = "EXTRACT(jsonPayload.status)"
  }
  depends_on = [google_project_service.apis]
}

resource "google_logging_metric" "app_latency" {
  name            = "app_latency"
  description     = "Request latency in ms per service and route"
  filter          = "${local.app_logs} AND jsonPayload.message=\"request\""
  value_extractor = "EXTRACT(jsonPayload.latency_ms)"
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "DISTRIBUTION"
    unit        = "ms"
    labels { key = "service" }
    labels { key = "route" }
  }
  label_extractors = {
    service = "EXTRACT(jsonPayload.service)"
    route   = "EXTRACT(jsonPayload.route)"
  }
  bucket_options {
    explicit_buckets { bounds = [25, 50, 100, 200, 300, 500, 750, 1000, 1500, 2000, 3000, 5000, 10000] }
  }
  depends_on = [google_project_service.apis]
}

resource "google_logging_metric" "app_errors" {
  name        = "app_errors"
  description = "ERROR log entries per service and error_type"
  filter      = "${local.app_logs} AND severity>=ERROR AND jsonPayload.error_type:*"
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    labels { key = "service" }
    labels { key = "error_type" }
  }
  label_extractors = {
    service    = "EXTRACT(jsonPayload.service)"
    error_type = "EXTRACT(jsonPayload.error_type)"
  }
  depends_on = [google_project_service.apis]
}

output "frontend_url" { value = google_cloud_run_v2_service.frontend.uri }
output "backend_url" { value = google_cloud_run_v2_service.backend.uri }
output "image" { value = local.image }
