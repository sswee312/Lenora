FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:0.8 /uv /usr/local/bin/uv
WORKDIR /srv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy LENORA_ENV=production
COPY pyproject.toml uv.lock ./
COPY src ./src
COPY adapters/cloudinary ./adapters/cloudinary
COPY adapters/openai ./adapters/openai
RUN uv sync --frozen --no-dev --all-packages
RUN useradd --system --uid 10001 lenora && mkdir -p /data && chown lenora /data
USER lenora
EXPOSE 8080
ENV PORT=8080
ENV LENORA_DATA_DIR=/data
# Hosting platforms terminate TLS at their proxy; trust it so result URLs keep https.
ENV LENORA_FORWARDED_ALLOW_IPS=*
VOLUME ["/data"]
CMD ["/srv/.venv/bin/lenora-backend"]
