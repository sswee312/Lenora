from pathlib import Path

from pydantic import AliasChoices, Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class OpenAISettings(BaseSettings):
    # env_ignore_empty: an empty LENORA_OPENAI_API_KEY= line in .env must not hide OPENAI_API_KEY.
    model_config = SettingsConfigDict(env_prefix="LENORA_OPENAI_", extra="ignore", populate_by_name=True,
                                      env_ignore_empty=True)

    api_key: SecretStr = Field(min_length=1, validation_alias=AliasChoices("LENORA_OPENAI_API_KEY", "OPENAI_API_KEY"))
    daily_budget_usd: float = Field(default=5.0, ge=0)
    speech_model: str = Field(default="gpt-4o-mini-tts", min_length=1)
    rewrite_model: str = Field(default="gpt-5.4-mini", min_length=1)
    # For tests only.
    base_url: str = "https://api.openai.com/v1"
    data_dir: Path = Field(default=Path(".data"), validation_alias=AliasChoices("LENORA_DATA_DIR"))
