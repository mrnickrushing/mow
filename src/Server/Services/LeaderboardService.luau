--!strict
--[[
	LeaderboardService — the all-time boards on the lobby fence.

	The reference's lobby has two of these standing at the back: a gold-headed
	frame reading LEAVES COLLECTED with the top players and their totals down
	it, and they are most of why its yard feels like somewhere with other
	people in it rather than a menu you happen to walk around. The profile has
	carried `stats.unitsSold` since the beginning, with a comment saying it was
	for exactly this, and nothing was ever built to read it.

	Ranking across servers needs an OrderedDataStore, because the top ten is a
	question about everybody who has ever played and a server only knows about
	the fifty people in it. Writes go in when a player leaves — the moment
	their lifetime total is final for that session — and the read is polled, so
	a board is at worst a minute out of date, which for an all-time total is
	not a difference anybody can see.

	Where there is no DataStore — Studio without API access — the board says so
	rather than standing empty and looking broken.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local Loop = require(Shared.Util.Loop)
local Palette = require(Shared.Config.Palette)
local Build = require(script.Parent.Parent.Lib.Build)
local DataService = require(script.Parent.DataService)

local LeaderboardService = {}

--- How many rows a board shows. The reference shows six or seven; ten is as
--- many as fit on a board a player can still read the top of.
local ROWS = 8
--- Seconds between reads. An all-time total does not move fast enough to be
--- worth a request more often than this, and the quota is shared.
local REFRESH = 60

local ordered: OrderedDataStore? = nil
local available = true

--[[
	One entry per kind of board, so adding a second is a table row.

	`stat` is the profile field; `title` is what the header says. The store
	name carries a version so the ladder can be reset without the old numbers
	bleeding into the new one.
]]
type BoardDef = {
	key: string,
	stat: string,
	title: string,
	--- Rendered under each name. Clippings are counted, not priced.
	suffix: string,
}

local BOARDS: { BoardDef } = {
	{ key = "clippings", stat = "unitsSold", title = "CLIPPINGS COLLECTED", suffix = "" },
}

type Row = { name: TextLabel, score: TextLabel }
local rows: { [string]: { Row } } = {}
local statusLabels: { [string]: TextLabel } = {}

--------------------------------------------------------------------
-- The board itself
--------------------------------------------------------------------

--[[
	A framed board, built the way the signs are.

	Same carpentry as the map boards next to it — posts running past the panel,
	a dark backing, rails across the face — because two different ideas of what
	a wooden board looks like standing ten studs apart is worse than either.
]]
local function buildBoard(parent: Instance, def: BoardDef, at: CFrame)
	local WOOD = Palette.color(Palette.house.roof)
	local RAIL = Palette.color(Palette.fence.rail)
	local width, height = 30, 34

	for _, side in { -1, 1 } do
		local post = Build.part({
			name = "BoardPost",
			size = Vector3.new(2.2, height + 8, 2.2),
			cframe = at * CFrame.new(side * (width * 0.5 + 1), 0, 1.2),
			color = WOOD,
			material = Enum.Material.WoodPlanks,
			parent = parent,
		})
		local _ = post
	end

	Build.part({
		name = "Backing",
		size = Vector3.new(width + 1.6, height + 1.6, 0.9),
		cframe = at,
		color = Color3.fromRGB(74, 52, 34),
		material = Enum.Material.WoodPlanks,
		parent = parent,
	})

	local face = Build.part({
		name = "Face",
		size = Vector3.new(width, height, 0.5),
		cframe = at * CFrame.new(0, 0, -0.5),
		color = Color3.fromRGB(38, 30, 24),
		material = Enum.Material.SmoothPlastic,
		parent = parent,
	})

	-- The gold header bar, which is what makes it read as a trophy board
	-- rather than a notice board.
	local header = Build.part({
		name = "Header",
		size = Vector3.new(width + 1.2, 5, 1.1),
		cframe = at * CFrame.new(0, height * 0.5 - 1.6, -0.7),
		color = Color3.fromRGB(240, 186, 62),
		material = Enum.Material.SmoothPlastic,
		parent = parent,
	})

	for _, y in { -height * 0.5 + 0.8, height * 0.5 - 4.4 } do
		Build.part({
			name = "BoardRail",
			size = Vector3.new(width + 1.6, 1.4, 1.1),
			cframe = at * CFrame.new(0, y, -0.7),
			color = RAIL,
			material = Enum.Material.WoodPlanks,
			parent = parent,
		})
	end

	--- Text on a surface, sized in pixels per stud so it stays put.
	local function surfaceOn(part: BasePart): Frame
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Front
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 26
		gui.LightInfluence = 0
		gui.Parent = part
		local holder = Instance.new("Frame")
		holder.Size = UDim2.fromScale(1, 1)
		holder.BackgroundTransparency = 1
		holder.Parent = gui
		return holder
	end

	local function label(parent_: Instance, text: string, size: UDim2, pos: UDim2, px: number, colour: Color3, align: Enum.TextXAlignment): TextLabel
		local l = Instance.new("TextLabel")
		l.Text = text
		l.Size = size
		l.Position = pos
		l.BackgroundTransparency = 1
		l.Font = Enum.Font.GothamBold
		l.TextSize = px
		l.TextColor3 = colour
		l.TextXAlignment = align
		l.TextYAlignment = Enum.TextYAlignment.Center
		l.Parent = parent_
		return l
	end

	label(surfaceOn(header), def.title, UDim2.fromScale(1, 1), UDim2.new(), 44,
		Color3.fromRGB(58, 40, 14), Enum.TextXAlignment.Center)

	local sheet = surfaceOn(face)
	local built: { Row } = {}
	local top = 0.13
	local rowHeight = (0.97 - top) / ROWS
	for i = 1, ROWS do
		local y = top + rowHeight * (i - 1)
		label(sheet, `{i}`, UDim2.fromScale(0.11, rowHeight), UDim2.fromScale(0.02, y), 30,
			Color3.fromRGB(240, 186, 62), Enum.TextXAlignment.Center)
		built[i] = {
			name = label(sheet, "—", UDim2.fromScale(0.55, rowHeight), UDim2.fromScale(0.14, y), 28,
				Color3.fromRGB(246, 240, 228), Enum.TextXAlignment.Left),
			score = label(sheet, "", UDim2.fromScale(0.28, rowHeight), UDim2.fromScale(0.70, y), 28,
				Color3.fromRGB(126, 232, 106), Enum.TextXAlignment.Right),
		}
	end
	rows[def.key] = built
	statusLabels[def.key] = label(sheet, "", UDim2.fromScale(0.96, 0.10), UDim2.fromScale(0.02, 0.02), 24,
		Color3.fromRGB(178, 166, 150), Enum.TextXAlignment.Center)
end

--- Builds every board. Called by the lobby once its yard exists, with the
--- place each board should stand.
function LeaderboardService.build(parent: Instance, at: CFrame)
	for index, def in BOARDS do
		buildBoard(parent, def, at * CFrame.new((index - 1) * 36, 0, 0))
	end
end

--------------------------------------------------------------------
-- The numbers
--------------------------------------------------------------------

local function statOf(profile: any, stat: string): number
	local stats = profile and profile.stats
	local value = stats and (stats :: any)[stat]
	return if type(value) == "number" then value else 0
end

--- Writes a player's lifetime total, so the next read can rank them.
function LeaderboardService.publish(player: Player)
	local store = ordered
	if not store or not available then
		return
	end
	local profile = DataService.get(player)
	if not profile then
		return
	end
	local value = math.floor(statOf(profile, BOARDS[1].stat))
	if value <= 0 then
		return
	end
	local ok, err = pcall(function()
		store:SetAsync(tostring(player.UserId), value)
	end)
	if not ok then
		warn(`[Leaderboard] could not publish {player.Name}: {err}`)
	end
end

local function refresh()
	local def = BOARDS[1]
	local built = rows[def.key]
	local status = statusLabels[def.key]
	if not built then
		return
	end

	if not available or not ordered then
		if status then
			status.Text = "waiting for a published server"
		end
		return
	end

	local store = ordered :: OrderedDataStore
	local ok, pages = pcall(function()
		return store:GetSortedAsync(false, ROWS)
	end)
	if not ok then
		if status then
			status.Text = "scores are having a lie down"
		end
		return
	end

	local page = (pages :: DataStorePages):GetCurrentPage()
	if status then
		status.Text = ""
	end
	for i = 1, ROWS do
		local entry = page[i]
		local row = built[i]
		if entry then
			--[[
				A name, not a number. `GetNameFromUserIdAsync` is a web call
				and it is cached by Roblox, but a failed one must not take the
				whole board down with it — a row that says the user id is a
				worse board, not a broken one.
			]]
			local named, name = pcall(function()
				return Players:GetNameFromUserIdAsync(tonumber(entry.key) or 0)
			end)
			row.name.Text = if named then name else "…"
			row.score.Text = Format.count(entry.value)
		else
			row.name.Text = "—"
			row.score.Text = ""
		end
	end
end

function LeaderboardService.start()
	local ok, store = pcall(function()
		return DataStoreService:GetOrderedDataStore("MowClippings_v1")
	end)
	if ok then
		ordered = store
	else
		available = false
		warn("[Leaderboard] no ordered store; the board will say so")
	end

	Players.PlayerRemoving:Connect(function(player)
		LeaderboardService.publish(player)
	end)

	Loop.forever("Leaderboard.refresh", function()
		refresh()
		task.wait(REFRESH)
	end)
end

return LeaderboardService
