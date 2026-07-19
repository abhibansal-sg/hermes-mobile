FROM python:3.13-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# Keep the unprivileged runtime identity stable so local Compose bind-backed
# secrets can be prepared for the exact reader on Linux hosts.
RUN groupadd --system --gid 999 hermes \
    && useradd --system --uid 999 --gid hermes --home /app hermes
WORKDIR /app

COPY requirements.txt ./
RUN pip install --requirement requirements.txt
COPY push_gateway ./push_gateway
COPY migrations ./migrations
RUN mkdir -p /app/data && chown -R hermes:hermes /app

USER hermes
EXPOSE 8081
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8081/readyz', timeout=2)"
CMD ["uvicorn", "push_gateway.app:create_app", "--factory", "--host", "0.0.0.0", "--port", "8081", "--proxy-headers", "--limit-concurrency", "512"]
