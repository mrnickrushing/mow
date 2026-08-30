--!strict
--[[
	MissedSpotController — "you missed a spot".

	Once a zone is nearly clear, the last few uncut tiles get a beacon above
	them. This is a direct answer to the reference game's most common
	frustration: players hunting a single stray tile across an entire property
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
local Properties = require(Shared.Config.Properties)
local GrassRenderer = require(script.Parent.GrassRenderer)
local PlayerState = require(script.Parent.Parent.PlayerState)

local MissedSpotController = {}

local container: Folder? = nil
local markers: { Part } = {}
--- Recomputed on this interval; scanning a whole property is not a per-frame job.
local SCAN_INTERVAL = 1.5

local function acquireMarker(index: number): Part
	local existing = markers[index]
	if existing then
		return existing
	end

	local part = Instance.new("Part")
	part.Name = "MissedSpot"
	part.Size = Vector3.new(1.4, 26, 1.4)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(255, 214, 96)
	part.Transparency = 0.55
	part.Parent = container
	markers[index] = part
	return part
end

--[[
	Finds uncut tiles in zones that are nearly finished.

	Only zones past the threshold are scanned, so a player mowing a fresh lawn
	never sees a beacon, and the marker count is capped so a large half-done
	property does not turn into a forest of pillars.
]]
local function scan()
	local grid = GrassRenderer.grid()
	local tiles = GrassRenderer.tiles()
	local property = PlayerState.property()
	local folder = container
	if not grid or not tiles or not property or not folder then
		return
	end

	local state = PlayerState.get()
	local found = 0

	for _, zone in property.zones do
		if state.unlockedZones[zone.id] then
			local r = zone.rect
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

			-- The zone's own progress decides this, not the whole property's, so
			-- a finished front yard flags its last tile while the back is still
			-- untouched.
			local cleared = if total > 0 then 1 - remaining / total else 1
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
					local floor = GameConfig.GROUND_Y + Properties.elevationAt(property, tx, tz)
					marker.CFrame = CFrame.new(wx, floor + 13, wz)
					marker.Parent = folder
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
