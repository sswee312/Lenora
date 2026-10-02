FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:0.8 /uv /usr/local/bin/uv
WORKDIR /srv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy LENORA_ENV=production
COPY pyproject.toml uv.lock ./
COPY src ./src
COPY adapters/cloudinary ./adapters/cloudinary
RUN uv sync --frozen --no-dev --all-packages
RUN useradd --system --uid 10001 lenora
USER lenora
EXPOSE 8080
ENV PORT=8080
CMD ["/srv/.venv/bin/lenora-backend"]
