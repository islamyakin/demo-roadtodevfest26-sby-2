# Wrap-up · Postmortem by prompt (paste into Grafana Assistant)

Write a blameless postmortem for the incidents on Cloud Run `frontend` and `backend` in the last 2 hours
(the `/5xx`, `/queryslow`, `/slow` and mystery rounds). For each incident:
- timeline with times from the data: start, alert, diagnosis, mitigation (new revision), recovery;
- impact: failed requests, peak 5xx ratio, peak p95, which routes and which service users saw;
- root cause and the service it lives in, plus the 5 Whys;
- what helped detection and what slowed it down.

Show the query behind every number. Mark anything you inferred and could not query as "inferred".
End with 3–5 action items that prevent a repeat (owner: TBD), separating quick mitigations from fixes for good.

---

Error budget: our SLOs are 99% of frontend requests succeed and 95% finish under 1 s, over 30 days.
Using `run_googleapis_com:request_count` and `run_googleapis_com:request_latencies_bucket` for `{monitored_resource="cloud_run_revision", service_name="frontend"}`,
how much of each 30-day error budget did these incidents burn? Show the queries. If this were production,
should we freeze risky releases?
