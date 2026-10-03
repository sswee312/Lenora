---
name: character-pipeline
description: Builds consistent character stills in Lenora — hero identity plate to seamless multi-angle sheet (bust and/or full-body) to environment plate to light-matched scene placement. Use when the same face must survive across stills, casting someone into a new environment, or photoreal identity lock before any later motion. Not for video prompting itself (hand off to video-prompting / cinematic-motion) and not for quick UGC talking-head anchors (use ugc-photo-prompts).
---

# Character Pipeline

This skill is **stills-only**. It builds reusable identity assets so the same person holds across plates and composites. If the user wants motion after that, hand off the approved scene still + sheets to `video-prompting` / `cinematic-motion` — do not own `generate_video` here.

## Pipeline (hard order)

```
1. Hero still          generate_image (or import_media / user photo)
2. Multi-angle sheet   generate_image with referenceMediaRefs = [hero]
                       bust sheet default; optional full-body turnaround
3. Environment plate   generate_image — empty set, locked camera/light
4. Scene placement     generate_image: env plate + sheet (+ optional wardrobe)
5. Fidelity close-up   optional generate_image or capture_frame from the scene still
```

Do **not** skip to scene placement without an approved sheet. Reroll stills until lighting and identity pass.

## Session gates

- `get_timeline` → `canGenerate`
- `list_models({ type: "image" })`
- Propose each paid generation; wait for confirmation
- Folders e.g. `Character/Hero`, `Character/Sheets`, `Character/Scenes`

## Model picks

Confirm via `list_models`:

| Step | Prefer |
|------|--------|
| Hero / sheet / env / scene | `grok-imagine`, `gpt-image-2`, or `seedream-v5-pro` (photoreal trio) |

Prefer `gpt-image-2` / `seedream-v5-pro` for any step that needs `referenceMediaRefs` if the current Grok build rejects refs. Trust each model's aspect/resolution enums from `list_models`.

## Step 1 — Hero still

Clear identity plate. Prefer candid editorial over beauty-retouch.

Include: age/skin/hair/eyes/expression; simple stable wardrobe; repeatable light; **skin texture preserved** (pores — no smoothing).

Avoid: unrepeatable glam grade; extreme pose that fights the sheet; busy BG that leaks into identity.

If the user supplies a photo, `import_media` and skip generation.

## Step 2 — Character sheet

`generate_image` with `referenceMediaRefs: [heroMediaRef]`.

### Head / bust sheet (default — identity lock)

- 4 views in one continuous image, left → right: front, left profile, right profile, back of head
- **No white gutters, borders, frames, or panel dividers** — seamless shared grey BG
- Neutral light grey BG; even studio light; no color cast
- Same crop, height, distance every view (chest-up / bust)
- Identical simple wardrobe; neutral expression unless asked otherwise
- Exact facial structure from hero
- **Detail emphasis:** razor-sharp focus, pores/microtexture, hair strands, fabric weave — no soft blur / beauty mush
- Clinical identity sheet — not fashion/editorial
- No vignette, no grade, no text watermark

For GPT Image 2: `quality: "high"` and prefer **`3840x2160`** (or at least `2560x1440`) when detail matters.

### Full-body turnaround (optional — wardrobe / silhouette)

When scene placement needs legs, stance, or clothing behavior:

- 4 full-body views in one continuous image — same no-gutter rules
- Shared grey floor+BG; identical wardrobe; consistent height/stance
- Head still matches hero; proportions consistent across views
- Same detail emphasis; `quality: "high"` + high res when available

Keep both when useful: **bust sheet** for face lock; **full-body** for whole-figure staging.

## Step 3 — Environment plate

Empty set only — **no people**. Lock camera, furniture, and lighting before the insert.

State practicals explicitly (window cool vs lamp warm, etc.) so scene placement has sources to match.

## Step 4 — Scene placement still

Composite the character into the locked environment plate.

```
Preserve the entire scene exactly: <env elements>.
Do not alter camera angle, framing, perspective, or environment.

Insert the subject from the character reference sheet — <short identity anchors>.
Pose: <body contacts, gaze, expression>.
Wardrobe: <from clothing ref if any — fabric behavior in THIS pose>.
Anatomy fully correct — natural joints, no elongation, believable foreshortening.
Match the scene's existing light direction, color temperature, intensity, and softness
exactly — subject lit only by sources visible in the plate (no extra beauty key).
Warm/cool splits, falloff, and contact shadows must match furniture in the plate.
Skin texture preserved — no retouching.
```

`referenceMediaRefs` order: `[environmentPlate, characterSheet, …]` — state each ref's job in the prompt.

**Environment plate** wins on camera, set, **and lighting**. **Sheet** wins on face. If the insert looks beauty-lit or flatter than the plate, reroll with explicit dual-source / falloff language.

## Identity lock block

Keep a short stable paragraph and paste into every later still prompt (update to the actual character):

```
Olive-warm skin, dark brown eyes, strong brow, full lips, high cheekbones,
defined jawline, long dark brunette hair with natural wave.
Natural skin texture — visible pores, no smoothing.
```

Consistency > poetry.

## Wardrobe changes

1. Neutral garment on the identity sheet when possible
2. Separate clothing still via `generate_image` / import
3. Scene placement binds fabric behavior to pose

## Anti-patterns

- Jumping to video from this skill (hand off instead)
- Sheet panels with gutters or different light/crop → four different people
- Soft / low-res sheets when face lock matters
- Scene placement that “improves” the plate's camera or beauty-relights the subject
- Rewording identity every call → slow face melt

## Handoff (optional)

When stills are approved and the user wants motion: pass scene still + sheets to `video-prompting` / `cinematic-motion`. Suggested ref ranking for those skills: env/scene → sheet → face close-up — declared in their prompts, not here.
