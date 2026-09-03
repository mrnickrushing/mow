--!strict
--[[
	GameConfig — global tuning constants.

	Grid geometry, network rates and render budgets live here. These are the
	numbers you reach for when the game feels wrong at a system level; per-item
	balance lives in Tools/Upgrades/Debris/Worlds.
]]

local GameConfig = {
	--------------------------------------------------------------------
	-- Identity
	--------------------------------------------------------------------
	-- The name it is published under. The loading screen spells this out for
	-- itself (ReplicatedFirst cannot wait on this module), so a rename touches
	-- both.
	GAME_NAME = "Mow Money, Mow Problems!",

	--------------------------------------------------------------------
	-- Grid geometry
	--------------------------------------------------------------------
	--- Side length of one tile, in studs.
	TILE_SIZE = 4,
	--- Tiles per chunk side. A chunk is the unit of replication.
	CHUNK_TILES = 8,
	--- Maximum debris height level. Height 0 means "clean".
	MAX_HEIGHT = 3,
	--- Studs of visual height per height level.
	HEIGHT_STUD = 0.8,
	--- Y coordinate of the lawn surface.
	GROUND_Y = 0,

	--[[
		The house, in studs, shared because two modules have to agree on it.

		The builder raises the walls and caps them; the level config decides
		how high the Rooftop's floor sits. When the builder owned these
		numbers privately and the config guessed at them, the guess was four
		studs low and the whole Rooftop was built inside the roof. Neither
		side guesses now.
	]]
	HOUSE_ROOF_HEIGHT = 24,
	--- Brick foundation the walls stand on.
	HOUSE_FOUNDATION = 4,
	--- How far the capped roof slab sits above the wall top, and its depth.
	HOUSE_ROOF_RISE = 3,
	HOUSE_ROOF_THICKNESS = 2.4,

	--------------------------------------------------------------------
	-- Network
	--------------------------------------------------------------------
	--- How often the client reports a mow intent, in Hz.
	MOW_INTENT_HZ = 10,
	--- How often the server flushes dirty chunks, in Hz.
	REPLICATION_HZ = 10,
	--- Server rejects intents arriving faster than this, in Hz. Slack over
	--- MOW_INTENT_HZ absorbs jitter without allowing a meaningful speed-up.
	MOW_INTENT_MAX_HZ = 15,
	--- An intent whose claimed position is further than this from the player's
	--- actual root part is discarded, in studs.
	MOW_POSITION_TOLERANCE = 28,
	--- Only replicate live chunk deltas to clients within this many studs.
	REPLICATION_RADIUS = 420,

	--------------------------------------------------------------------
	-- Client rendering
	--------------------------------------------------------------------
	--[[
		Tiles within this radius of the camera render as individual parts.

		Beyond it a whole chunk becomes one flat slab, so this is where the
		lawn stops being leaves and starts being a colour — and at fifty-six
		studs that seam landed close enough to the player to read as a hard
		line drawn across the grass. Pushed out far enough that the change
		happens in the middle distance, where the haze and the falling detail
		hide it, and still inside the part budget: a seventy-two stud radius is
		about a thousand tiles, four parts each at worst.
	]]
	DETAIL_RADIUS = 72,
	--- Chunks within this radius render as a single flat LOD plane.
	LOD_RADIUS = 460,
	--- Hard ceiling on pooled tile parts, protecting low-end devices.
	MAX_TILE_PARTS = 6000,
	--- How often the renderer rebuilds its visible set, in Hz.
	RENDER_REFRESH_HZ = 8,

	--------------------------------------------------------------------
	-- Economy
	--------------------------------------------------------------------
	--- What a run opens with. Read by `RunState.fresh`, which used to hard-code
	--- a zero beside it and leave this saying nothing.
	STARTING_CASH = 0,
	--- Bag units a fresh account can carry.
	BASE_BAG_CAPACITY = 25,
	BASE_WALK_SPEED = 16,
	BASE_FUEL = 100,
	--- Radius in studs within which the trailer accepts a dump.
	BASE_DUMP_RADIUS = 12,

	-- Seconds a full bag takes to pour into the trailer. The pour is the
	-- paycheck moment — one gold number counting up as the clippings stream in
	-- — so it is deliberately not instant, whatever the bag's size.
	BAG_EMPTY_SECONDS = 2.5,
	--[[
		Tips a player earns for finishing a property, at a full share of the
		work.

		`run.contribution` counts the levels each player has cut and says in
		its own declaration that it is "for the contribution split and the
		scoreboard". Nothing read either it or this number: winning paid
		exactly nothing beyond unlocking the next property, so a four-player
		team rewarded the one who stood still exactly as well as the three who
		mowed.

		The pool is this many tips per player in the run, divided by share of
		the work — so a solo player who finishes earns the whole of it, a team
		of four pulling evenly earn it each, and somebody who cut a tenth of
		what the others did earns a tenth. Tips rather than cash, because cash
		granted at the end of a run is wiped by the start of the next one.

		Sized against a run that already pays roughly eighty tips: enough that
		finishing is plainly worth more than mowing about for the same time,
		not so much that it moves the permanent tools within easy reach.
	]]
	ROUND_COMPLETION_BONUS = 25,

	--------------------------------------------------------------------
	-- Round flow
	--------------------------------------------------------------------
	INTERMISSION_SECONDS = 45,
	--- Zone completion above this fraction switches on missed-spot markers.
	-- Cash bonus each finished section adds to everyone's multiplier for the
	-- rest of the run. This is the run's progression spine: the world literally
	-- pays better the more of it you have cleaned.
	SECTION_CASH_BOOST = 0.3,

	MISSED_SPOT_THRESHOLD = 0.95,
	--- Cap on simultaneously highlighted missed tiles.
	MISSED_SPOT_MAX_MARKERS = 24,

	--------------------------------------------------------------------
	-- Feel
	--------------------------------------------------------------------
	--- Wet grass (sprinklers) multiplies cut rate by this.
	WET_CUT_PENALTY = 0.5,
	--- Walk speed multiplier while a wasp sting is wearing off.
	STING_WALK_PENALTY = 0.45,
	--- Tools at or below this tier stall outright in wet grass.
	WET_STALL_MAX_TIER = 3,
	--- Tiles in a row, in one straight line, to bank a Clean Stripe bonus.
	--[[
		Short enough to earn on the bag you start with.

		A stripe wanted twelve tiles. Grass is four units a level and a
		starting bag holds twenty-five, so twelve tiles of it is somewhere
		between forty-eight and ninety-six units — the bag fills at about
		five and cutting stops. The one piece of skill in the game was
		unreachable until two or three bag upgrades in, which is long after
		the moment it would have taught somebody to mow in straight lines.

		Six tiles of short grass is twenty-four units: it just fits, so the
		first clean stripe can happen on the first lawn. The bonus is per
		tile, so a short stripe still pays a short stripe's worth.
	]]
	STRIPE_MIN_TILES = 6,
	--- Cash per tile awarded for a completed stripe.
	STRIPE_BONUS_PER_TILE = 0.04,
	--- Tips awarded per completed stripe.
	STRIPE_TIP_REWARD = 1,
	--- Degrees of heading drift tolerated before a stripe breaks.
	STRIPE_MAX_DRIFT = 14,

	--------------------------------------------------------------------
	-- Persistence
	--------------------------------------------------------------------
	--[[
		What a lobby game pad is called.

		The server builds them and the client watches for them to know when to
		open the settings panel, so the name crosses the wire and belongs in
		one place. It was written out on both sides, and the moment the pads
		were renamed from `TeamPad` to `GamePad` the panel stopped opening —
		which is exactly the "nothing happens when I stand on the pad" the pads
		were rebuilt to fix.
	]]
	LOBBY_PAD_PREFIX = "GamePad",

	--[[
		The largest team one pad, one lobby, or one journal page has to plan
		for.

		Written independently as `LobbyService.GAME_SLOTS`,
		`LevelSelect.MAX_PARTY` and a bare `for order = 1, 4` in the journal's
		player list, which is the same shape of duplication that made the
		`GamePad` rename above break the level select panel: three unlinked
		copies of one number, agreeing today only because nobody has changed
		one of them yet.
	]]
	MAX_PARTY = 4,

	DATASTORE_NAME = "MowAllTheLawns_PlayerData_v1",
	--[[
		How often a profile is written back — which is also, and this is the
		part that mattered, how often its session lock is told somebody is
		still holding it. `Store.save` is the only thing that refreshes
		`lockHeartbeat`, and the autosave loop is the only thing that calls it
		while a player is playing.

		It was a hundred and twenty seconds against a ninety second timeout, so
		every live player's own lock read as dead for thirty seconds out of
		every two minutes, from their first minute onward. Store's comment
		about waiting for a lock says "once the holder stops beating,
		`lockIsLive` goes false on its own" — it was going false while the
		holder was still beating, which is the whole failure the lock exists to
		prevent: two servers holding one save, last writer wins, the other's
		progress gone.

		Three beats inside every timeout window now, so one missed or throttled
		save cannot open the hole. It also halves the progress a crash can
		take with it, which is the other thing autosave is for.
	]]
	AUTOSAVE_SECONDS = 30,
	--- Seconds before another server may steal a stale session lock. Must stay
	--- comfortably above AUTOSAVE_SECONDS; there is a test.
	SESSION_LOCK_TIMEOUT = 90,
}

--- Studs per chunk side.
GameConfig.CHUNK_STUDS = GameConfig.CHUNK_TILES * GameConfig.TILE_SIZE

--- The top face of a walkable capped roof: what a Rooftop section stands on.
GameConfig.HOUSE_ROOF_TOP = GameConfig.HOUSE_FOUNDATION
	+ (GameConfig.HOUSE_ROOF_HEIGHT - 4)
	+ GameConfig.HOUSE_ROOF_RISE
	+ GameConfig.HOUSE_ROOF_THICKNESS * 0.5

return GameConfig
