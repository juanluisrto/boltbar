# Boltbar logo — six variations

Shared construction (all six): the stadium from the reference (outer radius 287.5, inner 144.5, arm 143) is now centred on the 1744×902 canvas. Each logo is one background `<rect>` plus two filled `<path>`s. The bolt is a single constant-width channel that runs from the top edge of the symbol to the bottom edge. The two pieces are exact 180° rotations of each other, so their areas match and the symbol balances about its centre. (In the reference, the bolt sat about 32 px right of centre and the left piece was heavier.) Every tab's outer corner sits exactly on the extension of the matching arm cut, so the eye completes the bolt's edge across the C's opening. The annotation notches are gone.

| # | Colours (fg / bg) | Cut slope | Channel | Jog |
|---|---|---|---|---|
| 1 | #EFE9DE / #222326 | 13° (reference, 3/13) | 104 | horizontal, 164 |
| 2 | #3A86FF / #0A1128 | 22.8° | 66 | rising 32°, wedge tabs |
| 3 | #FFFFFF / #000000 | 28.8° | 84 | horizontal, 200 |
| 4 | #151413 / #F3EAD8 | 13° | 60 | horizontal, 146.8 (= arm weight) |
| 5 | #C6FF1A / #0E2B1D | 18.8° | 124 | rising 22°, wedge tabs |
| 6 | #FF6F59 / #1E1E21 | 13° outer, 45° centre | 72 | two horizontal jogs |

1. **Original refined.** Same slope and same 104 px channel as the reference. The only real change is the jog, which grows from 94 to 164 px. In the reference the two tabs never overlapped horizontally (−37 px), so the step was not walled on both sides. They now overlap by 33 px, which turns the step into a definite zigzag.
2. **Sharp.** The jog now rises to the right (ϟ-style) and the cuts are steeper. Each tab's corner is placed exactly on the inner edge of its arm, so the tab becomes a clean 35° barb with no leftover shoulder. The result is a crisp three-stroke zigzag with acute turns.
3. **Dynamic.** Same structure as #1, but the cuts lean 28.8° instead of 13° and the jog is longer (200). The whole bolt now leans forward, from top-right to bottom-left, which reads as speed.
4. **Minimal.** The channel is thinned to 60 px and the jog is kept horizontal. The tab width is set to exactly the arm thickness, so every stroke in the mark has the same weight. The bolt stays quiet and is discovered rather than announced.
5. **Bold.** Widest channel (124), using the barb construction from #2 with a shallower rise and fatter wedges. The gap is the first thing you notice after the link silhouette.
6. **Experimental.** The bolt has two jogs instead of one. The arms are cut at the reference's 13° slope, and the central stroke runs at 45° between two horizontal steps. Both tabs wall that centre stroke along its full length, so it reads as a crisp Z-shaped zigzag in the middle of the link.

## Checks (all six pass)
- The two paths never touch. The minimum distance between them equals the channel width everywhere (66–124 px, all at least 55).
- Every pixel inside the channel is pure background colour, from y = 163.5 (top of the symbol) to y = 738.5 (bottom).
- In renders at 1744×902 and at 64×64 and 32×32 (square icon crops), there are exactly two separate foreground shapes. The background dominates along the whole bolt centreline (worst case 23% foreground coverage, #4 at 32 px).

## What could not be fully satisfied
- **The bolt's outline is implied in two places.** Each piece is an open C, so its hole has to open into the channel somewhere. Where that happens, one side of the bolt is implied by the aligned corner rather than drawn as an edge. #2, #5 and #6 keep those openings smallest relative to the bolt, so they read most clearly.
- **The tabbed pieces can read as letterforms.** #1, #3 and #4 can look like "G D", and #6 like "C Z D". This comes from the C-plus-tab idea in the reference. The barb versions (#2, #5) read least like letters.
- **#6 uses two jogs** rather than the classic single jog, as its exploration.
- **At 32 px the gap is only 1.5–3 px.** The pieces stay separate, but the bolt is only a hint in #1 and #4. In #2, #5 and #6 it is still legible.
