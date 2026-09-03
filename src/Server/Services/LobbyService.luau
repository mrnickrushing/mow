--!strict
--[[
	LobbyService — the yard you stand in between runs.

	Choosing a property used to be a panel that covered the screen: you finished
	a run, a dark card appeared over the world, you clicked a row. It worked, and
	it read as a menu bolted to a game rather than a place in it.

	This is the same choice made with your feet. Four pads set the size of the
	team, because the work scales with how many hands are on it and a team of
	three should be able to say so. Three plaques pick the property, locked ones
	saying what has to be beaten first. Stand on a pad, pick a property, and the
	countdown takes everyone in.

	The lobby is built once, a long way from any lot, and never torn down: a run
	loads and unloads a property under `MowWorld`, and the lobby sits outside it
	so that arriving back is a move rather than a rebuild.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Palette = require(Shared.Config.Palette)
local Remotes = require(Shared.Remotes)
local Worlds = require(Shared.Config.Worlds)
local Build = require(script.Parent.Parent.Lib.Build)
local DataService = require(script.Parent.DataService)
local MowEconomyService = require(script.Parent.EconomyService)
local MowRunService = require(script.Parent.RunService)
local MatchmakingService = require(script.Parent.MatchmakingService)

local LobbyService = {}

--- Far enough from every lot that nothing can ever overlap it.
local CENTRE = Vector3.new(-600, 0, -600)
local FLOOR_W, FLOOR_D = 260, 260
--- Games that can be set up side by side in the yard, and the most people
--- any one of them can take.
local GAME_SLOTS = 4
--- Seconds between a team being ready and the property loading.
local COUNTDOWN = 6

local folder: Folder? = nil
--[[
	A game somebody can join, of which there are `GAME_SLOTS`.

	Each carries its own map, party size and countdown, so two groups in the
	yard are setting up two runs rather than fighting over one.
]]
export type Slot = {
	index: number,
	pad: BasePart,
	padLabel: TextLabel,
	boardLabel: TextLabel,
	worldId: string?,
	cap: number,
	countdown: number?,
}

local slots: { Slot } = {}
local statusLabel: TextLabel? = nil
--- The board over the pads that says how many of you are going.
local outcomeLabel: TextLabel? = nil

--[[
	The party size the pads were set to, from the settings panel.

	The room could only ever count how many people were standing on pads. It
	had no way to say how many you were *waiting* for, which is why a lone
	player had nothing telling them one was a valid answer. Defaults to the
	full four, so the behaviour without the panel is what it always was.
]]
--- What the last run did, so the lobby can say so rather than a panel.
local lastOutcome: string? = nil
local lastWorldName: string? = nil
local lastPhase = "lobby"

--------------------------------------------------------------------
-- Building
--------------------------------------------------------------------

--[[
	Text in this room lives on surfaces, not on billboards.

	A BillboardGui is drawn at a fixed pixel size however far away it is, so a
	sign fifty studs behind another sign lands on top of it: the first build of
	this lobby was four legible words and a pile of overlapping ones. A board is
	a board — it shrinks with distance, it sits where it was put, and two of
	them never occupy the same piece of screen.
]]
local function surface(part: BasePart, face: Enum.NormalId, scale: number): TextLabel
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 24
	gui.LightInfluence = 0
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(0.92, scale)
	label.Position = UDim2.fromScale(0.04, (1 - scale) * 0.5)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Text = ""
	label.Parent = gui
	return label
end

--[[
	A heading painted on the floor rather than stood up on a post.

	The first pass put both headings on boards at head height, which put a wall
	across the room: from the door you read "YOUR TEAM" and saw nothing else,
	because the sign was between you and the pads it was naming. Words on the
	floor label the thing you are walking towards without standing in front of
	it.
]]
local function floorHeading(name: string, width: number, at: Vector3, parent: Instance): TextLabel
	--[[
		Turned a quarter, because a Top face reads across the part's Z.

		Laid out the obvious way — long along X — the words came out running
		up the strip instead of along it, and turned the other way they came
		out mirrored. The strip is built long along Z and turned to face, so
		the footprint is the same and the sentence reads left to right.
	]]
	local strip = Build.part({
		name = name,
		size = Vector3.new(7, 0.3, width),
		cframe = CFrame.new(at + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, math.rad(-90), 0),
		color = Palette.color(Palette.house.trim),
		material = Enum.Material.SmoothPlastic,
		canCollide = false,
		parent = parent,
	})
	return surface(strip, Enum.NormalId.Top, 0.8)
end

local function pad(name: string, at: Vector3, colour: Color3, parent: Instance, span: number?): (BasePart, TextLabel)
	local size = span or 14
	local part = Build.part({
		name = name,
		size = Vector3.new(size, 1, size),
		cframe = CFrame.new(at + Vector3.new(0, 0.5, 0)) * CFrame.Angles(0, math.rad(-90), 0),
		color = colour,
		material = Enum.Material.SmoothPlastic,
		parent = parent,
	})
	part.TopSurface = Enum.SurfaceType.Smooth
	return part, surface(part, Enum.NormalId.Top, 0.55)
end

--[[
	The yard itself.

	It is a lawn with a fence round it, because that is what this game is about
	and because a grey slab in the void is a menu with walls. Big enough to walk
	about in while you decide, a path down the middle so the route to the pads
	is obvious, and everything that has to be read either painted on the ground
	or stood behind the thing it names.
]]
local function build()
	if folder then
		return
	end
	local root = Build.folder("MowLobby", workspace)
	folder = root
	local rng = Random.new(20260902)

	Build.part({
		name = "Lawn",
		size = Vector3.new(FLOOR_W, 2, FLOOR_D),
		cframe = CFrame.new(CENTRE - Vector3.new(0, 1, 0)),
		color = Palette.color(Palette.ground.lawn),
		material = Enum.Material.Grass,
		parent = root,
	})

	--[[
		A picket fence on all four sides, open where you arrive.

		The gap matters more than the fence: a yard you cannot see out of is a
		room, and the point of standing here is that it feels like the front of
		somebody's house.
	]]
	local halfW, halfD = FLOOR_W * 0.5, FLOOR_D * 0.5
	local fences = Build.folder("Fences", root)
	local corners = {
		{ CENTRE + Vector3.new(-halfW, 0, -halfD), CENTRE + Vector3.new(halfW, 0, -halfD) },
		{ CENTRE + Vector3.new(-halfW, 0, -halfD), CENTRE + Vector3.new(-halfW, 0, halfD) },
		{ CENTRE + Vector3.new(halfW, 0, -halfD), CENTRE + Vector3.new(halfW, 0, halfD) },
		-- The near side, in two runs with the gate between them.
		{ CENTRE + Vector3.new(-halfW, 0, halfD), CENTRE + Vector3.new(-18, 0, halfD) },
		{ CENTRE + Vector3.new(18, 0, halfD), CENTRE + Vector3.new(halfW, 0, halfD) },
	}
	for _, run in corners do
		Build.picketFence(fences, run[1], run[2], 9, false)
	end

	-- A path from the gate to the plaques, so the way in is a way somewhere.
	Build.flagstone(
		root,
		CENTRE + Vector3.new(0, 1.15, 20),
		Vector2.new(16, 190),
		5,
		rng
	)

	--------------------------------------------------------------------
	-- The games on offer
	--------------------------------------------------------------------

	--[[
		One pad, one game.

		The room used to have a single property choice shared by everybody in
		it: three plaques you stood on, four pads you stood on afterwards, and
		one `chosenWorld` between the lot. With one group in the yard that
		works. With two it is a fight — whoever last touched a plaque decides
		where the other four are about to be sent — and on a fifty-player
		server it is chaos.

		A pad is a game now. It carries its own map, its own party size and its
		own countdown, so four groups can be setting up four different runs
		side by side without touching each other. Standing on one opens the
		settings for that game; the board behind it says what it is.
	]]
	for index = 1, GAME_SLOTS do
		local x = (index - (GAME_SLOTS + 1) * 0.5) * 62
		local at = CENTRE + Vector3.new(x, 1.5, 22)
		local padPart, padLabel = pad(
			`GamePad{index}`,
			at,
			Palette.color(Palette.ground.stone),
			root,
			24
		)

		-- The board behind it, at head height and low enough that four of them
		-- in a row do not wall the yard off from its own marquee.
		local board = Build.part({
			name = `GameBoard{index}`,
			size = Vector3.new(40, 11, 1),
			cframe = CFrame.lookAt(
				CENTRE + Vector3.new(x, 10, 2),
				CENTRE + Vector3.new(x, 10, 3)
			),
			color = Palette.color(Palette.house.trim),
			material = Enum.Material.SmoothPlastic,
			parent = root,
		})
		for _, side in { -1, 1 } do
			Build.part({
				name = "BoardLeg",
				size = Vector3.new(1, 10, 1),
				cframe = CFrame.new(CENTRE + Vector3.new(x + side * 17, 5, 2)),
				color = Palette.color(Palette.fence.rail),
				material = Enum.Material.SmoothPlastic,
				parent = root,
			})
		end

		slots[index] = {
			index = index,
			pad = padPart,
			padLabel = padLabel,
			boardLabel = surface(board, Enum.NormalId.Front, 0.8),
			worldId = nil,
			cap = GAME_SLOTS,
			countdown = nil,
		}
	end

	local heading = floorHeading("PickSign", 96, CENTRE + Vector3.new(0, 1.9, 58), root)
	heading.Text = "STAND ON A PAD TO START A GAME"

	--------------------------------------------------------------------
	-- The yard it is all standing in
	--------------------------------------------------------------------

	--[[
		A lawn-care depot, not a lawn with signs on it.

		The room had a floor, a fence, some trees and its lettering, and that
		was the whole of it — which is exactly what it looked like. The game
		ships seventy-three props and the lobby used two of them.

		Everything below is built from those: the shed the tools are kept in,
		the trailer and the mowers parked beside it, the lamps down the path,
		crates and barrels and a dog. Nothing is imported for it. A free model
		off the marketplace is the usual way a published Roblox game acquires
		a backdoor, and there is nothing here that needs one.
	]]
	local yard = Build.folder("Yard", root)

	-- The way in: a gate you walk under, with the name over it.
	for _, side in { -1, 1 } do
		Build.mesh({
			prop = "Column",
			name = "ArchColumn",
			size = Vector3.new(4, 20, 4),
			cframe = CFrame.new(CENTRE + Vector3.new(side * 20, 10, 96)),
			parent = yard,
		})
	end
	local archBoard = Build.part({
		name = "ArchSign",
		size = Vector3.new(48, 8, 1.4),
		cframe = CFrame.lookAt(
			CENTRE + Vector3.new(0, 22, 96),
			CENTRE + Vector3.new(0, 22, 97)
		),
		color = Palette.color(Palette.house.trim),
		material = Enum.Material.SmoothPlastic,
		parent = yard,
	})
	surface(archBoard, Enum.NormalId.Front, 0.72).Text = GameConfig.GAME_NAME

	--[[
		Lamps down both sides of the path.

		Placed off the walked line rather than on it: the path is the one part
		of this room every player crosses, and a lamp post in the middle of it
		is a thing to get stuck on.
	]]
	for _, z in { 86, 58, 14, -22, -70 } do
		for _, side in { -1, 1 } do
			Build.part({
				name = "LampPost",
				size = Vector3.new(0.9, 11, 0.9),
				cframe = CFrame.new(CENTRE + Vector3.new(side * 26, 5.5, z)),
				color = Palette.color(Palette.fence.rail),
				material = Enum.Material.SmoothPlastic,
				parent = yard,
			})
			local lamp = Build.mesh({
				prop = "Lantern",
				name = "Lantern",
				size = Vector3.new(2.6, 3.9, 2.4),
				cframe = CFrame.new(CENTRE + Vector3.new(side * 26, 12.6, z)),
				canCollide = false,
				parent = yard,
			})
			local glow = Instance.new("PointLight")
			glow.Color = Color3.fromRGB(255, 226, 158)
			glow.Range = 34
			glow.Brightness = 1.1
			glow.Parent = lamp
		end
	end

	-- The shed the whole business runs out of, off the left of the path.
	local shedAt = CENTRE + Vector3.new(-92, 0, 8)
	Build.mesh({
		prop = "Shed",
		name = "Shed",
		size = Vector3.new(32, 36, 32),
		cframe = CFrame.new(shedAt + Vector3.new(0, 18, 0)) * CFrame.Angles(0, math.rad(90), 0),
		collisionSize = Vector3.new(30, 34, 30),
		parent = yard,
	})
	Build.flagstone(yard, shedAt + Vector3.new(20, 1.15, 0), Vector2.new(26, 34), 5, rng)
	for index, spec in {
		{ prop = "Crate", size = Vector3.new(5, 3, 4), at = Vector3.new(22, 1.5, 18) },
		{ prop = "Crate", size = Vector3.new(5, 3, 4), at = Vector3.new(27, 1.5, 15) },
		{ prop = "Barrel", size = Vector3.new(4, 4.2, 4), at = Vector3.new(21, 2.1, -14) },
		{ prop = "Sack", size = Vector3.new(3, 4, 3.3), at = Vector3.new(26, 2, -18) },
		{ prop = "Toolbox", size = Vector3.new(3, 2.4, 1.8), at = Vector3.new(18, 1.2, -6) },
	} do
		Build.mesh({
			prop = spec.prop,
			name = spec.prop,
			size = spec.size,
			cframe = CFrame.new(shedAt + spec.at) * CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0),
			canCollide = false,
			parent = yard,
		})
		local _ = index
	end

	-- The kit, parked on the right where you can see what you are working for.
	local parkAt = CENTRE + Vector3.new(92, 0, 8)
	Build.flagstone(yard, parkAt, Vector2.new(46, 60), 6, rng)
	Build.mesh({
		prop = "Trailer",
		name = "Trailer",
		size = Vector3.new(10, 6.1, 15),
		cframe = CFrame.new(parkAt + Vector3.new(4, 3, -20)) * CFrame.Angles(0, math.rad(90), 0),
		collisionSize = Vector3.new(7, 4, 14),
		parent = yard,
	})
	for index, z in { 6, 20 } do
		Build.mesh({
			prop = "RidingMower",
			name = "RidingMower",
			size = Vector3.new(6.6, 7.2, 11.2),
			cframe = CFrame.new(parkAt + Vector3.new(index * 2 - 3, 3.6, z))
				* CFrame.Angles(0, math.rad(if index == 1 then 96 else 84), 0),
			collisionSize = Vector3.new(5, 5, 9),
			parent = yard,
		})
	end
	Build.mesh({
		prop = "Dog",
		name = "Dog",
		size = Vector3.new(2.4, 5.6, 4.6),
		cframe = CFrame.new(parkAt + Vector3.new(-16, 2.8, -6)) * CFrame.Angles(0, math.rad(-40), 0),
		canCollide = false,
		parent = yard,
	})

	-- Hedges framing the depot, so the middle of the yard reads as a place
	-- rather than as the gap between two piles of props.
	for _, side in { -1, 1 } do
		Build.hedge(
			yard,
			CENTRE + Vector3.new(side * 58, 0, 40),
			CENTRE + Vector3.new(side * 58, 0, -28),
			5,
			4
		)
	end

	--------------------------------------------------------------------
	-- The board at the far end
	--------------------------------------------------------------------

	local statusPost = Build.part({
		name = "StatusBoard",
		size = Vector3.new(120, 30, 1.5),
		--[[
			Raised, so the lawn signs at the near end cannot stand in front of
			it. A six-stud board thirty studs from the gate subtends more of
			the view than a thirty-stud board two hundred studs away, which is
			how the old arrangement managed to hide its own marquee.
		]]
		cframe = CFrame.lookAt(
			CENTRE + Vector3.new(0, 40, -112),
			CENTRE + Vector3.new(0, 40, -111)
		),
		color = Palette.color(Palette.house.trim),
		material = Enum.Material.SmoothPlastic,
		parent = root,
	})
	for _, side in { -1, 1 } do
		Build.part({
			name = "BoardPost",
			size = Vector3.new(3, 55, 3),
			cframe = CFrame.new(CENTRE + Vector3.new(side * 56, 27.5, -112)),
			color = Palette.color(Palette.fence.rail),
			material = Enum.Material.SmoothPlastic,
			parent = root,
		})
	end
	--[[
		The board's top line, and what it says when there is no news.

		It only ever carried the result of the run you just came back from,
		which meant that on the one view every player is guaranteed to see —
		the first time they arrive, before they have played anything — the
		largest object in the game was a hundred and twenty studs of blank
		board with one line of instruction pushed into its bottom half. It
		reads as the game's masthead until there is an outcome to report.
	]]
	outcomeLabel = surface(statusPost, Enum.NormalId.Front, 0.32)
	local outcome = outcomeLabel :: TextLabel
	outcome.Position = UDim2.fromScale(0.04, 0.08)
	outcome.Text = GameConfig.GAME_NAME
	statusLabel = surface(statusPost, Enum.NormalId.Front, 0.38)
	local status = statusLabel :: TextLabel
	status.Position = UDim2.fromScale(0.04, 0.52)
	status.Text = "Stand on a pad and pick a property"

	--------------------------------------------------------------------
	-- Dressing
	--------------------------------------------------------------------

	-- Trees down both flanks, well clear of anything anybody has to read.
	for _, side in { -1, 1 } do
		for _, z in { 96, 58, 16, -30, -76 } do
			Build.mesh({
				prop = "Tree",
				name = "Tree",
				size = Vector3.new(24, 34, 24),
				collisionSize = Vector3.new(4, 30, 4),
				cframe = CFrame.new(CENTRE + Vector3.new(side * (halfW - 20), 17, z))
					* CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0),
				parent = root,
			})
		end
	end

	-- Hedges along the inside of the flanks, and a few bushes about.
	for _, side in { -1, 1 } do
		Build.hedge(
			root,
			CENTRE + Vector3.new(side * (halfW - 34), 1, -100),
			CENTRE + Vector3.new(side * (halfW - 34), 1, 100),
			8,
			7
		)
	end
	for _ = 1, 14 do
		local x = rng:NextNumber(-halfW + 30, halfW - 30)
		local z = rng:NextNumber(-halfD + 24, halfD - 24)
		if math.abs(x) > 34 then
			Build.mesh({
				prop = "Bush",
				name = "Bush",
				size = Vector3.new(7, 7, 7),
				cframe = CFrame.new(CENTRE + Vector3.new(x, 3.5, z))
					* CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0),
				canCollide = false,
				parent = root,
			})
		end
	end
