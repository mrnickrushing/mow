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
local SoundController = require(script.Parent.SoundController)

local GameConfig = require(Shared.Config.GameConfig)
local Palette = require(Shared.Config.Palette)
local Grid = require(Shared.Grid)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local Types = require(Shared.Types)
local Aim = require(script.Parent.Parent.Aim)
local GrassRenderer = require(script.Parent.GrassRenderer)
local GustController = require(script.Parent.GustController)
local PlayerState = require(script.Parent.Parent.PlayerState)

local MowController = {}

local player = Players.LocalPlayer
local intentRemote: UnreliableRemoteEvent
local mowing = false
local accumulator = 0
--- Fractional passes carried between ticks, mirroring the server's own carry.
local predictCarry = 0
--- When the cut cue may next fire, on `os.clock`. A swath can clear a dozen
--- tiles in one pass and each of them is a cut; without this the rustle plays a
--- dozen times on the same frame and turns into a burst of static.
local nextCutSound = 0
--- Shortest gap between two cut cues, in seconds.
local CUT_SOUND_GAP = 0.11
local predictScratch: { number } = {}
--- Clippings bagged since the last popup, and when that popup went up.
local pendingUnits = 0
local lastPopupAt = 0

--- How often a swath tool is allowed to throw a number up.
local SWATH_POPUP_HZ = 3

local ACTION_NAME = "MowAllTheLawns_Mow"

local mowingSignal = Instance.new("BindableEvent")
--- Fires with the new value whenever the player starts or stops working, so the
--- HUD and the tool's own effects do not each have to poll for it.
MowController.MowingChanged = mowingSignal

local collectedSignal = Instance.new("BindableEvent")
--- Fires with the clippings an armful put in the bag, the moment it is
--- predicted, so the number is on screen on the frame of the cut.
MowController.Collected = collectedSignal

local function rootPart(): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

--[[
	Announces what just went into the bag.

	A pickup fires the moment it lands, because one tuft is one grab. A swath
	covers a dozen tiles a tick and would otherwise bury the screen in numbers,
	so its take is pooled and released at a readable rate.

	The number is clippings, not cash: money does not exist until the bag is
	emptied at the trailer, and pretending otherwise on screen would teach the
	player the loop wrong.
]]
local function announce(tool: Types.ToolDef, units: number)
	pendingUnits += units

	if tool.mode ~= "pickup" then
		local now = os.clock()
		if now - lastPopupAt < 1 / SWATH_POPUP_HZ then
			return
		end
		lastPopupAt = now
	end

	local whole = math.floor(pendingUnits)
	if whole < 1 then
		return
	end
	MowController.Collected:Fire(whole)
	pendingUnits -= whole
end

--[[
	Weight this client believes it has cut since the server last told it.

	`PlayerState` carries the authoritative bag, and it arrives five times a
	second. That is fine for bare hands, which take about a second and a half
	to fill a starting bag. A Riding Mower fills the same bag in four
	hundredths of a second — eighteen tiles a pass, six passes a second — so
	between two updates the client would predict two hundred milliseconds of
	cutting against a bag the server had already declared full, the grass would
	vanish, and the server would refuse every bit of it.

	Reported exactly as it behaves: "the riding mower cuts the grass but it
	doesn't stay cut and it doesn't count towards the percentage nor money".
	The money and the percentage were right the whole time; only the picture
	lied.

	Reset whenever the server speaks, because whatever it just said already
	accounts for everything it accepted.
]]
local predictedWeight = 0

