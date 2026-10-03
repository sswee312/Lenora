---
name: lenora-ai-tools
description: Use Lenora's backend-powered AI tools (transform_media and generation tools) correctly, including capability checks, cost and polling.
---

# Lenora AI tools

Lenora's AI tools run through the Lenora backend the user connected in Settings → Backend. Editing tools (timeline, clips, color, captions) never need a backend.

## Before calling an AI tool
- AI tools appear in the tool list only while the connected backend supports them. If a tool you expect is missing, tell the user to open Settings → Backend; do not try a different tool to work around it.
- Call `list_models` to see the models, accepted input types and size limits. An empty `models` array with `loaded: true` means the backend isn't connected or configured; `loaded: false` means the first sync hasn't finished, so retry shortly.

## transform_media

One call, one direct edit, one undo step. The result appears as a new asset next to the source.

| operation | needs | use for |
|---|---|---|
| removeBackground | image | cut-outs, compositing |
| generativeFill | image, aspectRatio | extend a still to a new frame shape |
| replace | image, from, to | swap one object for another |
| remove | image, prompt | erase an object |
| recolor | image, prompt, color (#RRGGBB) | change an object's colour |
| backgroundReplace | image, prompt? | new backdrop behind the subject |
| restore | image | clean up compressed or noisy stills |
| reframe | video, aspectRatio | 9:16 / 1:1 / 4:5 cut of a 16:9 shot, subject kept in frame |

Text fields allow letters, digits, spaces and . ' - only. Describe objects plainly ("the red car"). Upscaling is upscale_media.
- Inputs must fit the limits `list_models` with `type: "transform"` reports (types, bytes, pixels). Convert or downscale first if needed.
- It has a provider cost; the receipt's `estimate` is informational. Confirm with the user before running it on many assets.
- It returns `{mediaRef, status: "generating", operation, estimate}` at once. Poll `get_media` until `mediaRef` is ready, check it with `inspect_media`, then place it with `add_clips`.

## Video from a prompt

If list_models shows requiresFirstFrame=false, generate_video can run from the prompt alone; the backend makes the first frame. Pass startFrameMediaRef when the user has a shot or still that must open the clip — it is cheaper and more controllable.

## Budget refusals

quota_exceeded means the backend's daily credit budget is spent. Tell the user; do not retry until the next UTC day or until they raise LENORA_CLOUDINARY_DAILY_CREDIT_BUDGET.

## Failures
- Errors carry a stable reason. A refusal (wrong type, too large, no backend) creates nothing — fix the input and retry.
- A failed job leaves a failed placeholder in the media panel with the provider's message.
- `provider_unavailable` with `retryable: false` means the account lacks the feature. Tell the user to enable it with their provider and press Test Connection.