end

--[[
	Standing on a pad means standing on the pad.

	This used to be a fixed seven-stud radius, which was smaller than the
	plaques it was testing: you could be stood squarely on The Gas Station with
	both feet on the stone and have the lobby decide you were on the grass. The
	pad's own footprint is the answer, with a stud of forgiveness at the edge.
]]
local function standingOn(part: BasePart, position: Vector3): boolean
	local offset = position - part.Position
	local reach = part.Size.X * 0.5 + 1
	return math.abs(offset.X) <= reach and math.abs(offset.Z) <= reach and math.abs(offset.Y) < 12
end

--- Everyone in the lobby right now, and where they are standing.
local function positions(): { [Player]: Vector3 }
	local out: { [Player]: Vector3 } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			out[player] = root.Position
		end
	end
	return out
end

--- Puts a player in the lobby, facing the property plaques.
function LobbyService.place(player: Player)
	build()
	local character = player.Character
	if not character or not character.PrimaryPart then
		return
	end
	local at = CENTRE + Vector3.new(0, 5, 104)
	character:PivotTo(CFrame.lookAt(at, at - Vector3.new(0, 0, 20)))
end

local function placeEveryone()
	for _, player in Players:GetPlayers() do
		LobbyService.place(player)
	end
end

--------------------------------------------------------------------
-- The loop
--------------------------------------------------------------------

