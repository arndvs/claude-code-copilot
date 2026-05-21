FROM python:3.12-slim

RUN pip install --no-cache-dir uv && \
    uv pip install --system "litellm[proxy]"

WORKDIR /app

COPY litellm_config.yaml .

EXPOSE 4000

ENV UV_NATIVE_TLS=true
ENV LITELLM_LOCAL_MODEL_COST_MAP=true

CMD ["litellm", "--config", "litellm_config.yaml", "--port", "4000", "--host", "0.0.0.0"]
