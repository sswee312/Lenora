---
name: ugc-editing
description: Covers assembling raw footage, trimming bad takes and silences, choosing and applying a talking-head/b-roll format (straight intercut, stacked split, or masked/floating overlay), and caption placement for UGC-style content — agnostic to whether the clips are AI-generated or real filmed footage. Use whenever the user wants to edit, cut, assemble, format, or caption UGC-style video, or pick a talking-head + b-roll layout. Picks up after ugc-photo-prompts/ugc-video-prompts if the footage is AI-generated, or after real footage is imported via import_media.
---

# UGC Editing

## Core principle

Editing is footage-source-agnostic. The same assemble → trim → layout → caption pipeline applies whether the clips came from `ugc-video-prompts` or a real phone shoot. This skill picks up wherever footage already exists and turns it into a finished vertical post. The single biggest editing mistake in UGC is padding — long pauses, repeated stumbles, slow setups. Cut harder than feels comfortable. Authentically raw ≠ unedited; it means tight pacing with natural-sounding joins.

**Tool model (current Lenora):** timeline positions are project frames; source trims are seconds via `source: [start, end]`. Linked A/V is folded into the video clip as `audio: { id, … }` — mute/edit audio by that nested id. Mutations return a timeline delta — patch from it; don't re-`get_timeline` after every call. Index **0 renders on top**.

---

## Step 0: Pre-flight — always run before touching the timeline

1. **`get_timeline`** — check resolution / `canGenerate`. Must be 9:16 (typically 1080×1920). If not:
   ```
   set_project_settings({ aspectRatio: "9:16", quality: "1080p" })
   ```
   Do this **before** placing clips. Explicitly configured settings stick (the first clip no longer snaps the project to its source aspect — placement may only note a mismatch).

2. **`get_media`** — identify A-roll and b-roll. Note `durationSeconds`, width/height, `hasAudio`.

3. **`inspect_media`** on the A-roll:
   - First: `overview: true` — storyboard + segment timestamps.
   - Then: `wordTimestamps: true` (window long clips with `startSeconds`/`endSeconds`) — read words as prose before cutting. Look for retakes, fillers, false starts, trailing dead air, weak sections.

---

## Step 1: Place A-roll only — no b-roll yet

```
add_clips({
  entries: [{
    mediaRef: AROLL_ID,
    startFrame: 0,
    // whole asset, or trim in SOURCE seconds (not project frames):
    source: [SKIP_PREROLL_S, END_S]   // omit for full file
  }]
})
// omit trackIndex on every entry → auto-creates video + linked audio tracks
```

- **Never pass `trackIndex` here** when you want a fresh storyline track. Omitting it auto-creates one shared video track (and linked audio). Specifying an existing index can overwrite whatever is already there.
- There is no `durationFrames` / `trimStartFrame` on `add_clips` — use `source: [startSeconds, endSeconds]` for source span, or `endFrame` (mutually exclusive with `source`) for an exact timeline occupy range.
- 16:9 A-roll in a 9:16 project may letterbox. Cover-crop the talking head to full frame:
  ```
  apply_layout({
    layout: "full",
    slots: [{ slot: "main", clipIds: [AROLL_CLIP_ID], anchor: "center" }]
  })
  ```
  Prefer `apply_layout` over `set_clip_properties` transforms — layout sets transform **and** crop together (transform-only leaves a stale crop and can stretch).

---

## Step 2: Cut bad takes and filler — words first

Prefer `remove_silence` first for dead air (no transcript), then word cuts.

**Read first, cut once per pass.** `get_transcript` → mark indices → one `remove_words` call. Indices shift after every cut — re-read before the next pass.

```
get_transcript()
remove_words({
  words: [
    [FIRST_RETAKE_START, FIRST_RETAKE_END],
    FILLER_INDEX,
    [FALSE_START_START, FALSE_START_END],
  ],
  cutAggressiveness: "tight"   // "balanced" / "loose" if joins feel clipped
})
// bulk fillers: remove_words({ matches: ["um", "uh", "hmm"] })
```

**What to cut:** duplicate retakes (keep the most fluent), fillers, false starts, trailing soft endings, off-topic tangents that break hook → value → CTA.

**What to keep:** natural pauses between real thoughts; best take of each section; the outro/CTA.

**Captions block ripple:** if a caption track exists, remove it before cutting:
```
manage_tracks({ remove: [{ trackId: CAPTION_TRACK_ID }] })
// or remove: [index] — prefer trackId from get_timeline
```
Then cut, then re-add captions. Never caption before cutting is finished. There is no `remove_tracks` tool.

---

## Step 3: Pick a layout format

**Format 0 — Straight intercut (default)**  
B-roll is supplementary, not simultaneous. Hard cuts alternating full-frame A-roll and b-roll on the **same** video track every 3–5s. Use `add_clips` (overwrite landing region) or `insert_clips` (ripple — requires `trackIndex`) — no layout tool.

**Format 1 — Stacked split, b-roll top / talking head bottom**  
B-roll is proof (product/result/location). Viewer needs both at once. `layout: "top_bottom"`, b-roll → `top`, head → `bottom`.

**Format 2 — Stacked split, head top / b-roll bottom**  
B-roll is filler/retention. Same layout, slots flipped.

**Format 3 — Full-bleed b-roll, floating head**  
Not clean via `apply_layout` alone — needs chroma/`apply_effect` + manual framing. Skip unless asked.

