--!strict
--[[
	Hud — everything on screen that is not the world.

	Laid out to match the reference. The right-hand column carries the numbers
	that change while you work — the multiplier, the cash, the tool and whether
	it is running. The bag sits bottom-left, out of the way of the ground you are
	looking at. Nothing has a panel behind it: the outline on every label is what
	carries legibility against a lawn covered in bright orange leaves.

	The middle of the screen is left almost empty on purpose. A crosshair, the
	rate you are being paid, and the money each armful just earned floating up
	beside it — that is the whole feedback loop, and putting any of it in a
	corner would mean looking away from the leaves to read it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Debris = require(Shared.Config.Debris)
local Loop = require(Shared.Util.Loop)
local RunOnly = require(script.Parent.RunOnly)
local Format = require(Shared.Util.Format)
local Remotes = require(Shared.Remotes)
local Tools = require(Shared.Config.Tools)
local MowController = require(script.Parent.Parent.Controllers.MowController)
local Journal = require(script.Parent.Journal)
local Store = require(script.Parent.Store)
local PlayerState = require(script.Parent.Parent.PlayerState)
local Theme = require(script.Parent.Theme)
local Props = require(Shared.Config.Props)
local SoundController = require(script.Parent.Parent.Controllers.SoundController)

local Hud = {}

local player = Players.LocalPlayer

local cashLabel: TextLabel
local multiplierLabel: TextLabel
local tipsLabel: TextLabel
local bagCountLabel: TextLabel
local bagCapacityLabel: TextLabel
local rateLabel: TextLabel
local purseHolder: Frame
local tipsHolder: Frame
local multiplierHolder: Frame
local toolButton: TextButton
--[[
	The word the first run puts under the tool button, or nothing.

	`refresh` writes that label five times a second from `MowController`, so a
	coaching step cannot simply set it and walk away — it has to be the thing
	refresh is reading.
]]
local coachWord: string? = nil
local toolIcon: Frame
local toolStateLabel: TextLabel
local toolNameLabel: TextLabel
local bagSack: Frame? = nil
local bagFill: Frame
--- The sack's own colour, kept so the full-bag red can be undone.
local BAG_SACK_COLOUR = Color3.fromRGB(158, 158, 160)
local journalBadge: Frame
local gainHolder: Frame
local toastHolder: Frame
local bannerHolder: Frame
local fuelPanel: Frame
local fuelFill: Frame
local fuelLabel: TextLabel
local hintLabel: TextLabel

local toastOrder = 0

--[[
	The bottom edge belongs to the hotbar, and everything above it stacks.

	The hotbar and the bag are anchored to the bottom by a pixel offset; the
	hint line and the toasts were placed at 0.86 and 0.74 of the screen's
	height. Those agree on a tall screen and converge on a short one, so on a
	phone the toasts and the hint were drawn on top of the tool slots —
	measured at 1136x640, 560x46 and 520x26 of overlap, and worse at 1024x576.
	None of it shows up on a desktop, which is why it lasted.

	Measuring these off the bottom edge instead keeps the same stack at every
	height. The numbers are chosen so a tall screen lands where it already did.
]]
--- The hotbar's own band: 80 pixels of slots and the 12 it sits clear by.
local HOTBAR_BAND = 92
--- Breathing room between the stacked rows.
local GUTTER = 8
--- Bottom offsets for the two rows that sit above the hotbar.
local HINT_BOTTOM = HOTBAR_BAND + GUTTER
local TOAST_BOTTOM = HINT_BOTTOM + 26 + GUTTER

local NOTICE_COLORS: { [string]: Color3 } = {
	sale = Theme.colors.cash,
	stripe = Theme.colors.tips,
	locked = Theme.colors.warn,
	stall = Theme.colors.warn,
	bagFull = Theme.colors.danger,
	tooFar = Theme.colors.warn,
	purchase = Theme.colors.grass,
	reward = Theme.colors.tips,
	quest = Theme.colors.cash,
	round = Theme.colors.accent,
	denied = Theme.colors.danger,
	afford = Theme.colors.cash,
	sectionClear = Theme.colors.cash,
	sectionUnlock = Theme.colors.cash,
}

--------------------------------------------------------------------
-- Pieces
--------------------------------------------------------------------

--- A filled circle. Roblox has no circle primitive, so it is a square with its
--- corner radius run all the way to half its width.
local function circle(parent: Instance, diameter: number, color: Color3): Frame
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(diameter, diameter)
	frame.BackgroundColor3 = color
	frame.BorderSizePixel = 0
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = frame

	return frame
end

--------------------------------------------------------------------
-- Build
--------------------------------------------------------------------

local function buildCrosshair(gui: ScreenGui)
	--[[
		A small hollow diamond: a rotated square outline. Big enough to find,
		small enough not to cover the leaf it is sitting on.

		Two rings, not one. A white outline alone disappears into a pale
		flagstone and into the sky over a roof; the ink halo behind it is what
		makes the same eleven pixels legible on every surface in the game
		without making them any bigger.
	]]
	local halo = Instance.new("Frame")
	halo.Name = "Crosshair"
	halo.Size = UDim2.fromOffset(14, 14)
	halo.Position = UDim2.fromScale(0.5, 0.5)
	halo.AnchorPoint = Vector2.new(0.5, 0.5)
	halo.Rotation = 45
	halo.BackgroundTransparency = 1
	halo.Parent = gui
	RunOnly.add(halo)
	Theme.corner(halo, 2)

	local outer = Instance.new("UIStroke")
	outer.Thickness = 5
	outer.Color = Theme.colors.outline
	outer.Transparency = 0.55
	outer.Parent = halo

	local mark = Instance.new("Frame")
	mark.Name = "Mark"
	mark.Size = UDim2.fromScale(1, 1)
	mark.BackgroundTransparency = 1
	mark.Parent = halo
	Theme.corner(mark, 2)

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Theme.colors.text
	stroke.Transparency = 0.08
	stroke.Parent = mark
end

--[[
	Everything down the right-hand edge, and the two controls at the bottom.

	Three groups, and the order they are read in: what you have (money, top
	right), where you can go (the rail), and what you are holding (the tool,
	bottom right, where the hand already is).

	The rail used to be two cream tiles at six and four degrees of tilt with
	the store pill at five. Straight tiles with a caption under each read as
	deliberate; tilted ones read as a mistake, and they were the loudest thing
	on the screen saying so.
]]
local function buildRightColumn(gui: ScreenGui)
	local column = Instance.new("Frame")
	column.Name = "Status"
	column.Size = UDim2.fromOffset(240, 460)
	column.Position = UDim2.new(1, -22, 0, 22)
	column.AnchorPoint = Vector2.new(1, 0)
	column.BackgroundTransparency = 1
	column.Parent = gui

	--[[
		The column is laid out in fixed pixels running down from the top edge,
		so on a short viewport its lower half ran off the bottom of the screen.
		Scaling it to the room actually left below its start keeps the whole
		column on screen, and leaves it untouched at its designed size on any
		display tall enough for it.
	]]
	Theme.fitToViewport(column, 260, 460, 40, nil, nil, true)

	----------------------------------------------------------------
	-- Money
	----------------------------------------------------------------

	local purse = Theme.chunkPanel({
		name = "Purse",
		size = UDim2.fromOffset(212, 58),
		position = UDim2.fromScale(1, 0),
		anchor = Vector2.new(1, 0),
		parent = column,
		radius = Theme.PILL,
	})

	-- The coin is drawn rather than an image so there is no asset to upload, and
	-- it reads at a glance as "this number is money" the way a $ alone does not.
	purseHolder = purse.Parent :: Frame

	local coin = circle(purse, 40, Color3.fromRGB(255, 224, 138))
	coin.Name = "Coin"
	coin.Position = UDim2.new(0, 10, 0.5, 0)
	coin.AnchorPoint = Vector2.new(0, 0.5)
	Theme.stroke(coin, 3, Theme.colors.outline, 0)
	local coinGrade = Instance.new("UIGradient")
	coinGrade.Color = ColorSequence.new(Color3.fromRGB(255, 224, 138), Color3.fromRGB(255, 176, 32))
	coinGrade.Rotation = 90
	coinGrade.Parent = coin

	local inner = circle(coin, 18, Color3.fromRGB(246, 196, 84))
	inner.Position = UDim2.fromScale(0.5, 0.5)
	inner.AnchorPoint = Vector2.new(0.5, 0.5)
	Theme.stroke(inner, 2.5, Color3.fromRGB(200, 138, 24), 0)

	cashLabel = Theme.text({
		name = "Cash",
		text = "$0.00",
		size = UDim2.new(1, -74, 1, 0),
		position = UDim2.new(1, -18, 0, 0),
		anchor = Vector2.new(1, 0),
		parent = purse,
		align = Enum.TextXAlignment.Right,
		textSize = 34,
	})

	--[[
		Tips and the multiplier, on two chips under the purse.

		Both are hidden at zero, as they always were: a brand new run should
		not carry a decoration that says nothing. They were plain text on the
		lawn before, which is the one place two small numbers cannot be read.
	]]
	local tipsChip = Theme.chip({
		name = "TipsChip",
		size = UDim2.fromOffset(110, 28),
		position = UDim2.new(1, -108, 0, 68),
		anchor = Vector2.new(1, 0),
		parent = column,
	})

	tipsHolder = tipsChip

	local tipsDot = circle(tipsChip, 11, Theme.colors.tips)
	tipsDot.Position = UDim2.new(0, 13, 0.5, 0)
	tipsDot.AnchorPoint = Vector2.new(0, 0.5)

	tipsLabel = Theme.text({
		name = "Tips",
		text = "",
		size = UDim2.new(1, -37, 1, 0),
		position = UDim2.fromOffset(31, 0),
		parent = tipsChip,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.tips,
		textSize = 16,
	})

	local multiplierChip = Theme.chip({
		name = "MultiplierChip",
		size = UDim2.fromOffset(92, 28),
		position = UDim2.new(1, 0, 0, 68),
		anchor = Vector2.new(1, 0),
		parent = column,
	})

	multiplierHolder = multiplierChip

	multiplierLabel = Theme.text({
		name = "Multiplier",
		text = "",
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0, 0),
		parent = multiplierChip,
		align = Enum.TextXAlignment.Center,
		color = Theme.colors.cash,
		textSize = 16,
	})

	----------------------------------------------------------------
	-- The rail
	----------------------------------------------------------------

	--- One cream tile, straight, with the ink outline and drop the rest of
	--- the chrome uses.
	local function tile(name: string, y: number): TextButton
		local face = Theme.cardFace({
			name = name,
			size = UDim2.fromOffset(76, 76),
			position = UDim2.new(1, 0, 0, y),
			anchor = Vector2.new(1, 0),
			parent = column,
			radius = 20,
			drop = 6,
			top = Color3.fromRGB(255, 246, 238),
			bottom = Color3.fromRGB(232, 205, 188),
		})
		local hit = Instance.new("TextButton")
		hit.Name = "Hit"
		hit.Size = UDim2.fromScale(1, 1)
		hit.BackgroundTransparency = 1
		hit.Text = ""
		hit.AutoButtonColor = false
		hit.ZIndex = face.ZIndex + 2
		hit.Parent = face
		return hit
	end

	--- The word under a tile, on a dark chip. A name works on every screen,
	--- where a key hint is a lie on one with no keyboard.
	local function caption(name: string, word: string, y: number): TextLabel
		local chip = Theme.chip({
			name = name .. "Chip",
			size = UDim2.fromOffset(104, 24),
			position = UDim2.new(1, -(76 - 104) * 0.5, 0, y),
			anchor = Vector2.new(1, 0),
			parent = column,
		})
		return Theme.text({
			name = name,
			text = word,
			size = UDim2.fromScale(1, 1),
			position = UDim2.fromScale(0, 0),
			parent = chip,
			align = Enum.TextXAlignment.Center,
			color = Theme.colors.progress,
			textSize = 14,
		})
	end

	local book = tile("Journal", 128)
	--[[
		Filling the tile, ribbon over the edge and all.

		This was fixed once — the icon was a small drawing centred in a cream
		square, which reads as a picture of a journal rather than as a journal
		— and the wave that rebuilt the rail put it back to a little over half.
		The handoff is explicit about keeping the larger number, and the reason
		is the same one as the first time: at tile size an object that touches
		its frame is a thing, and one that floats inside it is a drawing.
	]]
	Theme.icon({
		name = "BookIcon",
		prop = "Journal",
		size = UDim2.fromScale(1.02, 1.02),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = book.Parent :: GuiObject,
	})
	book.Activated:Connect(function()
		Journal.toggle()
	end)

	journalBadge = circle(book.Parent :: GuiObject, 28, Theme.colors.danger)
	journalBadge.Name = "Badge"
	journalBadge.Position = UDim2.fromOffset(-8, -8)
	journalBadge.ZIndex = book.ZIndex + 1
	Theme.stroke(journalBadge, 3, Theme.colors.outline, 0)

	local bang = Theme.text({
		name = "Bang",
		text = "!",
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0, 0),
		parent = journalBadge,
		align = Enum.TextXAlignment.Center,
		textSize = 16,
	})
	bang.TextYAlignment = Enum.TextYAlignment.Center

	local bookLabel = caption("BookLabel", "JOURNAL", 210)
	--- The holder, not the face: the face's parent carries the drop, and
	--- hiding the face alone leaves a black square on the lawn.
	RunOnly.piece("rail", (book.Parent :: Frame).Parent :: GuiObject, true)
	--- Named, but not hidden from here: `layoutTiles` owns whether a caption
	--- is up, because on a phone it is down whatever the gate says.
	RunOnly.piece("rail", bookLabel.Parent :: Frame)

	local soundHit = tile("Sound", 246)
	local soundFace = soundHit.Parent :: Frame

	--[[
		A quaver drawn from three rectangles, not the character U+266A.

		Every other icon on this screen is art the game ships. This one was a
		glyph, which is drawn by whatever font the player's device resolves and
		is the exact fault `Props.luau` calls out about typeset symbols — and
		there is no `Speaker` or `Note` prop to reach for instead. A circle, a
		bar and a tilted bar is a note on every device there is, and it takes
		the tile's ink colour like everything else here.
	]]
	local note = Instance.new("Frame")
	note.Name = "Note"
	note.Size = UDim2.fromScale(0.52, 0.52)
	note.Position = UDim2.fromScale(0.5, 0.5)
	note.AnchorPoint = Vector2.new(0.5, 0.5)
	note.BackgroundTransparency = 1
	note.Parent = soundFace

	local noteParts: { Frame } = {}
	local function notePart(name: string, size: UDim2, position: UDim2, radius: number, rotation: number): Frame
		local part = Instance.new("Frame")
		part.Name = name
		part.Size = size
		part.Position = position
		part.AnchorPoint = Vector2.new(0.5, 0.5)
		part.Rotation = rotation
		part.BackgroundColor3 = Theme.colors.outline
		part.BorderSizePixel = 0
		part.Parent = note
		Theme.corner(part, radius)
		table.insert(noteParts, part)
		return part
	end

	--[[
		A beamed pair, not a single quaver.

		Two heads under two stems with a bar across their tops, which is what
		the handoff's mock draws and the shape everything else in the world
		uses for "sound". One note on its own reads as a note; two joined read
		as music, and the beam gives the thing a top edge at tile size where a
		lone flag is three pixels of nothing.
	]]
	notePart("HeadLeft", UDim2.fromScale(0.36, 0.27), UDim2.fromScale(0.25, 0.82), 999, -18)
	notePart("HeadRight", UDim2.fromScale(0.36, 0.27), UDim2.fromScale(0.75, 0.7), 999, -18)
	notePart("StemLeft", UDim2.fromScale(0.09, 0.72), UDim2.fromScale(0.42, 0.47), 2, 0)
	notePart("StemRight", UDim2.fromScale(0.09, 0.72), UDim2.fromScale(0.92, 0.35), 2, 0)
	notePart("Beam", UDim2.fromScale(0.58, 0.15), UDim2.fromScale(0.67, 0.14), 3, -12)

	local soundLabel = caption("SoundLabel", "SOUND ON", 328)
	RunOnly.piece("rail", soundFace.Parent :: GuiObject, true)
	RunOnly.piece("rail", soundLabel.Parent :: Frame)

	--[[
		The store is a pill, not a third tile.

		Three identical squares in a row say "three settings"; nothing about a
		coin on a yellow square says the third one spends real money. A wide
		pill with the word on it is the only one of the three that reads as
		somewhere to go rather than something to toggle, which is what it is.
	]]
	local shop = Theme.chunkButton({
		name = "Store",
		variant = "gold",
		size = UDim2.fromOffset(158, 52),
		position = UDim2.new(1, 0, 0, 364),
		anchor = Vector2.new(1, 0),
		parent = column,
		radius = Theme.PILL,
		drop = 6,
		outline = 4,
	})

	local shopCoin = circle(shop, 30, Color3.fromRGB(255, 240, 188))
	shopCoin.Name = "StoreCoin"
	shopCoin.Position = UDim2.new(0, 12, 0.5, 0)
	shopCoin.AnchorPoint = Vector2.new(0, 0.5)
	shopCoin.ZIndex = shop.ZIndex + 1
	Theme.stroke(shopCoin, 3, Theme.colors.outline, 0)

	local shopWord = Theme.text({
		name = "StoreWord",
		text = "STORE",
		size = UDim2.new(1, -56, 1, 0),
		position = UDim2.fromOffset(50, 0),
		parent = shop,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.outline,
		textSize = 20,
	})
	shopWord.ZIndex = shop.ZIndex + 1

	RunOnly.piece("rail", shop.Parent :: GuiObject, true)

	shop.Activated:Connect(function()
		Store.toggle()
	end)

	--[[
		On a phone the rail stacks down the edge and drops its captions.

		A phone is short and wide: there is no vertical room to spare in the
		middle and plenty of it at the sides, which is the opposite of a
		tablet. Three words stacked down the edge of a four-hundred-point
		screen is more furniture than the icons themselves, and the store stops
		being a wide pill for the same reason — at fifty square with the word
		on it, it is still the only gold thing on the rail and still says what
		it is.

		Fifty rather than the seventy-six a tablet gets, and no smaller: the
		handoff's floor is forty-four points on the shortest side of anything
		a finger has to hit, which is why the column is `ownLayout` and stays
		at full size here instead of being shrunk to fit.
	]]
	local function layoutTiles()
		local phone = Theme.isPhone()
		local tiles = { book.Parent :: Frame, soundFace }
		local labels = { bookLabel, soundLabel }
		for index, face in tiles do
			local holder = face.Parent :: Frame
			if phone then
				holder.Size = UDim2.fromOffset(50, 50)
				--- A hundred and four, not eighty-six: the tips and multiplier
				--- chips sit at sixty-eight and are twenty-eight tall, and the
				--- first tile was drawn over the end of the multiplier.
				holder.Position = UDim2.new(1, 0, 0, 104 + (index - 1) * 58)
			else
				holder.Size = UDim2.fromOffset(76, 76)
				holder.Position = UDim2.new(1, 0, 0, 128 + (index - 1) * 118)
			end
			Theme.reround(face, if phone then 14 else 20)
			local chip = labels[index].Parent :: Frame
			--- The first run holds the whole rail back, captions included, so
			--- this is not the only rule about whether they are up.
			chip.Visible = not phone and not RunOnly.isHeld(chip)
		end

		local shopHolder = shop.Parent :: Frame
		if phone then
			shopHolder.Size = UDim2.fromOffset(50, 50)
			shopHolder.Position = UDim2.new(1, 0, 0, 104 + #tiles * 58)
			shopCoin.Visible = false
			shopWord.TextSize = 11
			shopWord.TextXAlignment = Enum.TextXAlignment.Center
			shopWord.Size = UDim2.fromScale(1, 1)
			shopWord.Position = UDim2.fromOffset(0, 0)
			Theme.reround(shop, 14)
		else
			shopHolder.Size = UDim2.fromOffset(158, 52)
			shopHolder.Position = UDim2.new(1, 0, 0, 364)
			shopCoin.Visible = true
			shopCoin.Size = UDim2.fromOffset(30, 30)
			shopWord.TextSize = 20
			shopWord.TextXAlignment = Enum.TextXAlignment.Left
			shopWord.Size = UDim2.new(1, -56, 1, 0)
			shopWord.Position = UDim2.fromOffset(50, 0)
			Theme.reround(shop, Theme.PILL)
		end
	end

	Theme.onScreenChange(layoutTiles)
	--- The captions are the one piece two rules decide, so the gate has to say
	--- when it moves.
	RunOnly.onGate(layoutTiles)

	----------------------------------------------------------------
	-- Fuel and the tool
	----------------------------------------------------------------

	fuelPanel = Theme.chunkPanel({
		name = "Fuel",
		size = UDim2.fromOffset(196, 62),
		position = UDim2.new(1, -22, 1, -300),
		anchor = Vector2.new(1, 1),
		parent = gui,
		radius = 16,
	})
	Theme.pad(fuelPanel, 9, 12, 11, 12)
	;(fuelPanel.Parent :: Frame).Visible = false
	RunOnly.piece("fuel", fuelPanel.Parent :: Frame)
	Theme.chromeScale(fuelPanel.Parent :: Frame, true)

	Theme.text({
		name = "FuelWord",
		text = "FUEL",
		size = UDim2.fromOffset(60, 18),
		position = UDim2.fromOffset(0, 0),
		parent = fuelPanel,
		color = Theme.colors.warn,
		textSize = 14,
	})

	fuelLabel = Theme.text({
		name = "FuelLabel",
		text = "",
		size = UDim2.fromOffset(100, 18),
		position = UDim2.fromScale(1, 0),
		anchor = Vector2.new(1, 0),
		parent = fuelPanel,
		align = Enum.TextXAlignment.Right,
		color = Theme.colors.progress,
		textSize = 15,
	})

	local fuelTrack = Instance.new("Frame")
	fuelTrack.Name = "Track"
	fuelTrack.Size = UDim2.new(1, 0, 0, 16)
	fuelTrack.Position = UDim2.fromOffset(0, 25)
	fuelTrack.BackgroundColor3 = Theme.colors.outline
	fuelTrack.BorderSizePixel = 0
	fuelTrack.ClipsDescendants = true
	fuelTrack.Parent = fuelPanel
	Theme.corner(fuelTrack, 8)

	fuelFill = Instance.new("Frame")
	fuelFill.Name = "Fill"
	fuelFill.Size = UDim2.fromScale(0, 1)
	fuelFill.BackgroundColor3 = Color3.fromRGB(255, 192, 103)
	fuelFill.BorderSizePixel = 0
	fuelFill.Parent = fuelTrack
	Theme.corner(fuelFill, 8)
	local fuelGrade = Instance.new("UIGradient")
	fuelGrade.Color = ColorSequence.new(Color3.fromRGB(255, 192, 103), Color3.fromRGB(240, 130, 28))
	fuelGrade.Rotation = 90
	fuelGrade.Parent = fuelFill

	--[[
		The tool button sits above Roblox's jump button, not in the column.

		`parkTool` measures the real jump control rather than guessing an
		inset, because Roblox sizes and places that one itself and it is not
		the same on a phone as on a tablet. The redesign changes the sizes and
		nothing else about how it is measured.
	]]
	toolButton = Instance.new("TextButton")
	toolButton.Name = "Tool"
	toolButton.Size = UDim2.fromOffset(124, 124)
	toolButton.Position = UDim2.new(1, -22, 1, -240)
	toolButton.AnchorPoint = Vector2.new(1, 1)
	toolButton.BackgroundColor3 = Color3.fromRGB(78, 58, 40)
	toolButton.BorderSizePixel = 0
	toolButton.Text = ""
	toolButton.AutoButtonColor = false
	-- Off until the first refresh says otherwise, so it cannot flash up in
	-- the lobby on the frame between being built and being told.
	toolButton.Visible = false
	toolButton.Parent = gui
	RunOnly.piece("tool", toolButton)

	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0.5, 0)
	round.Parent = toolButton
	local toolGrade = Instance.new("UIGradient")
	toolGrade.Color = ColorSequence.new(Color3.fromRGB(78, 58, 40), Color3.fromRGB(44, 33, 24))
	toolGrade.Rotation = 90
	toolGrade.Parent = toolButton
	Theme.stroke(toolButton, 5, Theme.colors.outline, 0)

	toolIcon = Theme.icon({
		name = "Icon",
		prop = Props.FALLBACK_TOOL_ICON,
		size = UDim2.fromScale(0.63, 0.63),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = toolButton,
	})

	--[[
		The name of the thing in your hand.

		The button showed a picture and a verb — PICK UP, MOW — and never once
		said what you were holding. With one icon per family that was close to
		unreadable: six mowers shared a drawing, so the only way to know which
		you had was to remember what you last bought.
	]]
	toolNameLabel = Theme.text({
		name = "ToolName",
		text = "",
		size = UDim2.fromOffset(220, 26),
		position = UDim2.new(1, -5, 1, -238),
		anchor = Vector2.new(1, 1),
		parent = gui,
		align = Enum.TextXAlignment.Center,
		color = Theme.colors.text,
		textSize = 21,
	})
	RunOnly.add(toolNameLabel)

	local stateChip = Theme.chip({
		name = "StateChip",
		size = UDim2.fromOffset(160, 34),
		position = UDim2.new(1, -5, 1, -212),
		anchor = Vector2.new(1, 1),
		parent = gui,
	})
	RunOnly.add(stateChip)

	toolStateLabel = Theme.text({
		name = "State",
		text = "",
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0, 0),
		parent = stateChip,
		align = Enum.TextXAlignment.Center,
		color = Theme.colors.cash,
		textSize = 22,
	})

	--[[
		Puts the tool button, its two labels and the fuel gauge above the jump
		button. Measured rather than guessed; where there is no jump button —
		a mouse, where this is a readout rather than a control — the fallback
		inset is used.
	]]
	--[[
		The tool button and the gauge, on a phone.

		A phone has three hundred and ninety points of height and Roblox's jump
		button is already eating the bottom right of it. A hundred and
		twenty-four point button with a gauge stacked over the name over the
		state word is most of that column; at eighty-four, with the gauge
		tucked in beside the button rather than above it, the stack is two
		items instead of three and the lawn is visible behind it.
	]]
	local function sizeTool()
		local phone = Theme.isPhone()
		local side = if phone then 84 else 124
		toolButton.Size = UDim2.fromOffset(side, side)
		;(fuelPanel.Parent :: Frame).Size = UDim2.fromOffset(if phone then 126 else 196, 62)
		fuelLabel.TextSize = if phone then 13 else 15
		toolNameLabel.TextSize = if phone then 16 else 21
		toolStateLabel.TextSize = if phone then 17 else 22
		stateChip.Size = UDim2.fromOffset(if phone then 120 else 160, if phone then 28 else 34)
	end

	--[[
		A reading of the jump control that can be trusted.

		Roblox lays its own touch controls out, and while it is doing so the
		button reports a position that is nowhere near where it will end up —
		measured here at (630, 332) on a 1375 x 973 screen, which is the middle
		of the sky. Whatever ran `parkTool` on that frame put the tool button,
		its name and its state chip up there with it, and nothing moved them
		back: the next call only comes with the next resize.

		A jump control is always in the bottom-right quarter of the screen. A
		reading that is not is a reading taken mid-layout, and the answer is to
		leave everything where it is and be asked again.
	]]
	local parked = false

	local function jumpControl(area: Vector2): GuiObject?
		local playerGui = player:FindFirstChild("PlayerGui")
		local touchGui = playerGui and (playerGui :: any):FindFirstChild("TouchGui")
		local found = touchGui and touchGui:FindFirstChild("JumpButton", true)
		if not (found and found:IsA("GuiObject")) then
			return nil
		end
		local jump = found :: GuiObject
		if jump.AbsoluteSize.Y <= 8 then
			return nil
		end
		local at = jump.AbsolutePosition
		if at.X < area.X * 0.5 or at.Y < area.Y * 0.5 then
			return nil
		end
		return jump
	end

	local function parkTool()
		if not (toolButton and toolStateLabel and toolNameLabel and stateChip) then
			return false
		end
		local area = gui.AbsoluteSize
		local width, height = toolButton.AbsoluteSize.X, toolButton.AbsoluteSize.Y
		if width < 1 or area.X < 1 then
			return false
		end
		local jump = jumpControl(area)
		--- Once it has been placed against a real control, a bad reading is
		--- worth nothing and the last good placement is worth keeping.
		if not jump and parked then
			return false
		end
		local fromRight, fromBottom
		if jump then
			fromRight = area.X - (jump.AbsolutePosition.X + jump.AbsoluteSize.X * 0.5) + width * 0.5
			--[[
				The daylight over the jump button has to hold the word as well
				as the button. The clearance is the chip's own height plus a
				margin either side, measured rather than assumed, so it still
				holds if the text size changes.
			]]
			local stateRoom = stateChip.AbsoluteSize.Y + 10
			fromBottom = area.Y - jump.AbsolutePosition.Y + stateRoom
			parked = true
		else
			fromRight, fromBottom = 26, 250
		end
		toolButton.Position = UDim2.new(1, -fromRight, 1, -fromBottom)

		--- Anchored bottom-right, so each offset is where that element's
		--- bottom edge sits: the name clears the top of the button, the chip
		--- hangs just under it, and the gauge sits above the name.
		local centreFromRight = fromRight - width * 0.5
		local nameBottom = fromBottom + height + 6
		toolNameLabel.Position =
			UDim2.new(1, -(centreFromRight - toolNameLabel.AbsoluteSize.X * 0.5), 1, -nameBottom)
		stateChip.Position = UDim2.new(
			1,
			-(centreFromRight - stateChip.AbsoluteSize.X * 0.5),
			1,
			-(fromBottom - (stateChip.AbsoluteSize.Y + 4))
		)
		local gauge = fuelPanel.Parent :: Frame
		if Theme.isPhone() then
			--[[
				Beside the button, sharing its bottom edge, because there is no
				room for a fourth thing in that column.

				The gauge is anchored bottom-right, so the offset is where its
				right edge goes: ten short of the button's left edge.
			]]
			gauge.Position = UDim2.new(1, -(fromRight + width + 10), 1, -fromBottom)
		else
			gauge.Position = UDim2.new(
				1,
				-(centreFromRight - gauge.AbsoluteSize.X * 0.5),
				1,
				-(nameBottom + toolNameLabel.AbsoluteSize.Y + 8)
			)
		end
		return jump ~= nil
	end

	--[[
		Kept asking until Roblox has drawn its touch controls.

		`TouchGui` does not exist when this builds, so the first call always
		falls back to a fixed inset and the button ends up in roughly the right
		place rather than the right one.
	]]
	task.spawn(function()
		for _ = 1, 40 do
			if parkTool() then
				break
			end
			task.wait(0.25)
		end
	end)

	local function paintSound()
		local on = not SoundController.isMuted()
		soundLabel.Text = if on then "SOUND ON" else "SOUND OFF"
		for _, part in noteParts do
			part.BackgroundTransparency = if on then 0 else 0.55
		end
		soundFace.BackgroundTransparency = if on then 0 else 0.35
	end

	--[[
		Take the saved value the first time the profile arrives.

		Only once: after that the button is the truth, and re-applying on
		every push would fight a player who muted the game a second ago.
	]]
	local soundApplied = false
	PlayerState.Changed:Connect(function()
		if soundApplied then
			return
		end
		soundApplied = true
		SoundController.setMuted(PlayerState.get().sfxEnabled == false)
		paintSound()
	end)

	soundHit.Activated:Connect(function()
		local nowMuted = not SoundController.isMuted()
		SoundController.setMuted(nowMuted)
		paintSound()
		--[[
			One button, both settings.

			A player pressing a speaker icon means "stop making noise", not
			"stop the effects but keep the music".
		]]
		local remote = Remotes.event(Remotes.SETTINGS)
		remote:FireServer("sfx", not nowMuted)
		remote:FireServer("music", not nowMuted)
	end)
	paintSound()

	Theme.onScreenChange(function()
		sizeTool()
		parkTool()
	end)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(parkTool)
	task.defer(parkTool)
