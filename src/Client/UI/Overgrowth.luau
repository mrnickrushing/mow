--!strict
--[[
	Overgrowth — the wall, as a card rather than a toast.

	Grass taller than your mower can bite is the game's one hard stop, and it
	was reported by a line of orange text that scrolled away: "The Push Reel
	Mower bogs down here — you need better gear." That names one side of the
	problem. The player is left standing on ground they can see, holding a
	tool that does nothing, with no idea what would take it or whether they
	can afford it.

	So it is a card, and it says the whole thing: what refused, why, what
	shifts it, what that costs against what you have — and the escape hatch,
	which is load-bearing. `Tools.luau` guarantees bare hands can shift
	anything a tile can hold, so a card that only offered a purchase would be
	telling the player the run is stuck when it is not.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Util.Format)
local Props = require(Shared.Config.Props)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local Journal = require(script.Parent.Journal)
local Theme = require(script.Parent.Theme)

local Overgrowth = {}

local player = Players.LocalPlayer
local gui: ScreenGui
local card: Frame
local marker: Part? = nil

--- How long the card stays up if the player neither buys nor dismisses.
local LINGER = 9
--- And how long before the same wall may raise it again, so walking into a
--- hedge for ten seconds is one card rather than a stack of them.
local COOLDOWN = 14

local shownAt = 0
local hideAt = 0

local INK = Theme.colors.outline
local DANGER = Theme.colors.danger

--------------------------------------------------------------------
-- The mark on the ground
--------------------------------------------------------------------

--[[
	The swath that would not cut, drawn where it is.

	The card says which growth refused; this says *there*. Without it the
	player has to work out which of the tiles in front of them the message was
	about, which on a mixed lawn is most of the problem.
]]
local function markGround(at: Vector3?)
	if not at then
		return
	end
	if not marker then
		local part = Instance.new("Part")
		part.Name = "MowOvergrowth"
		part.Size = Vector3.new(9, 0.2, 9)
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Transparency = 1
		part.Parent = Workspace

		local face = Instance.new("SurfaceGui")
		face.Name = "Box"
		face.Face = Enum.NormalId.Top
		face.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		face.PixelsPerStud = 24
		face.Parent = part

		local box = Instance.new("Frame")
		box.Name = "Refused"
		box.Size = UDim2.fromScale(1, 1)
		box.BackgroundColor3 = DANGER
		box.BackgroundTransparency = 0.78
		box.BorderSizePixel = 0
		box.Parent = face
		Theme.corner(box, 10)
		Theme.stroke(box, 4, DANGER, 0)

		marker = part
	end
	local part = marker :: Part
	part.CFrame = CFrame.new(at + Vector3.new(0, 0.12, 0))
	part.Parent = Workspace
end

local function clearGround()
	if marker then
		(marker :: Part).Parent = nil
	end
end

--------------------------------------------------------------------
-- The card
--------------------------------------------------------------------

local function clear()
	for _, child in card:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function draw(wall: any)
	clear()

	--- Row one: what refused, and why.
	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.Size = UDim2.fromOffset(56, 56)
	badge.BackgroundColor3 = DANGER
	badge.BorderSizePixel = 0
	badge.Parent = card
	Theme.corner(badge, 16)
	Theme.stroke(badge, 4, INK, 0)
	Theme.text({
		name = "Mark",
		text = "!",
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0, 0),
		parent = badge,
		align = Enum.TextXAlignment.Center,
		textSize = 30,
	})

	local headline = Theme.text({
		name = "Headline",
		text = `This {string.lower(tostring(wall.debris))} is too thick for the {wall.toolName}`,
		size = UDim2.new(1, -74, 0, 32),
		position = UDim2.fromOffset(74, 0),
		parent = card,
		align = Enum.TextXAlignment.Left,
		textSize = 28,
	})
	headline.TextTruncate = Enum.TextTruncate.AtEnd

	Theme.text({
		name = "Reason",
		text = `Your deck bogs down at cut power {wall.toolHeight}. This growth needs {wall.height}.`,
		size = UDim2.new(1, -74, 0, 24),
		position = UDim2.fromOffset(74, 34),
		parent = card,
		align = Enum.TextXAlignment.Left,
		color = Color3.fromRGB(232, 184, 176),
		textSize = 17,
		bold = false,
	})

	--- Row two: the fix, and the way to it.
	local fix = Instance.new("Frame")
	fix.Name = "Fix"
	fix.Size = UDim2.new(1, 0, 0, 84)
	fix.Position = UDim2.fromOffset(0, 74)
	fix.BackgroundColor3 = Color3.fromRGB(30, 22, 16)
	fix.BorderSizePixel = 0
	fix.Parent = card
	Theme.corner(fix, 16)
	Theme.stroke(fix, 3, INK, 0)
	Theme.pad(fix, 12, 14, 12, 14)

	local tool = if wall.fixId then Tools.get(wall.fixId) else nil
	if tool then
		local well = Instance.new("Frame")
		well.Name = "Well"
		well.Size = UDim2.fromOffset(56, 56)
		well.Position = UDim2.fromScale(0, 0.5)
		well.AnchorPoint = Vector2.new(0, 0.5)
		well.BackgroundColor3 = Color3.fromRGB(44, 33, 24)
		well.BorderSizePixel = 0
		well.Parent = fix
		Theme.corner(well, 12)
		Theme.stroke(well, 3, INK, 0)
		Theme.icon({
			name = "Icon",
			prop = Props.forTool(tool.id, tool.category),
			size = UDim2.fromScale(0.84, 0.84),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
			parent = well,
		})

		Theme.text({
			name = "Heading",
			text = "THE FIX",
			size = UDim2.fromOffset(200, 18),
			position = UDim2.fromOffset(70, 2),
			parent = fix,
			align = Enum.TextXAlignment.Left,
			color = Theme.colors.label,
			textSize = 14,
		})
		--- The stat that refused, and only that one: the deck width is the
		--- tool's headline everywhere else and is not what stopped this cut.
		Theme.text({
			name = "Tool",
			text = `{tool.name} · cut power {tool.maxHeight}`,
			size = UDim2.new(1, -290, 0, 26),
			position = UDim2.fromOffset(70, 22),
			parent = fix,
			align = Enum.TextXAlignment.Left,
			color = Theme.colors.progress,
			textSize = 21,
		})

		local afford = (tonumber(wall.cash) or 0) >= (tonumber(wall.fixCost) or 0)
		local cta = Theme.chunkButton({
			name = "Open",
			variant = if wall.owned then "gold" elseif afford then "primary" else "disabled",
			text = if wall.owned
				then `EQUIP THE {string.upper(tool.name)}`
				else `OPEN THE SHED — {Format.cash(tool.cost)}`,
			textSize = 19,
			size = UDim2.fromOffset(258, 52),
			position = UDim2.fromScale(1, 0.5),
			anchor = Vector2.new(1, 0.5),
			parent = fix,
			radius = 13,
			outline = 3,
		})
		cta.Modal = true
		cta.Activated:Connect(function()
			--[[
				Straight to the tool, not merely to the shed.

				"Open the shed" and then a page of sixteen tools is the same
				answer as the toast, one click further away.
			]]
			Overgrowth.hide()
			Journal.openTool(tool.id)
		end)
	else
		Theme.text({
			name = "Heading",
			text = "NOTHING IN THE SHED SHIFTS THIS — YOUR HANDS WILL",
			size = UDim2.fromScale(1, 1),
			position = UDim2.fromScale(0, 0),
			parent = fix,
			align = Enum.TextXAlignment.Left,
			color = Theme.colors.label,
			textSize = 18,
		})
	end

	--- Row three: what you have, and the way out that is not a purchase.
	Theme.text({
		name = "Escape",
		text = `You have {Format.cash(tonumber(wall.cash) or 0)}. Bare hands will shift it too — just slowly.`,
		size = UDim2.new(1, -130, 0, 24),
		position = UDim2.fromOffset(0, 172),
		parent = card,
		align = Enum.TextXAlignment.Left,
		color = Color3.fromRGB(201, 179, 148),
		textSize = 16,
		bold = false,
	})

	local dismiss = Theme.chip({
		name = "Dismiss",
		size = UDim2.fromOffset(112, 30),
		position = UDim2.new(1, 0, 0, 169),
		anchor = Vector2.new(1, 0),
		parent = card,
		radius = Theme.PILL,
	})
	Theme.stroke(dismiss, 3, INK, 0)
	local dismissHit = Instance.new("TextButton")
	dismissHit.Name = "Hit"
	dismissHit.Size = UDim2.fromScale(1, 1)
	dismissHit.BackgroundTransparency = 1
	dismissHit.Text = "DISMISS"
	dismissHit.Font = Theme.font
	dismissHit.TextColor3 = Theme.colors.label
	dismissHit.TextSize = 15
	dismissHit.Modal = true
	dismissHit.Parent = dismiss
	dismissHit.Activated:Connect(function()
		Overgrowth.hide()
	end)