--[[
	The game a player is standing on, if any.

	Settings are confirmed against a pad rather than against the room, which
	is the whole point of there being four of them: two groups setting up at
	once are setting up two games, not overwriting one.
]]
local function slotUnder(player: Player): Slot?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	for _, slot in slots do
		if standingOn(slot.pad, root.Position) then
			return slot
		end
	end
	return nil
end

--[[
	The plaques say what a property asks of you.

	A board in the world is seen by everyone at once, so it cannot show one
	player their own progress — it names the requirement instead, and whether
	the person standing on it has met that is settled when they stand on it.
]]

--[[
	One tick of the lobby.

	Occupancy is measured rather than touched: a `Touched` event fires on a
	brushed elbow and never fires again while you stand still, which is the
	opposite of what a pad wants to know.
]]
--[[
	Whether the team that is about to leave may play this property.

	`chosenWorld` is sticky on purpose: you step on a plaque to pick, then walk
	the ninety studs back to a team pad, and the choice has to survive the
	walk. What it also survived was the chooser. The plaque checks the record
	of the player standing on it — "It is the stepper's own record that decides
	now" — and then nothing ever looked again, so the team that actually
	departed was never the team that was tested. A player who has beaten The
	House could tap The Mansion, wander off, and the next first-timer to stand
	on a team pad was sent there alone.

	At least one of the departing players has to have earned it, which leaves
	a friend able to bring somebody along — the pads are a team, and a team of
	four going where one of them has been is the point of the room — while the
	empty case, where nobody leaving has the world open at all, is refused.
]]
local function teamAllows(team: { Player }, worldId: string): boolean
	local world = Worlds.expect(worldId)
	local required = world.requiresWorld
	if not required then
		return true
	end
	for _, player in team do
		local profile = DataService.get(player)
		if profile and profile.worldsBeaten[required] == true then
			return true
		end
	end
	return false
