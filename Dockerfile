FROM python:3.12-slim

# Pin the install toolchain + Python deps to the versions verified in production
# (2026-06) so a rebuild can't silently pull a behavior-changing LiteLLM. The base
# image stays a tag (python:3.12-slim) on purpose — it tracks Debian security
# patches; for a fully frozen artifact, deploy the prebuilt ECR image (see
# docs/hosted_deployment.md) instead of rebuilding on the box.
RUN pip install --no-cache-dir "uv==0.11.21" && \
    uv pip install --system "litellm[proxy]==1.89.1" "prisma==0.15.0"

WORKDIR /app

COPY litellm_config.yaml .
COPY litellm_logger.py .
COPY health_version.py .

EXPOSE 4000

# Build-time version info baked into the image (set during docker build).
ARG BUILD_SHA=unknown
ARG BUILD_TIMESTAMP=unknown
ENV BUILD_SHA=${BUILD_SHA}
ENV BUILD_TIMESTAMP=${BUILD_TIMESTAMP}

# /app on the import path so litellm can load the litellm_logger callback module.
ENV PYTHONPATH=/app
ENV UV_NATIVE_TLS=true
ENV LITELLM_LOCAL_MODEL_COST_MAP=true

CMD ["litellm", "--config", "litellm_config.yaml", "--port", "4000", "--host", "0.0.0.0"]
