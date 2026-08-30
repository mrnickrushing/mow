# Mow all the lawns! — design

A Roblox co-op mowing game in the mould of *Clean all the leaves!*. Up to a
dozen players share one overgrown property, race a completion bar against the
clock, and turn clippings into better equipment.

## The loops

**20 seconds.** Hold to mow. Grass falls in a swath as wide as your deck.
Clippings flow into your bag.

**2 minutes.** Bag fills, you walk to the trailer, it sells on approach.

**3 minutes.** Cash buys a bag or cut-speed level at the shed. You feel it
immediately.

**15 minutes.** Cash buys the next tool tier or the next zone gate — a whole new
area with denser, taller, more valuable debris.

**One round.** The server races a shared completion bar to 100% before the
timer. Scoreboard, payout, rotate to a bigger property.

Cash, tools, upgrades and zone unlocks persist across rounds and sessions. The
lawn does not.

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

## Progression

### Tools

| # | Tool | Cost | Deck | Power | Rate | Clears |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | Hand Shears | free | 1 | 1 | 1.2 | grass ≤2 |
| 1 | Rake | $12 | 1 | 2 | 1.5 | leaves |
| 2 | Push Reel Mower | $60 | 1 | 1 | 2.0 | grass ≤2 |
| 3 | Gas Push Mower | $450 | 2 | 2 | 3.0 | grass |
| 4 | String Trimmer | $2.5K | 1 | 3 | 4.0 | weeds, grass |
| 5 | Leaf Blower | $6K | 3 | 3 | 5.0 | leaves |
| 6 | Self-Propelled Mower | $9K | 3 | 3 | 4.0 | grass |
| 7 | Hedge Trimmer | $30K | 2 | 3 | 3.5 | hedges |
| 8 | Pole Saw | $60K | 1 | 3 | 2.0 | sticks |
| 9 | Chainsaw | $90K | 1 | 3 | 3.0 | sticks, trees |
| 10 | **Riding Mower** | $260K | 5 | 3 | 6.0 | grass |
| 11 | Backpack Blower | $900K | 6 | 3 | 9.0 | leaves |
| 12 | **Zero-Turn** | $2.4M | 7 | 3 | 8.0 | grass, weeds |
| 13 | Stump Grinder | $6M | 1 | 3 | 2.0 | stumps |
| 14 | Wood Chipper | $14M | — | — | — | 3x on wood |
| 15 | **Commercial Deck** | $34M | 11 | 3 | 10.0 | grass, weeds |

Tiers 10, 12 and 15 are ridden rather than carried.

### Upgrade lines

| Line | Levels | Per level |
| --- | --- | --- |
| Leaf Bag | 15 | ×1.55 capacity |
| Cut Speed | 4 | +16% |
| Mulching Blades | 12 | +18% debris |
| Work Boots | 10 | +1.8 studs/s |
| Business Sense | 10 | +15% cash |
| Fuel Tank | 8 | ×1.25 |
| Trailer Hitch | 5 | L1 unlocks the portable trailer, then +6 studs |

Cut Speed is deliberately short. A tile cannot take less than one pass, so past
a few levels the line would be selling nothing.

### Zones and properties

Two kinds of map, deliberately.

**The Starter House is a detailed residential property**, in the mould of the
game this borrows from. Nine zones, and not all of them are for sale:

| Zone | Opens by | Notes |
| --- | --- | --- |
| Front Yard | free | |
| Driveway | $500 | |
| Garage | **a hidden switch** | walled room; the switch is in the driveway |
| Rooftop | **clearing the front yard** | 24 studs up, porch stairs, parapet |
| Side Alley | $3,000 | |
| Backyard | $6,000 | trees |
| Pool Deck | $20,000 | real pool, sprinklers |
| Hedge Maze | $60,000 | hedge walls, wasps |
| Basement | $200,000 | sunken open-topped cellar, stairs down |

Two of the nine are **earned rather than bought**. A map where every door has a
price tag is a shop, not a place.

**The later five are open lots** — Corner Lot, The Ranch, The Orchard Estate,
Riverside Golf Course, The Overgrown Manor — each larger, denser and paying
more. They stay open on purpose: that is where an eleven-tile deck earns its
price. Properties unlock on lifetime earnings.

### Verticality and interiors

Zones carry an `elevation`. Since zones never overlap in X/Z, one height per
zone is enough to support both a rooftop and a cellar while the tile grid stays
flat — the rooftop takes the house's own footprint, and the basement gets its
own patch of lawn with the ground cut open above it.

Both the server's tile placement and the client's renderer read the same
`Properties.elevationAt`, so a rooftop costs nothing extra on the wire.

### Clutter is a mechanic, not decoration

Every zone scatters props — bins, planters, crates, patio chairs, barrels,
bushes; boxes and shelves indoors. A completion bar over an empty field makes
the last few percent a tedious sweep. The same bar over a cluttered yard makes
it a hunt. Props never collide, so they can hide a tile but never wall you off
from one.

## Balance

`scripts/simulate.luau` is the source of truth. It plays a virtual, ROI-optimal
player through the whole ladder and prints time-to-unlock for everything. It
runs in CI.

Current curve, roughly: first mower at 3½ minutes, gas mower at 28, riding mower
at 5¾ hours, zero-turn at 6½, commercial deck at 7, everything maxed around 7¼.
A real player is not ROI-optimal, so treat those as a floor.

**Known tuning weakness:** the endgame compresses. The top three tools land
inside about ninety minutes of each other, because income grows exponentially
while costs do not. Stretching it means raising the late tool costs and the
property payout multipliers together; the simulator will tell you immediately
whether it worked.

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
