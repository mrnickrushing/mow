# Icons — what the interface draws, and what it does not need drawn

Three separate icon systems live in `src/Shared/Config/Props.luau`, and which
one a slot uses decides whether it looks right or looks like a grey smudge.

1. **`TOOL_ID_ICON` — complete.** Sixteen drawn 2D icons, one per tool id. The
   six mowers differ in *outline* rather than colour on purpose: the reel mower
   shows its cylinder, the self-propelled its catcher, the zero-turn its lap
   bars. Reached through `Props.forTool(id, category)`.
2. **`ICONS` — 23 props with drawn 2D art.** Flat, one colour, heavy outline.
   These are the crispest thing the interface has.
3. **Everything else — mesh only.** About forty props with a mesh and no
   `icon`. `Theme.setIcon` falls back to a spun `ViewportFrame`.

## The eight-icon question, answered by measurement

The design handoff's `ICON-AUDIT.md` recommended commissioning eight drawn
icons — **Trailer, Shed, Gate, Grate, Sprinkler, Dog**, plus a **sound** glyph
and a **fuel** can — on the grounds that the first six would otherwise render
as spun meshes and be "illegible at tile size".

It also named the cheap check to run first: put each of them in a tile in
Studio and look. That check was run, at fifty-six points, against `Coin` and
`Sack` — two of the drawn 23 — as a control.

**Seven of the eight do not need drawing.**

| Prop | At 56px | Verdict |
| --- | --- | --- |
| `Trailer` | A green flatbed on its wheels | reads |
| `Shed` | A small open-fronted building | reads |
| `Gate` | An arched dark doorway | reads |
| `Grate` | An arched grille, distinct from the gate | reads |
| `Sprinkler` | A blue fan of water over green | reads clearly |
| `Dog` | Unmistakably a dog | reads clearly |
| `GasPump` | A red pump — this is the fuel icon | reads clearly |

They are softer than the flat drawn 23, which is what a lit mesh at tile size
looks like, and every one of them is identifiable. Commissioning art to replace
something a player can already name is work with no result behind it.

**The eighth was real.** There is no `Speaker` or `Note` prop, and the HUD's
sound tile was the character `U+266A` — a glyph, drawn by whatever font the
player's device resolves, which is the exact fault `Props.luau` calls out. It
is now three rectangles: a tilted round head, a stem, and a flag. A note on
every device there is, in the tile's own ink.

## The size rule

Fifty-six points is where a mesh still reads. **Thirty is not**, and neither is
it kind to the drawn 23: at thirty points the Golden Blade is a sliver, the
sack a grey lump and the rake a faint grey T. Measured, in the store's own
rows, which is why eleven of its fifteen carry a flat diamond in their column's
colour instead of a picture nobody could name.

So: a picture at forty-four points or more, a flat shape below that.

## If art is commissioned later

Match the existing 23: flat, one colour, a heavy ink outline, and readable as a
silhouette. Add the asset id to the `ICONS` table in `Props.luau` — a prop with
no entry still renders as its mesh, so nothing breaks in between.
