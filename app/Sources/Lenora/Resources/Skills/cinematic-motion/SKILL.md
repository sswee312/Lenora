---
name: cinematic-motion
description: Writes Lenora generate_video motion prompts so clips feel captured — one readable camera move plus imperfect handheld texture, not a timid micro-settle. Use for photoreal editorial motion, unstable handheld, beauty/product, or dialogue-to-camera. Bakeoff note: naive "slow cinematic push-in" can beat an over-soft effects score; always lead with visible motion.
---

# Cinematic Motion

Pretty stills go fake when motion is generic **or invisible**. The job is a **readable camera + subject change** that still feels handheld — not a dense effects essay the model ignores.

Prereqs: approved still from `character-pipeline` (or an existing plate). Authority rules from `video-prompting`.

## Bakeoff lesson (Flux draft, loft still)

A/B on the same start frame:

| Prompt | Result |
|--------|--------|
| Long LOW→HIGH→LOW micro-score (grip tilt, 4–5cm drift, settle) | Often looks near-static vs control |
| Naive “slow cinematic push-in…” | More visible motion; sometimes preferred |

**Implication:** micro-only recipes fail if the model under-delivers them. Always include **one obvious, named camera move** (push-in, lateral reframe, tilt recover) that a viewer can see in 6s. Texture (handheld / corrections) wraps that move — it does not replace it.

## Design principles

1. **Lead with visible motion** — one clear camera verb in the first lines of the prompt
2. **Camera has a body** — that move is imperfect (breathing, micro-corrections), not a gimbal slide
3. **One signature beat** — subject micro-action *or* a motivated push/tilt peak (1–2s)
4. **Density** — still open/close briefly, but don’t spend half the clip on LOW settle
5. **End near the still** — land close to start frame / fidelity image without freezing early

## Call pattern

```
list_models({ type: "video" })
# Iterate: flux-3 draft:true | seedance-2-mini | hailuo-03
# Final: seedance-2 | hailuo-03 | Flux enhanceDraftMediaRef (not upscale_media)

generate_video({
  model: "flux-3",
  draft: true,
  prompt: "<motion-first brief>",
  duration: 6,              // or model-allowed
  aspectRatio: "9:16",
  resolution: "720p",
  startFrameMediaRef: "<scene still>",
  folder: "Character/Takes"
})
```

Seedance: `framesAndReferencesExclusive` — prefer `startFrameMediaRef` alone for plate lock; keep prompt on **change**.

If using refs (when allowed): `@Image1` env/scene · `@Image2` sheet · `@Image3` fidelity face — declare jobs. Don’t dump long inventories Flux will ignore.

## Prompt structure (short > encyclopedic)

```
[CHANGE]                 // first — what moves
One clear camera move + one subject beat

[TEXTURE]
Handheld / corrections / how the move is imperfect

[LAND]
Settle near start frame in the last ~1s

[NEGATIVES]
No orbit, no drone, no look-at-camera (if off-axis), no face/wardrobe drift, no gimbal perfection
```

Optional short timed blocks **after** the CHANGE line — not instead of it. Cap inventory at ~4 named effects.

## Default 6s recipe (single-subject)

**Visible spine:** slow unstable push-in (or lateral reframe) across most of the clip.

| Time | Job |
|------|-----|
| 0–0.5s | Already mid-roll; handheld correcting into frame |
| 0.5–4.5s | **Push-in / reframe continues** — imperfect, breathing; one subject micro-gesture mid-way; camera slightly late |
| 4.5–6s | Ease off the move; hold near start-frame composition |

Signature options (pick one): weight shift, hand to pocket/hair, chin toward light, gaze adjust — **plus** the camera move, not instead of it.

## Writing subject + camera

- Gaze rule: never look at camera **or** always on lens — pick one and stick
- Contacts: pocket, chair back, window sill — tangible
- Camera: “slow unstable push-in ~8–12% tighter by end”, “2–4° tilt recovers”, “brief shake then continues push” — **magnitudes a viewer can see**
- Avoid: orbit, drone, perfect dolly, vibe-only “cinematic camera movement” with no verb
- Also avoid: only “4–5cm drift” / “micro chin ease” as the whole brief — too small for many models

## Anti-patterns

- Effects timeline with no **visible** camera verb (loses to naive push-in)
- Five big moves in 6 seconds
- Half the clip reserved for LOW settle / breath hold
- Subject and camera both idle
- Ending on a different face than the start frame
- `upscale_media` instead of `enhanceDraftMediaRef` for Flux drafts

## Mini template

```
[CHANGE]
Slow unstable handheld push-in from the start frame (~10% tighter by 0:05).
Mid-clip: she shifts weight / hand settles in pocket; camera chases slightly late.

[TEXTURE]
Breathing handheld, small corrections, 2–3° grip tilt once at the peak of the push.
No gimbal smoothness.

[LAND]
0:05–0:06 ease the push; hold near the start still. Off-axis gaze held (not into lens).

[NEGATIVES]
No look-at-camera, no wardrobe/face drift, no orbit/drone, no text/watermark.
```

## Validation

When testing this skill, always A/B against a **naive control** on the same plate (or same T2V brief) / model / duration. If control has clearer motion, the skill prompt was too soft — rewrite CHANGE first, then re-roll.

## Bakeoff notes (T2V, cheap 480p/720p, Aug 2026)

Project: `Skill Bakeoff CM+VP` · timelines **Cinematic Motion Bakeoff**.

| Finding | Implication |
|---------|-------------|
| Skill push ≈ naive “slow cinematic push-in” on Seedance Mini (beauty loft) | Structure alone doesn’t beat a clear verb; keep CHANGE short |
| Soft micro-only (hair tuck, no push) reads nearly static | Never ship micro-only as the whole brief |
| Tilt-up hands→face, chase-behind, neon alley push, product push all read clearly | Prefer **framing-changing** verbs over texture adjectives |
| Models often ignore “unstable / handheld / grip tilt” and still deliver smooth push | Texture is optional garnish; the verb is the product |
| Flux dialogue: long exact line mangled; shorter naive line cleaner | Short spoken lines; re-pin voice every call |
| 9:16 / 1:1 skill recipes work | Aspect is independent of motion craft |
