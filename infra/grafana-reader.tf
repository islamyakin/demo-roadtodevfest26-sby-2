# The identity Grafana uses to read Google Cloud: read-only. Its key file is the "JWT" that Grafana's
# Google data sources ask for (Authentication: Google JWT File). terraform apply writes it to
# grafana-reader.json in the repo root (mode 0600, gitignored); you upload it in Grafana yourself.
#
# Organizations with the policy iam.disableServiceAccountKeyCreation refuse keys: set grafana_key = false
# there (the account is still created; see grafana.tf.disabled for the keyless token route).

resource "google_service_account" "grafana" {
  account_id   = "grafana-reader"
  display_name = "Grafana reader (workshop)"
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "grafana" {
  for_each = toset(["roles/monitoring.viewer", "roles/logging.viewer", "roles/logging.viewAccessor"])
  project  = var.project_id
  role     = each.key
  member   = "serviceAccount:${google_service_account.grafana.email}"
}

resource "google_service_account_key" "grafana" {
  count              = var.grafana_key ? 1 : 0
  service_account_id = google_service_account.grafana.name
}

resource "local_sensitive_file" "grafana_key" {
  count           = var.grafana_key ? 1 : 0
  filename        = "${path.module}/../grafana-reader.json"
  content         = base64decode(google_service_account_key.grafana[0].private_key)
  file_permission = "0600"
}
