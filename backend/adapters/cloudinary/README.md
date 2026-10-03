# lenora-adapter-cloudinary

Cloudinary adapter for lenora-backend. Every result is a signed delivery URL (`s--<8>--`), so the account can keep strict transformations on.

| Model | Kind | Notes |
|---|---|---|
| `cloudinary/background-removal` | `image.removeBackground` | 75 transformations |
| `cloudinary/generative-edit` | `image.edit` | ops `fill`, `replace`, `remove`, `recolor`, `backgroundReplace`, `restore` |
| `cloudinary/upscale` | `image.upscale` | 4×; inputs up to 2048 × 2048 |
| `cloudinary/reframe` | `video.reframe` | `ar_<W:H>,c_fill,g_auto`; on the fly up to `LENORA_CLOUDINARY_ON_THE_FLY_VIDEO_MAX_BYTES`, larger videos (up to 100 MB) through `eager_async` |
| `cloudinary/image-generation` | `image.generate` | needs the Image Generation add-on |
| `cloudinary/image-to-video` | `video.generate` | needs the Image to Video add-on; prompt-only requests chain through image generation |
| `cloudinary/publish` | `video.publish` | Stream (HLS ≤1080p), download, poster, optional vertical cut (9:16, 1:1, 4:5) and 5–30 s teaser. Stream 8, vertical 14, teaser 2 per started second; poster 1. Free plan: up to 100 MB per export. |

## Add-ons

`LENORA_CLOUDINARY_IMAGE_GENERATION` and `LENORA_CLOUDINARY_IMAGE_TO_VIDEO` take `auto` (default), `on` or `off`. In `auto`, the first real request that Cloudinary refuses with 401 or 403 marks the add-on unavailable. Its models then leave `/v1/capabilities` and stay hidden across restarts. `GET /v1/health?recheck=addons` (Settings → Backend → Test Connection in the app) clears the learned state.

## Costs and budget

Estimates use Cloudinary's published transformation counts (1 credit = 1000 transformations). Add-on prices are not published, so `LENORA_CLOUDINARY_COST_IMAGE_GENERATION` and `LENORA_CLOUDINARY_COST_IMAGE_TO_VIDEO_PER_SECOND` default to cautious guesses; set them from your Cloudinary usage report. `LENORA_CLOUDINARY_DAILY_CREDIT_BUDGET` refuses jobs with `quota_exceeded` once the UTC day's estimates reach it. The budget lives in memory, per process.

## State

Chain jobs and learned add-on state live in `LENORA_DATA_DIR/cloudinary.sqlite3`. Run a single instance, and mount a volume when you deploy with Docker. If the process crashes while a chain hands off from image to video, the video step can be submitted, and billed, twice.

## Publish

`video.publish` uploads one export (a single request, up to `min(100 MB, the account video limit)`), then asks Cloudinary for every derived output in one `explicit` call with `eager_async`:

| Role | Transformation |
|---|---|
| `stream` | `sp_auto:maxres_1080p/m3u8` |
| `poster` | `so_auto/jpg` |
| `vertical` | `ar_<aspect>,c_fill,g_auto/mp4` |
| `teaser` | `e_preview:duration_<N>/mp4` |
| `download` | the original file |

Every URL is signed. Links are public but unlisted: the public ID holds a random UUID. Results arrive when every output is ready. An output still pending after 15 minutes is reported in `failedOutputs`, and the job fails only when the stream does. Publishing more outputs later requests only the missing ones and costs nothing for the rest.

`DELETE /v1/assets/{assetRef}?model=cloudinary/publish` runs `destroy` with `invalidate=true`. That removes the video and every derived output and clears the CDN cache. A second delete returns 404 `not_found`.

## Limits

- Replace, recolor and background replace are not offered in Cloudinary's AP data centre. There, those requests fail with `provider_error`.
- Text that goes into transformation URLs (`from`, `to`, `prompt`) is limited to letters, digits, spaces and `.'-`, up to 100 characters.
- Admin API lookups count toward the account's hourly Admin API limit (500 on Free).