end

--------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------

function Overgrowth.hide()
	if not gui or not gui.Enabled then
		return
	end
	gui.Enabled = false
	clearGround()
	clear()
end

function Overgrowth.show(wall: any)
	if not gui or type(wall) ~= "table" then
		return
	end
	local now = os.clock()
	if now - shownAt < COOLDOWN and gui.Enabled then
		--- Already saying it. Push the deadline out rather than redraw under
		--- the player's finger.
		hideAt = now + LINGER
		return
	end
	shownAt = now
	hideAt = now + LINGER

	draw(wall)
	markGround(wall.at)
	gui.Enabled = true

	card.BackgroundTransparency = 1
	TweenService:Create(card, TweenInfo.new(0.2), { BackgroundTransparency = 0 }):Play()
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "MowOvergrowth"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.DisplayOrder = 9
	gui.Parent = player:WaitForChild("PlayerGui")

	card = Theme.chunkPanel({
		name = "Card",
		size = UDim2.fromOffset(700, 218),
		position = UDim2.new(0.5, 0, 1, -78),
		anchor = Vector2.new(0.5, 1),
		parent = gui,
		radius = 22,
		drop = 8,
		outline = 5,
		top = Color3.fromRGB(74, 38, 32),
		bottom = Color3.fromRGB(46, 24, 20),
	})
	local ring = card:FindFirstChildOfClass("UIStroke")
	if ring then
		ring.Color = DANGER
	end
	Theme.pad(card, 20, 24, 22, 24)
	Theme.fitToViewport(card.Parent :: GuiObject, 740, 320)
end

function Overgrowth.start()
	build()

	--[[
		A card that cannot draw must not take the game with it.

		This runs inside a remote handler, which is the one place where an
		error is invisible: the player would see a tool that refuses ground
		and nothing else at all, which is the bug this screen exists to fix.
	]]
	Remotes.event(Remotes.OVERGROWTH).OnClientEvent:Connect(function(wall: any)
		xpcall(function()
			Overgrowth.show(wall)
		end, function(message)
			warn(`[Overgrowth] the card did not draw: {message}`)
		end)
	end)

	--- It takes itself away: a card about a refusal should not become a thing
	--- the player has to clear before they can carry on.
	task.spawn(function()
		while true do
			task.wait(0.5)
			if gui and gui.Enabled and os.clock() >= hideAt then
				Overgrowth.hide()
			end
		end
	end)
end

return Overgrowth
