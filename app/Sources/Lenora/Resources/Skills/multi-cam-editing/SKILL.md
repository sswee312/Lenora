---
name: multi-cam-editing
description: Edit multi-camera / shared-audio sessions (podcasts, interviews, panels) inside Lenora — create a multicam group first, verify sync and mic-to-person mapping, then cut angles to the speaker with wide/layout moments for overlap. Use whenever the footage has multiple cameras, multiple mics, dual-system sound, or the user mentions multicam, multi-cam, podcast edit, interview cut, camera switching, or synced audio.
---

# Multi-Cam Editing

## Core principle

Always start from a **multicam group**. Do not manually stack angles and hope they stay aligned — `manage_multicam` syncs members by audio, locks their timing, and lets `change_cam` switch what the viewer sees without breaking sync. Editing is deliberate: know whether cameras are **speaker angles** or **A/B coverage**, trim with soft landings at sentence ends and tighter joins mid-thought, and put picture cuts on the same seams as audio cuts (especially B-cam). For tight, rapid, or chaotic dialogue, **err on the side of not cutting** — messy joins hurt more than a few extra seconds.

---

## Workflow checklist

```
- [ ] 1. Inventory media — cameras, mics, who is on which file
- [ ] 2. Create multicam group (manage_multicam) — never skip this
- [ ] 3. Verify sync + mic ↔ person mapping
- [ ] 4. Agree trim goals with the user (format-specific)
- [ ] 5. Trim / tighten (get_transcript → remove_words / remove_silence)
- [ ] 6. Program the cut (change_cam — speaker cams + wide/layout)
- [ ] 7. Review with get_multicam + inspect_timeline
```

---

## Step 1: Inventory the session

```
get_media()
get_timeline()
```

Classify every source before grouping:

