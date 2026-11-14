# One Dockerfile, two images: APP picks the module (frontend.py or backend.py).
#   docker build --platform linux/amd64 --build-arg APP=frontend -t <user>/shop-frontend app/
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY common.py frontend.py backend.py ./

ARG APP=frontend
ENV APP=${APP} PORT=8080 PYTHONUNBUFFERED=1
USER 10001
EXPOSE 8080
# Same command as the Procfile used by Cloud Build: 1 worker, 16 threads (= Cloud Run concurrency 16).
CMD exec gunicorn --bind :${PORT} --workers 1 --threads 16 --timeout 0 ${APP}:app