end

--[[
	The bag, which is a sack with a level in it.

	The number alone was not readable: "34" beside "90" is arithmetic, and a
	player glancing at the corner of the screen while walking backwards does
	not do arithmetic. The sack has a fill inside it now — the same green the
	completion bar uses, anchored to the bottom and as tall as the fraction —
	so how full it is arrives as a shape before the digits are read.
]]
local function buildBag(gui: ScreenGui)
	local panel = Theme.chunkPanel({
		name = "Bag",
		size = UDim2.fromOffset(212, 86),
		parent = gui,
	})
	Theme.pad(panel, 10, 16, 12, 12)
	local holder = panel.Parent :: Frame
	--[[
		Bottom-left on a keyboard; top-left, under the job panel, on touch.

		The bottom-left corner of a touch screen is where Roblox draws the
		movement thumbstick, and the bag sat squarely on it — a readout under
		a thumb is a readout nobody reads and a thumbstick that starts on a
		sack. With a mouse there is no thumbstick and the corner is free.
	]]
	--[[
		Top left, under the job panel, on every screen.

		It used to sit bottom-left with a mouse and move to the top-left only
		on touch, where Roblox draws the movement thumbstick over that corner
		— a readout under a thumb is a readout nobody reads. Now that the
		hotbar has the bottom-left on every screen, one place for the bag is
		both simpler and the only one that is free everywhere: the job panel
		is 22 down and 121 tall and wants 12 of air under it.
	]]
	holder.Position = UDim2.fromOffset(22, 155)
	holder.AnchorPoint = Vector2.new(0, 0)
	RunOnly.piece("bag", holder)
	RunOnly.add(holder)
	Theme.chromeScale(holder, true)

	-- A sack: a rounded body with a pinched neck above it.
	local neck = Instance.new("Frame")
	neck.Name = "Neck"
	neck.Size = UDim2.fromOffset(24, 15)
	neck.Position = UDim2.fromOffset(16, 0)
	neck.BackgroundColor3 = Color3.fromRGB(120, 120, 124)
	neck.BorderSizePixel = 0
	neck.Parent = panel
	Theme.corner(neck, 6)
	Theme.stroke(neck, 3, Theme.colors.outline, 0)

	local sack = Instance.new("Frame")
	sack.Name = "Sack"
	bagSack = sack
	sack.Size = UDim2.fromOffset(56, 51)
	sack.Position = UDim2.fromOffset(0, 11)
	sack.BackgroundColor3 = BAG_SACK_COLOUR
	sack.BorderSizePixel = 0
	sack.ClipsDescendants = true
	sack.Parent = panel
	Theme.corner(sack, 18)
	Theme.stroke(sack, 3, Theme.colors.outline, 0)
	local sackGrade = Instance.new("UIGradient")
	sackGrade.Color = ColorSequence.new(Color3.fromRGB(182, 182, 184), Color3.fromRGB(142, 142, 146))
	sackGrade.Rotation = 90
	sackGrade.Parent = sack

	bagFill = Instance.new("Frame")
	bagFill.Name = "Level"
	bagFill.Size = UDim2.new(1, -6, 0, 0)
	bagFill.Position = UDim2.new(0, 3, 1, -3)
	bagFill.AnchorPoint = Vector2.new(0, 1)
	bagFill.BackgroundColor3 = Color3.fromRGB(168, 237, 140)
	bagFill.BorderSizePixel = 0
	bagFill.Parent = sack
	Theme.corner(bagFill, 14)
	local levelGrade = Instance.new("UIGradient")
	levelGrade.Color = ColorSequence.new(Color3.fromRGB(168, 237, 140), Color3.fromRGB(95, 194, 70))
	levelGrade.Rotation = 90
	levelGrade.Parent = bagFill

	bagCountLabel = Theme.text({
		name = "Count",
		text = "0",
		size = UDim2.fromOffset(70, 36),
		position = UDim2.fromOffset(68, 4),
		parent = panel,
		align = Enum.TextXAlignment.Left,
		textSize = 34,
	})

	bagCapacityLabel = Theme.text({
		name = "Capacity",
		text = "/ 0",
		size = UDim2.fromOffset(70, 26),
		position = UDim2.fromOffset(138, 12),
		parent = panel,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.body,
		textSize = 22,
	})

	local bagWord = Theme.text({
		name = "BagWord",
		text = "BAG WEIGHT",
		size = UDim2.fromOffset(140, 18),
		position = UDim2.fromOffset(68, 42),
		parent = panel,
		color = Theme.colors.label,
		textSize = 14,
	})

	--[[
		On a phone the sack shrinks and the caption goes.

		The panel is two hundred and twelve wide against a screen of three
		hundred and ninety points, and the word BAG WEIGHT under a number that
		already has a slash and a capacity beside it is the third way of saying
		the same thing. Thirty-two by thirty-six is small, and it is allowed to
		be: the sack is a readout, not something a finger has to hit.

		The top-left corner is the same on both, because the alternative is the
		bottom-left and that is where Roblox draws the movement thumbstick.
	]]
	Theme.onScreenChange(function()
		local phone = Theme.isPhone()
		holder.Size = UDim2.fromOffset(if phone then 138 else 212, if phone then 56 else 86)
		--- The objective panel is off on a phone, so the corner it was leaving
		--- room for is empty and the bag takes it.
		holder.Position = UDim2.fromOffset(22, if phone then 22 else 155)
		neck.Size = UDim2.fromOffset(if phone then 15 else 24, if phone then 9 else 15)
		neck.Position = UDim2.fromOffset(if phone then 9 else 16, 0)
		sack.Size = UDim2.fromOffset(if phone then 32 else 56, if phone then 36 else 51)
		sack.Position = UDim2.fromOffset(0, if phone then 7 else 11)
		bagCountLabel.TextSize = if phone then 22 else 34
		bagCountLabel.Size = UDim2.fromOffset(if phone then 48 else 70, if phone then 24 else 36)
		bagCountLabel.Position = UDim2.fromOffset(if phone then 42 else 68, if phone then 4 else 4)
		bagCapacityLabel.TextSize = if phone then 15 else 22
		bagCapacityLabel.Size = UDim2.fromOffset(if phone then 48 else 70, if phone then 20 else 26)
		bagCapacityLabel.Position = UDim2.fromOffset(if phone then 88 else 138, if phone then 8 else 12)
		bagWord.Visible = not phone
	end)
