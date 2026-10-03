---
name: video-prompting
description: Base craft for AI video prompts inside Lenora across Seedance, Kling, MiniMax H3/Hailuo, Grok, and Veo. Assigns @Image/@Video/@Audio authority, locks identity and screen geography, then stages timed shots. Use for generate_video multimodal prompts, precise video edits, or cinematic AI video beyond simple UGC talking-head beats. For UGC selfie-then-animate prefer ugc-photo-prompts then ugc-video-prompts. Specialized siblings: character-pipeline, cinematic-motion, motion-graphics, podcast-ad.
---

# Video Prompting

Write a **production brief**, not a vibe paragraph. Models fail when every asset competes for identity, motion, camera, and style.

## Core rule

**Assign authority before action.** Every reference gets one job and an explicit boundary on what it must *not* control. Then: lock continuity → place screen geography → time the shot → light/sound → short negatives.

## When to use which skill

| Need | Skill |
|------|--------|
| Multimodal / cinematic / edit prompts | **this skill** |
| Face consistency across stills → video | `character-pipeline` |
| Documentary handheld / density maps | `cinematic-motion` |
| Overheard two-person podcast ad | `podcast-ad` |
| UGC talking-head / product selfie | `ugc-photo-prompts` → `ugc-video-prompts` |
| Assemble / caption finished clips | `ugc-editing` |
| Kinetic titles / flat glass UI / H3 product journey promos | `motion-graphics` |

## Session gates

1. `list_models` for `image` / `video` / `audio` — ids and caps drift. If it returns no models, the Lenora backend isn't connected or configured: tell the user to check Settings → Backend.
2. Propose prompt + model + duration + aspect (+ refs). **Wait for confirmation** — paid, not undoable.
3. Fire `generate_*`; do not busy-poll. Ready when `get_media({ ids })` has **no** `generationStatus`. On `failed`, report and ask before retry.
4. Organize with `folder` (e.g. `Hero/Sheets`, `Hero/Takes`).

## Reference wiring

| Tool argument | Prompt tags | Typical job |
|---------------|-------------|-------------|
| `startFrameMediaRef` / `endFrameMediaRef` | implied first/last frame | Image-to-video anchors |
| `referenceImageMediaRefs` | `@Image1`… (some Kling: `@Element1`) | Identity, wardrobe, product, scene |
| `referenceVideoMediaRefs` | `@Video1`… | Motion timing, camera rhythm |
| `referenceAudioMediaRefs` | `@Audio1`… | Voice, lip-sync audio, music timing |
| `generate_image` → `referenceMediaRefs` | model-specific | Still identity lock |

Declare authority when multiple refs are passed:

```
@Image1 defines identity and wardrobe only. Ignore its background.
@Video1 defines motion timing and camera only. Do not inherit its people or location.
@Audio1 defines <Character>'s voice timbre and delivery only.
```

Never: “use all references to make the same scene.”

## Prompt architecture

Stable truth first; time second; polish last.

```
[REFERENCE USE]     — what each @ImageN / @VideoN / @AudioN controls + ignores
[IDENTITY LOCKS]    — count, face, hair, wardrobe, props, voice ownership
[SCENE]             — place, time of day, dramatic goal, emotional turn
[DIALOGUE]          — exact quoted lines, speakers, delivery + voice pins
[SCREEN GEOGRAPHY]  — who/what is left/right/front before anyone moves
[SHOT LIST]         — time ranges: framing, action, dialogue, end state
[ACTING]            — posture, gaze, gesture, emotional progression
[LIGHT / IMAGE]     — light, palette, texture, lens, DoF
[CAMERA]            — sizes, move rules, axis, transitions
[SOUND]             — ambience, dialogue clarity, music rule
[NEGATIVES]         — only the failure modes that matter
```

**Length vs start frame:** with `startFrameMediaRef` alone and simple motion, keep the prompt short (camera + action + speech/SFX) — do not re-describe the still. With multi-ref / timed performance / edits, use the full architecture.

## Continuity + shot timing

Lock subject count, face/hair/wardrobe, prop ownership, screen direction, voice ownership. Place people before they move.

Treat duration as an editorial budget (`list_models` → `durations`). One primary beat per range: establish → escalate → resolve. Prefer one beat per `generate_video` call; assemble on the timeline. If dialogue rushes, shorten lines — do not cram two turns into one short clip.

## Model routing

Confirm ids/caps via `list_models` before firing. Default stack for these skills:

| Stage | Prefer | How |
|-------|--------|-----|
| **Iterate** | `seedance-2-mini`, MiniMax H3 (`hailuo-03`), or Flux 3 **draft** | Mini / H3 as normal generates. Flux 3: `draft: true` (720p preview; `supportsDraft` must be true). |
| **Final** | `seedance-2` or MiniMax H3 (`hailuo-03`) | Full-quality generate (ask before Seedance 1080p/4K). A draft is a preview only: re-generate the approved prompt as a final; there is no enhance step. |

**Flux 3 draft → final**

1. Iterate: `generate_video({ model: "flux-3", draft: true, … })` (only when `list_models` reports `supportsDraft`).
2. When `get_media` shows the draft ready and the user approves it, generate the final with the same prompt on `seedance-2` or `hailuo-03`, without `draft`.
3. Do **not** use `upscale_media` to turn a draft into a final.