| Role | What it is | `kind` in manage_multicam |
|---|---|---|
| Close / single | One person framed | `angle` (or `both` if that file's audio is their mic) |
| Master wide | Whole set / all participants in frame | `angle` (label it `wide`) |
| Dedicated mic | Lav, recorder, mix bus with no useful picture | `mic` |
| Cam + own audio | Remote podcast / Zoom-style per-person file | `both` |

**Decide what the cameras represent** — this drives the whole program cut:

| Setup | Cameras mean | Cut strategy |
|---|---|---|
| **Speaker cams** | Each angle is a different person (host / guest / panel) | Default to whoever is talking; wide/layout for overlap |
| **A-cam / B-cam** | Same subject or scene, different angles (hero + alternate) | Stay on **A-cam most of the time**; use **B-cam sparingly** where it earns its keep (reaction, emphasis, cover a jump, visual variety on a long hold) |

Label angles for the setup you actually have (`host`/`guest`/`wide`, or `a-cam`/`b-cam`). Prefer short, stable labels over filenames.

Use `inspect_media` (overview + a short dialogue window) when filenames don't make roles obvious.

---

## Step 2: Always create the multicam group first

```
manage_multicam({
  create: {
    name: "Session",
    master: "host-mic",          // or best all-speakers source — see below
    members: [
      { mediaRef: WIDE_ID,  kind: "angle", angleLabel: "wide" },
      { mediaRef: HOST_ID,  kind: "angle", angleLabel: "host" },
      { mediaRef: GUEST_ID, kind: "angle", angleLabel: "guest" },
      { mediaRef: MIC_ID,   kind: "mic",   angleLabel: "host-mic" },
    ]
  }
})
```

**Member-kind rules (from the tool — follow exactly):**

- Separate cameras + mics → `angle` + `mic`
- One file per participant with its own audio (remote podcast) → `both`
- Cameras + one master mic → `angle`s + one `mic`
- Always include at least one `mic` or `both`. Pure `angle` audio is scratch for sync only and **never plays** — an all-angle group is silent. If camera sound *is* program audio, mark those members `both`, not `angle`.

**Master:** the member whose clock defines group time and whose audio feeds transcript/waveforms. Default is the first `mic`/`both`. When every member is `both`, pass `master` explicitly — pick the source that hears every speaker best (usually the host).

Create places stamped program clips on the timeline (one program video track + one audio track per mic). Read the response: every member should report a confident `offsetSeconds`. Weak correlation → pin `offsetSeconds` (slate/clap) and recreate. `sync_clips` is refused on multicam clips (already aligned) — only use it on plain clips before grouping. Do not angle-cut on a weak sync.

---

## Step 3: Verify sync and audio ↔ person

```
get_multicam({ groupId: GROUP_ID })
get_transcript({ clipId: MULTICAM_CLIP_ID, granularity: "segments" })
inspect_timeline({ startFrame: SAMPLE_A, endFrame: SAMPLE_B, maxFrames: 4 })
```

Check before any creative cutting:

1. **Sync** — clap/slate/first overlapping speech lands together across angles (spot-check 2–3 moments with `inspect_timeline` / short listens).
2. **Mic ↔ person** — when person A talks, the waveform/transcript energy matches A's angle; no swapped lavs or host/guest flip.
3. **Master choice** — if a guest mic is clearer for the whole conversation, recreate with that as `master` rather than living with a bad transcript source.

If audio is wrong for a person, fix membership/kinds/master and recreate the group. Do not "fix it in the cut."

---

## Step 4: Agree what to trim (work with the user)

Do not silently gut the recording. Propose a trim plan from the transcript, then confirm:

| Format | Usually remove | Usually keep |
|---|---|---|
| **User discovery / interview** | Interviewer's questions (when the deliverable is guest-only answers); pre-roll setup; "can you hear me"; retakes of the same answer | Guest answers in full; natural pauses that carry meaning; emotional beats |
| **Podcast / panel** | Beginning slate, tech checks, "we're recording," ending "ok that's a wrap," long off-topic tangents the hosts already flagged | Banter that defines the show; overlapping laughs; cold open if one exists |
| **Either** | Long silences, repeated false starts, obvious "start over" takes | Rapid back-and-forth, crosstalk, punchlines that need the setup |

Ask when ambiguous: guest-only answers vs full conversation, how aggressive on filler, whether a tangent stays.

---

## Step 5: Trim deliberately

```
get_transcript()                    // words for cutting; segments first if the piece is long
remove_words({
  words: [ /* indices / [start, end] spans from the plan */ ],
  cutAggressiveness: "balanced"     // override per pass — see below
})
```

**Cut aggressiveness by where the seam lands:**

| Seam type | Aggressiveness | Why |
|---|---|---|
| **End of a sentence / thought** | `loose` (or leave ~**4–5 frames** of pad after the last kept word) | The final word needs a beat to land — cutting flush makes endings feel chopped |
| **Between words / mid-sentence** (filler, false start, retake splice) | `tight` | Aggressive joins play clean inside a continuing thought |
| Default / mixed pass | `balanced` | When a batch spans both kinds of seams |

Prefer splitting into two `remove_words` passes when the plan mixes end-of-sentence drops and mid-sentence cleanup: tight pass for interior junk first, then a looser pass (or frame pad) for sentence-final trims. If the tool only leaves silence via `cutAggressiveness`, use `loose` at sentence ends rather than `tight`.

**How to cut:**

- Read the transcript as prose. Mark everything to remove, then cut in as few `remove_words` passes as possible (indices shift after each call — re-read between passes).
- Prefer word-based cuts over frame ripples. Use `remove_silence` only for true dead air, not as a substitute for editorial judgment.
- **Tight / rapid / chaotic segments — leave them alone.** Fast exchanges, piled interruptions, and laughter rarely splice cleanly. If a cut would land mid-breath or mid-overlap, keep the span.
- After each meaningful pass, spot-check joins (`get_transcript` around the seam + a short `inspect_timeline`). Undo if a join sounds wrong, then retry with a wider keep.

Captions block ripple: if a caption track exists, `manage_tracks({ remove: [{ trackId }] })` first, cut, then re-add captions. (There is no `remove_tracks` tool.)

---

## Step 6: Program the camera cut

Angle cuts live **inside** the group via `change_cam` — never split/stack the multicam carrier by hand to switch cameras.

```
get_multicam({ groupId: GROUP_ID })   // angle labels + current program

change_cam({
  groupId: GROUP_ID,                 // or clipId of any group clip
  entries: [
    { range: [0, 1800], angle: "host" },
    { range: [1800, 4200], angle: "guest" },
    { range: [4200, 5100], angle: "wide" },          // overlap / laugh
    // no wide? layout + angles in SLOT ORDER (first = program slot):
    { range: [5100, 6000], layout: "side_by_side",
      angles: ["host", "guest"] }
  ]
})
```

Layouts use `angles: [...]` (slot order), **not** `{ slot, angle }` objects. A later full-frame `{ range, angle }` over the same span clears a layout. Extra angles beyond the layout's slots become synced overlay clips (ordinary group clips — restyle/remove normally).

### Cutting rules of thumb

**Speaker-cam setup** (each angle = a person):

1. **Default: show whoever is talking** — cut to their close on (or just before) their first word; hold through their turn.
2. **Master wide when energy is shared** — overlapping speech, group laughter, reactions, pauses where faces matter more than one mouth. If a `wide` exists, prefer it here.
3. **No wide? Simulate with layouts** — two people → `side_by_side` / `top_bottom`; three → `three_up`; four → `grid_2x2`; one primary + others → `main_sidebar` or `pip_*` (main = speaker, inset = reactor).
4. **Stay flexible** — a short reaction on the listener is fine after a strong line; don't ping-pong every clause.

**A-cam / B-cam setup** (same scene, alternate angles — not different speakers):

1. **A-cam is the spine** — most of the program stays on A-cam.
2. **B-cam is seasoning** — use it briefly where it helps: cover a jump cut, a reaction beat, emphasis, or relief on a long A-cam hold. Do not flip A/B as if they were two speakers.
3. **Never let a word-cut land mid B-cam.** If you trimmed audio at a seam, the B-cam shot must start and/or end on that same cut (or sit entirely between cuts on unbroken audio). A B-cam hold that straddles a `remove_words` join looks like a glitch — especially bad on B-cam.

**Align camera changes with edit seams (all setups):**

- Prefer switching angles **on** the same frames as word/silence cuts you already made — picture cut and sound cut land together.
- Especially for B-cam (and any brief cutaway): in on a cut, out on a cut. Do not start B-cam mid-word or ride it across a splice.
- After trimming, build the `change_cam` program from the **post-cut** transcript/timeline so ranges match the kept audio.
- **Batch entries** — one `change_cam` with the full program (or large contiguous chunks). Later entries win on overlap. Re-read with `get_multicam` to confirm the run-length program looks right.

Layouts available to `change_cam` (same family as `apply_layout`, excluding full-frame): `side_by_side`, `top_bottom`, `pip_bottom_right`, `pip_bottom_left`, `pip_top_right`, `pip_top_left`, `grid_2x2`, `main_sidebar`, `three_up`.

---

## Step 7: Review

```
get_multicam({ groupId: GROUP_ID })
inspect_timeline({ startFrame: 0, endFrame: TOTAL, maxFrames: 8 })
```

Confirm:

- Program matches the setup: speaker-following **or** A-cam-heavy with sparse B-cam — not random flips
- Angle changes land on edit seams; no B-cam (or cutaway) straddling a word-cut
- Sentence endings still have a short pad (~4–5 frames / loose aggressiveness); mid-sentence joins can be tight
- Sync still holds after trims; no silent stretches from missing `mic`/`both`
- Trim plan matches what the user approved

When the cut is locked and you need plain unstamped clips: `manage_multicam({ ungroup: { groupId } })` — clips stay put, stamps drop, `change_cam` no longer applies. (There is no `bake` action.)

---

## Common failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Group is silent | All members marked `angle` | Recreate with at least one `mic` or `both` |
| Wrong person sounds loudest / transcript follows wrong voice | Bad `master` or swapped mic kinds | Recreate with correct master / mic mapping |
| `needsAttention` on a member | Weak audio correlation | Pin `offsetSeconds` from clap/slate; widen `searchWindowSeconds` |
| Angle cut "does nothing" on timeline read | Looking at `get_timeline` (hides internal angles) | Use `get_multicam` for the program EDL |
| Joins sound chopped after tightening | Cut into rapid/overlap dialogue, or `tight` on a sentence end | Undo; restore the span; use `loose` / ~4–5 frame pad at sentence ends |
| Sentence endings feel clipped | `tight` aggressiveness on end-of-thought seams | Re-cut those seams with `loose` or leave pad after the last word |
| B-cam (or cutaway) glitches on a splice | Angle hold straddles a word-cut | Rebuild `change_cam` so B-cam in/out lands on the same frames as the audio cut |
| A/B footage ping-pongs like two speakers | Treated A/B as speaker cams | Keep A-cam as spine; B-cam only in short, motivated beats |
| Stacked unsynced cameras on the edit timeline | Skipped multicam create | Remove hand-stacked clips; `manage_multicam` create from media refs |

---

## Guardrails

- Multicam group **before** creative cutting — sync and membership first.
- Confirm trim intent with the user when the format is ambiguous.
- Soft landings at sentence ends; aggressive only mid-thought / between words.
- Know the setup: speaker cams vs A-cam/B-cam — cut accordingly.
- Put camera changes on edit cuts; never leave a word-cut in the middle of B-cam.
- Prefer fewer, cleaner angle changes over constant switching.
- When unsure whether a cut will play clean, **keep the footage**.
