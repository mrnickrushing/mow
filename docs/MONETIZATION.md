# Monetization setup

Every gamepass and developer product is already built. All that is missing is
the Roblox ids, which live in exactly one file:

**`src/Shared/Config/Monetization.luau`**

Until an id is filled in, that entry is treated as unconfigured: the store hides
it, purchase prompts refuse it, and the game plays start to finish without it.
Nothing else in the codebase needs to change when you paste an id in.

## How to wire one up

1. On the [Creator Dashboard](https://create.roblox.com/dashboard/creations),
   open your experience → **Monetization** → **Passes** or **Developer Products**.
2. Create the item with the name and price from the tables below.
3. Copy its id.
4. Paste it into the matching `id = 0,` line in `Monetization.luau`.

That is the whole process. Do them one at a time if you like — each becomes
available the moment its id is real.

## Gamepasses

Permanent, bought once.

| Name | Suggested | Effect |
| --- | --- | --- |
| 2x Cash | R$ 199 | Doubles everything you sell |
| 2x Bag | R$ 249 | Doubles capacity |
| Auto-Collect | R$ 399 | Cut debris drifts to you |
| VIP | R$ 499 | VIP estate, gold skins, permanent 1.25x |
| Fast Feet | R$ 149 | +30% walk speed |
| Infinite Fuel | R$ 349 | Never refuel |
| Instant Dump | R$ 599 | Sell from anywhere |

## Developer products

Consumable, bought repeatedly.

| Name | Suggested | Effect |
| --- | --- | --- |
| **Rent a Zero-Turn (2 min)** | R$ 49 | The flagship impulse buy |
| Rent a Riding Mower (2 min) | R$ 25 | A cheaper first taste |
| Fuel Can | R$ 10 | Instant refill |
| 3x Cash (5 min) | R$ 39 | Stacks with everything |
| Empty Bag | R$ 15 | Remote sell |
| Clean Sweep | R$ 99 | Clears 5% of your current zone |
| Neighbourhood Boost (10 min) | R$ 149 | 2x for the whole server, announced |
| Extend Round (+10 min) | R$ 79 | More time for everyone |

## Tool unlocks

Every paid tool is sold three ways, and only the first is free of Robux:

1. **Run cash** — the price in `Tools.luau`, earned during the run.
2. **This run** — `robuxOnce`, buys the tool for the run in progress only.
3. **Forever** — `robuxPermanent`, recorded on the profile and handed back at
   the start of every future run.

These products are **generated from the tool table**, two per paid tool, rather
than written out here: thirty hand-maintained entries would drift from the tools
they price the first time one is renamed. The keys are predictable —
`tool_<id>_run` and `tool_<id>_forever`, which `Monetization.toolProductKeys`
returns — so pasting real ids in means editing the generated loop's `id = 0` to
a lookup table keyed by that same string:

```lua
local TOOL_PRODUCT_IDS = {
    tool_rake_run = 000000000,
    tool_rake_forever = 000000000,
    -- ...
}
```

Until then the shop draws those two buttons **dead rather than hidden**, so the
card does not change shape the day the ids arrive.

The permanent kind is the only thing besides records and totals that outlives a
run. It is deliberately a head start, not a bigger number: a player who buys the
Zero-Turn outright still has to clear every section, still races the same clock,
and still cannot skip a wave. What they bought is the first ten minutes back.

## How the rental system works

Rentals are not special-cased. `BoostService` grants the tool through the same
ownership table the shop writes to, so equipping, cutting and mounting a vehicle
all work without knowing rentals exist. When the timer runs out the grant is
removed and the player gets back whatever they were holding.

Adding a new rental is a config row, not code:

```lua
{
    key = "rentCommercialDeck",
    id = 0,
    name = "Rent a Commercial Deck (90s)",
    robux = 99,
    kind = "rental",
    toolId = "commercial_deck",
    seconds = 90,
    description = "Ninety seconds, eleven tiles wide.",
},
```

Two behaviours worth knowing:

- Renting something you **already own** converts to a 2x cash boost for the
  same duration instead, so nobody pays for something they have.
- Buying the same timed boost twice **extends** it rather than replacing it.

## Keeping it fair

The free reward loops in `Monetization.rewards` exist so progression never
depends on spending:

- **Daily streak** — seven escalating days, resetting only after a two-day gap
  so players in other timezones are not punished.
- **Playtime** — cash every 8 minutes of active play.
- **Free rental** — a two-minute riding mower every 30 minutes. This is also the
  most honest advertisement the paid rentals have.
- **First completion** — a one-off bonus the first time you are on a server that
  reaches 100%.

To add a group bonus, set `rewards.groupId` to your group's id. It is off while
that is `0`.

## Receipts

`MonetizationService.ProcessReceipt` returns `NotProcessedYet` whenever a grant
cannot be completed — an unloaded profile, or a player who left before the
receipt landed. Roblox retries, rather than consuming a purchase the player
never received. Do not "simplify" this into always returning `PurchaseGranted`.
