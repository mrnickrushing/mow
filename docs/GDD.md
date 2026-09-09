# Mow all the lawns! — design

A Roblox co-op mowing game in the mould of *Clean all the leaves!*. Up to a
dozen players share one overgrown property, race a completion bar against the
clock, and turn clippings into better equipment.

## The shape of it

**Not a tycoon.** You pick a world from the lobby, arrive with nothing, and
clear it section by section against the clock — two hours on The House, less after. Cash, tools and
upgrades live for the length of the run and no longer. Clear the last section
and the grate opens: walk out and you have beaten the world.

What survives a run is small on purpose — best times, lifetime totals, which
worlds you have beaten, and anything bought with Robux. Nothing you can grind.

## The loops

**20 seconds.** Hold to work. Debris comes up in a swath as wide as your tool.

**2 minutes.** Bag fills, you walk to the trailer, it sells on approach.

**3 minutes.** Cash buys a bag or speed level at the shed. Prices are in single
dollars, because you started this run with nothing twenty minutes ago.

**One section.** Clear it and the gate to the next opens. On a busy server it
fills back up first: one wave per player, capped at two, so a team does more
work than a solo player rather than finishing in a fraction of the time.

**One run.** Six sections, a grate, and a time on the board.

## What makes it ours

Sixteen ideas do most of the work. In rough order of how much they matter:

1. **Grass has height, not just presence.** Every tile is 0–3. A weak mower
   shaves one level per pass; a good one takes all three. The early game is
   *honestly* slow rather than artificially slow, and every mower upgrade is a
   visible jump rather than a number.

2. **Deck width is the headline stat.** Tools cut a swath 1 to 11 tiles wide.
   Width is felt far more than speed.

3. **Mow stripes.** Cut in long parallel lines and you bank a Clean Stripe
   bonus. Almost free to build, looks superb in a thumbnail, and gives a genre
   with no skill expression something to be good at.

4. **"You missed a spot."** Past 95% in a zone, the stragglers get a beacon.
   A direct fix for the reference game's worst frustration.

5. **Overgrowth gates.** Grass too thick for your tool bogs the mower down and
   refuses. You feel the wall and go buy the fix, instead of reading a greyed
   out button.

6. **Debris types gate tools.** Clippings, leaves, weeds, hedges, sticks, logs,
   stumps — each needs its own gear. This is what keeps the shed interesting.

7. **Bag weight, not bag count.** A log takes 15 units of space to a clipping's
   1 but pays far more per unit. Hauling wood is a decision.

8. **The portable trailer.** A mid-game upgrade that lets you park the dump
   point anywhere. The reference game's single worst pain, sold back as its most
   satisfying purchase.

9. **Instant dump.** Sells on approach. No prompt, no animation lock, no queue.

10. **Mulching Blades.** More debris per square, which stays useful long after
    every other line has saturated.

11. **Fuel.** Gas gear burns it while cutting, not while carried. Running dry
    sends you to the shed and keeps the cheap manual tools relevant.

12. **Golden Blades.** One hidden collectible per zone, respawned each round.
    Explicitly never required for 100%.

13. **Hazards.** Sprinklers wet the ground and keep it wet — a low-tier tool
    stalls on it until it dries — and the neighbour's dog takes a cut of a
    heavy bag. Two of them, on nine sections: five sprinklers and four dogs,
    spread across all four worlds.

14. **Tips.** A skill currency from stripes, blades and completions.

15. **Property rotation.** Four maps, each larger and richer than the last,
    and the ladder is built to take more.

16. **Contribution-split payouts.** The round bonus goes by work actually done.

17. **A first run that arrives a piece at a time.** The HUD is not handed over
    all at once. A new player gets a lawn, a completion bar and one lit button;
    the bag turns up when there is something in it, the hotbar and the shed when
    there is something to buy, and the rest at the last step. Four steps — hold
    to work, fill the bag and walk it to the trailer, buy a wider deck, then hit
    the overgrowth wall — and the last of those is the point of the other three.
    A tour of the shed teaches where the buttons are; walking a mower into grass
    it will not cut teaches what the shed is *for*, and the player goes there on
    their own. Every step ends on something the player does rather than a button
    they press, and the only button on the card is SKIP. Walked once; the
    profile remembers.

## Worlds

Four, each a chain of sections gated on clearing the one before it.
Twenty-five sections in all, twenty-two of them required: House 8 (6 required),
Mansion 6 (5), Gas Station 5, Cemetery 6.

