---
name: podcast-ad
description: Builds converting podcast-style ads in Lenora as an overheard two-person conversation — sceptic arc, believer mechanism, opposed reverse-shot stills, locked voice + eyeline, exact off-screen backchannels, Flux-first beats, assemble + silence trim. Use for podcast ads, UGC conversation ads, sceptic-to-believer product spots — not for single-hook talking-head ads (use ugc-video-prompts).
---

# Podcast Ad

The ad is **two people, one room, one conversation**. Viewer overhears; nobody pitches the lens. Script is ~80% of the result.

Lenora does not generate a full multi-speaker room in one pass — **segment the exchange into model-length beats**, lock room/identity with matching reverse-shot stills, then assemble on the timeline.

Pair with `video-prompting`. For faces that must match brand talent across variants, run `character-pipeline` first. Finish captions/layout with `ugc-editing` patterns when helpful.

## Why this format works

- She never addresses camera — kills “ad argument in the head”
- His doubts are the buyer’s doubts — conversion when *he* clicks
- Pattern-matches podcast clips in the feed, not classic ad shapes

Break overheard staging (lens eye contact, hard CTA, cheerleading sceptic) and you lose the format.

## Step 1 — Write the exchange (sceptic first)

| Role | Job |
|------|-----|
| Believer | Transformation. Casual certainty. Talks to a mate, not a customer. |
| Sceptic | Doubt → convert on camera. **Write him first — his arc is the ad.** |

**Sceptic’s four beats (required)**

1. **Open doubt** — names the quiet part out loud
2. **Honest question** — hands her the floor without agreeing
3. **The click** — mechanism connects to *his* life (not a parrot of her claim)
4. **Concession** — stops arguing; does **not** gush

**Believer craft:** human comparison over feature list; **disarm the scary version**, then educate with a specific mechanism; callback close; **no hard CTA** inside the dialogue.

Map the script onto generation beats that fit `list_models` durations (often 4–10s). Prefer **tight** durations (often 5–6s). One conversational turn (or half-turn) per clip is safer than cramming. Flux 3 minimum is **5s**.

### Backchannels (reactive ad-libs)

**Agent judgment (this skill):** on longer believer turns, decide whether 1–2 quiet off-screen listener murmurs earn a place — sparse, **woven through** her speech (not parked only at the end), not after every clause, **not** a reverse-shot cutaway. Skip short callbacks and all sceptic-speaking beats.

**Model prompt:** never paste that judgment as a menu (`uh-huh / oh? / mm`). After you decide, write **exact** off-screen lines and **where** they sit relative to her words.

| Agent decides | Prompt must say |
|---------------|-----------------|
| Whether this beat gets a backchannel | Exact phrase(s): `"Oh?"` |
| Which 1–2 murmurs + placement | After which of her clauses |
| Same sceptic Voice lock, quieter than her | Verbatim Voice + “quieter than her, audio only, not on camera” |

Example — agent chose two spots; prompt gets:

```
[DIALOGUE]
Believer says exactly: "Those water-retention drops changed everything —
one salty meal prep day and I'd look puffy. Now I just don't."
Voice: <believer Voice lock verbatim>

[BACKCHANNEL]
Off-screen male partner only (not on camera). Same sceptic Voice lock, quieter than her.
After she says "changed everything" he says exactly: "Oh?"
After she says "I'd look puffy" he says exactly: "Really?"
No other reactions. Do not invent a second person in frame.
```

## Step 2 — Two matching start frames

`list_models({ type: "image" })` → `generate_image` for each speaker.

### Still models (validated)

| Prefer | Model id | Notes |
|--------|----------|-------|
| **1st** | `grok-imagine` (Grok Imagine 2) | Strong photoreal + natural podcast staging; **no** `referenceMediaRefs` in Lenora yet |
| **1st (tie)** | `gpt-image-2` (GPT Image 2) | Use for reverse still with refs; `resolution: "1024x1536"` for 9:16 |
| **1st (tie)** | `seedream-v5-pro` (Seedream 5.0 Pro) | Refs OK; aspect often `portrait_16_9` |

Do **not** default to Nano Banana / Krea / Ideogram / Recraft / MAI / Reve for podcast stills unless asked or the preferred trio fails.

These stills are **shot / reverse-shot** anchors: same room + camera grammar, **opposed eyelines**.

### Hard rules

1. **One person only.** No foreground shoulder, OTS, interviewer blur, or second body.
2. **Same camera grammar on both.** Height, distance (chest-up), table edge, wall, lights — copy-paste. Only wardrobe + face + gesture + **eyeline side** change.
3. **Same room word-for-word.**
4. **Flip the reverse shot.** Believer frame-RIGHT ↔ sceptic frame-LEFT (or vice versa). Mirror mic/boom side with the subject.
5. Generate A, then B with `referenceMediaRefs: [stillA]` (use GPT Image 2 / Seedream if A was Grok): preserve room + camera height/distance — replace subject and **flip eyeline**.

### Prompt pattern

