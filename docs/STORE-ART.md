# Store art — the pictures nobody plays

Two scripts build everything the Roblox store page shows. Neither uploads:
Open Cloud has no endpoint for an experience's icon or its thumbnails, so
every file here goes up by hand on the Creator Dashboard.

```
python3 scripts/store_art.py     the icon and the shipping thumbnail
python3 scripts/thumbnails.py    the four thumbnails of the A/B test
```

## The four thumbnails

`Mow Thumbnails.dc.html` asks for four 1920×1080 frames that differ only in
the picture and the one claim printed on it:

| File | Claim | The mechanic behind it |
| --- | --- | --- |
| `thumb-a-clock-1920x1080.png` | a race | the run clock, and a section at 62% |
| `thumb-b-before-after-1920x1080.png` | a transformation | grass has height, and it comes off |
| `thumb-c-eleven-wide-1920x1080.png` | power | the Commercial Deck cuts eleven tiles |
| `thumb-d-nightmare-1920x1080.png` | scale | the Cemetery is world four, and it is dark |

**The lockup never moves.** Two lines at 136 points from 72 / 64, and the
same gold hook under them, in all four — built once in `lockup()` and stamped
on each. If the type shifts between variants, the test measures the type and
you learn nothing about the image. Change it in one place or not at all.

**The pictures are screenshots.** Every claim above is a claim about
something that exists in the build, so the picture under it is the build. A
generated illustration of a mower would be a picture of the genre.

## Re-shooting

Sources live in `art/branding/shots/`, named for the slot they fill:
`b-before.png`, `b-after.png`, `c.png`, `d.png`. Variant A uses the
full-resolution render beside them. Drop better files in with the same names
and re-run the script — the compositor crops to 16:9 (or 8:9 for B's halves)
and scales, so anything 16:9 or wider than tall works.

The three Studio shots in the repo are **724 × 502**, which is what Studio's
viewport gives while it is in iPad device emulation at *Fit to Window*: the
emulated device is drawn at about half scale, and that is all the pixels the
window has. Scaled to 1920 they are soft, and the unsharp pass in `fit()`
only papers over it. To replace them properly, in Studio:

1. Close the device-emulation bar (the **×** at its right-hand end) so the
   viewport renders at the window's own size.
2. Close the Output and Assistant panes, so the viewport gets the width.
3. Take the four frames at the cameras below and save them over the files in
   `art/branding/shots/`.

That is roughly 1900 × 950 of real pixels — a 1.14× scale to 1920 rather
than 2.65×.

### The cameras

Set up through the shot rig (a run in progress, the HUD and the viewmodel
suppressed, the machine anchored and levelled after mounting):

**B — The Mansion, `grand_lawn`.** The whole point is that the camera does
not move between the two, so take the first, mow the section, take the
second without touching anything.

```lua
camera.FieldOfView = 60
camera.CFrame = CFrame.lookAt(Vector3.new(232, 11, 58), Vector3.new(258, 6, 150))
```

**C — The Mansion, the Commercial Deck.** One real pass cut north to south
ending at the machine, so the grass in front of it is standing:

```lua
-- pass:  commercial_deck from (225, 152) heading (0, -1) for 18 studs
-- rider: (225, 4, 112) facing -Z, mounted, then levelled at y = 5.1
camera.FieldOfView = 50
camera.CFrame = CFrame.lookAt(Vector3.new(233, 16, 66), Vector3.new(225, 5, 110))
```

**D — The Cemetery, `the_rows`, at its own hour.**

```lua
-- pass:  riding_mower from (140, 330) heading (0, 1) for 40 studs
-- rider: (140, 4, 362) facing +Z, mounted, then levelled at y = 5.1
camera.FieldOfView = 50
camera.CFrame = CFrame.lookAt(Vector3.new(158, 9, 336), Vector3.new(142, 6, 366))
```

**A** needs no camera: it is the render at
`art/branding/mow-all-the-lawns-thumbnail-1920x1080.png`, which is already
1920 × 1080.

## What Studio will not give you

Grass tufts are drawn within `DETAIL_RADIUS` (72 studs) of the *camera* and
thin out from 62% of that; past it a chunk is one flat plane. So an uncut
lawn photographs as a mown one wherever it is more than about forty studs
away, and any shot meant to show grass height has to be taken close to it.
That is not a bug and it is not fixable from here — it is why B and C are
both shot from inside the grass rather than from across the garden.
