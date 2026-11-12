# Lab 2 · Dashboard by prompt (paste into Grafana Assistant)

A ready-made dashboard "Shop · Overview" already exists in the folder "Workshop". Build your own next to it, so you
learn the queries: create a dashboard called "Shop · RED" in the folder "Workshop", data source "Google Cloud (PromQL)"
unless noted.
Services: Cloud Run `frontend` and `backend`. Use a 60s minimum interval and `[5m]` rate windows
(Cloud Run metrics arrive every minute with a 2–3 min delay).

Row "Per service" (Cloud Run built-in, filter `monitored_resource="cloud_run_revision", service_name=~"frontend|backend"`):
1. Rate: requests/s by service_name, from `run_googleapis_com:request_count`.
2. Errors: 5xx ratio in percent by service_name (`response_code_class="5xx"` over all).
3. Duration: p50 and p95 latency in ms by service_name, from `run_googleapis_com:request_latencies_bucket`.
4. CPU: p95 CPU utilization by service_name, from `run_googleapis_com:container_cpu_utilizations_bucket`.
5. Instances: `run_googleapis_com:container_instance_count` by service_name and state.

Row "Per route" (log-based metrics, labels `service`, `route`, `status`; every selector needs `monitored_resource="cloud_run_revision"`):
6. Rate: requests/s by service and route, from `logging_googleapis_com:user_app_requests`.
7. Errors: 5xx ratio in percent by service and route (`status=~"5.."`).
8. Duration: p95 latency in ms by service and route, from `logging_googleapis_com:user_app_latency_bucket`.

Row "Why":
9. Error types: rate of `logging_googleapis_com:user_app_errors` by service and error_type.
10. Logs panel from "Google Cloud Logging":
    `resource.type="cloud_run_revision" AND resource.labels.service_name=("frontend" OR "backend") AND severity>=WARNING`.

---

Check every panel: run each query and tell me whether it returns data. Fix the ones that don't and show me what you
changed. (Panels 2, 7 and 9 may be empty while nothing is failing: say so instead of "fixing" them. If you cannot query
Google Cloud Logging for panel 10, say so: I will check it myself.)
