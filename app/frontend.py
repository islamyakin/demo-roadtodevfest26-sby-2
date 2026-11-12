"""frontend: the shop users hit. Calls the private backend with an ID token.

  GET /           home: calls backend /          healthy baseline
  GET /5xx        checkout: calls backend /pay    502 when the backend fails  (root cause: backend)
  GET /queryslow  order history: backend /query   slow, then 502              (root cause: backend DB)
  GET /slow       recommendations: CPU-bound loop, no cache                    (root cause: here)
                  It holds the CPU (and Python's GIL), so / on the same instance gets slow too.
                  fix: RECO_CACHE=true (compute once, serve from memory)
"""
import base64
import json
import os
import time
import urllib.error
import urllib.request

from flask import request

from common import make_app

BACKEND_URL = os.environ.get("BACKEND_URL", "http://localhost:8081")
RECO_ITEMS = int(os.environ.get("RECO_ITEMS", "3000000"))
RECO_CACHE = os.environ.get("RECO_CACHE", "false").lower() == "true"
_reco = {}

app, log = make_app("frontend")
log("INFO", "frontend starting", backend_url=BACKEND_URL, reco_items=RECO_ITEMS,
    reco_cache=RECO_CACHE)

_token = {"value": "", "exp": 0.0}


def id_token():
    """ID token for the backend, from the metadata server. Off Cloud Run: no auth (local backend)."""
    if not os.environ.get("K_SERVICE"):
        return ""
    if time.time() > _token["exp"] - 60:
        req = urllib.request.Request(
            "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/"
            f"default/identity?audience={BACKEND_URL}", headers={"Metadata-Flavor": "Google"})
        token = urllib.request.urlopen(req, timeout=5).read().decode()
        payload = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        # The metadata server may hand back a cached token with minutes left: trust its own exp.
        _token.update(value=token, exp=claims["exp"])
    return _token["value"]


def call_backend(method, path):
    """Returns (status, ms); status None = no HTTP answer. Forwards the trace headers so both
    services log the same trace."""
    headers = {k: request.headers[k] for k in ("traceparent", "X-Cloud-Trace-Context")
               if k in request.headers}
    start = time.monotonic()
    status = None
    try:
        if token := id_token():
            headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(BACKEND_URL + path, method=method, headers=headers,
                                     data=b"" if method == "POST" else None)
        with urllib.request.urlopen(req, timeout=10) as resp:
            status = resp.status
    except urllib.error.HTTPError as e:
        status = e.code
    except OSError as e:  # metadata server or backend: connection refused, DNS, timeout
        log("ERROR", f"backend {method} {path} unreachable: {e}", error_type="UpstreamUnreachable",
            upstream="backend", upstream_path=path)
    ms = int((time.monotonic() - start) * 1000)
    if status is None:
        pass  # already logged as UpstreamUnreachable
    elif status >= 400:
        log("ERROR", f"backend {method} {path} returned {status} after {ms}ms",
            error_type="UpstreamError", upstream="backend", upstream_path=path,
            upstream_status=status, upstream_ms=ms)
    elif ms > 1000:
        log("WARNING", f"backend {method} {path} slow: {ms}ms", upstream="backend",
            upstream_path=path, upstream_ms=ms)
    return status, ms


def reply(status, ok_body, what):
    if status is None or status >= 400:  # 401/403/429 is a failure too, not a fake success
        return {"error": f"{what} failed upstream"}, 502
    return ok_body


@app.get("/")
def home():
    status, _ = call_backend("GET", "/")
    return reply(status, {"page": "home"}, "catalog")


@app.get("/5xx")
def checkout():
    status, _ = call_backend("POST", "/pay")
    return reply(status, {"page": "checkout", "status": "paid"}, "payment")


@app.get("/queryslow")
def order_history():
    status, ms = call_backend("GET", "/query")
    return reply(status, {"page": "orders", "backend_ms": ms}, "order search")


@app.get("/slow")
def recommendations():
    if RECO_CACHE and "score" in _reco:
        return {"page": "recommendations", "score": _reco["score"] % 100, "cached": True}
    start = time.thread_time()  # this request's CPU only, not the other 15 threads'
    score = _reco["score"] = sum(i * i % 7 for i in range(RECO_ITEMS))  # scores every item
    cpu_ms = int((time.thread_time() - start) * 1000)
    if cpu_ms > 50:  # ~100 ms on a laptop, 2-3x on a Cloud Run vCPU: always worth a WARNING
        log("WARNING", f"slow render: recommendations scored {RECO_ITEMS} items in {cpu_ms}ms "
            f"CPU (CPU-bound, no cache)", cpu_ms=cpu_ms, items=RECO_ITEMS)
    return {"page": "recommendations", "score": score % 100}


if __name__ == "__main__":
    app.run(port=int(os.environ.get("PORT", "8080")), threaded=True)
