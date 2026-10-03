---
name: timeless-love-story
description: Generates a ~70-second cinematic short where one couple is reincarnated across five historical eras plus a modern-day finale, shot in a consistent handheld DV-camcorder "found footage" style, scored with epic-romantic orchestral strings. Requires two reference photos (man, woman) and their two names — ask for these if missing. Use when the user asks to make a multi-era love story video, a reincarnated-lovers video, a "Timeless"-style short, or describes this exact concept (couple across history eras, camcorder POV, doorway transitions between eras). Always use this skill for this request rather than improvising the flow — the execution order (sheets first, then everything in parallel) is the point of the skill.
---

# 🎬 Timeless — Multi-Era Love Story Generator

## What this makes
A ~70-second cinematic short where one couple is reincarnated across five historical
eras plus a modern-day finale, all shot in a consistent handheld DV-camcorder "found
footage" style. The story: in every era the two lovers find each other, share a beat of
action/romance, and the man (always holding the camcorder, first-person POV) follows the
woman through a dark doorway/threshold that transitions seamlessly into the NEXT era.
Ends with a present-day subway reunion embrace and a script title card of their two names,
scored with an epic-romantic orchestral strings track.

The eras, in order: **Ancient Egypt → Ancient Rome → Medieval → Wild West → Renaissance →
Modern Day (finale)**. (You may trim to fewer if the user wants a shorter piece, but this
is the canonical set.) Medieval comes before Wild West — not alphabetical/chronological
order — because the shot lists are written as a match-cut: Medieval ENDS on the couple
running hand-in-hand through a dark stone gateway, and Wild West OPENS on that exact
hand-in-hand run bursting out of a gateway into daylight. Swapping this order breaks the
continuity the prompts were written for.

## The ONLY things you need from the user
Before doing anything, you MUST have:
1. **Two reference images** — one of the man, one of the woman (any photos; they anchor
   facial identity across every era).
2. **Two names** — the man's and the woman's, for the closing title card.

If either is missing, STOP and ask for it. Example: *"Send me a photo of each person and
their two names, and I'll build the whole thing."* Do not proceed on assumptions. You may
optionally ask two refinements (but default sensibly if they don't answer): aspect ratio
(default **16:9 horizontal** — the character sheets are always horizontal regardless), and
whether five eras is right.

## Golden rules of execution order (this is the whole point of the skill)
1. **Session check first.** `get_timeline` once, then `list_models`. If `list_models` returns
   no models, the Lenora backend isn't connected or configured — tell the user to check
   Settings → Backend; generation will fail otherwise. **Read the
   project's actual `fps` from this response and use it for all frame math below** — do
   not assume 24fps. (The reference build that produced the numbers in Step 3 happened to
   run at 24fps, 1280×720; a 30fps project needs every frame count recalculated, e.g. an
   11s clip is 264 frames at 24fps but 330 frames at 30fps.)
2. **HARD GATE — photos before videos.** Generate ALL character sheets first and **do not
   call `generate_video` (or start any era clip) until every sheet is fully finished** —
   `get_media` shows **no** `generationStatus` on each. Placeholders / still-generating
   sheets are not enough. Videos take those sheets as `referenceImageMediaRefs`; firing
   them early means broken or missing identity. Music may wait with the video batch, but
   **never** ahead of sheet readiness.
3. **Only after ALL sheets are ready, fire EVERYTHING else in parallel and don't block:**
   - Generate all 6 era videos in one batch.
   - Generate the music track.
   - As each generation returns a placeholder id, **immediately place it on the timeline
     even while it's still generating** (Lenora allows placing generating clips — they
     fill in automatically when done). Add the text card too. This way the instant the
     last render finishes, the finished edit already exists — no assembly step afterward.
4. **Don't busy-poll.** Fire generations, place placeholders, move on. Only read
   `get_media ids:[...]` when you genuinely need to confirm readiness.

---

## MODEL CHOICES (resolve via `list_models` first — ids drift)
- **Character sheets (images):** `seedream-v5-pro` (Seedream 5.0 Pro). It gave the most
  photoreal, consistent results in testing. Note its aspect ratios use different labels —
  16:9 horizontal is `landscape_16_9`, NOT `16:9` (that errors).
