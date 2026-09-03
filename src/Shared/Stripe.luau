--!strict
--[[
	Stripe — the geometry of a clean stripe, with no Roblox in it.

	This lived inside StripeService, where it could not be tested: the service
	reads characters and fires remotes, so nothing in the suite could ever ask
	it what a stripe was. That is how it came to measure one by counting the
	distinct tiles cut, which for a deck eleven tiles across counted eleven
	tiles for every step and turned the length of a stripe into the area the
	mower covered. It sits beside Grid for the same reason Grid does: it is a
	rule about ground, and a rule nothing can check is a rule that drifts.

	A stripe is a distance: how far the player has driven along the heading
	they started on. The tile set stays, but only as proof that work happened,
	so standing still on one tile is worth nothing.
]]

local GameConfig = require(script.Parent.Config.GameConfig)

local Stripe = {}

export type State = {
	--- Heading the stripe was started on, as a unit vector in world space.
	dirX: number,
	dirZ: number,
	--- Where it began, and the furthest along the heading the player has since
	--- got, in studs. A maximum, so backing up cannot shorten a stripe that
	--- has already been cut.
	startX: number,
	startZ: number,
	along: number,
	--- Distinct tiles cut. Proof of work, not length.
	tiles: number,
	seen: { [number]: boolean },
	lastAt: number,
}

--- A stripe lapses if no cutting happens for this long.
Stripe.IDLE_TIMEOUT = 1.2

local MAX_DRIFT_COS = math.cos(math.rad(GameConfig.STRIPE_MAX_DRIFT))

function Stripe.new(dirX: number, dirZ: number, atX: number, atZ: number, now: number): State
	return {
		dirX = dirX,
		dirZ = dirZ,
		startX = atX,
		startZ = atZ,
		along = 0,
		tiles = 0,
		seen = {},
		lastAt = now,
	}
end

--- Length in tiles, which is what the minimum and the bonus are both measured
--- in. Zero until something has actually been cut.
function Stripe.length(state: State): number
	if state.tiles <= 0 then
		return 0
	end
	return math.floor(state.along / GameConfig.TILE_SIZE) + 1
end

--[[
	Whether a cut made now, on this heading, carries the stripe on.

	False means the stripe is over — banked if it was long enough, and a new
	one started from here — which happens when the player turns past
	STRIPE_MAX_DRIFT or stops cutting for longer than the idle timeout.
]]
function Stripe.continues(state: State, dirX: number, dirZ: number, now: number): boolean
	if now - state.lastAt > Stripe.IDLE_TIMEOUT then
		return false
	end
	return state.dirX * dirX + state.dirZ * dirZ >= MAX_DRIFT_COS
end

--- Records one cut tile against the stripe.
function Stripe.record(state: State, atX: number, atZ: number, tileIndex: number, now: number)
	state.lastAt = now

	local along = (atX - state.startX) * state.dirX + (atZ - state.startZ) * state.dirZ
	state.along = math.max(state.along, along)

	if not state.seen[tileIndex] then
		state.seen[tileIndex] = true
		state.tiles += 1
	end
end

return Stripe