--[[
	Applies the same swath the server will, so the grass reacts immediately.

	Only the visual height moves; the bag, cash and completion bar all wait for
	the server, so a prediction that turns out wrong costs nothing but a frame of
	grass that pops back up — provided the prediction is made against a bag the
	server would recognise, which is what `predictedWeight` is for.
]]
local function predict(root: BasePart, look: Vector3, toolId: string, passes: number)
	local tool = Tools.get(toolId)
	local grid = GrassRenderer.grid()
	local tiles = GrassRenderer.tiles()
	if not tool or not grid or not tiles then
		return
	end

	local state = PlayerState.get()
	local levelsAvailable = Balance.toolPower(tool, state.upgrades) * passes
	if levelsAvailable < 1 then
		return
	end

	local space = math.max(state.bagCapacity - state.bagWeight - predictedWeight, 0)
	local yieldMultiplier = Balance.yieldMultiplier(state.upgrades, toolId)

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

	local bagged = 0

	-- A tool that moves debris rather than absorbing it throws some of it. This
	-- is what stops a blower reading as a delete key: the whole appeal is
	-- watching a drift come apart and tumble off down the garden.
	local throw = GustController.strengthFor(tool.category)
	local tint: Color3? = if tool.category == "Mower"
		then Palette.color(Palette.grass.blade)
		else nil

	for _, index in indices do
		local byte = buffer.readu8(tiles, index - 1)
		local owns = PlayerState.isSectionOpen(PlayerState.sectionIdAt(index))

		-- Same module the server runs, so a prediction can only be wrong about
		-- timing, never about the rules. Predicting a locked zone or a full bag
		-- would flash grass away and restore it, which reads as a bug.
		local outcome = Cutting.evaluate(byte, tool, levelsAvailable, yieldMultiplier, owns, space)
		if outcome.status == "cut" then
			-- Read where the debris was before removing it, so a blower has
			-- something to throw.
			if throw then
				local centre, size = GrassRenderer.tileBounds(index)
				if centre and size then
					local floor = centre - Vector3.new(0, size.Y * 0.5, 0)
					GustController.blow(floor, look, math.min(outcome.levels * 2, 4), throw, tint)
				end
			end

			GrassRenderer.predictCut(index, outcome.levels)
			space -= outcome.weight
			predictedWeight += outcome.weight
			bagged += outcome.units
		end
	end

	if bagged > 0 then
		announce(tool, bagged)

		--[[
			One rustle per handful, not per tile.

			The two samples alternate at random so a long pass over a deep lawn
			does not repeat a single waveform, and `SoundController` pitches
			each one differently again on top of that.
		]]
		local now = os.clock()
		if now >= nextCutSound then
			nextCutSound = now + CUT_SOUND_GAP
			SoundController.play(if math.random() < 0.5 then "Cut" else "CutAlt")
		end
	end
end

local function setMowing(value: boolean)
	if mowing == value then
		return
	end
	mowing = value
	if not value then
		accumulator = 0
		predictCarry = 0
	end

	-- Engine noise belongs to the machine, so it runs only while a mower is
	-- actually cutting — not for a rake, and not while one idles in the shed.
	local tool = MowController.equippedTool()
	SoundController.setLoop("MowerLoop", value and tool ~= nil and tool.category == "Mower")

	MowController.MowingChanged:Fire(mowing)
end

--- The tool in hand, or nil when nothing is equipped.
function MowController.equippedTool(): Types.ToolDef?
	local state = PlayerState.get()
	return if state.equippedTool ~= "" then Tools.get(state.equippedTool) else nil
end

local equipped = MowController.equippedTool

--[[
	The word under the tool button.

	A blower says ON or OFF because it stays running; hands say PICK UP because
	they take one pile at a time. Getting this wrong on touch is the difference
	between a player understanding a tool and mashing the screen.
]]
function MowController.actionLabel(): string
	local tool = equipped()
	if not tool then
		return ""
	elseif tool.toggle then
		return if mowing then "ON" else "OFF"
	elseif tool.mode == "pickup" then
		return "PICK UP"
	end
	return "MOW"
end

MowController.setMowing = setMowing

--[[
	The trigger going down.

	A blower runs until you switch it off, so its trigger latches. Everything
	else works while held, which is what makes mowing a line feel like one
	continuous action rather than a string of clicks.
]]
function MowController.press()
	local tool = equipped()
	if tool and tool.toggle then
		setMowing(not mowing)
	else
		setMowing(true)
	end
end

--- The trigger coming up. A latched tool ignores it and keeps running.
function MowController.release()
	local tool = equipped()
	if not (tool and tool.toggle) then
		setMowing(false)
	end
