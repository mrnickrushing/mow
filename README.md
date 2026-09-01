# Mow all the lawns!

A Roblox co-op yard-clearing game in the vein of *Clean all the leaves!*. Pick a
world, arrive with nothing, and clear it section by section against a
ninety-minute clock. Each section you finish opens the gate to the next; clear
the last one and the grate opens, you walk out, and you have beaten it.

Work debris into your bag → walk to the trailer, it sells on approach → buy a
wider tool and a bigger bag → open the next gate. Cash and gear last for the run
and no longer, so every world starts from bare hands.

On a busy server a section fills back up once per player, so eight people do
eight times the work rather than finishing eight times faster.

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

Plays one run of each world from nothing and reports whether it is beatable
inside the clock, where it stalls, and what gear you finish holding. Pass a
player count (`luau scripts/simulate.luau -a 4`) to check wave scaling. Run it after
any balance change.

## Layout

| Path | What lives there |
| --- | --- |
| `src/Shared/Config/` | Every tunable number: worlds and their sections, tools, upgrades, debris, monetization, balance |
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
