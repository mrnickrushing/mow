# Getting the game onto Roblox (and your iPad)

The experience already exists on Roblox: **Mow Money, Mow Problems!**
(universe `10764684362`, start place `71269136447904`). Two ways a build
reaches it:

- **`scripts/publish.sh`** — builds and publishes from your own computer.
  Needs `.deploy_key` in the repo root (gitignored): an Open Cloud API key
  with the **universe-places: write** scope for this experience.
- **CI, automatically on every merge** — the `Publish to Roblox` step in
  `.github/workflows/ci.yml` uploads the freshly built place through the
  same Open Cloud endpoint, live immediately. It needs one secret.

## One-time: give CI the key

1. At <https://create.roblox.com/dashboard/credentials> create (or reuse)
   an API key with access permission **universe-places → write**, restricted
   to this experience. Set accepted IPs to `0.0.0.0/0` — GitHub's runners
   have no fixed address. If you already made a key for `scripts/publish.sh`
   (`.deploy_key`), the same key works.
2. Repo → **Settings → Secrets and variables → Actions → New repository
   secret** → name `ROBLOX_API_KEY`, value = the key.

That's it — the universe and place ids are public identifiers and are
already baked in as defaults (`ROBLOX_UNIVERSE_ID` / `ROBLOX_PLACE_ID`
secrets override them if the experience ever changes). Until the secret
exists, the step prints a note and skips.

## Finding it on the iPad

The GitHub release is a Studio file and never appears in the Roblox app —
only published builds do. In the **Roblox app**:

1. Tap your **avatar / profile** (bottom bar).
2. Scroll to **Creations** (your experiences) — *Mow Money, Mow Problems!*
   is there. Direct link: <https://www.roblox.com/games/71269136447904>.
3. Tap **Play**. A private experience is playable by you as its owner;
   flip it to Public on the Creator Dashboard when you want others in.

If it does not appear under Creations, check
<https://create.roblox.com/dashboard/creations> on any browser — the
experience page also has a Play button that hands off to the app.

## Notes

- Both paths publish the **binary** `.rbxl`; the `.rbxlx` on the GitHub
  release stays for anyone who wants the place as readable XML.
- The endpoint is Open Cloud's
  `POST /universes/v1/{universeId}/places/{placeId}/versions?versionType=Published`.
  `Published` goes live immediately; `Saved` would stage without going live.
- Rotating the key = updating the `ROBLOX_API_KEY` secret (and
  `.deploy_key` locally).
