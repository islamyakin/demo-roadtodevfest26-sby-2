"""Grafana token sync: runs as the Cloud Run job "grafana-token-sync", every 10 minutes.

Grafana Cloud cannot use Google credentials on its own, and service-account keys are off the table
(org policy iam.disableServiceAccountKeyCreation). So this job, running as the read-only account
grafana-reader, mints a fresh 1-hour access token and writes it into both Grafana data sources:
  gcp-promql   Prometheus data source -> Cloud Monitoring PromQL API   (Authorization header)
  gcp-logging  Google Cloud Logging plugin, auth type "accessToken"
Standard library only, so it runs on the plain python image.
"""
import json
import os
import urllib.request


def call(method, url, token, body=None):
    req = urllib.request.Request(url, method=method, headers={"Authorization": f"Bearer {token}",
                                                             "Content-Type": "application/json"},
                                 data=None if body is None else json.dumps(body).encode())
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


project, sa = os.environ["PROJECT_ID"], os.environ["SA_EMAIL"]
grafana, grafana_token = os.environ["GRAFANA_URL"].rstrip("/"), os.environ["GRAFANA_TOKEN"]

# 1. This job's own identity, from the Cloud Run metadata server.
md = urllib.request.Request("http://metadata.google.internal/computeMetadata/v1/instance/"
                            "service-accounts/default/token", headers={"Metadata-Flavor": "Google"})
base_token = json.load(urllib.request.urlopen(md, timeout=10))["access_token"]

# 2. A fresh token with a full hour left (the metadata server may return a cached one with minutes left).
token = call("POST", f"https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/{sa}:generateAccessToken",
             base_token, {"scope": ["https://www.googleapis.com/auth/cloud-platform"], "lifetime": "3600s"})["accessToken"]

# 3. Write it into both data sources (GET the current model, change the auth part, PUT it back).
for uid in ("gcp-promql", "gcp-logging"):
    ds = call("GET", f"{grafana}/api/datasources/uid/{uid}", grafana_token)
    ds.setdefault("jsonData", {})
    if uid == "gcp-promql":
        ds["url"] = f"https://monitoring.googleapis.com/v1/projects/{project}/location/global/prometheus/"
        ds["jsonData"]["httpHeaderName1"] = "Authorization"
        ds["secureJsonData"] = {"httpHeaderValue1": f"Bearer {token}"}
    else:
        ds["jsonData"].update(authenticationType="accessToken", defaultProject=project)
        ds["secureJsonData"] = {"accessToken": token}
    call("PUT", f"{grafana}/api/datasources/uid/{uid}", grafana_token, ds)
    print(f"updated {uid}")