**The House** (Easy, 2:00:00, 1× payout) — Front Yard opens the Backyard and
the **Pool Deck** together, those open the **Hedge Maze**, the maze opens the
Farm, the farm opens the Basement. Clear the Basement and the grate at the back
of it opens.

Two areas sit off that path: the **Garage**, opened by finding a switch hidden
in the front yard, and the **Rooftop**, opened by clearing the front yard.
Neither is required to finish, which is the point of them — somewhere to go that
nobody made you go.

**The Mansion** (Medium, 2:30:00, 1.6×) — Grand Lawn → **East Terrace** →
Orangery → Long Maze → Cellars, with the **Tennis Court** off the path beside
them. The terrace is not the old East Wing renamed: it is a raised stone
terrace at elevation 6 with steps up to it. The court is the first hard surface
anybody mows — tarmac inside a mesh fence, one wave, and no grass in its fill
because nothing grows through tarmac.

**The Gas Station** (Hard, 3:00:00, 2.1×) — Forecourt → Wash Bay → Back Lot →
Storage Yard → Workshop. A commercial lot rather than a garden: chain-link
fencing, a canopy, and gates between the parts of it.

**The Cemetery** (Nightmare, 3:30:00, 2.5×) — The Lawns opens The Rows and
**The Walks**; the rows open the Corn Maze, the maze opens the Chapel, the
chapel opens the Crypt, and the grate is rebuilt into the crypt's far wall.
The only property worked after dark, and the only one where a narrower tool can
beat a wider one: The Rows carry no clutter because the headstones *are* the
clutter, and a zero-turn spends half its time reversing out from between two
of them. The shed and the trailer sit at opposite ends of the entrance, which
is unique to it — on a night map the walk to sell is not the walk to upgrade.

### Sections are not all at ground level

A third of them are not. Basements and cellars sit at −18, the Rooftop on top
of the house, the East Terrace at +6. Stairs and stairwells are built to reach
them, and a section's elevation is what decides whether its ground can be
walked onto or has to be climbed to.

### One door per world is bought, not cleared

| World | Section | Price |
| --- | --- | --- |
| The House | Pool Deck | $18 |
| The Mansion | Orangery | $140 |
| The Gas Station | Wash Bay | $75 |
| The Cemetery | The Walks | $240 |

Each is priced near a seventh of what the sections before it are worth. They
were $1, $8 and $15 against worlds holding thousands, so the gate always opened
the moment you walked up to it and the mechanic never did anything: a cash gate
that cannot make you choose is a door with a sign on it.

Later worlds pay more, but only enough to reach the gear they need. Paying
several times the first world once made them the *easiest*, which the simulator
caught.

## Tools

Sixteen, priced for a run rather than a career: $10 for the first mower,
$650,000 for the commercial deck that only the last world can reach.

| # | Tool | Cost | Deck | Power |
| --- | --- | --- | --- | --- |
| 0 | Bare Hands | free | 1 | 1 |
| 1 | Push Reel Mower | $10 | 1 | 1 |
| 2 | Rake | $30 | 1 | 2 |
| 3 | Gas Push Mower | $60 | 2 | 2 |
| 4 | String Trimmer | $140 | 1 | 3 |
| 5 | Leaf Blower | $320 | 3 | 3 |
| 6 | Self-Propelled Mower | $700 | 3 | 3 |
| 7 | Hedge Trimmer | $1.5K | 2 | 3 |
| 8 | Pole Saw | $3.2K | 1 | 3 |
| 9 | Chainsaw | $6.8K | 1 | 3 |
| 10 | **Riding Mower** | $14K | 5 | 3 |
| 11 | Industrial Backpack Blower | $30K | 6 | 3 |
| 12 | **Zero-Turn Mower** | $65K | 7 | 3 |
| 13 | Stump Grinder | $140K | 1 | 3 |
| 14 | Wood Chipper | $300K | 1 | — |
| 15 | **Commercial Deck Mower** | $650K | 11 | 3 |

The first rung mows, deliberately. The rake used to sit at $8 against the reel
mower's $25, so the opening purchase of a lawn-mowing game was a rake and the
opening minutes were spent raking; they have swapped places and prices.

**Bare hands can shift anything a tile holds.** That is a rule, not an
accident: a section full of something you cannot afford the tool for is a dead
run, and the simulator walled itself twice before this was enforced. Every
other tool is a speed upgrade, never a gate.

