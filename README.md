# Mow all the lawns!

A Roblox co-op mowing game in the vein of *Clean all the leaves!*: up to a dozen
players share one overgrown property, race a completion bar against the clock,
and turn clippings into better equipment.

Cut grass into your bag → dump it at the trailer for cash → buy a wider deck, a
bigger bag, a louder engine → unlock the next zone → repeat until you are sitting
on a zero-turn clearing eleven tiles at a time.

## Getting started

You need three CLIs. [Rokit](https://github.com/rojo-rbx/rokit) installs all of
them at the pinned versions:

```sh
rokit install
```

Then sync into Studio:

```sh
rojo serve
```

…and connect from the Rojo plugin. Full walkthrough in [docs/SETUP.md](docs/SETUP.md).

## Verifying a change

```sh
./scripts/check.sh
```

That runs the whole gate: regenerate the sourcemap, typecheck every file against
the real Roblox API, run the test suite, and confirm the place still builds.

```sh
luau scripts/simulate.luau
```

Plays a virtual player through the entire ladder and prints time-to-unlock for
every tool, upgrade and property. Run it after any balance change — it is how the
curve gets tuned without grinding for hours.

## Layout

| Path | What lives there |
| --- | --- |
| `src/Shared/Config/` | Every tunable number: tools, upgrades, debris, properties, monetization, balance |
| `src/Shared/Grid.luau` | Tile-space geometry and swath rasterisation |
| `src/Shared/ChunkCodec.luau` | Tile bit packing and the chunk wire format |
| `src/Server/Services/` | Authoritative game logic |
| `src/Client/` | Rendering, input and UI |
| `tests/` | Pure-logic tests, runnable outside Studio |
| `docs/` | Design doc, setup guide, monetization setup |

## Design notes

Two decisions shape most of the codebase:

**Tiles are data, not Instances.** The world's grass lives in a `buffer`, one
byte per tile, and the server never creates a part for it. Cutting is grid maths,
not raycasts or `Touched` events. The client renders a pooled, culled window of
that buffer. This is what lets a 25,000-tile property run with a full server.

**The client only reports where it is and what it is holding.** Every cut, sale
and purchase is decided server-side, so exploit resistance falls out of the
architecture rather than being bolted on.

## Status

See [docs/GDD.md](docs/GDD.md) for the full design and the phase plan.
