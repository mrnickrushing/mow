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
local Palette = require(Shared.Config.Palette)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local Types = require(Shared.Types)
local GrassRenderer = require(script.Parent.GrassRenderer)
local PopupController = require(script.Parent.PopupController)
local PlayerState = require(script.Parent.Parent.PlayerState)

local MowController = {}

local player = Players.LocalPlayer
local intentRemote: UnreliableRemoteEvent
local mowing = false
local accumulator = 0
local predictScratch: { number } = {}
--- Units cut since the last popup, and when that popup went up. A swath tool
--- covers a dozen tiles a tick, so its numbers are pooled into one rather than
--- burying the screen; a pickup tool takes one pile and pops immediately.
local pendingUnits = 0
local lastPopupAt = 0

--- How often a swath tool is allowed to throw a number up.
local SWATH_POPUP_HZ = 3

local ACTION_NAME = "MowAllTheLawns_Mow"

local mowingSignal = Instance.new("BindableEvent")
--- Fires with the new value whenever the player starts or stops working, so the
--- HUD and the tool's own effects do not each have to poll for it.
MowController.MowingChanged = mowingSignal

local function rootPart(): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

--[[
	Throws a `+N` up for what was just taken.

	A pickup lands its number on the pile itself, because that is the thing the
	player aimed at. A swath has no single target, so its take is pooled and
	shown over the player at a readable rate instead.
]]
local function announce(tool: Types.ToolDef, units: number, index: number, fallback: Vector3)
	pendingUnits += units

	if tool.mode ~= "pickup" then
		local now = os.clock()
		if now - lastPopupAt < 1 / SWATH_POPUP_HZ then
			return
		end
		lastPopupAt = now
	end

	local total = math.round(pendingUnits)
	if total < 1 then
		return
	end
	pendingUnits = 0

	local centre = GrassRenderer.tileBounds(index)
	local at = if centre then centre + Vector3.new(0, 2.2, 0) else fallback + Vector3.new(0, 3.5, 0)
	PopupController.show(at, `+{total}`, Palette.color(Palette.ui.text))
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

	-- Same branch the server takes: one tile for a pickup tool, a rectangle for
	-- a swath one. Predicting the wrong shape would flash the wrong grass away.
	local indices: { number }
	if tool.mode == "pickup" then
		table.clear(predictScratch)
		local target = Cutting.pickupTarget(
			grid,
			tiles,
			root.Position.X,
			root.Position.Z,
			look.X,
			look.Z,
			tool,
			function(index)
				return PlayerState.isSectionOpen(PlayerState.sectionIdAt(index))
			end
		)
		if target then
			predictScratch[1] = target
		end
		indices = predictScratch
	else
		indices = Grid.rasterizeSwath(
			grid,
			root.Position.X,
			root.Position.Z,
			look.X,
			look.Z,
			tool.deck,
			tool.reach,
			predictScratch
		)
	end

	local cutUnits = 0
	local lastCutIndex: number? = nil

	for _, index in indices do
		local byte = buffer.readu8(tiles, index - 1)
		local owns = PlayerState.isSectionOpen(PlayerState.sectionIdAt(index))

		-- Same module the server runs, so a prediction can only be wrong about
		-- timing, never about the rules. Predicting a locked zone or a full bag
		-- would flash grass away and restore it, which reads as a bug.
		local outcome = Cutting.evaluate(byte, tool, levelsAvailable, yieldMultiplier, owns, space)
		if outcome.status == "cut" then
			GrassRenderer.predictCut(index, outcome.levels)
			space -= outcome.weight
			cutUnits += outcome.units
			lastCutIndex = index
		end
	end

	if cutUnits > 0 and lastCutIndex then
		announce(tool, cutUnits, lastCutIndex, root.Position)
	end
end

local function setMowing(value: boolean)
	mowing = value
	if not value then
		accumulator = 0
	end
	MowController.MowingChanged:Fire(mowing)
end

--- The word on the action button for the tool in hand.
local function actionLabel(tool: Types.ToolDef?): string
	if not tool then
		return "MOW"
	elseif tool.toggle then
		return if mowing then "ON" else "OFF"
	elseif tool.mode == "pickup" then
		return "PICK UP"
	end
	return "MOW"
end

--- Keeps the button reading as whatever the held tool actually does. A blower
--- says ON or OFF because it stays running; hands say PICK UP because they take
--- one pile at a time. Getting this wrong on touch is the difference between a
--- player understanding the tool and mashing the screen.
local function refreshLabel()
	local state = PlayerState.get()
	local tool = if state.equippedTool ~= "" then Tools.get(state.equippedTool) else nil
	ContextActionService:SetTitle(ACTION_NAME, actionLabel(tool))
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
		local state = PlayerState.get()
		local tool = if state.equippedTool ~= "" then Tools.get(state.equippedTool) else nil

		-- A blower runs until you switch it off, so its button latches. Everything
		-- else works while held, which is what makes mowing a line feel like one
		-- continuous action rather than a string of clicks.
		if tool and tool.toggle then
			if inputState == Enum.UserInputState.Begin then
				setMowing(not mowing)
				refreshLabel()
			end
		elseif inputState == Enum.UserInputState.Begin then
			setMowing(true)
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			setMowing(false)
		end
		return Enum.ContextActionResult.Pass
	end, true, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2, Enum.KeyCode.E)

	refreshLabel()
	ContextActionService:SetPosition(ACTION_NAME, UDim2.new(1, -140, 1, -180))

	-- Switching tools mid-swing stops the swing: a latched blower must not keep
	-- running through a rake, and the button has to relabel either way.
	local lastTool = PlayerState.get().equippedTool
	PlayerState.Changed:Connect(function()
		local equipped = PlayerState.get().equippedTool
		if equipped ~= lastTool then
			lastTool = equipped
			setMowing(false)
		end
		refreshLabel()
	end)

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