end

local function buildMiddle(gui: ScreenGui)
	rateLabel = Theme.text({
		name = "Rate",
		text = "",
		size = UDim2.fromOffset(340, 34),
		--[[
			Under the completion bar, not over it.

			This was pinned fourteen pixels from the top edge, which was clear
			air when the top of the screen was empty. The section bar is a
			panel across the top centre now, a hundred and twenty-eight tall
			and twenty-two down, and the rate was drawn straight through it.
			Below the bar it is still the first thing under the number it is
			about, and the middle of the screen stays empty either side.
		]]
		position = UDim2.new(0.5, 0, 0, 22 + 128 + 8),
		anchor = Vector2.new(0.5, 0),
		parent = gui,
		align = Enum.TextXAlignment.Center,
		color = Theme.colors.cash,
		textSize = 27,
	})
	RunOnly.piece("rate", rateLabel)
	RunOnly.add(rateLabel)
	Theme.chromeScale(rateLabel)
	--- Placed under the completion bar, which is not always the height it was
	--- authored at — two rows on a phone, and scaled down on a tablet too
	--- narrow to hold it beside the columns. `Hud.setBarBottom` is how the bar
	--- says where it actually ended.
	Theme.onScreenChange(function()
		Hud.setBarBottom(22 + (if Theme.isPhone() then 98 else 128))
	end)

	gainHolder = Instance.new("Frame")
	gainHolder.Name = "Gains"
	gainHolder.Size = UDim2.fromOffset(300, 150)
	gainHolder.Position = UDim2.fromScale(0.78, 0.09)
	gainHolder.AnchorPoint = Vector2.new(0.5, 0)
	gainHolder.BackgroundTransparency = 1
	gainHolder.Parent = gui
	Theme.chromeScale(gainHolder)

	hintLabel = Theme.text({
		name = "Hint",
		text = "",
		size = UDim2.fromOffset(520, 26),
		position = UDim2.new(0.5, 0, 1, -HINT_BOTTOM),
		anchor = Vector2.new(0.5, 1),
		parent = gui,
		align = Enum.TextXAlignment.Center,
		color = Theme.colors.tips,
		textSize = 18,
	})
	Theme.chromeScale(hintLabel)
