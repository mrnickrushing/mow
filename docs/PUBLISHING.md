# Getting the game onto Roblox (and your iPad)

The `latest` release on GitHub is a **Studio file** — it never touches
Roblox's servers, which is why nothing shows up in the Roblox app. To play on
an iPad or phone, the place has to be **published to a Roblox experience**.
CI does that automatically on every merge — after a one-time setup that only
a person can do, because Roblox requires the experience itself to be created
in Studio.

## One-time setup (needs a Mac or Windows PC with Roblox Studio)

1. **Publish once from Studio.**
   Download `MowAllTheLawns.rbxlx` from
   <https://github.com/mrnickrushing/mow/releases/tag/latest>, open it in
   Roblox Studio, then **File → Publish to Roblox As…** Give it the name
   *Mow all the lawns!* and publish. This creates the experience.

2. **Copy the two ids.**
   Go to <https://create.roblox.com/dashboard/creations>, open the new
   experience, and note:
   - **Universe ID** — shown on the experience's overview page.
   - **Place ID** — the number in the start place's URL
     (`roblox.com/games/<PLACE_ID>/...`), also listed under *Places*.

3. **Make an Open Cloud API key.**
   At <https://create.roblox.com/dashboard/credentials> create an API key:
   - Access permissions: add **universe-places**, scope **write**, and
     restrict it to this one experience.
   - Accepted IP addresses: `0.0.0.0/0` (GitHub's runners have no fixed IP).
   - Copy the key — it is shown once.

4. **Paste all three into GitHub.**
   Repo → **Settings → Secrets and variables → Actions → New repository
   secret**, three times:

   | Secret name          | Value                    |
   | -------------------- | ------------------------ |
   | `ROBLOX_API_KEY`     | the Open Cloud key       |
   | `ROBLOX_UNIVERSE_ID` | the universe id          |
   | `ROBLOX_PLACE_ID`    | the start place id       |

From the next merge on, CI uploads the freshly built place to that
experience and publishes it live. Until the secrets exist, the step prints a
note and skips — nothing breaks.

## Playing it on the iPad

Open the **Roblox app** → tap your avatar (profile) → under your profile's
**Experiences / Creations** you'll find *Mow all the lawns!* → tap it →
**Play**. A private experience is playable by you, its owner; when you want
others in, set it to Public on the Creator Dashboard. Make sure the
experience's supported devices include tablet/phone (they are on by
default).

## Notes

- CI publishes the **binary** `.rbxl` (smaller, same content); the `.rbxlx`
  on the release stays for anyone who wants to read the place as XML.
- The publish endpoint is Open Cloud's
  `POST /universes/v1/{universeId}/places/{placeId}/versions?versionType=Published`.
  `versionType=Published` makes the build live immediately; change it to
  `Saved` if you ever want merges to stage without going live.
- Rotating the API key only means updating the `ROBLOX_API_KEY` secret.
