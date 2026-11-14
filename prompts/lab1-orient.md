# Lab 1 · Get oriented (paste into Grafana Assistant)

Rule for every answer in this workshop: show the query you ran and what it returned. No evidence, no claim.

---

Which data sources do I have? For each one, say in one line what it can answer about two Cloud Run services,
`frontend` and `backend` (region asia-southeast2), and what it cannot.

---

Using the "Google Cloud Monitoring" data source with a PromQL query, show requests per second per service and response_code_class over the last 30 minutes:
`sum by (service_name, response_code_class) (rate(run_googleapis_com:request_count{monitored_resource="cloud_run_revision", service_name=~"frontend|backend"}[5m]))`.
Explain the query, and tell me why `frontend` and `backend` have about the same rate.

---

Cloud Run metrics have no route label. Using "Google Cloud Monitoring" (PromQL), show the same per route from the log-based metric:
`sum by (service, route, status) (rate(logging_googleapis_com:user_app_requests{monitored_resource="cloud_run_revision"}[5m]))`.
(Log-based metrics need the `monitored_resource="cloud_run_revision"` matcher in PromQL.)
Which routes exist on each service?

---

Using "Google Cloud Logging", show the last 20 entries for
`resource.type="cloud_run_revision" AND resource.labels.service_name=("frontend" OR "backend")`.
What fields are in jsonPayload? Pick one frontend `request` line and find the backend line with the same `trace`:
what does that tell me about how one user request flows?