end

local function build(): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "MowHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.Parent = player:WaitForChild("PlayerGui")

	buildCrosshair(gui)
	buildRightColumn(gui)
	buildBag(gui)
	buildMiddle(gui)

	toastHolder = Instance.new("Frame")
	toastHolder.Name = "Toasts"
	toastHolder.Size = UDim2.fromOffset(560, 120)
	toastHolder.Position = UDim2.new(0.5, 0, 1, -TOAST_BOTTOM)
	toastHolder.AnchorPoint = Vector2.new(0.5, 1)
	toastHolder.BackgroundTransparency = 1
	toastHolder.Parent = gui
	RunOnly.piece("toasts", toastHolder)
	Theme.chromeScale(toastHolder)

	local toastLayout = Instance.new("UIListLayout")
	toastLayout.SortOrder = Enum.SortOrder.LayoutOrder
	toastLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	toastLayout.Padding = UDim.new(0, 5)
	toastLayout.Parent = toastHolder

	bannerHolder = Instance.new("Frame")
	bannerHolder.Name = "Banners"
	bannerHolder.Size = UDim2.fromScale(1, 1)
	bannerHolder.BackgroundTransparency = 1
	bannerHolder.Parent = gui

	return gui
end

--------------------------------------------------------------------
-- Transient
--------------------------------------------------------------------

