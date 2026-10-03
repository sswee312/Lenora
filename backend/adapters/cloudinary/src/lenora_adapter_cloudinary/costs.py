from lenora_backend.kinds import Estimate

UNIT = "cloudinary_credits"
TRANSFORMATIONS_PER_CREDIT = 1000
REMOVE_BACKGROUND = 75
EDIT = {"fill": 50, "replace": 120, "remove": 50, "recolor": 50, "backgroundReplace": 230, "restore": 100}
UPSCALE_SMALL, UPSCALE_LARGE, UPSCALE_SMALL_MAX_PIXELS = 10, 100, 250_000
# HD progressive video (4/s) plus automatic-gravity cropping (10/s).
REFRAME_PER_SECOND = 14
# Publish, per started second of input: adaptive streaming up to 1080p 8/s, AI preview 2/s; a poster is one image.
PUBLISH_PER_SECOND = {"stream": 8, "vertical": REFRAME_PER_SECOND, "teaser": 2}
POSTER = 1


def credits(transformations: float) -> Estimate:
    return Estimate(amount=transformations / TRANSFORMATIONS_PER_CREDIT, unit=UNIT)


def upscale(pixels: int) -> Estimate:
    return credits(UPSCALE_SMALL if pixels < UPSCALE_SMALL_MAX_PIXELS else UPSCALE_LARGE)


def reframe(duration_seconds: float) -> Estimate:
    return credits(REFRAME_PER_SECOND * max(1, -(-duration_seconds // 1)))


def publish(duration_seconds: float, roles: list[str]) -> Estimate:
    seconds = max(1, -(-duration_seconds // 1))
    return credits(sum(POSTER if role == "poster" else PUBLISH_PER_SECOND[role] * seconds for role in roles))


def image_generation(per_image: float, count: int) -> Estimate:
    return Estimate(amount=per_image * count, unit=UNIT)


def image_to_video(per_second: float, duration: int, audio: bool) -> Estimate:
    return Estimate(amount=per_second * duration * (2 if audio else 1), unit=UNIT)