---

## Step 4: Place b-roll

### Format 0 — intercut on the storyline track

```
add_clips({
  entries: [
    { mediaRef: BROLL_1, startFrame: F0, source: [0, 4] },
    { mediaRef: BROLL_2, startFrame: F1, source: [0, 3] },
  ]
})
// same track as A-roll → overwrites those ranges (split/trim under the hood)
```

Mute any linked b-roll audio (nested `audio.id` on each placed video, or mute the b-roll audio track via `manage_tracks`).

### Format 1–2 — stacked split (critical: span-scope the head)

`apply_layout` on an existing clip is **whole-clip** (time-invariant). If you layout the entire A-roll into `bottom`, the head stays half-frame for the whole video — including stretches with no b-roll (black / empty top).

**Do this instead:**

1. `split_clips` the A-roll at each b-roll span boundary so overlay segments are their own clips.
2. `add_clips` each b-roll tile on a **new** track (omit `trackIndex` on the whole batch) covering exactly those frames — use `startFrame` + `source` or `endFrame`.
3. Mute b-roll audio immediately:
   ```
   set_clip_properties({
     clipIds: [BROLL_AUDIO_NESTED_IDS],  // video.audio.id from timeline/delta
     volume: 0
   })
   ```
4. For each overlapping pair, `apply_layout`:
   ```
   apply_layout({
     layout: "top_bottom",
     slots: [
       { slot: "top",    clipIds: [BROLL_CLIP_ID], anchorY: 0.4 },
       { slot: "bottom", clipIds: [AROLL_SEGMENT_ID], anchor: "center" }
     ]
   })
   ```
5. Leave non-overlay A-roll segments full-frame (`layout: "full"` only if something dirtied them).

**Do not** use `insert_clips` for overlay b-roll — it ripples the storyline and breaks sync. **Do not** build splits with `set_clip_properties` / `set_keyframes` transforms.

Optional shortcut for a single continuous stacked section: `apply_layout` **placement** mode with `mediaRef` in every slot + `startFrame`/`endFrame` creates stacked tracks for that range only — useful when A-roll isn't already on the timeline for that span. Don't mix `mediaRef` and `clipIds` across slots in one call.

---

## Step 5: Captions

`add_captions` finds spoken audio itself — there is **no `clipIds` filter**. Mute all b-roll / non-dialogue audio **before** captioning or captions will pick up the wrong speech.

```
add_captions({
  animation: "highlightPop",          // or "wordPop"
  highlightColor: "#FFD700",
  maxWords: 3,
  transform: { centerY: 0.5 },        // 0.5 seam (split); 0.82 lower-third (full-frame)
  style: {
    color: "#FFFFFF",
    bold: true,
    fontSize: 48,                     // ~48 split; 60+ full-frame
    fontCase: "mixed"                 // NOT "uppercase" — natural case
  }
})
```

- Restyle later: `update_text({ captionGroupId, style: {…}, transform: {…}, animation })`.
- `fontCase` is display casing (`mixed` / `uppercase` / `lowercase`). Prefer `mixed`.
- Caption clips show as `captionGroups` summaries on `get_timeline` — use `captionDetail: true` only when editing individual caption clips.

---

## Step 6: Verify

```
inspect_timeline({ startFrame: 0, endFrame: totalFrames, maxFrames: 6 })
```

Check samples for: b-roll filling its half only during overlay spans; talking head full-frame elsewhere; captions at the seam/lower-third; no stretched clips (stale crop — reset with `apply_layout` `full`).

---

## Common failure modes

| Symptom | Cause | Fix |
|---|---|---|
| B-roll overwrites A-roll | `trackIndex` pointed at storyline | Re-add b-roll with `trackIndex` omitted |
| Head stuck in bottom half forever | `apply_layout` on whole A-roll clip | Split A-roll; layout only overlay segments |
| Clip looks stretched | Transform without clearing crop | `apply_layout({ layout: "full", slots: [{ slot: "main", clipIds: [ID] }] })` |
| Captions from b-roll dialogue | B-roll audio still audible | `volume: 0` on nested b-roll audio ids, then regenerate captions |
| `remove_words` sync-lock | Caption track present | `manage_tracks` remove caption track → cut → re-caption |
| `add_clips` rejected | Used `durationFrames` / bare array | Use `{ entries: [{ mediaRef, startFrame, source? }] }` |
| Stale timeline mental model | Re-read skipped after foreign edits | Patch from mutation deltas; `get_timeline` after failures / user edits |

---

## Track order — typical end state

Index **0 = top** (what you see on top in the preview).

| Index | Content |
|---|---|
| 0 | Captions (text) |
| 1 | B-roll video (muted linked audio) |
| 2 | A-roll video |
| … | A-roll audio (linked; may appear as nested `audio` on the video clip) |

---

## Pacing benchmarks

- Hook in the first 2–3 seconds.
- A cut, b-roll switch, or caption change roughly every 3–5 seconds.
- Most UGC ads: 15–60s (30–45s sweet spot for Reels with CTA).
- Captions are not optional — most social video is watched muted.
- AI talking heads: keep faces to 2–3s before cutting to b-roll.

---

## Guardrails

- Build fictional, generic personas — don't edit in a specific real, identifiable person without consent, and don't recreate a named public figure's likeness.
- Keep wardrobe/pose/action choices brand-safe and non-sexualizing by default; only go further if the user explicitly asks.
