"""backend: orders + payments behind the frontend. Private: only frontend-sa may call it.

The root causes of /5xx and /queryslow live here:
  POST /pay    the primary payment gateway times out for PAYMENT_FAILURE_RATE of calls  -> 503
               fix: fail over, PAYMENT_GATEWAY=payment-gw-backup.internal
  GET  /query  order search does a full table scan (no index), holding one of
               DB_POOL_SIZE connections for ~1.2 s; under load the pool runs dry -> slow, then 503
               fix: "CREATE INDEX", ORDERS_INDEX=true
"""
import os
import random
import threading
import time

from flask import jsonify

from common import make_app

PAYMENT_GATEWAY = os.environ.get("PAYMENT_GATEWAY", "payment-gw.internal")
PAYMENT_FAILURE_RATE = float(os.environ.get("PAYMENT_FAILURE_RATE", "0.6"))
PAYMENT_TIMEOUT_MS = int(os.environ.get("PAYMENT_TIMEOUT_MS", "1500"))
DB_POOL_SIZE = int(os.environ.get("DB_POOL_SIZE", "4"))
DB_POOL_TIMEOUT_MS = int(os.environ.get("DB_POOL_TIMEOUT_MS", "2000"))
ORDERS_INDEX = os.environ.get("ORDERS_INDEX", "false").lower() == "true"

app, log = make_app("backend")
pool = threading.BoundedSemaphore(DB_POOL_SIZE)
log("INFO", "backend starting", payment_gateway=PAYMENT_GATEWAY,
    payment_failure_rate=PAYMENT_FAILURE_RATE, orders_index=ORDERS_INDEX,
    payment_timeout_ms=PAYMENT_TIMEOUT_MS, db_pool_size=DB_POOL_SIZE,
    db_pool_timeout_ms=DB_POOL_TIMEOUT_MS)


@app.get("/")
def catalog():
    time.sleep(random.uniform(0.005, 0.02))  # indexed lookup: fast
    return {"service": "backend", "products": 42}


@app.post("/pay")
def pay():
    degraded = PAYMENT_GATEWAY == "payment-gw.internal"  # the primary is having a bad day
    if degraded and random.random() < PAYMENT_FAILURE_RATE:
        time.sleep(PAYMENT_TIMEOUT_MS / 1000)
        log("ERROR", f"PaymentGatewayTimeout: {PAYMENT_GATEWAY} did not answer within "
            f"{PAYMENT_TIMEOUT_MS}ms", error_type="PaymentGatewayTimeout",
            dependency=PAYMENT_GATEWAY, timeout_ms=PAYMENT_TIMEOUT_MS)
        return jsonify(error="payment gateway timeout"), 503
    time.sleep(random.uniform(0.05, 0.15))
    return {"status": "paid"}


@app.get("/query")
def query():
    start = time.monotonic()
    if not pool.acquire(timeout=DB_POOL_TIMEOUT_MS / 1000):
        log("ERROR", f"ConnectionPoolTimeout: no DB connection after {DB_POOL_TIMEOUT_MS}ms "
            f"(pool size {DB_POOL_SIZE}, all busy)", error_type="ConnectionPoolTimeout",
            db_pool_size=DB_POOL_SIZE)
        return jsonify(error="database busy"), 503
    waited_ms = int((time.monotonic() - start) * 1000)
    try:
        query_ms = int(random.uniform(10, 40) if ORDERS_INDEX else random.uniform(800, 1600))
        time.sleep(query_ms / 1000)
    finally:
        pool.release()
    if ORDERS_INDEX:
        return {"orders": 3, "query_ms": query_ms}
    log("WARNING", f"slow query {query_ms}ms: SELECT * FROM orders WHERE customer_email = ? "
        f"(full table scan, rows_examined=1200000, no index on orders.customer_email)",
        query_ms=query_ms, pool_wait_ms=waited_ms, table="orders", rows_examined=1200000,
        index_used=None)
    return {"orders": 3, "query_ms": query_ms}


if __name__ == "__main__":
    app.run(port=int(os.environ.get("PORT", "8081")), threaded=True)
