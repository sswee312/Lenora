---
name: motion-graphics
description: Kinetic titles, stings, Apple-flat glass UI motion, and scripted product promos in Lenora via MiniMax H3 Max (hailuo-03-max) — exact string locks, journey tempo (not metronome chops), sparse accents, switching product-native UI, and image/video refs including logos. Use for motion graphics, kinetic type, cold opens, bumpers, glassy UI explainers, Introducing product films, or agent demos. Prefer over video-prompting for readable on-screen type. Not for photoreal handheld camera feel (use cinematic-motion). Sibling: video-prompting for cinematic multimodal; caption-templates for timeline captions.
---

# Motion graphics

Flat **kinetic type + UI motion graphics** in Lenora. **Always use MiniMax H3 Max (`hailuo-03-max`)** — it holds exact short strings when locked and **accepts image/video refs** (logos, UI plates, short clips). Most other video models are weaker at readable type; use `generate_image` / `add_texts` for those.

Confirm live caps with `list_models({ type: "video" })` before every generate (resolutions, durations, ref limits drift).

## Two jobs (pick one)

| Job | Length | Optimize for |
|-----|--------|----------------|
| **A. Style sting / title** | 5–15s | One motion grammar |
| **B. Product journey promo** | ~10s | User script + musical arc + switching product UI |

Do not mix a style sting with a product film in one generate.

## Model

| Need | Model | Notes |
|------|-------|--------|
| **All MG in this skill** | `hailuo-03-max` | Default. Prefer highest listed res (often **768p**). Use `@Image1` / `referenceImageMediaRefs` for logos and UI plates; `@Video1` / video refs when caps allow. Start/end frames OK when useful. |
| True trim V2V edit (not MG) | Aleph / Happy Horse Edit / … | `sourceVideoMediaRef` + `sourceClipId` — outside this skill’s lane. |

Do **not** route logo or ref work to `hailuo-03` unless the user explicitly asks or Max is unavailable in `list_models`.

## Session gates

1. `get_timeline` — if `canGenerate` is false, ask sign-in / subscribe.
2. `list_models({ type: "video" })` — confirm `hailuo-03-max` + ref caps.
3. Propose prompt + duration + aspect + resolution (+ refs/frames). **Wait for confirmation.**
4. `generate_video` with `model: "hailuo-03-max"`. Do not busy-poll.
5. Assemble with `create_timeline` + `add_clips`. Retry failures once.

## Hard rules

1. **Exact string allowlist** — every on-screen phrase listed; no invented glyphs/paragraphs/digits.
2. **Accent is rare** — one hex as punctuation, not a full-video wash.
3. **Flat / orthographic** — Apple frosted UI or flat type; no heavy 3D extrusion unless asked.
4. **Glass clean** — frosted fills, hairlines, soft speculars; almost no drop shadows.
5. **Always moving** — residual drift on the last frame; no dead freeze.
6. **One job per generate** — cut stings/ambient/end cards on the timeline.

---

## Job A — style stings

```
TEMPLATE: <Style name>. Flat graphic. No people / no photos / no 3D gloss.
Accent: <hex> (rare).
Only strings: "<A>" "<B>" … Exact.
Type look: <…> — flat vector.
Pacing: <SLOW|FAST|…>.
Animation grammar: <how type moves>.
Shot clock: 0–Xs: …
```

| Id | Grammar (keep distinct) | Energy | Duration |
|----|-------------------------|--------|----------|
| S01 Swiss grid | Thin rules → words wipe into cells | Slow editorial | 15s 16:9 |
| S02 Strobe | Full-bleed word per hard cut + flash | Ultra fast | 12s 16:9 |
| S03 Liquid morph | Continuous letter morphs on plane | Medium | 15s 16:9 |
| S04 Data HUD | Slot punches + one progress string | Techno | 15s 16:9 |
| S05 Letterpress | Top-down stamp squash settles | Slow heavy | 15s 16:9 |
| S06 Z-tunnel | Perspective billboards rush to camera | Accelerating | 15s 16:9 |
| S07 Luxury ribbon | Soft ribbon wipes, huge margins | Very slow | 15s 16:9 |
| S08 Comic | Panel frames + speed lines | Beat comic | 15s 16:9 |
| S09 Split duel | L/R halves antiphonal then merge | Alternating | 15s 16:9 |
| S10 Orbit | Continuous orbit of word-slabs (only if depth wanted) | One-shot | 15s 16:9 |
| S11 Stickers | Pills stack upward with spring | Social | 8s 9:16 |
| S12 Typewriter | Caret types whole words, cascade | Terminal | 15s 16:9 |

**Tasteful (not slam):** soft fade, whisper tracking, paper curtain, breathing scale, soft-focus resolve, lowercase drift, stacked quiet lines, silk rise — SLOW + dissolves from the same skeleton.

