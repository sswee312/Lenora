---
name: lenora-ai-tools
description: Use Lenora's backend-powered AI tools (transform_media and generation tools) correctly, including capability checks, cost and polling.
---

# Lenora AI tools

Lenora's AI tools run through the Lenora backend the user connected in Settings → Backend. Editing tools (timeline, clips, color, captions) never need a backend.

## Before calling an AI tool
- AI tools appear in the tool list only while the connected backend supports them. If a tool you expect is missing, tell the user to open Settings → Backend; do not try a different tool to work around it.
- Call `list_models` to see the models, accepted input types and size limits.

## transform_media
- `operation: "removeBackground"` cuts out the subject of an image asset and imports a transparent PNG next to it.
- Inputs: PNG, JPEG, WebP, HEIC or TIFF within the model's size limit (10 MB on Cloudinary's free plan). Convert or downscale first if needed.
- It costs provider credits; the receipt's `estimate` is informational. Confirm with the user before running it on many assets.
- It returns `{mediaRef, status: "generating", estimate}` at once. Poll `get_media` until `mediaRef` is ready, check it with `inspect_media`, then place it with `add_clips`.
- The finished import is one undo step; `undo` removes it.

## Failures
- Errors carry a stable reason. A refusal (wrong type, too large, no backend) creates nothing — fix the input and retry.
- A failed job leaves a failed placeholder in the media panel with the provider's message.
