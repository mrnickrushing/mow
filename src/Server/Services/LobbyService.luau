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
local Palette = require(Shared.Config.Palette)
local Worlds = require(Shared.Config.Worlds)
local Build = require(script.Parent.Parent.Lib.Build)
local DataService = require(script.Parent.DataService)
local MowRunService = require(script.Parent.RunService)
local MatchmakingService = require(script.Parent.MatchmakingService)

local LobbyService = {}

--- Far enough from every lot that nothing can ever overlap it.
local CENTRE = Vector3.new(-600, 0, -600)
local FLOOR_W, FLOOR_D = 170, 170
--- How close counts as standing on a pad.
local PAD_RADIUS = 7
local TEAM_PADS = 4
--- Seconds between a team being ready and the property loading.
local COUNTDOWN = 6

local folder: Folder? = nil
local teamPads: { BasePart } = {}
local teamLabels: { TextLabel } = {}
local levelPads: { [string]: BasePart } = {}
local levelLabels: { [string]: TextLabel } = {}
local statusLabel: TextLabel? = nil
local outcomeLabel: TextLabel? = nil

local chosenWorld: string? = nil
local countdownLeft: number? = nil
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

local function build()
	if folder then
		return
	end
	local root = Build.folder("MowLobby", workspace)
	folder = root

	Build.part({
		name = "Floor",
		size = Vector3.new(FLOOR_W, 2, FLOOR_D),
		cframe = CFrame.new(CENTRE - Vector3.new(0, 1, 0)),
		color = Palette.color(Palette.ground.path),
		material = Enum.Material.Concrete,
		parent = root,
	})

	for _, side in { -1, 1 } do
		Build.part({
			name = "Wall",
			size = Vector3.new(FLOOR_W, 22, 2),
			cframe = CFrame.new(CENTRE + Vector3.new(0, 11, side * FLOOR_D * 0.5)),
			color = Palette.color(Palette.fence.rail),
			material = Enum.Material.SmoothPlastic,
			parent = root,
		})
		Build.part({
			name = "Wall",
			size = Vector3.new(2, 22, FLOOR_D),
			cframe = CFrame.new(CENTRE + Vector3.new(side * FLOOR_W * 0.5, 11, 0)),
			color = Palette.color(Palette.fence.rail),
			material = Enum.Material.SmoothPlastic,
			parent = root,
		})
	end

	local teamHeading = floorHeading("TeamSign", 60, CENTRE + Vector3.new(0, 0, 46), root)
	teamHeading.Text = "YOUR TEAM — STAND ON A PAD"

	for index = 1, TEAM_PADS do
		local at = CENTRE + Vector3.new((index - (TEAM_PADS + 1) * 0.5) * 18, 0, 30)
		local part, label = pad(`TeamPad{index}`, at, Palette.color(Palette.ground.stone), root)
		label.Text = `{index}`
		teamPads[index] = part
		teamLabels[index] = label
	end

	local pickHeading = floorHeading("PickSign", 66, CENTRE + Vector3.new(0, 0, -12), root)
	pickHeading.Text = "PICK A PROPERTY — STAND ON ONE"

	local list = Worlds.list
	for index, world in list do
		local at = CENTRE + Vector3.new((index - (#list + 1) * 0.5) * 48, 0, -42)
		local part, label = pad(`LevelPad_{world.id}`, at, Palette.color(Palette.ground.stoneDark), root, 22)
		label.Text = world.name
		levelPads[world.id] = part
		levelLabels[world.id] = label
	end

	local statusPost = Build.part({
		name = "StatusBoard",
		size = Vector3.new(86, 26, 1),
		cframe = CFrame.lookAt(
			CENTRE + Vector3.new(0, 15, -82),
			CENTRE + Vector3.new(0, 15, -81)
		),
		color = Palette.color(Palette.house.trim),
		material = Enum.Material.SmoothPlastic,
		canCollide = false,
		parent = root,
	})
	outcomeLabel = surface(statusPost, Enum.NormalId.Front, 0.34)
	local outcome = outcomeLabel :: TextLabel
	outcome.Position = UDim2.fromScale(0.04, 0.06)
	statusLabel = surface(statusPost, Enum.NormalId.Front, 0.4)
	local status = statusLabel :: TextLabel
	status.Position = UDim2.fromScale(0.04, 0.5)
	status.Text = "Stand on a pad and pick a property"
end

local function standingOn(part: BasePart, position: Vector3): boolean
	local offset = position - part.Position
	return offset.X * offset.X + offset.Z * offset.Z <= PAD_RADIUS * PAD_RADIUS
		and math.abs(offset.Y) < 12
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
	local at = CENTRE + Vector3.new(0, 4, 66)
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

local function refreshLevelLabels(unlockedBy: { [string]: boolean })
	for _, world in Worlds.list do
		local label = levelLabels[world.id]
		if label then
			local unlocked = not world.requiresWorld or unlockedBy[world.requiresWorld]
			local mark = if chosenWorld == world.id then "▶ " else ""
			label.Text = if unlocked
				then `{mark}{world.name}\n{world.difficulty}`
				else `{world.name}\nBeat {Worlds.expect(world.requiresWorld :: string).name} first`
			label.TextColor3 = if unlocked
				then Color3.fromRGB(255, 255, 255)
				else Color3.fromRGB(150, 150, 150)
		end
	end
end

--[[
	One tick of the lobby.

	Occupancy is measured rather than touched: a `Touched` event fires on a
	brushed elbow and never fires again while you stand still, which is the
	opposite of what a pad wants to know.
]]
local function step(delta: number)
	if MowRunService.phase() ~= "lobby" then
		return
	end
	local where = positions()

	-- Who is on a team pad.
	local party = 0
	local team: { Player } = {}
	for index = 1, TEAM_PADS do
		local part = teamPads[index]
		local label = teamLabels[index]
		if part and label then
			local occupant: Player? = nil
			for player, position in where do
				if standingOn(part, position) then
					occupant = player
					break
				end
			end
			if occupant then
				party += 1
				table.insert(team, occupant)
				label.Text = occupant.DisplayName
				part.Color = Palette.color(Palette.ground.lawn)
			else
				label.Text = `{index}`
				part.Color = Palette.color(Palette.ground.stone)
			end
		end
	end

	-- What anyone standing on a plaque has picked, if they may pick it.
	local unlockedBy: { [string]: boolean } = {}
	for player in where do
		local profile = DataService.get(player)
		if profile and profile.worldsBeaten then
			for id, beaten in profile.worldsBeaten do
				if beaten then
					unlockedBy[id] = true
				end
			end
		end
	end

	for id, part in levelPads do
		for player, position in where do
			if standingOn(part, position) then
				local world = Worlds.expect(id)
				local allowed = not world.requiresWorld or unlockedBy[world.requiresWorld]
				if allowed then
					chosenWorld = id
				end
			end
		end
	end

	refreshLevelLabels(unlockedBy)

	-- Ready when somebody is on a pad and a property is picked.
	local status = statusLabel
	if party > 0 and chosenWorld then
		countdownLeft = (countdownLeft or COUNTDOWN) - delta
		local left = math.max(math.ceil(countdownLeft or 0), 0)
		if status then
			status.Text = `{Worlds.expect(chosenWorld).name} — team of {party} — starting in {left}`
		end
		if (countdownLeft or 0) <= 0 then
			local id = chosenWorld
			countdownLeft = nil
			chosenWorld = nil
			if status then
				--[[
					The team leaves; the lobby does not.

					Only the players on the pads are sent, so anybody still
					choosing keeps a working room around them rather than
					being dragged into somebody else's lawn.
				]]
				status.Text = "Finding you a lawn…"
			end
			MatchmakingService.send(team, id, party)
		end
	else
		countdownLeft = nil
		if status then
			status.Text = if chosenWorld
				then `{Worlds.expect(chosenWorld).name} — stand on a team pad to start`
				else "Stand on a pad and pick a property"
		end
	end
end

function LobbyService.start()
	build()

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
							else ""
					end
					chosenWorld = nil
					countdownLeft = nil
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
