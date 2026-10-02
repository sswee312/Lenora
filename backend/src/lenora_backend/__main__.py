import json
import logging
import sys

import uvicorn
from pydantic import ValidationError

from lenora_backend.app import create_app
from lenora_backend.settings import load_environment


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        return json.dumps({"level": record.levelname, "logger": record.name, "message": record.getMessage()})


def main() -> None:
    try:
        settings = load_environment()
        port = settings.bind_port
    except (ValidationError, ValueError) as error:
        names = {".".join(str(p) for p in e["loc"]) for e in error.errors()} if isinstance(error, ValidationError) else set()
        hint = "LENORA_TOKEN is missing or shorter than 32 characters. Run ./scripts/bootstrap." if "token" in names else str(error)
        print(f"lenora-backend: {hint}", file=sys.stderr)
        sys.exit(2)
    handler = logging.StreamHandler()
    if settings.env == "production":
        handler.setFormatter(JsonFormatter())
    logging.basicConfig(level=logging.INFO, handlers=[handler])
    uvicorn.run(create_app(settings), host=settings.bind_host, port=port,
                proxy_headers=settings.env == "production", log_config=None)


if __name__ == "__main__":
    main()
