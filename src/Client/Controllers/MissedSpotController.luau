--!strict
--[[
	MissedSpotController — "you missed a spot".

	Once a section is nearly clear, the last few uncut tiles get a beacon above
	them. This is a direct answer to the reference game's most common
	frustration: players hunting a single stray tile across an entire world
	with no idea where it is.

	It runs entirely on the client's copy of the tile buffer, so it costs the
	server nothing, and only switches on past the threshold so it never spoils
	the actual mowing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkCodec = require(Shared.ChunkCodec)
local GameConfig = require(Shared.Config.GameConfig)
local Grid = require(Shared.Grid)
local Worlds = require(Shared.Config.Worlds)
local GrassRenderer = require(script.Parent.GrassRenderer)
local PlayerState = require(script.Parent.Parent.PlayerState)

local MissedSpotController = {}

local container: Folder? = nil
local markers: { Part } = {}

--[[
	What the scan found, for anything that wants to say it out loud.

	The hero bar changes its whole face past the threshold — gold fill, a count
	instead of a percentage — and the count is this number. It is worked out
	here because this is the one place that already walks the buffer.
]]
export type Straggle = {
	remaining: number,
	cleared: number,
	past: boolean,
}

local straggle: { [string]: Straggle } = {}
local spots: { Vector3 } = {}

function MissedSpotController.sectionState(sectionId: string?): Straggle?
	return if sectionId then straggle[sectionId] else nil
end

--- Where the marks are, for the off-screen chip.
function MissedSpotController.spots(): { Vector3 }
	return spots
end
--- Recomputed on this interval; scanning a whole world is not a per-frame job.
local SCAN_INTERVAL = 1.5

local GOLD = Color3.fromRGB(255, 206, 74)
local INK = Color3.fromRGB(24, 18, 10)

--[[
	One straggler, drawn as three things.

	A single neon column told you where a tile was and nothing else — at a
	distance it is a yellow line on a lawn full of yellow leaves. The handoff
	asks for a mark that reads at any range: a diamond that stays the same
	size on screen however far away it is, a column under it that fades out
	rather than stopping, and a ring on the ground so you can see which tile
	it means once you are standing over it.
]]
local function acquireMarker(index: number): Part
	local existing = markers[index]
	if existing then
		return existing
	end

	--- The anchor is the column's base; everything else hangs off it.
	local part = Instance.new("Part")
	part.Name = "MissedSpot"
	part.Size = Vector3.new(1.6, 9, 1.6)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(255, 214, 96)
	part.Transparency = 0.5
	part.Parent = container

	--- Two more courses above it, each fainter: a column that fades rather
	--- than one that stops.
	for course, fade in { 0.72, 0.88 } do
		local upper = Instance.new("Part")
		upper.Name = `Fade{course}`
		upper.Size = Vector3.new(1.6, 9, 1.6)
		upper.Anchored = true
		upper.CanCollide = false
		upper.CanQuery = false
		upper.CanTouch = false
		upper.CastShadow = false
		upper.Material = Enum.Material.Neon
		upper.Color = Color3.fromRGB(255, 214, 96)
		upper.Transparency = fade
		upper.Parent = part
	end

	--- The ring on the ground, drawn as a stroke on a flat part's top face so
	--- it is hollow — a filled disc hides the tile it is pointing at.
	local ring = Instance.new("Part")
	ring.Name = "Ring"
	ring.Size = Vector3.new(7, 0.2, 7)
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Transparency = 1
	ring.Parent = part

	local face = Instance.new("SurfaceGui")
	face.Name = "Ground"
	face.Face = Enum.NormalId.Top
	face.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	face.PixelsPerStud = 24
	face.AlwaysOnTop = false
	face.Parent = ring

	local ellipse = Instance.new("Frame")
	ellipse.Name = "Ellipse"
	ellipse.Size = UDim2.fromScale(1, 1)
	ellipse.BackgroundTransparency = 1
	ellipse.Parent = face
	local ellipseRound = Instance.new("UICorner")
	ellipseRound.CornerRadius = UDim.new(0.5, 0)
	ellipseRound.Parent = ellipse
	local ellipseEdge = Instance.new("UIStroke")
	ellipseEdge.Thickness = 5
	ellipseEdge.Color = GOLD
	ellipseEdge.Transparency = 0.15
	ellipseEdge.Parent = ellipse

	--- The diamond, on a billboard so it is the same size at any distance.
	local badge = Instance.new("BillboardGui")
	badge.Name = "Badge"
	badge.Size = UDim2.fromOffset(34, 34)
	--- Above the column, not inside it: the three courses reach twenty-two
	--- studs and a diamond buried in neon is a smudge.
	badge.StudsOffsetWorldSpace = Vector3.new(0, 26, 0)
	badge.AlwaysOnTop = true
	badge.LightInfluence = 0
	badge.MaxDistance = 900
	badge.Parent = part

	local diamond = Instance.new("Frame")
	diamond.Name = "Mark"
	diamond.AnchorPoint = Vector2.new(0.5, 0.5)
	diamond.Position = UDim2.fromScale(0.5, 0.5)
	diamond.Size = UDim2.fromOffset(26, 26)
	diamond.Rotation = 45
	diamond.BackgroundColor3 = GOLD
	diamond.BorderSizePixel = 0
	diamond.Parent = badge
	local diamondRound = Instance.new("UICorner")
	diamondRound.CornerRadius = UDim.new(0, 4)
	diamondRound.Parent = diamond
	local diamondEdge = Instance.new("UIStroke")
	diamondEdge.Thickness = 3
	diamondEdge.Color = INK
	diamondEdge.Parent = diamond

	markers[index] = part
	return part
end

--- Where the column's three courses and its ring sit, given the tile floor.
local function placeMarker(marker: Part, wx: number, floor: number, wz: number)
	marker.CFrame = CFrame.new(wx, floor + 4.5, wz)
	local course = 1
	for _, child in marker:GetChildren() do
		if child:IsA("Part") and child.Name ~= "Ring" then
			child.CFrame = CFrame.new(wx, floor + 4.5 + course * 9, wz)
			course += 1
		elseif child:IsA("Part") and child.Name == "Ring" then
			child.CFrame = CFrame.new(wx, floor + 0.12, wz)
		end
	end
end

--[[
	Finds uncut tiles in sections that are nearly finished.

	Only sections past the threshold are scanned, so a player mowing a fresh lawn
	never sees a beacon, and the marker count is capped so a large half-done
	world does not turn into a forest of pillars.
]]
local function scan()
	local grid = GrassRenderer.grid()
	local tiles = GrassRenderer.tiles()
	local world = PlayerState.world()
	local folder = container
	if not grid or not tiles or not world or not folder then
		return
	end

	local found = 0
	table.clear(spots)

	for _, section in world.sections do
		if PlayerState.isSectionOpen(section.id) then
			local r = section.rect
			local total, remaining = 0, 0
			local stragglers: { number } = {}

			for tz = r.z, math.min(r.z + r.d - 1, grid.depth - 1) do
				for tx = r.x, math.min(r.x + r.w - 1, grid.width - 1) do
					local index = Grid.toIndex(grid, tx, tz)
					local byte = buffer.readu8(tiles, index - 1)
					if ChunkCodec.debris(byte) ~= 0 then
						total += 1
						if ChunkCodec.height(byte) > 0 then
							remaining += 1
							if #stragglers < GameConfig.MISSED_SPOT_MAX_MARKERS then
								table.insert(stragglers, index)
							end
						end
					end
				end
			end

			-- The section's own progress decides this, not the whole world's, so
			-- a finished front yard flags its last tile while the back is still
			-- untouched.
			local cleared = if total > 0 then 1 - remaining / total else 1
			straggle[section.id] = {
				remaining = remaining,
				cleared = cleared,
				past = cleared >= GameConfig.MISSED_SPOT_THRESHOLD and remaining > 0,
			}
			if cleared >= GameConfig.MISSED_SPOT_THRESHOLD and remaining > 0 then
				for _, index in stragglers do
					if found >= GameConfig.MISSED_SPOT_MAX_MARKERS then
						break
					end
					found += 1
					local tx, tz = Grid.fromIndex(grid, index)
					local wx, wz = Grid.tileToWorld(grid, tx, tz)
					local marker = acquireMarker(found)
					-- On the tile's own floor, so a beacon on the roof does not
					-- appear to be floating over the lawn instead.
					local floor = GameConfig.GROUND_Y + Worlds.elevationAt(world, tx, tz)
					placeMarker(marker, wx, floor, wz)
					marker.Parent = folder
					table.insert(spots, Vector3.new(wx, floor + 4, wz))
				end
			end
		end
	end

	for index = found + 1, #markers do
		markers[index].Parent = nil
	end
end

function MissedSpotController.start()
	container = Instance.new("Folder")
	;(container :: Folder).Name = "MowMissedSpots"
	;(container :: Folder).Parent = Workspace

	local accumulator = 0
	RunService.Heartbeat:Connect(function(delta)
		accumulator += delta
		if accumulator >= SCAN_INTERVAL then
			accumulator = 0
			scan()
		end
	end)
end

return MissedSpotController
