"""Shared by both services: one JSON log line per event, readable by Cloud Logging,
the log-based metrics (infra/main.tf) and Grafana Assistant."""
import json
import os
import sys
import time

from flask import Flask, g, has_request_context, request

PROJECT = os.environ.get("PROJECT_ID", "")
REVISION = os.environ.get("K_REVISION", "local")  # set by Cloud Run


def trace_id():
    """Trace id of the current request, from the headers Cloud Run adds (and the frontend forwards)."""
    if not has_request_context():
        return ""
    tp = request.headers.get("traceparent", "")  # W3C: 00-<trace>-<span>-<flags>
    if tp.count("-") == 3:
        return tp.split("-")[1]
    return request.headers.get("X-Cloud-Trace-Context", "").split("/")[0]  # <trace>/<span>;o=1


def make_app(service):
    app = Flask(service)

    def log(severity, message, **fields):
        entry = {"severity": severity, "message": message, "service": service,
                 "revision": REVISION, **fields}
        tid = trace_id()
        if tid and PROJECT:  # same trace in frontend + backend logs = one request end to end
            entry["logging.googleapis.com/trace"] = f"projects/{PROJECT}/traces/{tid}"
        sys.stdout.write(json.dumps(entry) + "\n")  # one write: lines from 16 threads never interleave
        sys.stdout.flush()

    @app.before_request
    def _start():
        g.start = time.monotonic()

    @app.after_request
    def _request_log(resp):
        # Feeds the app_requests / app_latency log-based metrics: per-route RED that Cloud Run can't give.
        route = request.url_rule.rule if request.url_rule else "other"
        log("INFO", "request", route=route, method=request.method, status=resp.status_code,
            latency_ms=int((time.monotonic() - g.start) * 1000))
        return resp

    return app, log
