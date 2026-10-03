"""Add-ons this Cloudinary account has subscribed to, read from the usage report."""
from dataclasses import dataclass

from lenora_backend.errors import ProblemError
from lenora_adapter_cloudinary.api import CloudinaryAPI

# Product counters, not add-ons. image_generation is offered through the existing auto/on/off switch.
SKIP = frozenset({
    "transformations", "objects", "bandwidth", "storage", "requests", "resources",
    "derived_resources", "media_limits", "credits", "impressions", "seconds_delivered",
    "image_generation",
})


@dataclass(frozen=True)
class Subscribed:
    id: str
    usage: int
    limit: int


@dataclass(frozen=True)
class AnalysisModel:
    id: str
    display_name: str
    addon: str
    endpoint: str
    mode: str = "analyze"  # analyze | explicit
    requires: str | None = None  # prompt | tags | questions


@dataclass(frozen=True)
class DeliveryModel:
    id: str
    display_name: str
    addon: str
    kind: str


# Endpoints are the Analyze API model names. object_detection is the usage key for Cloudinary AI Content Analysis.
ANALYSIS_MODELS: tuple[AnalysisModel, ...] = (
    AnalysisModel("cloudinary/google-tagging", "Google Auto Tagging", "google_tagging", "google_tagging"),
    AnalysisModel("cloudinary/google-logo-detection", "Google Logo Detection", "google_tagging", "google_logo_detections"),
    AnalysisModel("cloudinary/imagga-tagging", "Imagga Auto Tagging", "imagga_tagging", "imagga_tagging", mode="explicit"),
    AnalysisModel("cloudinary/ai-vision", "AI Vision", "ai_vision", "ai_vision_general", requires="prompt"),
    AnalysisModel("cloudinary/ai-vision-tagging", "AI Vision Tagging", "ai_vision", "ai_vision_tagging", requires="tags"),
    AnalysisModel("cloudinary/ai-vision-moderation", "AI Vision Moderation", "ai_vision", "ai_vision_moderation", requires="questions"),
    AnalysisModel("cloudinary/captioning", "Image Captioning", "object_detection", "captioning"),
    AnalysisModel("cloudinary/object-detection", "Object Detection", "object_detection", "coco"),
    AnalysisModel("cloudinary/fashion-detection", "Fashion Detection", "object_detection", "cld_fashion"),
    AnalysisModel("cloudinary/text-detection", "Text Detection", "object_detection", "cld_text"),
    AnalysisModel("cloudinary/human-anatomy", "Human Anatomy", "object_detection", "human_anatomy"),
    AnalysisModel("cloudinary/image-quality", "Image Quality", "object_detection", "image_quality"),
    AnalysisModel("cloudinary/lvis", "LVIS Detection", "object_detection", "lvis"),
    AnalysisModel("cloudinary/shop-classifier", "Shop Classifier", "object_detection", "shop_classifier"),
    AnalysisModel("cloudinary/unidet", "UniDet", "object_detection", "unidet"),
    AnalysisModel("cloudinary/watermark-detection", "Watermark Detection", "object_detection", "watermark_detection"),
)
DELIVERY_MODELS: tuple[DeliveryModel, ...] = (
    DeliveryModel("cloudinary/viesus-correct", "Viesus Correct", "viesus_correct", "image.enhance"),
    DeliveryModel("cloudinary/imagga-crop", "Imagga Crop", "imagga_crop", "image.crop"),
)
ANALYSIS_BY_ID = {model.id: model for model in ANALYSIS_MODELS}
DELIVERY_BY_ID = {model.id: model for model in DELIVERY_MODELS}


def subscribed(usage: dict) -> dict[str, Subscribed]:
    """Add-ons with a numeric limit. A limit means the account is subscribed."""
    found = {}
    for key, value in usage.items():
        if key in SKIP or not isinstance(value, dict):
            continue
        limit = value.get("limit")
        if isinstance(limit, bool) or not isinstance(limit, (int, float)):
            continue
        used = value.get("usage")
        found[key] = Subscribed(key, int(used) if isinstance(used, (int, float)) and not isinstance(used, bool) else 0, int(limit))
    return found


class AccountAddons:
    """Last usage report. Empty until health loads it; a failed refresh keeps the previous report."""

    def __init__(self):
        self.enabled: dict[str, Subscribed] = {}
        self.report: dict | None = None
        self.error: str | None = None

    async def refresh(self, api: CloudinaryAPI) -> None:
        try:
            report = await api.usage()
        except ProblemError as error:
            self.error = error.detail
            return
        self.report = report
        self.enabled = subscribed(report)
        self.error = None

    def details(self) -> list[dict]:
        rows = [
            {"id": item.id, "mode": "account", "available": True, "reason": f"{item.usage} of {item.limit} used"}
            for item in sorted(self.enabled.values(), key=lambda item: item.id)
        ]
        if self.error and not rows:
            rows.append({"id": "account", "mode": "account", "available": False, "reason": self.error})
        return rows
