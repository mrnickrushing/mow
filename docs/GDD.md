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

13. **Hazards.** Sprinklers wet the ground and keep it wet; wasps sting but pay
    a tip; the neighbour's dog takes a cut of a heavy bag.

14. **Tips.** A skill currency from stripes, blades and completions.

15. **Property rotation.** Six maps, each larger and richer than the last.

16. **Contribution-split payouts.** The round bonus goes by work actually done.

## Worlds

Three, each a chain of sections gated on clearing the one before it.

**The House** (Easy) — Front Yard opens the Backyard and the Pool together,
those open the Maze, the Maze opens the Farm, the Farm opens the Basement.
Clear the Basement and the grate at the back of it opens.

Two areas sit off that path: the **Garage**, opened by finding a switch hidden
in the front yard, and the **Rooftop**, opened by clearing the front yard.
Neither is required to finish, which is the point of them — somewhere to go that
nobody made you go.

**The Mansion** (Medium) — Grand Lawn → East Wing → Orangery → Long Maze →
Cellars. Bigger in every direction.

**The Gas Station** (Hard) — Forecourt → Wash Bay → Back Lot → Storage Yard →
Workshop. The longest chain and the most ground.

Later worlds pay more, but only enough to reach the gear they need. Paying
several times the first world once made them the *easiest*, which the simulator
caught.

## Tools

Sixteen, priced for a run rather than a career: $8 for a rake, $650,000 for the
commercial deck that only the last world can reach.

| # | Tool | Cost | Deck | Power |
| --- | --- | --- | --- | --- |
| 0 | Bare Hands | free | 1 | 1 |
| 1 | Rake | $8 | 1 | 2 |
| 2 | Push Reel Mower | $25 | 1 | 1 |
| 3 | Gas Push Mower | $60 | 2 | 2 |
| 4 | String Trimmer | $140 | 1 | 3 |
| 5 | Leaf Blower | $320 | 3 | 3 |
| 6 | Self-Propelled Mower | $700 | 3 | 3 |
| 7 | Hedge Trimmer | $1.5K | 2 | 3 |
| 8 | Pole Saw | $3.2K | 1 | 3 |
| 9 | Chainsaw | $6.8K | 1 | 3 |
| 10 | **Riding Mower** | $14K | 5 | 3 |
| 11 | Backpack Blower | $30K | 6 | 3 |
| 12 | **Zero-Turn** | $65K | 7 | 3 |
| 13 | Stump Grinder | $140K | 1 | 3 |
| 14 | Wood Chipper | $300K | — | — |
| 15 | **Commercial Deck** | $650K | 11 | 3 |

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

Current: all three worlds beaten in 27–30 minutes by a player who never wastes a
second — about a quarter of The House's two-hour clock and a third to a half of
the later worlds'. Real players are nowhere near optimal, so the clock should
feel tight rather than generous; The House was lengthened from ninety minutes
after a party of three ran out with the backyard barely done.

Wave scaling is invariant up to the cap: a section holds U units per wave and
needs one wave per player, so the total is N·U shared between N people and
everybody does U. Past `Worlds.MAX_WAVES` (two) the share falls on purpose: a
party of three owing three waves of every section ran out of the clock with the
backyard barely done. There is a test for both halves.

**Known tuning weakness:** the three worlds all sit near a third of the clock,
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
- **Sound and music.** No audio at all yet.
- **Tutorial.** New players get the free front yard and the HUD hints; there is
  no guided first-run sequence.
- **Art direction.** The look is placeholder geometry in a summer palette. The
  reference game is autumnal and far more detailed; matching it properly needs
  reference images, which no amount of reading its wikis will supply.
- **Interiors are shells.** The garage and basement are walled rooms with props,
  not furnished spaces, and the house itself has no interior at all.