Swap only allowlist + accent when branding; **do not** treat palette swaps of one grammar as a style library.

### Short use-case clocks (5s)

| Use | Pattern | Example strings |
|-----|---------|-----------------|
| Cold open | Slam → whip → freeze | COLD / OPEN / GO |
| Launch bumper | Assemble → stamp → hold | LAUNCH / DAY / NOW |
| Section title | Soft swiss wipes | STEP / 02 / WHY |
| Chapter dynamic | Sticker springs | CHAPTER / NYC / DAY |
| Chapter simple | One-word fade | LATER |
| Tip card | Card slide + badge | TIP / LOCK / VOICE |
| Trailer end | Slow push + thud | COMING / SOON |
| Ad sting | Ident bars + slam | AD / BREAK |
| Soft bed | Ribbon drift under VO | ATELIER |
| End lockup | Assemble + rule | YOUR / BRAND |

---

## Job B — product journey promos

Scripted product/feature spots.

### Rhythm (ceiling ≠ grid)

“~2s max per readable hold” is a **ceiling**. Build:

1. **Inhale** — sparse hook  
2. **Door** — one decisive reveal  
3. **Climb** — accelerating staggers  
4. **Hit** — peak + payoff line  
5. **Exhale** — brand lockup, still drifting  

### Switch UI every act

| Act | Pattern | Product-native examples |
|-----|---------|-------------------------|
| Hook | Near-empty + type (+ logo) | Wordmark field |
| Door | Core canvas | Timeline, doc, board, map, inbox |
| Climb | Tools / agent / edits | Clips rearrange, cards dock, nodes connect |
| Hit | Payoff plate | User’s payoff line |
| Exhale | Sparse lockup | Product name + tiny live footer |

### Intake → prompt

Need: product type, **exact script phrases**, logo still(s), accent hex, aspect (default 16:9 / 10s).

```
Flat Apple-glass kinetic product film. Orthographic 2D.
Frosted UI, hairlines, almost no drop shadows. Accent <HEX> RARE only.

@Image1 = <LOGO> mark — exact geometry when it appears; ignore @Image1 background.

Only strings (exact, no others):
"<LINE_1>"
"<LINE_2>"
"<LINE_3>"
"<LINE_4>"
"<LINE_5>"
"<PRODUCT_NAME>"

TEMPO ARC (unequal):
0–~1.6s INHALE — <LINE_1>; soft restless drift; logo if needed.
~1.6–3.2s DOOR — frosted swipe reveals <CORE_UI>; <LINE_2>.
~3.2–5.0s CLIMB — <INTERACTION_UI>; <LINE_3>; canvas alive.
~5.0–7.0s ACCELERATE — denser motion; <LINE_4>; speed peaks.
~7.0–8.6s HIT — payoff <LINE_5>; one sharp accent flash.
~8.6–10s EXHALE — <PRODUCT_NAME>; tiny live footer; decelerate, never freeze.

Switch UI each act. Always moving. No people. No photoreal devices. No fake digits.
```

**Logo / plate lock:** `hailuo-03-max` + `referenceImageMediaRefs` + `@Image1` (and more `@ImageN` if needed). Optional `startFrameMediaRef` when the open must match a plate exactly — confirm via `list_models` whether frames and refs can combine.

### Iteration fixes

| Feedback | Fix |
|----------|-----|
| Flat rhythm | Unequal arc; accelerate climb |
| Too much accent | 1–3 punctuation moments only |
| Repetitive UI | New motif every act |
| Too 3D / plasticky | Orthographic frosted 2D |
| Fake shadows | Hairlines + speculars |
| Melted logo | Clean mark still + `@Image1` on Max |
| Wrong copy | Re-lock allowlist from script |

---

## Generate + assemble

```
generate_video({
  model: "hailuo-03-max",
  prompt,
  duration,
  aspectRatio,
  resolution,  // prefer top Max tier from list_models
  folder: "Motion-Graphics/…",
  name,
  referenceImageMediaRefs?,  // logos / UI plates
  referenceVideoMediaRefs?,  // short clips if caps allow
  startFrameMediaRef?
})
```

Then `create_timeline` + sequential `add_clips`. Keep variants separate.

## Anti-patterns

Even 2s chops · same card loop · accent wash · 3D glass slabs · muddy shadows · palette-only “styles” · still→I2V for a video beat · invented UI copy · text-only “use the logo” · routing MG to non-Max models by default

## Not this skill

- Timeline captions → `caption-templates`  
- Photoreal handheld / captured feel → `cinematic-motion`  
- Multimodal cinematic craft → `video-prompting`  
- UGC talking-head → `ugc-video-prompts`  
- Full assemble/captions edit → `ugc-editing` after plates exist