--[[
	The gold tally: one number that climbs while money is arriving.

	This is the reference's paycheck moment translated — as the bag pours into
	the trailer, a single `+4.36$` counts up sip by sip rather than a shower of
	little popups. One climbing number reads as a transaction in progress; many
	separate ones read as noise. When nothing has arrived for a beat, it drifts
	up and fades, and the next pour starts a fresh count.
]]
local tallyAmount = 0
local tallyLabel: TextLabel? = nil
local tallyFadeAt = 0

function Hud.gain(amount: number)
	if amount <= 0 then
		return
	end

	tallyAmount += amount
	tallyFadeAt = os.clock() + 0.8

	local existing = tallyLabel
	local label: TextLabel
	if existing then
		label = existing
	else
		label = Theme.text({
			name = "Tally",
			text = "",
			size = UDim2.fromOffset(280, 50),
			position = UDim2.fromOffset(10, 40),
			parent = gainHolder,
			align = Enum.TextXAlignment.Center,
			color = Theme.colors.tips,
			textSize = 40,
		})
		tallyLabel = label
	end
	label.Text = `+{Format.cashSuffix(tallyAmount)}`
	label.TextTransparency = 0
	local stroke = label:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = 0
	end
end

--- Lets the tally go once the stream has stopped feeding it.
local function stepTally()
	local label = tallyLabel
	if not label or tallyAmount <= 0 or os.clock() < tallyFadeAt then
		return
	end

	tallyAmount = 0
	tallyLabel = nil

	local info = TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(label, info, { Position = label.Position - UDim2.fromOffset(0, 34), TextTransparency = 1 })
		:Play()
	local stroke = label:FindFirstChildOfClass("UIStroke")
	if stroke then
		TweenService:Create(stroke, info, { Transparency = 1 }):Play()
	end
	task.delay(0.85, function()
		label:Destroy()
	end)
