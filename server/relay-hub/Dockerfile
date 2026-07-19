FROM python:3.13-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN groupadd --system hermes && useradd --system --gid hermes --home /app hermes
WORKDIR /app

COPY requirements.txt ./
RUN pip install --requirement requirements.txt
COPY relay_hub ./relay_hub
COPY migrations ./migrations
RUN mkdir -p /app/data && chown -R hermes:hermes /app

USER hermes
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/readyz', timeout=2)"
CMD ["uvicorn", "relay_hub.app:create_app", "--factory", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers", "--ws-max-size", "400000", "--limit-concurrency", "1024"]