### Upgrade lines

Seven, all reset each run: Leaf Bag, Cut Speed, Mulching Blades, Work Boots,
Business Sense, Fuel Tank, Trailer Hitch. First levels cost a dollar or two.

## Balance

`scripts/simulate.luau` is the source of truth. It plays a virtual, ROI-optimal
player through the whole ladder and prints time-to-unlock for everything. It
runs in CI.

It now simulates a single run rather than a career, and reports whether a world
can be beaten inside its clock, where a run stalls, and what gear you finish
holding. Pass a player count to check wave scaling.

The clocks are 2:00:00 on The House, 2:30:00 on The Mansion, 3:00:00 on The Gas
Station and 3:30:00 on The Cemetery. The two middle ones were more than doubled
from where this document last described them, and for a reason worth keeping in
mind: the old ratio was satisfied by handing the player a bigger property and
*less* time, which is not a harder world so much as an impossible one.

An ROI-optimal player who never wastes a second finishes each of them in well
under half its clock. Real players are nowhere near optimal, so the clock should
feel tight rather than generous; The House was lengthened from ninety minutes
after a party of three ran out with the backyard barely done. The tightest
margin in the game is The Cemetery's 0.09 seconds per unit against The Gas
Station's 0.104 — and it still gives more clock than any other property,
because there is about a third more ground on it.

Wave scaling is invariant up to the cap: a section holds U units per wave and
needs one wave per player, so the total is N·U shared between N people and
everybody does U. Past `Worlds.MAX_WAVES` (two) the share falls on purpose: a
party of three owing three waves of every section ran out of the clock with the
backyard barely done. There is a test for both halves.

**Known tuning weakness:** the worlds all sit near a third of the clock,
so difficulty comes from length and complexity rather than from time pressure
tightening. If the later worlds should feel tense, they need more ground rather
than richer payouts — richer payouts made them faster last time.

## Architecture

Two decisions shape the code.

**Tiles are data, not Instances.** The world's grass is a `buffer`, one byte per
tile — 2 bits of height, 3 of debris type, 1 wet flag. The server creates no
part for it. Cutting rasterises the tool's swath with pure grid maths: no
raycasts, no physics, no `Touched`. The client keeps its own copy and draws a
bounded window — pooled parts inside the detail radius, one plane per chunk
beyond. This is what lets a 25,000-tile property run with a full server.

**The client reports only where it is and what it holds.** Every cut, sale and
purchase is decided server-side against rate limits, ownership, a position
plausibility check and zone unlocks. Exploit resistance falls out of the shape
rather than being added later.

`Shared/Cutting.luau` holds the per-tile decision and is used by *both* sides, so
client prediction can be wrong about timing but never about the rules.

## Performance budget

| Measure | Target |
| --- | --- |
| Server frame, 12 players mowing | < 8 ms |
| Client, mid-range phone | > 45 FPS |
| Replication per client | < 30 KB/s |
| Server-side grass Instances | 0 |

Tuning knobs are in `GameConfig`: `DETAIL_RADIUS`, `LOD_RADIUS`,
`MAX_TILE_PARTS`, `REPLICATION_RADIUS` and the tick rates.

## Not built

Deliberately out of scope, and why:

- **Rebirth and idle crew.** Cut during planning in favour of a linear climb.
- **Co-op two-person hauling.** The social hook exists via the shared map and
  the contribution split; a dedicated two-player job is not built.
- **Sound and music.** Configured, not mixed. `Shared/Config/Audio.luau`
  carries per-property notes, the churchyard's included; what is missing is the
  pass that balances them.
- **Art direction.** Done, and no longer this list's business.
  `Shared/Config/Palette.luau` is a complete autumn palette with four world
  styles — house, estate, station, churchyard — plus a night pass, and
  `Shared/Config/Props.luau` is a catalogue of about seventy real models with
  drawn 2D icons for twenty-three of them and for all sixteen tools. Eight more
  were thought to be needed; seven of them were then measured at tile size and
  read fine as meshes, and the eighth — a sound glyph, which had no prop behind
  it at all — is drawn from primitives. `docs/ICONS.md` has the measurement and
  the size rule it produced.
- **Interiors are shells.** The garage, basement, cellars and workshop are
  walled rooms with a clutter count, not furnished spaces, and the house itself
  has no interior at all.