| Other goals | Prefer | Notes |
|-------------|--------|-------|
| Synced spoken dialogue | Kling V3/O3, or Grok | Quoted line; pin voice every beat |
| Stills / sheets | `grok-imagine`, `gpt-image-2`, or `seedream-v5-pro` | Best of multi-room podcast bakeoff; see `character-pipeline` / `podcast-ad` |
| Avoid as default | Veo | Content-checker failures common |

## Precise editing

1. **Master** — source / `@Video1` owns timeline, subjects, camera, audio.
2. **Changes** — exact subject/object/region/line/time only.
3. **Preserve** — identity, occlusion, eyelines, camera, dialogue, ambience, duration.

## Text and titles

Most video models **cannot** render reliable readable text — use `generate_image` plates or `add_texts`. **Exception:** MiniMax H3 / H3 Max kinetic flat type with an exact string allowlist — follow `motion-graphics` (do not improvise long paragraphs of type).

## Recipes (near-look patterns)

### Beat-synced stylized title

Silhouette motion via `generate_video`; title plates via `generate_image`; cut on music with `detect_beats`.

```
@Image1 = silhouette identity only. Ignore photoreal BG.
Flat black silhouettes on solid poster colors (2–3 saturated fields). No naturalistic shading.
Comic-panel crops; freeze-holds dead-still for one full beat; hard cuts only; heavy grain/gate weave.
Alternate kinetic bursts with freeze holds. End frozen mid-pose on a solid field.
```

Then: generate geometric title stills → `detect_beats` → place clips/stills on downbeats.

### Texture morph

```
@Image1 = source surface texture only. @Image2 = destination landscape only.
Continuous macro push; transform when contours align. No hard cut, tear, or seam.
```

### Motion transfer

```
@Image1 = identity/wardrobe only. @Video1 = motion/timing/camera only — not its cast or location.
Ordered action with stable L/R geography. Physically believable contacts and shadows.
```

### Voice lock

Reuse pitch + tone + accent + pace **verbatim** every beat. Better on Seedance: pass beat-1 audio as `referenceAudioMediaRefs` (`@Audio1` = voice only) on later beats.

### Surgical edit

```
Source is sole master. Replace/remove/add only listed items.
Preserve identity, timing, occlusion, eyeline, camera, layout, dialogue, ambience. Nothing else.
```

## Troubleshooting

| Failure | Fix |
|---------|-----|
| Identity drifts | One primary identity ref; lock face/hair/wardrobe (`character-pipeline`) |
| Wrong voice owner | `@Audio1` → named character + exact line |
| Motion ref changes cast | “Motion/timing only”; reject its actors/location |
| Action chaos | Chronological L/C/R state sequence |
| Edit rebuilds frame | Master + changes + preserve |
| Dialogue rushed | Shorter line; one turn per clip |
| Voice changes across beats | Same four voice pins every call, or `@Audio1` lock |
| Stiff puppet | Mid-gesture still; one micro-action (`cinematic-motion`) |
| Room pops between people | Identical set wording on both stills (`podcast-ad`) |
| Bad burned-in titles | `generate_image` / `add_texts`, not video |
| Refs ignored | `@Image1` = first `referenceImageMediaRefs` entry |
| `list_models` returns no models | Backend not connected — Settings → Backend |

Debug order: authority → locks → timing → preserve → then adjectives.

## Bakeoff notes (T2V, cheap 480p/720p, Aug 2026)

Project: `Skill Bakeoff CM+VP` · timeline **Video Prompting Bakeoff**. No refs — text-only stress test of architecture vs vibe.

| Finding | Implication |
|---------|-------------|
| Screen geography (woman LEFT / man RIGHT) held on Seedance Mini | Keep explicit L/R before action |
| Exact quoted dialogue landed on Grok + Gemini Omni Flash | Pin line + voice every call; works without audio refs |
| “Alone” failed when SCENE said busy café (extras appeared) | Negatives must ban extras: “no other people visible” |
| Vibe-only romantic prompt invented a kiss + uncontrolled action | Architecture buys **control**, not prettier stills |
| Chaos anti-prompt (swap sides / look at cam / third person) did all three | Geography + subject-count locks are load-bearing |
| Silhouette + solid field + freeze/kinetic (Seedance Mini, Happy Horse) | Stylized recipe works without refs |
| Texture morph macro→canyon (Seedance Mini) | Continuous transform recipe is strong |
| Product pour timed late on Flux draft | Shot-list timing is approximate; put critical action mid-clip |
| Landscape “one tracking shot” on LTX still cut angles | Prefer one beat per call; assemble multi-angle on timeline |
| Kling V3 jobs often sit in `generating` much longer than Seedance/Grok/Flux draft | Prefer Mini/Grok/Flux draft for cheap iteration |

## Checklist before generate_video

- [ ] User confirmed cost; `list_models` current
- [ ] Every ref has authority + ignore; tags match tool arg order
- [ ] Subject count + geography locked
- [ ] Duration fits one beat; dialogue fits budget
- [ ] No readable text expected from the video model
- [ ] If editing: master + changes + preserve