- **Era videos:** `seedance-2` (Seedance 2, the regular/quality one — not Fast), **720p**,
  duration **11s** each (the finale is **14s**). Pass the era's man+woman sheets as
  `referenceImageMediaRefs` and reference them in-prompt as `@Image1` (man) and
  `@Image2` (woman).
- **Music:** `elevenlabs-music`, `instrumental: true`, duration **90** (closest supported
  value ≥ the ~70s runtime; you trim it down on the timeline).

---

## STEP 1 — Character sheets (10 images: man + woman × 5 costume eras)

For the Modern finale, generate 2 more sheets (man + woman) — 12 total — but you can do
those in the same batch. Every sheet uses this **fixed deterministic 6-panel layout** so
they're consistent (this exact template mattered — free-form layouts came out
inconsistent):

> Fixed 2-row × 3-column grid. **Top row:** (1) full body front, (2) full body side
> profile, (3) close-up face front. **Bottom row:** (4) close-up face left profile,
> (5) close-up face back-of-head, (6) close-up face right profile.

**Prompt template (fill `{ERA COSTUME}` per era, keep everything else verbatim):**

```
Ultra-photorealistic DSLR photograph, single-character reference sheet, fixed 2-row by
3-column grid layout, 16:9, neutral seamless gray studio backdrop, consistent studio
strobe lighting across all six panels, visible skin texture and pores. Subject: a real
{man/woman} {ERA COSTUME}. Top row, left to right: (1) full body front view, standing
straight, arms at sides; (2) full body side profile view, facing right; (3) close-up face
portrait, front view, neutral expression. Bottom row, left to right: (4) close-up face
portrait, left side profile; (5) close-up face portrait, back of head view showing hair;
(6) close-up face portrait, right side profile. Identical framing size and distance across
all panels in each row, consistent identity, hairstyle, and costume in every panel. Small
white annotation labels under each panel. Real photographic lighting and shadow falloff,
sharp focus, shot on Canon EOS R5, 85mm lens. No illustration, no CGI, no painting, no
cartoon, no airbrushing, no plastic skin, no text watermark.
```

Pass BOTH user reference images in `referenceMediaRefs` on every sheet (they anchor the
face). `aspectRatio: "landscape_16_9"`, model `seedream-v5-pro`, folder e.g.
`Eras/CharacterSheets/{Era}`.

**`{ERA COSTUME}` values:**
- **Egypt — man:** `dressed as Ancient Egyptian royalty — dark hair, broad shoulders, pleated white linen kilt, gold pectoral collar, kohl eyeliner`
- **Egypt — woman:** `dressed as Ancient Egyptian royalty — long hair in a straight sheath, sheer white linen gown, gold collar necklace, kohl eyeliner, henna on hands`
- **Rome — man:** `as a Roman gladiator — muscular build, worn leather and bronze armor with scratches, arm guard, short sword, battle-worn sandals`
- **Rome — woman:** `as a Roman noblewoman — hair braided up, draped crimson and cream stola, gold laurel-style hairpiece, leather sandals`
- **Wild West — man:** `in 1880s American frontier clothing — weathered canvas duster coat, cracked leather vest, dusty wide-brim hat, holster with revolver, scuffed riding boots`
- **Wild West — woman:** `in 1880s American frontier clothing — small bonnet, high-necked cotton prairie blouse, fitted riding skirt, worn leather gloves, dusty boots`
- **Medieval — man:** `as a medieval knight — polished steel plate armor, chainmail underlayer, longsword, tabard with a simple crest`
- **Medieval — woman:** `as a medieval noblewoman — hair with a braided crown, velvet burgundy medieval gown with gold embroidery, jeweled circlet`
- **Renaissance — man:** `in Renaissance-era Venetian nobility clothing — doublet with slashed sleeves in deep green velvet, gold chain, tailored breeches, leather boots`
- **Renaissance — woman:** `in Renaissance-era Venetian nobility clothing — pearl-strand hairpiece, ornate brocade gown with structured bodice, lace collar, jeweled rings`
- **Modern — man:** `in modern-day casual clothing — fitted black t-shirt or henley under a black leather jacket, dark denim jeans`
- **Modern — woman:** `in an elegant modern evening outfit — a fitted burgundy satin slip dress with thin straps and a cutout side detail, hair worn naturally down and slightly wavy, delicate thin necklace, subtle elegant makeup`

