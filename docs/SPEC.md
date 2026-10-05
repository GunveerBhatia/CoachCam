# Coach Cam — Product Spec

The source of truth for *what* the app does and the photography knowledge behind it.
The coaching rules in `CoachCam/Resources/playbook.json` are built from the "Photography
rules" section below. Every threshold lives in `CoachCam/Resources/config.json`.

## Goal
A personal iPhone camera (iPhone 18 Pro Max) that, within about 0.5 s of pointing it, knows
what's in the frame, sets up the camera, coaches you with short text steps, and tells you
when the shot is right: green shutter, "Take it", and one haptic tap. You press the shutter.
Everything is automatic by default and can be overridden with a tap.

## Architecture (revised 2026-09-28)
**Detection** is automatic and only *describes* the frame. It never picks the photo type.
- Subject category: people, building, food, sky/landscape, object (specific names), or general
- Number of people, and each person's type (kid, teen, man, woman, older man, older woman),
  on-device, "person" when unsure, correctable by tap
- Props and background, lighting (level, harshness, backlight, direction), distance, phone tilt
- A category must be confident and stable for several frames before it changes
- Sanity checks, e.g. nothing closer than about 2 m can be a building; buildings need distance,
  strong vertical lines, and are usually outdoors

**Shot suggestions** (replaced photo types, 2026-10-04): when a subject locks, a row of 3–6
text cards (icon, title, one line; no example images) shows the suggestions that fit what's
detected (subject, people count/types, props, light, time of day), ranked by fit and by your
favourites. Tapping a card starts its step-by-step walkthrough; the lens follows the tapped card.
48 suggestions live in `playbook.json` (food, one person, selfies, duos, groups, buildings,
sky, objects), each with conditions, lens, camera height/angle, placement, lighting, auto
settings, burst use and steps.

**Guided steps:** one step at a time (text under ~8 words + a matching arrow), auto-advance
after ~0.4 s with a check mark and haptic, quiet step-back if a done step comes undone, Skip and
swipe-back, progress dots, and "Take it" + green shutter when all steps pass. Step text, arrow
types and checks come from the playbook's step library.
## Photography rules (research)

### General (all photos)
- Level: straighten the phone (level line).
- Crop: "Step back, head is cut off" / "Move closer".
- Placement: subject on the nearest rule-of-thirds line, or dead centre when symmetrical.
- Headroom: not too much empty space above the head; don't cut the head off either.
- Don't crop at joints (knees, ankles, elbows, wrists).
- Clean background: nothing growing out of heads, no bright distractions at the edges.
- Tips address whoever must act ("You: crouch lower", "Left person: step forward"), one at a
  time, under about 8 words.

### Lens choice
| Situation | Lens |
|---|---|
| Headshot / head-and-shoulders | 4x (100mm; pros use about 85mm-equivalent). Too close for 4x → 2x and "step back". |
| Solo full body / fits | 1x or 2x depending on distance |
| Mirror fit | 1x |
| Groups | 1x; 0.5x only if people don't fit and you can't step back |
| Buildings | 1x or 2x and step back; avoid 0.5x (converging lines) |
| Food | 1x or 2x; never 0.5x (food looks like it's sliding off) |
| Sunsets / landscapes | 1x; 4x or 8x to make a distant sun or subject bigger |
| Close-up object | macro |

### Headshot / pro
Camera at eye level or slightly above. Body angled 30–45° from the camera, head turned back to
the lens. Chin forward and slightly down, never lifted. Shoulders dropped, small lean toward
the lens. Head tilt 5° at most. Eyes at the lens, not the screen.

### Mirror fit
Stand 4–5 ft from the mirror. Phone at chest height. Body angled about 30° from the mirror.
Hold the phone slightly to the side so it doesn't block the face or outfit. Weight on one leg,
other knee slightly bent, one foot slightly forward. Clean background.

### Front selfie
Phone slightly above eye level. Chin forward and slightly down. Turn toward the light. Warn
when the phone is too close (face distortion).

### Duo / group
Stagger head heights: no straight row, no heads stacked directly on top of each other.
- 2 people: bodies angled about 45° toward each other, heads at different heights, the person
  closer to the camera a half-step forward.
- 3 people: a triangle; one sits or kneels, two stand at different heights.
- 4+: build out from the tallest person as the anchor; every face visible between the
  shoulders in front.
Close the gaps (shoulders touching, leaning in). Camera slightly above eye level.

### Friend shoots me
Pick or approve the pose before handing over the phone. The app then coaches the photographer
with dead-simple steps: "Crouch lower", "Step back two steps", "Turn phone sideways", "Wait for green".

### Building / architecture
Keep the phone level (pitch near 0°) so verticals stay straight; tilting up → "Keep phone
level, step back". Suggest a higher vantage point if it doesn't fit. Symmetrical → centre;
asymmetrical → thirds. Golden hour: warm, textured facades. Blue hour (about 20–30 min after
sunset): best for lit buildings and skylines. Offer vertical-line correction after capture.

### Food
- Flat dishes (pizza, salads, bowls, boards): overhead, phone parallel to the table.
- Tall or layered dishes (burgers, cakes, drinks, stacks): straight on, at the food's eye level.
- Everything else: 45°.
Coach the angle with phone pitch ("Raise to overhead", "Lower to 45°"). Light from the side or
behind, never from the front; warn if your shadow falls on the food. Remind to wipe the plate
rim and clean the lens when the image looks hazy.

### Sunset / sky / landscape
Horizon on the lower third if the sky is the star, upper third if the ground is; never dead
centre. Horizon perfectly level. Look for a foreground element (tree, rock, person) for depth.
People in a sunset: get low so they're against open sky; leave a gap between two people so
their silhouettes don't merge. Best light is roughly 20–30 min either side of sunset; keep
shooting after the sun goes down. Expose for the sky; let the foreground go dark.

### Lighting (people)
- Harsh midday sun: "Move into open shade" (just inside a building's or tree's shadow); face
  the person toward open sky, not deep into trees.
- Can't move: turn the person so the sun is behind them (warm rim light).
- Backlit, face too dark: "Light is behind you, turn around", or rely on HDR / face exposure.
- One side of the face much darker: "Turn toward the window/light".
- Too dark overall: "Find more light or hold still".

### Auto camera settings
Backlit person: expose and focus on the face, HDR when available. Sunset: expose for the sky.
High contrast: HDR / multi-frame. Low light: highest quality; longer exposure when steady;
very dark → burst, align, and average, with a "Hold still" countdown. Motion: shorter shutter,
higher ISO. White balance: correct strong casts toward natural skin tones.

## Poses
Three vibes: Street, Casual, Pro. A pose library (JSON, 60+ poses) tagged by vibe, number of
people, shot type, props/setting, with short text steps confirmed by body-pose detection.
"Next pose" cycles to another fitting pose.

## Other features
"Take it" signal with burst best-shot picking; after-photo looks (Original, Enhanced, Dusk,
Daylight, Night, Soft portrait) protecting skin tones; Ideas button (Claude API, only on
tap, key in Keychain); learns your style on-device with a reset button.

## Milestones
M0 pipeline ✅ · M1 camera ✅ · M2 detection (in progress) · M3 auto settings · M4 composition
coaching · M5 lighting coaching · M6 poses · M7 "Take it" + burst · M8 after the photo ·
M9 Ideas · M10 learns my style · M11 polish.