```
Podcast studio mid-shot, chest-up, eye-level camera, locked framing.
Single subject only — no other people, no foreground shoulder, no over-the-shoulder.
Wooden table edge low in frame, broadcast mic on boom in shot.
Background: <identical room description>.
Warm practicals, normal exposure, real room — not a film set.
Subject mid-gesture, mouth slightly open — not into lens.
```

Then only subject + eyeline differ:

```
Believer: <wardrobe/face>. Eyeline: looking frame-RIGHT toward off-screen partner.
Sceptic: <wardrobe/face>. Eyeline: looking frame-LEFT (OPPOSITE of believer).
Preserve room and camera height/distance from reference — flip orientation only.
```

Negatives: `no second person, no OTS, no interviewer, no looking into lens, no same-side eyeline as the other speaker`.

### Frame checklist

- [ ] One person only; no OTS / shoulder
- [ ] Matching height, distance, room
- [ ] Mic in front of speaker
- [ ] Off-axis eyeline; **opposed** across the pair
- [ ] Mid-gesture / mouth slightly open

`folder: "PodcastAd/Stills"`

## Step 3 — Generate conversation beats

1. `get_timeline` — set delivery aspect (often `9:16`) via `set_project_settings` **before** placing if needed.
2. `list_models({ type: "video" })`.
3. **Prefer Flux 3** `draft: true` for dialogue naturalism (validated bakeoff). Also fine: `seedance-2-mini`, MiniMax H3 (`hailuo-03`). Lip-sync misses: Kling V3/O3 or Grok.
4. **Final:** re-generate the approved beat on `seedance-2` / H3 without `draft` (not `upscale_media` on a draft).
5. Propose beats; wait for confirmation.
6. `startFrameMediaRef` = that speaker’s still. Seedance: `framesAndReferencesExclusive` — don’t combine first frame with reference image pools.

### Voice lock (required)

Before any `generate_video`, write **two fixed Voice lines** with explicit **accent + tone + pitch + pace**. Paste **verbatim** every beat for that speaker. Name the accent the user wants (e.g. Australian, US California, UK).

```
Believer Voice: <accent>, <pitch>, <tone>, <pace>, no dead air
Sceptic Voice: <accent>, <pitch>, <tone>, <pace>, no dead air
```

Example (only if the brief asks Aussie):

```
Believer Voice: Australian woman, natural Aussie accent not exaggerated,
warm mid pitch, lightly upbeat certainty, brisk conversational pace, no dead air
Sceptic Voice: Australian man, natural Aussie accent not exaggerated,
medium-low pitch, dry sceptical tone, measured but snappy, no dead air
```

Never rewrite mid-ad. Optional: beat-1 audio as `@Audio1` on later Seedance/H3 calls.

### Prompt extras every beat

```
[SCENE]
Animate from the start frame. Overheard — talks to off-screen partner, not the lens.
Locked camera; ambient room only.

[GEOGRAPHY]
Match the start frame: one subject, mic in shot. Hold the SAME off-axis eyeline
side as the still for the entire clip. Natural micro head turns only within that
side — never swing to camera, never flip to the opposite side.

[DIALOGUE]
<Speaker> says exactly: "<line>"
Voice: <paste that speaker's locked Voice line verbatim>

[BACKCHANNEL]   // believer long turns only, after agent decided exact lines
...exact off-screen lines + placements...

[ACTING]
Talk to the off-screen partner the whole time. Fill the duration with speech —
minimal trailing silence. No cheerleading. No hard sell to lens.

[CAMERA]
Hold the start-frame angle. No orbit, no new coverage.

[NEGATIVES]
No looking down the lens, no eye contact with camera, no turning to face camera,
no flipping eyeline, no second person, no OTS, no room/light change, no CTA
lower-third, no identity swap, no subtitles/watermark, no long pauses.
```

Regenerate **that beat** only on failure. `folder: "PodcastAd/Beats"`

## Step 4 — Assemble + finish

```
add_clips({
  entries: [
    { mediaRef: BEAT1, startFrame: 0 },
    { mediaRef: BEAT2, startFrame: END1 }
  ]
})
```

- `remove_silence` (tight: `minimumPauseSeconds: 0.25`, light `speechPaddingSeconds`) after assembly
- Product / before-after over mechanism beat: higher video track or `apply_layout` PIP
- Captions: `add_captions` — clean default unless asked
- Do not over-polish into “ad grade”

## Turning one into thirty

| Lever | Change |
|-------|--------|
| Objection swap | Only his lines / his beats |
| Product swap | Keep four-beat arc; rewrite mechanism |
| Clip the click | His click beat as a short with a new hook ahead |

## Anti-patterns

- Writing believer first; sceptic has nothing to do
- Sceptic ends as brand ambassador
- Start frames or video beats staring at / turning to camera
- Same-side eyelines on both speakers
- Vague Voice lines (no accent + tone) — voices drift
- Vague backchannel menus in the model prompt (agent must pick exact lines)
- Reverse-shot cutaways for `uh-huh` / `oh?` (bake off-screen under her instead)
- OTS / foreground shoulder / second person in a “single” still
- Over-long durations leaving dead air
- Vague mechanism (“it just works”); hard CTA in dialogue
- One overloaded clip for the whole ad; skipping timeline assembly