**STOP here until every sheet is done.** Confirm with `get_media({ ids: [...] })` that
**none** of the 12 sheet assets still have a `generationStatus`. Do **not** open Step 2,
do **not** call `generate_video`, and do **not** place era clips until that check passes.
(Placing *video* placeholders while *videos* generate is fine later — placing or generating
videos off unfinished *photos* is not.)

---

## STEP 2 — Era videos (ONLY after all sheets are finished — then fire all 6 + place placeholders)

Shared style spine for EVERY clip (this is the signature look — keep verbatim):

> **DV 16mm tape camcorder footage look, soft slightly blurry digital tape quality, faint
> tape noise, highlights blooming in low light, auto-exposure flickering subtly, muted
> color contrast, realistic skin tones. First-person POV, handheld, held directly in hand
> by @Image1 the whole time — the camcorder itself never appears on screen. Maintain
> constant hand shake, misaligned framing, delayed focus pulls, clumsy zoom in and out,
> occasional self-cam framing where his own face gets cut off at the edge, imperfect shots
> that briefly lose the subject.** … `[per-era shot list]` … **Muted desaturated color,
> visible tape grain and noise, no text, no watermark.**

Continuity spine: `@Image1` = man (holds camera), `@Image2` = woman (leads him onward).
Each era ends with the pair crossing a dark doorway/threshold; the NEXT era opens emerging
from that threshold with the costume already changed — the shadow hides the wardrobe swap,
so cuts read as one continuous journey. Each is a numbered shot list ("Shot 1: … Shot 2:
…") because explicit per-shot definition (not summary) gave the best cut rhythm.

All videos: `seedance-2`, `resolution: "720p"`, `aspectRatio: "16:9"`, `duration: 11`
(finale `14`), `referenceImageMediaRefs` = [that era's man sheet, woman sheet].

### 2a. EGYPT (11s) — the "meet-cute," intimate/tired vlog tone
```
DV 16mm tape camcorder footage look, soft slightly blurry digital tape quality, faint tape
noise, highlights blooming in low light, auto-exposure flickering subtly, muted color
contrast, realistic skin tones. First-person POV, handheld, held directly in hand by
@Image1 the whole time — the camcorder itself never appears on screen. Late-afternoon,
low-energy-but-happy vibe, tired but content after a long day of labor at the pyramid site,
quieter and slower pacing, occasional heavy breathing between moments, genuine unposed
warmth. Maintain constant hand shake, misaligned framing, delayed focus pulls, clumsy zoom
in and out, occasional self-cam framing where his own face gets cut off at the edge,
imperfect shots that briefly lose the subject. Shot 1: he lifts the camera and pans it
slowly across the pyramids in the hazy golden light, tired exhale audible, dust settling
around him. Shot 2: clumsy zoom past tired workers finishing up for the day near the
pyramid base, camera dips and re-settles. Shot 3: he turns the camera on himself for a
second, dusty and worn out but smiling faintly, top of his head clipped by the frame, then
swings it back around because he spots @Image2 nearby. Shot 4: he quietly films her from a
small distance, delayed autofocus slowly sharpening on her face as she notices him and
gives a small, warm, unguarded smile back — soft golden backlight, hair glowing at the
edges. Shot 5: he laughs softly to himself, camera shaking a little, and starts walking
toward her, footage bouncing gently with each step, glimpses of dusty ground and her figure
ahead. Shot 6: he catches up beside her, briefly angling the camera to catch both their
faces close together in frame, easy and happy, before she turns and starts walking toward a
dark doorway built into the pyramid, waving him along. Shot 7: he follows her still filming,
footage jostling as he walks, the frame swallowed briefly into shadow and tape noise as
they both cross into the dark threshold together. Muted desaturated color, visible tape
grain and noise, no text, no watermark.
```

### 2b. ROME (11s) — a battle beat, exhilarating
```
DV 16mm tape camcorder footage look, soft slightly blurry digital tape quality, faint tape
noise, highlights blooming in bright sun, auto-exposure flickering, muted color contrast,
realistic skin tones. First-person POV, handheld, camera strapped/held loosely by @Image1
during a gladiator fight — the camcorder itself never appears on screen, footage whips and
shakes violently with combat motion. Bright midday colosseum, dusty sand arena, roaring
crowd, tense but exhilarated energy, heavy breathing. Maintain constant hand shake,
misaligned framing, delayed focus pulls, clumsy whip-pans, occasional frames that clip his
own face or lose the subject entirely in the chaos. Shot 1: frame swinging wildly as he
blocks and clashes swords with an armored opponent in the sandy arena, dust kicking up,
crowd roaring in the stands behind. Shot 2: mid-fight, a whip-pan up into the stands catches
@Image2 on her feet cheering, draped Roman dress, fists raised, shouting his name, sun
flaring the lens. Shot 3: back to combat, frame shaking hard as he pushes his opponent back,
swings his sword, dust and sand spraying across the lens. Shot 4: another quick glance-cut
to her in the crowd, her face lit up with pride and excitement, cheering harder, delayed
focus pull sharpening on her expression. Shot 5: he lands the winning blow, opponent
staggering back, crowd erupting, camera jostling with his triumphant motion, fists raised.
Shot 6: he turns and starts running out of the arena, camera bouncing hard with his sprint,
glimpses of sand, colosseum walls, and the archway tunnel ahead as he bolts toward it,
breathing hard, footage swallowed briefly by shadow as he exits into the tunnel. Muted
desaturated color, visible tape grain and noise, no text, no watermark.
```

### 2c. WILD WEST (11s) — playful; comes AFTER Medieval in the timeline. OPENS on the hand-in-hand run from Medieval's ending threshold, ENDS approaching a glowing building so it hands into the next indoor scene
```
DV 16mm tape camcorder footage look, soft slightly blurry digital tape quality, faint tape
noise, highlights blooming in harsh sun, auto-exposure flickering, muted dusty color
contrast, realistic skin tones. First-person POV, handheld, held directly by @Image1 the
whole time — camcorder never appears on screen. Playful, breathless, fun energy shifting
from urgency into laughter. Maintain constant hand shake, misaligned framing, delayed focus
pulls, clumsy zoom, occasional frames clipping his own face or losing the subject. Shot 1:
continuing straight from a dark stone gateway, @Image2 is already holding his hand pulling
him along as they run together, footage bouncing hard with both their motion, her gown
replaced mid-motion by a prairie blouse and riding skirt as they burst out of the shadowed
threshold into blinding daylight. Shot 2: they emerge together into a sunbaked frontier
town, dusty street, wooden saloon fronts, still hand in hand, both laughing now that the
danger has passed, footage settling from overexposed to clear. Shot 3: he swings the camera
to catch her laughing face as they slow to a jog, breathless, dust on both of them, duster
coat and wide-brim hat visible at his frame edges. Shot 4: a riderless horse tied outside a
saloon comes into view, she runs ahead and swings up into the saddle first. Shot 5: he
climbs up onto the horse behind her, settling in seated behind her, camera jostling as he
gets situated, one arm holding the reins area near her. Shot 6: she glances back over her
shoulder at him and the camera, laughing candidly, a genuine unposed grin, wind blowing
loose strands of her hair across her face. Shot 7: the horse breaks into a trot then eases
toward a grand lit building ahead at the edge of town, warm golden windows glowing, faint
sound of music and chatter drifting out, they slow to a stop and dismount together, walking
side by side toward the glowing doorway, footage settling calmer and quieter as they
approach the entrance, anticipation in the air. Muted desaturated dusty color transitioning
to warm golden light near the end, visible tape grain and noise, no text, no watermark.
```

### 2d. MEDIEVAL (11s) — dramatic rescue; comes BEFORE Wild West in the timeline. ENDS on her leading him by the hand through a gate, which is exactly what Wild West's opening shot continues from
```
DV 16mm tape camcorder footage look, soft slightly blurry digital tape quality, faint tape
noise, highlights blooming, auto-exposure flickering, muted cold color contrast, realistic
skin tones. First-person POV, handheld, held or strapped to @Image1 the whole time —
camcorder never appears on screen, footage whips violently with combat motion. Tense,
dramatic, urgent energy, heavy breathing, distant shouting and clashing steel. Maintain
constant hand shake, misaligned framing, delayed focus pulls, clumsy whip-pans, occasional
frames losing the subject in chaos. Shot 1: he bursts through a dark stone gate into a
besieged castle courtyard at dusk, torches and smoke, footage overexposing then settling,
steel plate armor visible at frame edges, distant clash of battle. Shot 2: whip-pan across
the courtyard catches @Image2 in a velvet gown cornered near a wall by approaching
soldiers, fear on her face, reaching a hand out. Shot 3: he draws his sword, frame shaking
hard as he charges and clashes blades with a soldier blocking his path, sparks and dust
flying, camera jostling with each strike. Shot 4: quick glance-cut to her, still cornered,
calling out to him, torchlight flickering across her face. Shot 5: he fights through,
footage chaotic, another clash of steel, he breaks past the last soldier. Shot 6: he
reaches her, grabs her hand, camera swinging as they turn together and run back toward the
gate, arrows whistling past in the torchlit smoke. Shot 7: they sprint through the stone
gateway together, footage bouncing hard with the run, shadow and darkness swallowing the
frame as they cross the threshold, breathless. Muted cold desaturated color, visible tape
grain and noise, no text, no watermark.
```

### 2e. RENAISSANCE (11s) — romantic ballroom; the pair finally slow down and dance
```
DV 16mm tape camcorder footage look, soft slightly blurry digital tape quality, faint tape
noise, highlights blooming softly around candlelight, auto-exposure flickering gently, warm
muted color contrast, realistic skin tones. First-person POV, handheld, held by @Image1 the
whole time — camcorder never appears on screen. Warm, romantic, tender energy, quiet awe,
soft breathing, low murmur of a ballroom in the background. Maintain constant hand shake,
misaligned framing, delayed focus pulls, gentle clumsy zoom, occasional frames clipping his
own face or softly losing focus. Shot 1: he steps through a dark doorway into a grand
candlelit Venetian ballroom, chandeliers and dancing couples in period dress, footage
adjusting from darkness to warm golden glow, velvet doublet visible at frame edges. Shot 2:
shaky slow pan across the dance floor, elegant couples waltzing, candlelight blooming softly
on the lens. Shot 3: the camera finds @Image2 across the room in an ornate brocade gown,
delayed focus pull slowly sharpening on her as she notices him and smiles warmly, a pearl
hairpiece catching candlelight. Shot 4: brief self-cam glimpse of him smiling, quietly
stunned, before turning the camera back toward her as he starts walking across the room.
Shot 5: footage weaves gently through dancing couples as he crosses the floor toward her,
glimpses of gowns and candlelight blurring past. Shot 6: he reaches her, camera raised to
catch both their faces close together, warm and tender, her laughing softly at something he
says. Shot 7: he sets the camera down on a nearby ledge, frame now slightly off-center and
static, catching the two of them stepping into a slow dance together under the chandelier
light, candlelight flickering across the lens. Warm soft desaturated color, visible tape
grain and noise, no text, no watermark.
```

### 2f. MODERN FINALE (14s) — present-day subway reunion + embrace, the emotional resolve
```
DV 16mm tape camcorder footage look, soft slightly blurry digital tape quality, faint tape
noise, highlights blooming under fluorescent station lights, auto-exposure flickering, muted
color contrast, realistic skin tones. First-person POV, handheld, held by @Image1 the whole
time — camcorder never appears on screen. Warm, emotional, quietly overwhelmed energy,
breath catching, ambient subway station sounds. Maintain constant hand shake, misaligned
framing, delayed focus pulls, clumsy zoom, occasional frames clipping his own face or losing
the subject. Shot 1: he stands on a Japanese subway platform, modern casual clothes, camera
tiredly scanning the opposite platform across the tracks. Shot 2: across the tracks he spots
@Image2 in an elegant burgundy dress standing still, staring back at him, delayed focus pull
sharpening on her stunned emotional expression, both frozen for a moment locking eyes.
Shot 3: a train rushes through between them on the near track, lights and windows strobing
past, motion blur streaking the frame, blocking his view of her for a few seconds. Shot 4:
the instant the train clears, she is already turning and hurrying toward the stairs on her
side, disappearing down into the station, having rushed to try to reach him. Shot 5:
realizing what she's doing, he immediately turns and sprints toward his own stairwell,
footage bouncing violently as he runs down into the station corridor, pushing past
commuters, breathing hard, searching. Shot 6: he bursts into the main station concourse
scanning frantically, and spots her running in from the opposite corridor at the same
moment, both moving fast toward each other, footage shaking hard with the run. Shot 7: they
collide together in an embrace in the middle of the busy concourse, camera jostling then
settling as he wraps his arms around her, holding close on both their faces, her crying and
laughing at once. Shot 8: the embrace holds, camera steadies further, he pulls back slightly
to look at her face, cupping it gently, both smiling through tears, foreheads touching,
station lights and blurred crowd passing behind them, tape noise flickering softly, the
moment lingers a little longer before a soft fade. Warm muted desaturated color, visible
tape grain and noise, no text, no watermark.
```

**Notes learned in testing:**
- Story order on the timeline is Egypt → Rome → Medieval → Wild West → Renaissance →
  Modern (see the note in "Golden rules" above — this is not the order the era names are
  introduced in, it's the order the match-cuts require).
- Make the man read **hopeful/yearning, not fierce**, in any close-up (this was an explicit
  fix — "fierce" came out wrong).
- Add **out-of-focus foreground pass-bys** (people/objects crossing close to the lens
  during close-ups) for dynamism and depth — it noticeably improved the best take.
- **Atmosphere sells it:** volumetric haze, drifting sand/dust, shallow-focus bokeh,
  warm desaturated grade. Frame the woman as ethereal beauty, the man as the one drawn
  after her.
- Generate **3 slight variations** of the FIRST era and show the user to lock the look
  before committing the rest, if the user is picky — otherwise generate all six straight.
- If a model errors, `list_models` and fall back (Seedance Fast for iteration; Kling v3
  if Seedance itself fails).

---

## STEP 3 — Assemble the timeline (do this WITH placeholders, while renders run)

Use the project's **actual fps from `get_timeline`** (Golden rule 1) — never assume 24fps.
Compute each clip's frame duration as `round(durationSeconds * fps)`: an 11s clip is 264
frames at 24fps but 330 frames at 30fps; the 14s finale is 336 frames at 24fps but 420
frames at 30fps. Lay the six era clips back-to-back on the top video track (V1) starting
at frame 0, **in story order (Egypt → Rome → Medieval → Wild West → Renaissance →
Modern)**. `add_clips` auto-creates the linked audio partner for each video on an audio
track (A1) — that carries the camcorder ambience.

Placement pattern (contiguous, one after another) — worked example at 30fps (recompute at
your project's actual fps):

| Clip            | Frames (start→end) | Duration |
|-----------------|--------------------|----------|
| Egypt           | 0 → 330            | 330      |
| Rome            | 330 → 660          | 330      |
| Medieval        | 660 → 990          | 330      |
| Wild West       | 990 → 1320         | 330      |
| Renaissance     | 1320 → 1650        | 330      |
| Modern finale   | 1650 → 2070        | 420      |

**Total video runtime = 2070 frames (~69s) at 30fps** — at 24fps the same shape totals
1660 frames. Exact per-clip counts follow each render's real duration — place each new
clip's `startFrame` at the previous clip's `endFrame` so they stay contiguous. Add clips
with `add_clips` (auto video+linked-audio). You can add a clip whose media is **still
generating** — it fills in when ready.

---

## STEP 4 — Music (fire the generation, place it immediately, trim + fade)

Generate with `elevenlabs-music`, `instrumental: true`, `duration: 90`:

```
Epic romantic orchestral strings, upbeat from the very first note, no slow intro —
immediately driving, energetic string ostinatos with soaring violins, rich cello and viola
underneath, bold and heroic yet warm and romantic in melody. Continuously building in layers
and intensity throughout, adding brass and full orchestra swells, into a triumphant sweeping
climax near the end, then resolving into a warm, satisfying final cadence. Cinematic,
passionate, bright, propulsive energy throughout, entirely orchestral, no percussion-heavy
sections.
```

**Do NOT name a real composer/piece** in the prompt (copyright flag). If the user asks for a
specific classical style, describe it generically ("baroque-style strings, harpsichord
accents").

Then:
1. `add_clips` the music placeholder onto a NEW audio track (omit trackIndex → it lands on
   its own track, e.g. A2), `startFrame: 0`. It can be placed while still generating.
2. **Trim it to exactly match the video runtime WITHOUT the text card** — i.e. end at the
   last video frame (the total from Step 3's table, at your project's actual fps). Use
   `endFrame` on placement, or `durationFrames` after — the source is 90s so it gets
   trimmed down.
3. **Default the music to a background level of −12 dB** (≈ **0.25** linear volume) — this
   is the standing preference. Set `volume: 0.25` on the clip.
4. **Natural fade-out via keyframes** over the last ~5–6s of runtime (convert to frames at
   your project's fps — e.g. ~140 frames at 24fps, ~175 frames at 30fps). IMPORTANT:
   setting a scalar `volume` CLEARS keyframes, so set the base volume FIRST, then apply
   keyframes LAST. Keyframe the volume track: hold 0.25 until the fade-start frame, then
   ramp to 0 at the final frame. e.g. for a 2070-frame video at 30fps:
   `set_keyframes(property: "volume", keyframes: [[0, 0.25], [1930, 0.25], [2070, 0]])`.

---

## STEP 5 — Title card (the two names)

`add_texts` on its own top video track. Place it over the **end of the final embrace**,
fading in, and hold it a touch past — but keep the music/video decisions above in mind
(music ends with the video; the card can extend slightly into black if the user wants, or
end with the video). Reference build (30fps, 2070-frame total): text ran frames
**1980 → 2070** (fades in over the last ~90 frames of the reunion, ends with the video).
Scale proportionally to your project's fps and total runtime — roughly the last 3s of the
reunion shot.

Exact style used (verbatim), swapping in the two user names as `"{Name1} & {Name2}"`:

```
content: "{Name1} & {Name2}"
animation: "fadeIn"
transform: { centerX: 0.5, centerY: 0.5 }
style: {
  fontName: "Snell Roundhand",   // elegant romantic script
  fontSize: 90,
  italic: true,
  color: "#F5E6C8",              // warm cream/gold
  shadow: { enabled: true, color: "#000000", blur: 20, offset: {x:0, y:2}, opacity: 0.6 }
}
```

Centered, script, cream-gold with a soft drop shadow. If the user later wants the card to
hold past the video, extend BOTH the text clip AND the music tail together so the resolve
plays under it — don't leave the card sitting in silence.

---

## Recap of the parallelization (the heart of the skill)
1. Get 2 images + 2 names (ASK if missing). `get_timeline`.
2. `list_models` (empty → tell the user to check Settings → Backend). Fire ALL 12 character sheets (Seedream, `landscape_16_9`, both user refs
   on each). **Block until every sheet is finished** (no `generationStatus`). No videos yet.
3. **Only then** fire ALL 6 era videos (Seedance 2, 720p, 11s / finale 14s, each era's 2
   finished sheets as refs) + the music (ElevenLabs, 90s instrumental) — one burst, no
   waiting between videos/music.
4. As each placeholder id returns, immediately `add_clips` it onto the timeline in story
   order (videos contiguous on V1; music on its own track); set music to 0.25 + fade
   keyframes; `add_texts` the name card. Everything is wired before renders finish.
5. Renders complete → the edit is already assembled and plays end to end. Spot-check with
   `inspect_timeline` at a few frames, offer an `export_project`.

## Guardrails
- Never proceed without the two images and two names — hard gate #1.
- Never generate era videos until all character sheets are fully ready — hard gate #2.
  Unfinished photos ⇒ do not call `generate_video`.
- Costs real money (generation) and isn't undoable — this skill implies the user has
  approved generating the full set; if they seem unsure, confirm scope (5 eras vs fewer)
  once before the big batch, then go.
- Keep it brand-safe and non-sexualizing regardless of the reference photos.
- Don't recreate a real identifiable public figure beyond the two people the user supplied.