end

--[[
	A tap on the world, which is how a touch game says "act here".

	On a phone or tablet the only trigger used to be the round tool button in
	the corner, so the screen itself was dead: tapping the pile in front of you
	did nothing, which is backwards on a platform where tapping the thing is
	the first thing anybody tries. A tap now works the tool for a beat — long
	enough for the intent loop to take a real bite out of whatever the tool is
	pointed at — and tapping again before the beat is up simply extends it, so
	drumming on the screen reads as continuous work. A latched tool (the
	blower) treats a tap as its switch, same as its button.

	Held separately from press/release so a tap's delayed let-go can tell
	whether it is still the most recent thing that happened, rather than
	cutting short a newer tap.
]]
local TAP_BURST_SECONDS = 0.45
local tapCount = 0

function MowController.tap()
	local tool = equipped()
	if tool and tool.toggle then
		MowController.press()
		return
	end
	tapCount += 1
	local tap = tapCount
	MowController.press()
	task.delay(TAP_BURST_SECONDS, function()
		if tap == tapCount then
			MowController.release()
		end
	end)
end

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

	-- Heading comes from the camera, because the game is played down the barrel:
	-- the crosshair is a promise that what it covers is what the tool works on,
	-- and reading the character instead would break that every time the player
	-- strafed.
	local flat = Aim.direction()

	intentRemote:FireServer({
		position = root.Position,
		look = flat,
		toolId = state.equippedTool,
	})

	--[[
		Fractional passes are carried between ticks, exactly as the server
		carries them.

		Without the carry the prediction was dead for every tool in the early
		game: bare hands earn 0.12 of a pass in a tenth of a second, `predict`
		floors that to nothing and returns, and so the grass only ever moved
		when the server's chunk delta arrived and not one gain number was ever
		shown. The server has always accumulated the remainder; this is the
		same sum on the same numbers.
	]]
	local tool = Tools.get(state.equippedTool)
	if tool then
		-- The same tile the server reads, through the same helper: predicting a
		-- dry rate on wet ground would cut grass here and have the server put
		-- it straight back.
		local grid = GrassRenderer.grid()
		local tiles = GrassRenderer.tiles()
		local wet = grid ~= nil
			and tiles ~= nil
			and Cutting.isWetAt(grid, tiles, root.Position.X, root.Position.Z)
		predictCarry += Balance.effectiveCutRate(tool, state.upgrades, wet) * elapsed
		local passes = math.floor(predictCarry)
		if passes > 0 then
			predictCarry -= passes
			predict(root, flat, state.equippedTool, passes)
		end
	end
end

function MowController.start()
	intentRemote = Remotes.unreliable(Remotes.MOW_INTENT)

	-- The server's bag is the real one; drop the guess whenever it arrives.
	PlayerState.Changed:Connect(function()
		predictedWeight = 0
	end)

	-- Bound through ContextActionService so it works on touch and gamepad too,
	-- and so the mobile button is created for us.
	-- Bound without a touch button of its own: the HUD draws the round tool
	-- button, so that one control shows the tool, its state and its name rather
	-- than a generic square with a word on it.
	ContextActionService:BindAction(ACTION_NAME, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			MowController.press()
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			MowController.release()
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2, Enum.KeyCode.E)

	--[[
		The engine has already done the filtering by the time this fires: a
		touch the UI consumed does not reach it, and neither does a drag the
		camera claimed as a look. What is left is a deliberate tap on the
		world, which is the platform's grammar for "use the thing" — the round
		button stays as the hold control, this is the tap one.
	]]
	UserInputService.TouchTapInWorld:Connect(function(_, processedByUI)
		if processedByUI then
			return
		end
		MowController.tap()
	end)

	-- Switching tools mid-swing stops the swing: a latched blower must not keep
	-- running through a rake.
	local lastTool = PlayerState.get().equippedTool
	PlayerState.Changed:Connect(function()
		local held = PlayerState.get().equippedTool
		if held ~= lastTool then
			lastTool = held
			setMowing(false)
		end
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