end

--- The clippings an armful just added, in white — cash it is not, yet.
function Hud.bagged(units: number)
	if units < 1 then
		return
	end

	local label = Theme.text({
		name = "Bagged",
		text = `+{units}`,
		size = UDim2.fromOffset(160, 34),
		position = UDim2.fromOffset(60, 96),
		parent = gainHolder,
		align = Enum.TextXAlignment.Center,
		color = Theme.colors.text,
		textSize = 24,
	})

	local info = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(label, info, { Position = UDim2.fromOffset(60, 44), TextTransparency = 1 }):Play()
	local stroke = label:FindFirstChildOfClass("UIStroke")
	if stroke then
		TweenService:Create(stroke, info, { Transparency = 1 }):Play()
	end
	task.delay(0.75, function()
		label:Destroy()
	end)
end

function Hud.toast(kind: string, message: string)
	--[[
		Nothing shouts over a coaching step.

		The first two steps are one instruction on an otherwise empty screen,
		and the game has plenty to say while they run — a stripe banked, a
		load sold, a tip earned. Held back rather than queued: by the time the
		step is over the news is stale.
	]]
	if RunOnly.isHeld(toastHolder) then
		return
	end

	toastOrder += 1

	local ink = NOTICE_COLORS[kind] or Theme.colors.text

	--[[
		A capsule with a dot on it, not a rectangle with a corner radius of
		four. It sits over the lawn with nothing behind it, so it needs the
		same ink border everything else on this screen has, and the dot in the
		notice's own colour says which kind of thing happened before the
		sentence is read.
	]]
	local frame = Instance.new("Frame")
	frame.Name = "Toast"
	frame.Size = UDim2.fromOffset(520, 42)
	frame.BackgroundColor3 = Theme.colors.outline
	frame.BackgroundTransparency = 0.18
	frame.BorderSizePixel = 0
	frame.LayoutOrder = toastOrder
	frame.Parent = toastHolder
	Theme.corner(frame, 21)
	local edge = Theme.stroke(frame, 3, Theme.colors.outline, 0)

	local dot = circle(frame, 12, ink)
	dot.Name = "Dot"
	dot.Position = UDim2.new(0, 22, 0.5, 0)
	dot.AnchorPoint = Vector2.new(0, 0.5)

	local text = Theme.text({
		text = message,
		size = UDim2.new(1, -70, 1, 0),
		position = UDim2.fromOffset(44, 0),
		parent = frame,
		align = Enum.TextXAlignment.Left,
		color = ink,
		textSize = 21,
	})

	task.delay(2.6, function()
		if not frame.Parent then
			return
		end
		--- The border and the dot fade with the fill, or a ring and a spot are
		--- left hanging on the lawn after the message has gone.
		local span = TweenInfo.new(0.35)
		TweenService:Create(edge, span, { Transparency = 1 }):Play()
		TweenService:Create(dot, span, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(text, span, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		local fade = TweenService:Create(frame, span, { BackgroundTransparency = 1 })
		fade:Play()
		fade.Completed:Wait()
		frame:Destroy()
	end)
end

--[[
	The card that drops in when a section is finished.

	A quest ticked off in the corner is easy to miss while you are staring at the
	ground; clearing a whole garage is the one moment in a run worth stopping
	the player for, so it gets a medal and the middle of the screen.
]]
function Hud.card(message: string, banner: string, accent: string?)
	local frame = Instance.new("Frame")
	frame.Name = "Card"
	frame.Size = UDim2.fromOffset(540, 128)
	frame.Position = UDim2.fromScale(0.5, 0.03)
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.BackgroundColor3 = Theme.colors.progress
	frame.BorderSizePixel = 0
	frame.Parent = bannerHolder
	Theme.corner(frame, 16)
	Theme.stroke(frame, 3, Theme.colors.outline, 0.1)

	local title = Theme.text({
		name = "Title",
		text = message,
		size = UDim2.new(1, -36, 0, 60),
		position = UDim2.fromOffset(18, 8),
		parent = frame,
		align = Enum.TextXAlignment.Center,
		color = Theme.colors.outline,
		textSize = 23,
	})
	title.TextWrapped = true
	local titleStroke = title:FindFirstChildOfClass("UIStroke")
	if titleStroke then
		titleStroke:Destroy()
	end

	local ribbon = Instance.new("Frame")
	ribbon.Name = "Ribbon"
	ribbon.Size = UDim2.fromOffset(400, 46)
	ribbon.Position = UDim2.new(0.5, 24, 0, 72)
	ribbon.AnchorPoint = Vector2.new(0.5, 0)
	ribbon.BackgroundColor3 = Color3.fromRGB(240, 230, 198)
	ribbon.BorderSizePixel = 0
	ribbon.Parent = frame
	Theme.corner(ribbon, 8)
	Theme.stroke(ribbon, 3, Theme.colors.outline, 0.1)

	local ribbonText = Theme.text({
		name = "Banner",
		text = if accent then `{banner} <font color="#5cb2ff">{accent}</font>` else banner,
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0, 0),
		parent = ribbon,
		align = Enum.TextXAlignment.Center,
		color = Theme.colors.outline,
		textSize = 30,
	})
	local ribbonStroke = ribbonText:FindFirstChildOfClass("UIStroke")
	if ribbonStroke then
		ribbonStroke:Destroy()
	end

	local medal = circle(frame, 56, Theme.colors.tips)
	medal.Name = "Medal"
	medal.Position = UDim2.new(0.5, -206, 0, 66)
	medal.AnchorPoint = Vector2.new(0.5, 0)
	Theme.stroke(medal, 3, Theme.colors.outline, 0.1)

	-- The medal wore a typographic star. It is the golden blade the world hides
	-- one of, which is the thing the medal is actually for.
	Theme.icon({
		name = "Star",
		prop = "GoldenBlade",
		size = UDim2.fromScale(0.72, 0.72),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = medal,
	})

	task.delay(3.4, function()
		if not frame.Parent then
			return
		end
		local fade = TweenService:Create(frame, TweenInfo.new(0.4), { BackgroundTransparency = 1 })
		fade:Play()
		fade.Completed:Wait()
		frame:Destroy()
	end)
end

--- Kept for callers that want the old wide strip rather than the card.
function Hud.banner(message: string)
	Hud.toast("quest", message)
end

--------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------

--- True while the player is actually sitting on something.
local function seated(): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.SeatPart ~= nil
end

local function refresh()
	local state = PlayerState.get()

	cashLabel.Text = Format.cash(state.cash)

	-- Only shown once something has actually raised it, so a brand new run is
	-- not carrying a decoration that says nothing.
	--- On a chip of its own now, so the brackets that used to separate it
	--- from the lawn behind it are two characters doing nothing.
	multiplierLabel.Text = if state.cashMultiplier > 1.001
		then `×{string.format("%.2f", state.cashMultiplier)}`
		else ""

	-- Hidden at zero, like the multiplier: a new player has none and does not
	-- need a counter telling them so. The chip goes with the words, or an
	-- empty dark pill is left sitting on the lawn saying nothing.
	tipsLabel.Text = if state.tips > 0 then `{Format.count(state.tips)} tips` else ""
	;(tipsLabel.Parent :: Frame).Visible = state.tips > 0
	;(multiplierLabel.Parent :: Frame).Visible = state.cashMultiplier > 1.001

	bagCountLabel.Text = Format.count(state.bagWeight)
	bagCapacityLabel.Text = `/ {Format.count(state.bagCapacity)}`
	bagCountLabel.TextColor3 = if state.bagWeight >= state.bagCapacity
		then Theme.colors.danger
		elseif state.bagWeight >= state.bagCapacity * 0.8 then Theme.colors.warn
		else Theme.colors.text

	--[[
		What one clipping is worth right now, which is the number the whole
		economy is denominated in and the one an upgrade visibly moves.

		It left out the property's own payout multiplier, which is the entire
		mechanism by which a harder lawn pays better — 1.6x at The Mansion and
		2.1x at The Gas Station. So the readout said two cents a clipping in
		all three worlds, understating what the player was actually paid by up
		to a factor of two and flattening the one number that was supposed to
		make moving up feel like moving up. `Economy.valuePerUnit` has had the
		right formula the whole time; this is the same one, and the client has
		known which world it is in since it was told.
	]]
	local world = PlayerState.world()
	local payout = if world then world.payoutMultiplier else 1
	local perClipping = Debris.get(Debris.Grass).value * payout * math.max(state.cashMultiplier, 1)
	rateLabel.Text = `{Format.cashSuffix(perClipping)} / clipping`

	local tool = Tools.get(state.equippedTool)
	Theme.setIcon(toolIcon, if tool then Props.forTool(tool.id, tool.category) else Props.FALLBACK_TOOL_ICON)
	toolNameLabel.Text = if tool then tool.name else ""
	toolStateLabel.Text = coachWord or MowController.actionLabel()
	toolStateLabel.TextColor3 = if coachWord ~= nil
		then Theme.colors.tips
		elseif MowController.isMowing() then Theme.colors.cash
		else Theme.colors.subtext
	--[[
		A tool to show, and somewhere to use it.

		`State` — the word under the button that says PICK UP or MOWING — was
		registered with `RunOnly` and the eighty-six pixel button it belongs
		to was not, so the lobby carried a big round control with a glove on
		it that did nothing at all when pressed. Registering the button too
		does not work: this line runs five times a second and would turn it
		straight back on. So it asks.
	]]
	toolButton.Visible = tool ~= nil and RunOnly.permits(toolButton)
	toolNameLabel.Visible = toolButton.Visible

	local burnsFuel = tool ~= nil and tool.fuelBurn > 0
	--- The holder carries the drop shadow, so hiding the body alone would
	--- leave a dark rectangle sitting on the lawn with nothing on it.
	local fuelHolder = fuelPanel.Parent :: Frame
	fuelHolder.Visible = burnsFuel and state.fuelCapacity > 0 and RunOnly.permits(fuelHolder)
	if fuelHolder.Visible then
		local fuelFraction = math.clamp(state.fuel / state.fuelCapacity, 0, 1)
		fuelFill.Size = UDim2.fromScale(fuelFraction, 1)
		fuelFill.BackgroundColor3 = if fuelFraction <= 0.15
			then Theme.colors.danger
			else Color3.fromRGB(255, 192, 103)
		fuelLabel.Text = `{math.floor(state.fuel)} / {math.floor(state.fuelCapacity)}`
	end

	local fraction = PlayerState.bagFraction()
	--[[
		The bag turns red when it is full, and the count with it.

		Full is the one state that makes every other control do nothing, and
		it was being announced by a line of hint text at the bottom of the
		screen and a number that looked like any other number. On a tablet,
		with the readout moved to the top-left corner, that is not an
		announcement.
	]]
	local full = fraction >= 1
	bagCountLabel.TextColor3 = if full then Theme.colors.danger else Theme.colors.text
	bagCapacityLabel.TextColor3 = if full then Theme.colors.danger else Theme.colors.body
	if bagSack then
		bagSack.BackgroundColor3 = if full then Theme.colors.danger else BAG_SACK_COLOUR
	end
	--- The level inside the sack, which is the part anyone actually reads.
	bagFill.Size = UDim2.new(1, -6, math.clamp(fraction, 0, 1), 0)
	local rideable = tool ~= nil and tool.vehicle ~= nil
	if state.rentalSecondsLeft > 0 and state.rentalToolId ~= "" then
		local rented = Tools.get(state.rentalToolId)
		hintLabel.Text = `{if rented then rented.name else "Rental"} — {Format.clock(state.rentalSecondsLeft)} left`
	elseif fraction >= 1 then
		hintLabel.Text = "Bag full — head to the trailer"
	elseif burnsFuel and state.fuel <= 0 then
		hintLabel.Text = "Out of fuel — refill at the shed"
	--[[
		Held down over nothing.

		A pickup tool takes one tile, and the ground where a prop stands is
		bare — so pressing the button while stood against the crate on the
		first lawn does nothing whatever, which is indistinguishable from the
		game being broken. Same complaint the full bag and the empty tank
		produced, same answer.
	]]
	elseif MowController.reachingNothing() then
		hintLabel.Text = "Nothing in reach — stand over the grass"
	elseif rideable and not seated() then
		--[[
			Only while they are still off it.

			This asked whether a rideable tool was equipped and nothing else,
			so it went on saying "Tap Ride to get on the mower" while the
			player was sitting on the mower, with the button beside it already
			reading "Hop Off". The one line on screen telling you what to do
			next was telling you to do the thing you had just done.
		]]
		hintLabel.Text = if Theme.hasKeyboard() then "Press F to get on the mower" else "Tap Ride to get on the mower"
	else
		hintLabel.Text = ""
	end
end

--------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------

function Hud.start()
	build()
	refresh()

	--[[
		Sitting down is not a change to the player's own state, so nothing
		would have redrawn the hint until the next unrelated push.
	]]
	local function watchSeat(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.Seated:Connect(refresh)
		end
		refresh()
	end
	player.CharacterAdded:Connect(function(character)
		task.spawn(watchSeat, character)
	end)
	if player.Character then
		task.spawn(watchSeat, player.Character)
	end

	Loop.forever("Hud.tally", function()
		task.wait(0.15)
		stepTally()
	end)

	PlayerState.Changed:Connect(refresh)
	MowController.MowingChanged.Event:Connect(refresh)
	MowController.Collected.Event:Connect(function(units: number)
		Hud.bagged(units)
	end)

	-- On touch the round tool button is the trigger as well as the readout. On a
	-- mouse the pointer is locked to the middle of the screen in first person,
	-- so there is nothing to click it with and it stays a readout.
	if UserInputService.TouchEnabled then
		toolButton.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then
				MowController.press()
			end
		end)
		toolButton.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then
				MowController.release()
			end
		end)
	end

	local notify = Remotes.event(Remotes.NOTIFY)
	notify.OnClientEvent:Connect(function(kind: any, message: any, amount: any)
		if type(kind) ~= "string" or type(message) ~= "string" then
			return
		end

		-- The pour feeds the tally silently, sip by sip; a lump-sum sale (the
		-- Empty Bag product) feeds the same counter and keeps its toast.
		if kind == "tally" then
			if type(amount) == "number" then
				Hud.gain(amount)
			end
			return
		end
		if kind == "sale" and type(amount) == "number" then
			Hud.gain(amount)
		end

		--[[
			What each kind sounds like.

			These are the player's own moments — their sale, their section —
			so they play flat rather than from a point in the world. Deliberately
			not every kind: a stall ("you need a saw for this") happens the
			instant you press a prompt you cannot use, and giving that a noise
			only punishes someone for trying something.
		]]
		if kind == "sale" then
			SoundController.play("Sell")
		elseif kind == "sectionClear" then
			SoundController.play("Win")
		elseif kind == "sectionUnlock" or kind == "quest" then
			SoundController.play("Click")
		end

		if kind == "sectionClear" then
			Hud.card(message, "COMPLETED!")
		elseif kind == "sectionUnlock" then
			-- The message is just the section's name; the card carries the rest.
			Hud.card(`A new area is open!`, "Unlocked :", message)
		else
			-- Everything else is a toast, quests included: the toast is already
			-- coloured for its kind, so a quest does not need a branch of its
			-- own to say the same thing in the same way.
			Hud.toast(kind, message)
		end

	end)
