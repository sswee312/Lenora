from lenora_backend.errors import ProblemError
from lenora_adapter_cloudinary.store import Store

IMAGE_GENERATION = "imageGeneration"
IMAGE_TO_VIDEO = "imageToVideo"
NAMES = {IMAGE_GENERATION: "Image Generation", IMAGE_TO_VIDEO: "Image to Video"}


class Addons:
    """Add-on availability: `on`/`off` are fixed; `auto` is available until a real job is refused."""

    def __init__(self, modes: dict[str, str], store: Store):
        self.modes = modes
        self.store = store

    def available(self, addon: str) -> bool:
        mode = self.modes[addon]
        return mode == "on" or (mode == "auto" and addon not in self.store.unavailable_addons())

    def learn_refusal(self, addon: str, code: str, now: float) -> ProblemError:
        if self.modes[addon] == "auto":
            self.store.mark_unavailable(addon, code, now)
        return self.refusal(addon)

    def refusal(self, addon: str) -> ProblemError:
        name = NAMES[addon]
        return ProblemError("provider_unavailable", (
            f"This Cloudinary account doesn't include the {name} add-on. "
            "Enable it in the Cloudinary console, then use Test Connection."
        ), retryable=False)

    def recheck(self) -> None:
        self.store.clear_addons()

    def details(self) -> list[dict]:
        learned = self.store.unavailable_addons()
        rows = []
        for addon, mode in self.modes.items():
            reason = None
            if mode == "off":
                reason = "turned off in settings"
            elif mode == "auto" and addon in learned:
                reason = f"refused by Cloudinary ({learned[addon]}); use Test Connection after enabling it"
            rows.append({"id": addon, "mode": mode, "available": self.available(addon), "reason": reason})
        return rows
