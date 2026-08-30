--!strict
--[[
	MowController — turns input into mow intents.

	Sends the player's position and heading at a fixed rate while they are
	mowing, and predicts the cut locally so the grass falls the instant the
	button is held. The server's chunk deltas overwrite that prediction a moment
	later, so a mispredicted cut heals itself rather than needing rollback.

	Nothing here decides what was cut — only that the player is trying.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Cutting = require(Shared.Cutting)
local GameConfig = require(Shared.Config.GameConfig)
local Grid = require(Shared.Grid)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local GrassRenderer = require(script.Parent.GrassRenderer)
local PlayerState = require(script.Parent.Parent.PlayerState)

local MowController = {}

local player = Players.LocalPlayer
local intentRemote: UnreliableRemoteEvent
local mowing = false
local accumulator = 0
local predictScratch: { number } = {}

local ACTION_NAME = "MowAllTheLawns_Mow"

local function rootPart(): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

--[[
	Applies the same swath the server will, so the grass reacts immediately.

	Only the visual height moves; the bag, cash and completion bar all wait for
	the server, so a prediction that turns out wrong costs nothing but a frame of
	grass that pops back up.
]]
local function predict(root: BasePart, look: Vector3, toolId: string, passes: number)
	local tool = Tools.get(toolId)
	local grid = GrassRenderer.grid()
	local tiles = GrassRenderer.tiles()
	if not tool or not grid or not tiles then
		return
	end

	local levelsAvailable = tool.power * passes
	if levelsAvailable < 1 then
		return
	end

	local state = PlayerState.get()
	local space = math.max(state.bagCapacity - state.bagWeight, 0)
	local yieldMultiplier = Balance.yieldMultiplier(state.upgrades)

	local indices =
		Grid.rasterizeSwath(grid, root.Position.X, root.Position.Z, look.X, look.Z, tool.deck, tool.reach, predictScratch)

	for _, index in indices do
		local byte = buffer.readu8(tiles, index - 1)
		local owns = PlayerState.ownsZone(PlayerState.zoneIdAt(index))

		-- Same module the server runs, so a prediction can only be wrong about
		-- timing, never about the rules. Predicting a locked zone or a full bag
		-- would flash grass away and restore it, which reads as a bug.
		local outcome = Cutting.evaluate(byte, tool, levelsAvailable, yieldMultiplier, owns, space)
		if outcome.status == "cut" then
			GrassRenderer.predictCut(index, outcome.levels)
			space -= outcome.weight
		end
	end
end

local function setMowing(value: boolean)
	mowing = value
	if not value then
		accumulator = 0
	end
end

MowController.setMowing = setMowing

function MowController.isMowing(): boolean
	return mowing
end

local function step(delta: number)
	if not mowing then
		return
	end

	accumulator += delta
	local interval = 1 / GameConfig.MOW_INTENT_HZ
	if accumulator < interval then
		return
	end
	local elapsed = accumulator
	accumulator = 0

	local root = rootPart()
	if not root then
		return
	end

	local state = PlayerState.get()
	if not state or state.equippedTool == "" then
		return
	end

	-- Heading comes from the character rather than the camera so that mowing
	-- follows where the player is walking, which is what makes stripes possible.
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(0, 0, 1)
	else
		flat = flat.Unit
	end

	intentRemote:FireServer({
		position = root.Position,
		look = flat,
		toolId = state.equippedTool,
	})

	local tool = Tools.get(state.equippedTool)
	if tool then
		predict(root, flat, state.equippedTool, tool.rate * elapsed * state.cutRateMultiplier)
	end
end

function MowController.start()
	intentRemote = Remotes.unreliable(Remotes.MOW_INTENT)

	-- Bound through ContextActionService so it works on touch and gamepad too,
	-- and so the mobile button is created for us.
	ContextActionService:BindAction(ACTION_NAME, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			setMowing(true)
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			setMowing(false)
		end
		return Enum.ContextActionResult.Pass
	end, true, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2, Enum.KeyCode.E)

	ContextActionService:SetTitle(ACTION_NAME, "MOW")
	ContextActionService:SetPosition(ACTION_NAME, UDim2.new(1, -140, 1, -180))

	-- Releasing the button while the window is unfocused would otherwise leave
	-- the player mowing forever.
	UserInputService.WindowFocusReleased:Connect(function()
		setMowing(false)
	end)

	player.CharacterRemoving:Connect(function()
		setMowing(false)
	end)

	RunService.Heartbeat:Connect(step)
end

return MowController