end

--- Shows or hides the red dot on the journal.
--[[
	The one lit thing on a first run.

	The handoff's first step is a screen with almost nothing on it and a
	hundred-and-twenty-four point button that cannot be missed: five pixels of
	`ui.tips` round its edge, a soft ring outside that, and a glow behind it.
	Three concentric circles rather than a radial gradient, because Roblox has
	no radial gradient and an uploaded png for this would be an asset to
	maintain for one screen.

	The rings are children of the button, so `parkTool` moving it above the
	jump control moves them too.
]]
--[[
	The money, standing down.

	The first coaching step wants the cash capsule at forty per cent — present,
	because a player should see where their money will appear, but not
	competing with the one lit button. Roblox has no group opacity, so this
	walks the capsule and blends every transparency it finds towards one,
	remembering what each was so it can be put back exactly.
]]
local dimmed: { [Instance]: { [string]: number } } = {}

local function fade(object: Instance, amount: number)
	local known = dimmed[object]
	if not known then
		local record: { [string]: number } = {}
		if object:IsA("GuiObject") then
			record.BackgroundTransparency = object.BackgroundTransparency
		end
		if object:IsA("TextLabel") or object:IsA("TextButton") then
			record.TextTransparency = object.TextTransparency
			record.TextStrokeTransparency = object.TextStrokeTransparency
		end
		if object:IsA("UIStroke") then
			record.Transparency = object.Transparency
		end
		dimmed[object] = record
		known = record
	end
	for property, original in known do
		(object :: any)[property] = original + (1 - original) * amount
	end
