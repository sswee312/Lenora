from typing import Literal

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

AddonMode = Literal["auto", "on", "off"]


class CloudinarySettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="LENORA_CLOUDINARY_", extra="ignore")

    cloud_name: str = Field(min_length=1, pattern=r"^[A-Za-z0-9_-]+$")
    api_key: str = Field(min_length=1)
    api_secret: SecretStr = Field(min_length=1)
    on_the_fly_video_max_bytes: int = Field(default=41943040, gt=0)
    image_generation: AddonMode = "auto"
    image_to_video: AddonMode = "auto"
