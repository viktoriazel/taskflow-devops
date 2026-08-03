# syntax=docker/dockerfile:1

FROM python:3.12-slim-bookworm

# Predictable Python runtime behavior
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    HOME=/app

# Fixed non-root UID/GID; /app is intentionally not writable by appuser
RUN groupadd --gid 1000 appuser && \
    useradd --uid 1000 --gid appuser --home-dir /app \
        --no-create-home --shell /usr/sbin/nologin appuser

WORKDIR /app

# Install dependencies first for layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Application code — root-owned, read-only for appuser
COPY --chmod=0644 app.py .
COPY templates/ templates/
RUN chmod 0755 templates && chmod 0644 templates/*.html

USER appuser

EXPOSE 8000

CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "--timeout", "60", "--no-control-socket", "app:app"]