end

--- `on` puts the purse and its two chips at forty per cent; off restores them.
function Hud.dimPurse(on: boolean)
	local amount = if on then 0.6 else 0
	for _, root in { purseHolder, tipsHolder, multiplierHolder } do
		if root then
			fade(root, amount)
			for _, child in root:GetDescendants() do
				fade(child, amount)
			end
		end
	end
end

function Hud.spotlight(on: boolean, word: string?)
	coachWord = if on then word else nil

	local edge = toolButton:FindFirstChildOfClass("UIStroke")
	if edge then
		edge.Color = if on then Theme.colors.tips else Theme.colors.outline
	end

	local halo = toolButton:FindFirstChild("Halo")
	if on and not halo then
		local glow = Instance.new("Frame")
		glow.Name = "Halo"
		glow.Size = UDim2.fromScale(1, 1)
		glow.Position = UDim2.fromScale(0.5, 0.5)
		glow.AnchorPoint = Vector2.new(0.5, 0.5)
		glow.BackgroundTransparency = 1
		glow.BorderSizePixel = 0
		--- Behind the button it belongs to. See the note in `Theme.bevel`
		--- about this project's `ZIndexBehavior`.
		glow.ZIndex = toolButton.ZIndex - 1
		glow.Parent = toolButton

		for index, ring in { { 1.13, 0.78 }, { 1.4, 0.88 }, { 1.75, 0.94 } } do
			local circle_ = Instance.new("Frame")
			circle_.Name = `Ring{index}`
			circle_.Size = UDim2.fromScale(ring[1], ring[1])
			circle_.Position = UDim2.fromScale(0.5, 0.5)
			circle_.AnchorPoint = Vector2.new(0.5, 0.5)
			circle_.BackgroundColor3 = Theme.colors.tips
			circle_.BackgroundTransparency = ring[2]
			circle_.BorderSizePixel = 0
			circle_.ZIndex = glow.ZIndex
			circle_.Parent = glow
			local round_ = Instance.new("UICorner")
			round_.CornerRadius = UDim.new(0.5, 0)
			round_.Parent = circle_
		end
	elseif halo and not on then
		halo:Destroy()
	end
end

--[[
	Where the completion bar's bottom edge is, in pixels down the screen.

	The bar shrinks to fit between the objective panel and the status column
	on a narrow tablet, so the line under it cannot be placed from the bar's
	authored height — at 1024 wide that left the rate floating sixty pixels
	below a bar that had stood down to two thirds.
]]
function Hud.setBarBottom(y: number)
	if not rateLabel then
		return
	end
	rateLabel.Position = UDim2.new(0.5, 0, 0, y + 8)
end

function Hud.setJournalBadge(visible: boolean)
	journalBadge.Visible = visible
end

return Hud
