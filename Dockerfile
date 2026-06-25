FROM python:3.12-slim

# Pinned to the versions verified in production (2026-06). Bump deliberately —
# an unpinned install lets a rebuild silently pull a behavior-changing LiteLLM
# (e.g. a release that changes DB-less auth handling).
RUN pip install --no-cache-dir uv && \
    uv pip install --system "litellm[proxy]==1.89.1" "prisma==0.15.0"

WORKDIR /app

COPY litellm_config.yaml .

EXPOSE 4000

ENV UV_NATIVE_TLS=true
ENV LITELLM_LOCAL_MODEL_COST_MAP=true

CMD ["litellm", "--config", "litellm_config.yaml", "--port", "4000", "--host", "0.0.0.0"]
