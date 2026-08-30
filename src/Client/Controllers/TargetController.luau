--!strict
--[[
	TargetController — the outline on the thing you are about to pick up.

	Pickup tools act on one tile at a time, so the player has to be able to see
	which one before they commit. This draws a white box around it and keeps that
	box in step with the tile the server would actually choose: the same
	`Cutting.pickupTarget` runs on both sides, so the outline can never sit on one
	drift while a different one disappears.

	Swath tools have no single target, so the outline simply goes away when one is
	equipped — which doubles as a readable signal that the tool works differently
	now.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Cutting = require(Shared.Cutting)
local Palette = require(Shared.Config.Palette)
local Tools = require(Shared.Config.Tools)
local Aim = require(script.Parent.Parent.Aim)
local GrassRenderer = require(script.Parent.GrassRenderer)
local PlayerState = require(script.Parent.Parent.PlayerState)

local TargetController = {}

local player = Players.LocalPlayer
local anchor: Part? = nil
local box: SelectionBox? = nil
local current: number? = nil

--- Retargeting every frame is wasted work — the tile only changes when the
--- player has walked or turned an appreciable amount.
local REFRESH_HZ = 20
local accumulator = 0

local function rootPart(): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function isOpen(index: number): boolean
	return PlayerState.isSectionOpen(PlayerState.sectionIdAt(index))
end

--- The tile the equipped pickup tool is pointed at, if any.
function TargetController.current(): number?
	return current
end

local function ensureAdornment(): (Part, SelectionBox)
	local existingPart = anchor
	local existingBox = box
	if existingPart and existingBox then
		return existingPart, existingBox
	end

	local part = Instance.new("Part")
	part.Name = "MowPickupTarget"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.Parent = Workspace

	local selection = Instance.new("SelectionBox")
	selection.Adornee = part
	selection.Color3 = Palette.color(Palette.ui.target)
	selection.LineThickness = 0.035
	selection.SurfaceColor3 = Color3.new(1, 1, 1)
	selection.SurfaceTransparency = 0.88
	selection.Parent = part

	anchor = part
	box = selection
	return part, selection
end

local function hide()
	current = nil
	local selection = box
	if selection then
		selection.Visible = false
	end
end

local function show(index: number)
	local centre, size = GrassRenderer.tileBounds(index)
	if not centre or not size then
		hide()
		return
	end

	local part, selection = ensureAdornment()
	part.Size = size
	part.CFrame = CFrame.new(centre)
	selection.Visible = true
	current = index
end

local function step(delta: number)
	accumulator += delta
	if accumulator < 1 / REFRESH_HZ then
		return
	end
	accumulator = 0

	local state = PlayerState.get()
	local tool = if state.equippedTool ~= "" then Tools.get(state.equippedTool) else nil
	if not tool or tool.mode ~= "pickup" then
		hide()
		return
	end

	local root = rootPart()
	local grid = GrassRenderer.grid()
	local tiles = GrassRenderer.tiles()
	if not root or not grid or not tiles then
		hide()
		return
	end

	local look = Aim.direction()
	local index = Cutting.pickupTarget(grid, tiles, root.Position.X, root.Position.Z, look.X, look.Z, tool, isOpen)
	if index then
		show(index)
	else
		hide()
	end
end

function TargetController.start()
	RunService.RenderStepped:Connect(step)

	player.CharacterRemoving:Connect(hide)
end

return TargetController