end

--[[
	One tick of the lobby: every game on offer, considered on its own.

	Occupancy is measured rather than touched: a `Touched` event fires on a
	brushed elbow and never fires again while you stand still, which is the
	opposite of what a pad wants to know.
]]
local function step(delta: number)
	if MowRunService.phase() ~= "lobby" then
		return
	end
	local where = positions()
	local anyReady = false

	for _, slot in slots do
		--[[
			Who is standing on this pad, in a stable order.

			`positions()` is a map keyed by player, and iterating one of those
			gives no order at all — so without sorting, the party that gets cut
			at the cap would be a different four every tick.
		]]
		local here: { Player } = {}
		for player, position in where do
			if standingOn(slot.pad, position) then
				table.insert(here, player)
			end
		end
		table.sort(here, function(a, b)
			return a.UserId < b.UserId
		end)

		local team: { Player } = {}
		local waiting = false
		for _, player in here do
			if DataService.get(player) == nil then
				--[[
					Stood on the pad, but their save has not landed yet.

					A run built before the profile arrives is a run without the
					tools they paid Robux for, so the pad waits rather than
					sending them into one.
				]]
				waiting = true
			elseif #team < slot.cap then
				table.insert(team, player)
			end
		end

		local world = if slot.worldId then Worlds.get(slot.worldId) else nil
		local ready = #team > 0
			and world ~= nil
			and teamAllows(team, slot.worldId :: string)

		if ready then
			anyReady = true
			slot.countdown = (slot.countdown or COUNTDOWN) - delta
			local left = math.max(math.ceil(slot.countdown or 0), 0)
			slot.padLabel.Text = `{#team}/{slot.cap}\nStarting in {left}`
			slot.pad.Color = Palette.color(Palette.ground.lawn)

			if (slot.countdown or 0) <= 0 then
				local id = slot.worldId :: string
				slot.countdown = nil
				slot.worldId = nil
				slot.cap = GAME_SLOTS
				--[[
					This game leaves; the yard does not.

					Only the players on this pad are sent, so the three games
					beside it carry on being set up rather than being dragged
					into somebody else's lawn.
				]]
				MatchmakingService.send(team, id, #team)
			end
		else
			slot.countdown = nil
			if waiting then
				slot.padLabel.Text = "…"
				slot.pad.Color = Palette.color(Palette.ground.stoneDark)
			elseif world and #team > 0 then
				-- Somebody is on it with a map set that none of them has earned.
				slot.padLabel.Text = `{#team}/{slot.cap}\nNeeds {Worlds.expect((world :: any).requiresWorld).name}`
				slot.pad.Color = Palette.color(Palette.ground.stoneDark)
			elseif world then
				slot.padLabel.Text = `0/{slot.cap}\nStand here`
				slot.pad.Color = Palette.color(Palette.ground.stone)
			else
				slot.padLabel.Text = "Create a game!"
				slot.pad.Color = Palette.color(Palette.ground.stone)
			end
		end

		slot.boardLabel.Text = if world
			then `{(world :: any).name}\n{string.upper((world :: any).difficulty)}`
			else "Select a map!"
	end

	local status = statusLabel
	if status then
		status.Text = if anyReady
			then "Off you go — good luck out there"
			else "Stand on a pad to set a game up"
	end
end

--[[
	The settings panel, confirmed.

	Sets the property and the party size in one go, from the player who pressed
	the button — checked against their own record, the same way the plaques
	are, so confirming a map you have not unlocked is refused here as well as
	there.
]]
local function onConfirm(player: Player, payload: any)
	if MowRunService.phase() ~= "lobby" or type(payload) ~= "table" then
		return
	end
	local worldId = (payload :: any).worldId
	local wanted = tonumber((payload :: any).maxPlayers)
	if type(worldId) ~= "string" or not Worlds.get(worldId) or not wanted then
		return
	end

	local world = Worlds.expect(worldId)
	local profile = DataService.get(player)
	local beaten = if profile then profile.worldsBeaten else nil
	local allowed = not world.requiresWorld
		or (beaten ~= nil and beaten[world.requiresWorld] == true)
	if not allowed then
		MowEconomyService.notify(
			player,
			"denied",
			`{world.name} needs {Worlds.expect(world.requiresWorld :: string).name} first`,
			nil
		)
		return
	end

	local slot = slotUnder(player)
	if not slot then
		MowEconomyService.notify(player, "denied", "Stand on a pad to set a game up", nil)
		return
	end
	if slot.countdown then
		-- Already counting down; the settings are settled.
		return
	end

	slot.worldId = worldId
	slot.cap = math.clamp(math.floor(wanted), 1, GAME_SLOTS)
	MowEconomyService.notify(
		player,
		"quest",
		`{world.name} — up to {slot.cap} player{if slot.cap == 1 then "" else "s"}`,
		nil
	)
end

function LobbyService.start()
	build()

	Remotes.event(Remotes.LOBBY_CONFIRM).OnServerEvent:Connect(onConfirm)

	--[[
		The lobby is entered by watching the phase rather than by being told.

		`RunService` owns the phase and has no signal for it, and giving it one
		so the lobby could subscribe would have the run reaching into the menu.
		A poll costs a table walk a few times a second and keeps the arrow
		pointing one way.
	]]
	task.spawn(function()
		local last = os.clock()
		while true do
			local now = os.clock()
			local delta = now - last
			last = now

			local phase = MowRunService.phase()
			if phase ~= lastPhase then
				if phase == "won" or phase == "lost" then
					lastOutcome = phase
					lastWorldName = Worlds.expect(MowRunService.worldId()).name
				elseif phase == "lobby" then
					-- Back from a run: gather everyone in and say how it went.
					local label = outcomeLabel
					if label then
						label.Text = if lastOutcome == "won" and lastWorldName
							then `You cleared {lastWorldName}!`
							elseif lastOutcome == "lost" and lastWorldName
								then `The clock beat you on {lastWorldName}.`
							else GameConfig.GAME_NAME
					end
					for _, slot in slots do
						slot.worldId = nil
						slot.cap = GAME_SLOTS
						slot.countdown = nil
					end
					placeEveryone()
				end
				lastPhase = phase
			end

			local ok = pcall(step, delta)
			if not ok then
				warn("[Lobby] a tick failed; the yard keeps running")
			end
			task.wait(0.25)
		end
	end)

	-- Somebody arriving between runs belongs in the lobby, not on the last lot.
	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function()
			task.wait(0.3)
			if MowRunService.phase() == "lobby" then
				LobbyService.place(player)
			end
		end)
	end)
end

return LobbyService
