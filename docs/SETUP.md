# Setting up

## 1. Install the toolchain

[Rokit](https://github.com/rojo-rbx/rokit) installs everything at the pinned
versions in `rokit.toml`:

```sh
rokit install
```

That gives you `rojo`, `luau-lsp`, `stylua` and `selene`. The test runner also
needs the standalone `luau` CLI from
[luau-lang/luau releases](https://github.com/luau-lang/luau/releases) — put it on
your PATH, or point `LUAU_BIN` at it.

## 2. Connect Studio

Install the [Rojo plugin](https://create.roblox.com/store/asset/13916111004) in
Studio, then from the repo root:

```sh
rojo serve
```

In Studio, open the Rojo plugin and click **Connect**. The whole `src/` tree
syncs in and stays live as you edit.

The place needs nothing built by hand. `WorldService` generates the ground,
house, shed, trailer, fences, trees and signs from the tables in
`src/Shared/Config/Properties.luau` the moment the server starts.

## 3. Turn on data persistence

In Studio: **Game Settings → Security → Enable Studio Access to API Services**.

Without it, saves fall back to memory only. The game is fully playable in that
mode and says so loudly in the output; nothing persists between sessions.

## 4. Play

Press **Play**. You start with hand shears on the front yard of the Starter
House.

| Key | Does |
| --- | --- |
| Hold **left mouse** / **E** | Mow |
| **B** | Open the shed (also opens when you walk up to it) |
| **G** | Open the Robux store |
| **F** | Get on or off a riding mower |
| Walk to the trailer | Sells your bag automatically |

## Verifying a change

```sh
./scripts/check.sh
```

Regenerates the sourcemap, typechecks every file against the real Roblox API,
runs the test suite, and builds the place. All four must pass.

```sh
luau scripts/simulate.luau
```

Plays a virtual player through the whole ladder and prints time-to-unlock for
every tool, upgrade and property. Run it after **any** balance change.

## Where things live

| Path | What it is |
| --- | --- |
| `src/Shared/Config/` | Every tunable number in the game |
| `src/Shared/Grid.luau` | Tile geometry and swath rasterisation |
| `src/Shared/ChunkCodec.luau` | Tile bit packing and the wire format |
| `src/Shared/Cutting.luau` | What one tool does to one tile — used by both sides |
| `src/Server/Services/` | Authoritative game logic |
| `src/Client/` | Rendering, input and UI |

## Common problems

**"Grass does not appear."** The client asks for chunks as it walks into them.
If nothing renders at all, check the output for a `MowRemotes` warning — the
client waits 30 seconds for the server to create the remote folder.

**"Progress is not saving."** Studio API access is off (step 3). The output says
`running memory-only` when this is the case.

**"Typecheck fails on a fresh clone."** `scripts/check.sh` downloads the Roblox
API definitions into `.tools/` on first run. It needs network access once.
