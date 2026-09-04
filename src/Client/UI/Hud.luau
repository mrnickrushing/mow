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
local toolButton: TextButton
local toolIcon: Frame
local toolStateLabel: TextLabel
local toolNameLabel: TextLabel
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
	-- A small hollow diamond: a rotated square outline, which is exactly what
	-- the reference uses. Big enough to find, small enough not to cover the leaf
	-- it is sitting on.
	local mark = Instance.new("Frame")
	mark.Name = "Crosshair"
	mark.Size = UDim2.fromOffset(11, 11)
	mark.Position = UDim2.fromScale(0.5, 0.5)
	mark.AnchorPoint = Vector2.new(0.5, 0.5)
	mark.Rotation = 45
	mark.BackgroundTransparency = 1
	mark.Parent = gui
	RunOnly.add(mark)

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Theme.colors.text
	stroke.Transparency = 0.15
	stroke.Parent = mark
end

local function buildRightColumn(gui: ScreenGui)
	local column = Instance.new("Frame")
	column.Name = "Status"
	column.Size = UDim2.fromOffset(220, 420)
	column.Position = UDim2.new(1, -20, 0, 78)
	column.AnchorPoint = Vector2.new(1, 0)
	column.BackgroundTransparency = 1
	column.Parent = gui

	--[[
		The column is laid out in fixed pixels running down from 78 below the
		top edge, so on a short viewport its lower half — the fuel gauge, the
		tool button that doubles as the touch action control, and the word under
		it — ran off the bottom of the screen and sat on top of the round timer.
		Scaling it to the room actually left below its start keeps the whole
		column on screen, and leaves it untouched at its designed size on any
		display tall enough for it.
	]]
	Theme.fitToViewport(column, 240, 420, 90)

	multiplierLabel = Theme.text({
		name = "Multiplier",
		text = "",
		size = UDim2.fromOffset(200, 22),
		position = UDim2.new(1, -6, 0, 0),
		anchor = Vector2.new(1, 0),
		parent = column,
		align = Enum.TextXAlignment.Right,
		color = Theme.colors.tips,
		textSize = 18,
	})

	--[[
		Tips, opposite the multiplier on a row that is usually empty.

		They were shown nowhere on the HUD at all — only as a line buried in
		the journal's stats — which was survivable while they bought nothing.
		Now that they buy tools outright, a currency you cannot see is a
		currency nobody spends. It shares the top row with the multiplier
		because that one is blank until something raises it, and both are short
		and pinned to opposite ends.
	]]
	tipsLabel = Theme.text({
		name = "Tips",
		text = "",
		size = UDim2.fromOffset(120, 22),
		position = UDim2.fromOffset(4, 0),
		parent = column,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.tips,
		textSize = 18,
	})

	cashLabel = Theme.text({
		name = "Cash",
		text = "$0.00",
		size = UDim2.fromOffset(170, 40),
		position = UDim2.new(1, -46, 0, 22),
		anchor = Vector2.new(1, 0),
		parent = column,
		align = Enum.TextXAlignment.Right,
		textSize = 32,
	})

	-- The coin is drawn rather than an image so there is no asset to upload, and
	-- it reads at a glance as "this number is money" the way a $ alone does not.
	local coin = circle(column, 38, Theme.colors.tips)
	coin.Name = "Coin"
	coin.Position = UDim2.new(1, -2, 0, 23)
	coin.AnchorPoint = Vector2.new(1, 0)
	Theme.stroke(coin, 3, Theme.colors.outline, 0.1)

	local inner = circle(coin, 22, Color3.fromRGB(246, 196, 84))
	inner.Position = UDim2.fromScale(0.5, 0.5)
	inner.AnchorPoint = Vector2.new(0.5, 0.5)

	-- The journal, with a badge when something in it is waiting to be read.
	-- Pressing it opens the book, which matters most on touch where Tab does
	-- not exist.
	local book = Instance.new("TextButton")
	book.Name = "Journal"
	book.Size = UDim2.fromOffset(62, 62)
	book.Position = UDim2.new(1, -14, 0, 76)
	book.AnchorPoint = Vector2.new(1, 0)
	book.BackgroundColor3 = Theme.colors.progress
	book.BorderSizePixel = 0
	book.Rotation = -6
	book.Text = ""
	book.AutoButtonColor = true
	book.Parent = column
	Theme.corner(book, 8)
	Theme.stroke(book, 3, Theme.colors.outline, 0.05)
	--[[
		The journal fills its tile and hangs over the bottom of it.

		At 0.78 it was a small picture centred in a cream square, which is
		what "a square with a drawn journal in it" describes. Drawn edge to
		edge, with the ribbon crossing the border, the square reads as
		something the journal is resting on rather than a frame around a
		symbol.
	]]
	Theme.icon({
		name = "BookIcon",
		prop = "Journal",
		size = UDim2.fromScale(1.02, 1.02),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = book,
	})

	book.Activated:Connect(function()
		Journal.toggle()
	end)

	journalBadge = circle(book, 22, Theme.colors.danger)
	journalBadge.Name = "Badge"
	journalBadge.Position = UDim2.fromOffset(-8, -6)
	Theme.stroke(journalBadge, 2.5, Theme.colors.outline, 0.05)

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

	--[[
		A word under each tile, the way the reference labels its own.

		These used to be key hints — a small pill reading "Tab" or "G" — and
		a key hint is a lie on a screen with no keyboard, so on a tablet they
		were switched off and the two buttons went out unlabelled. That is
		most of the people who play this: two coloured squares in the corner
		with a picture on them and nothing saying what either one is.

		A name works on every screen, and the keyboard's shortcut rides along
		with it where there is a keyboard to press. One line, not two.
	]]
	local hasKeyboard = Theme.hasKeyboard()

	--[[
		The word alone, with no key beside it.

		The key used to ride along where there was a keyboard to press, and
		that worked while the word was "Book". "Journal  Tab" wants eighty-eight
		pixels in a seventy-pixel pill sitting seventy-two from its neighbour,
		and widening the pill collides with the one next to it. The keys are
		listed on the journal's own controls page, which is where a keyboard
		player can read all of them at once rather than one per tile.
	]]
	local function caption(name: string, word: string, _key: string, x: number): TextLabel
		local label = Theme.text({
			name = name,
			text = word,
			-- Seventy-two apart, so seventy wide leaves a hair between them.
			-- `layoutTiles` sets that spacing, whatever is written above.
			size = UDim2.fromOffset(70, 22),
			position = UDim2.new(1, x, 0, 142),
			anchor = Vector2.new(1, 0),
			parent = column,
			align = Enum.TextXAlignment.Center,
			color = Theme.colors.outline,
			textSize = 15,
		})
		label.BackgroundColor3 = Theme.colors.progress
		label.BackgroundTransparency = 0
		Theme.corner(label, 5)
		Theme.stroke(label, 2, Theme.colors.outline, 0.2)
		return label
	end

	-- Centred under a 62-wide tile whose right edge is 14 in from the screen:
	-- the caption is 70 wide, so it hangs four pixels proud either side.
	local bookLabel = caption("BookLabel", "Journal", "Tab", -8)

	--[[
		The store, which is a button and not a third icon.

		It was bound to G and to nothing else, which meant that on a tablet —
		the way most of this game is played — the Robux store could not be
		opened at all. There was no button anywhere on the screen, and the only
		place the key was written down was a line on the journal's tips page
		that you needed the journal open to read.

		So it became a tile, and that was the wrong shape. Three identical
		squares in a row say "three settings"; nothing about a coin on a yellow
		square says the third one spends real money, and the player who wants
		to buy something has to guess which square to press. A wide pill with
		the word on it is the only one of the three that reads as somewhere to
		go rather than something to toggle, which is what it is.

		It also gets the icon column back down to two, which is the difference
		between furniture and clutter down the edge of a phone.
	]]
	local shop = Instance.new("TextButton")
	shop.Name = "Store"
	shop.AnchorPoint = Vector2.new(1, 0)
	shop.BackgroundColor3 = Theme.colors.tips
	shop.BorderSizePixel = 0
	shop.Text = ""
	shop.AutoButtonColor = true
	shop.Parent = column
	Theme.corner(shop, 10)
	Theme.stroke(shop, 3, Theme.colors.outline, 0.05)

	local shopIcon = Theme.icon({
		name = "StoreIcon",
		prop = "Coin",
		size = UDim2.fromOffset(26, 26),
		position = UDim2.new(0, 11, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		parent = shop,
	})

	local shopWord = Theme.text({
		name = "StoreWord",
		text = if hasKeyboard then "STORE  G" else "STORE",
		size = UDim2.new(1, -48, 1, 0),
		position = UDim2.fromOffset(44, 0),
		parent = shop,
		align = Enum.TextXAlignment.Left,
		color = Theme.colors.outline,
		textSize = 17,
	})

	shop.Activated:Connect(function()
		Store.toggle()
	end)

	--[[
		A way to turn the noise off.

		The profile has carried `sfxEnabled` since the beginning, saved and
		loaded with everything else, and nothing anywhere read it — there was
		no control, so the setting could never be anything but true. A game
		that cuts, sells and chops ten times a second and cannot be muted is
		a game people play on silent, which loses the sound altogether rather
		than only when they want it gone.

		Third tile in the same row, labelled with its own state the way the
		reference labels its music toggle.
	]]
	local soundTile = Instance.new("TextButton")
	soundTile.Name = "Sound"
	soundTile.Size = UDim2.fromOffset(62, 62)
	soundTile.Position = UDim2.new(1, -158, 0, 76)
	soundTile.AnchorPoint = Vector2.new(1, 0)
	soundTile.BackgroundColor3 = Theme.colors.progress
	soundTile.BorderSizePixel = 0
	soundTile.Rotation = 4
	soundTile.Text = ""
	soundTile.AutoButtonColor = true
	soundTile.Parent = column
	Theme.corner(soundTile, 8)
	Theme.stroke(soundTile, 3, Theme.colors.outline, 0.05)

	local note = Theme.text({
		name = "Note",
		text = utf8.char(0x266A),
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0, 0),
		parent = soundTile,
		align = Enum.TextXAlignment.Center,
		textSize = 34,
	})
	note.TextYAlignment = Enum.TextYAlignment.Center

	local soundLabel = caption("SoundLabel", "Sound", "", -152)

	--[[
		On a phone the three tiles stack down the edge instead of across it.

		A row grows leftward from the right edge, so the third tile is three
		tile-widths in — measured on an iPhone 17 in landscape, the far one
		sat a fifth of the screen width inside the edge and a third of the way
		down, right over the grass being cut. A phone is short and wide: there
		is no vertical room to spare in the middle and plenty of it at the
		sides, which is the opposite of a tablet.

		So they go into a column hard against the right edge, starting near
		the top, smaller, and without their captions — three words stacked
		down the edge of a four-hundred-point screen is more furniture than
		the icons themselves. Every other device keeps the row, which is what
		the labels were added for.
	]]
	local function isPhone(): boolean
		local camera = workspace.CurrentCamera
		return camera ~= nil and camera.ViewportSize.Y <= 500
	end

	local function layoutTiles()
		local phone = isPhone()
		--[[
			Book first, because the captions are placed from this same index.

			They used to be two lists: the tiles were laid out left-to-right from
			one array and the captions were positioned by hand from constants
			written when the row had a different order in it. The row said
			Sound, Store, Book and the captions underneath said Book, Shop,
			Sound — every label under the wrong tile, on every desktop. Deriving
			both from one loop is what stops that coming back.
		]]
		local tiles = { book, soundTile }
		local labels = { bookLabel, soundLabel }
		local spins = { -6, 4 }
		for index, tile in tiles do
			if phone then
				tile.Size = UDim2.fromOffset(52, 52)
				tile.Position = UDim2.new(1, -4, 0, 8 + (index - 1) * 58)
				tile.Rotation = 0
			else
				tile.Size = UDim2.fromOffset(62, 62)
				tile.Position = UDim2.new(1, -14 - (index - 1) * 72, 0, 76)
				tile.Rotation = spins[index]
				labels[index].Position = UDim2.new(1, -8 - (index - 1) * 72, 0, 142)
			end
			labels[index].Visible = not phone
		end

		-- Under the icons either way, so it is the widest thing in the corner
		-- and the last thing the eye lands on rather than one of a set.
		if phone then
			shop.Size = UDim2.fromOffset(112, 36)
			shop.Position = UDim2.new(1, -4, 0, 8 + #tiles * 58)
			shop.Rotation = 0
		else
			shop.Size = UDim2.fromOffset(132, 40)
			shop.Position = UDim2.new(1, -14, 0, 176)
			shop.Rotation = 5
		end
		shopWord.TextSize = if phone then 15 else 17
		shopIcon.Size = if phone then UDim2.fromOffset(22, 22) else UDim2.fromOffset(26, 26)
	end

	layoutTiles()
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(layoutTiles)

	--[[
		Puts the tool button just above Roblox's jump button.

		Measured rather than guessed: the jump control is drawn by Roblox at a
		size and place of its own choosing, which is not the same on a phone
		as on a tablet. Where there is no jump button — a mouse, where this is
		a readout rather than a control — the fallback inset is used, which is
		clear of the store either way.
	]]
	local function parkTool()
		if not (toolButton and toolStateLabel and toolNameLabel) then
			return false
		end
		local touchGui = player:FindFirstChild("PlayerGui") and (player.PlayerGui :: any):FindFirstChild("TouchGui")
		local jump = touchGui and touchGui:FindFirstChild("JumpButton", true)
		local area = gui.AbsoluteSize
		local width, height = toolButton.AbsoluteSize.X, toolButton.AbsoluteSize.Y
		if width < 1 or area.X < 1 then
			return false
		end
		local fromRight, fromBottom
		if jump and jump:IsA("GuiObject") and jump.AbsoluteSize.Y > 8 then
			fromRight = area.X - (jump.AbsolutePosition.X + jump.AbsoluteSize.X * 0.5) + width * 0.5
			-- Sixteen pixels of daylight over the jump button, so the two read
			-- as a stack rather than as one control.
			fromBottom = area.Y - jump.AbsolutePosition.Y + 16
		else
			fromRight, fromBottom = 22, 240
		end
		toolButton.Position = UDim2.new(1, -fromRight, 1, -fromBottom)
		--[[
			The name above, the state below, both centred on the button.

			Anchored bottom-right, so the offset is where each label's bottom
			edge sits: the name clears the top of the button, the state hangs
			just under it. Getting these the same way round put the name across
			the button's face and the word on top of the icon.
		]]
		local centreFromRight = fromRight - width * 0.5
		toolNameLabel.Position =
			UDim2.new(1, -(centreFromRight - toolNameLabel.AbsoluteSize.X * 0.5), 1, -(fromBottom + height + 4))
		toolStateLabel.Position =
			UDim2.new(1, -(centreFromRight - toolStateLabel.AbsoluteSize.X * 0.5), 1, -(fromBottom - 28))
		return jump ~= nil
	end

	--[[
		Kept asking until Roblox has drawn its touch controls.

		`TouchGui` does not exist when this builds, so the first call always
		falls back to a fixed inset and the button ends up in roughly the right
		place rather than the right one. Re-parking until the jump button turns
		up costs a handful of frames and is the difference between measured and
		guessed.
	]]
	task.spawn(function()
		for _ = 1, 40 do
			if parkTool() then
				break
			end
			task.wait(0.25)
		end
	end)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(parkTool)

	local function paintSound()
		local on = not SoundController.isMuted()
		soundLabel.Text = if on then "Sound ON" else "Sound OFF"
		note.TextTransparency = if on then 0 else 0.55
		soundTile.BackgroundColor3 = if on then Theme.colors.progress else Theme.colors.panel
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

	soundTile.Activated:Connect(function()
		local nowMuted = not SoundController.isMuted()
		SoundController.setMuted(nowMuted)
		paintSound()
		--[[
			One button, both settings.

			A player pressing a speaker icon means "stop making noise", not
			"stop the effects but keep the music". Both fields are written so
			the profile matches what they actually asked for, and so
			`musicEnabled` is a real setting rather than a field nothing
			reads — which is what it was until there was music to enable.
		]]
		local remote = Remotes.event(Remotes.SETTINGS)
		remote:FireServer("sfx", not nowMuted)
		remote:FireServer("music", not nowMuted)
	end)
	paintSound()

	-- The tool, and whether it is running. On touch this is also the button that
	-- runs it; on a mouse the camera is locked to the centre of the screen, so
	-- it can only ever be a readout.
	--[[
		The tool button sits above the jump button, not on top of the store.

		It lived in the top-right column at a fixed drop of 190, and the store
		pill above it runs from 176 to 216 — so on every screen that is not a
		phone the two overlapped, and the word PICK UP was printed across the
		store. It also put the one control a player holds down at the top of
		the screen, as far from a thumb as the layout allows.

		So it comes out of the column and parks itself against the bottom
		right, just above Roblox's jump button, which is where the hand
		already is. `parkTool` measures the real jump button rather than
		guessing an inset, because Roblox sizes and places that control
		itself and it is not the same on every screen.
	]]
	toolButton = Instance.new("TextButton")
	toolButton.Name = "Tool"
	toolButton.Size = UDim2.fromOffset(86, 86)
	toolButton.Position = UDim2.new(1, -22, 1, -240)
	toolButton.AnchorPoint = Vector2.new(1, 1)
	toolButton.BackgroundColor3 = Theme.colors.panelLight
	toolButton.BackgroundTransparency = 0.15
	toolButton.BorderSizePixel = 0
	toolButton.Text = ""
	toolButton.AutoButtonColor = false
	-- Off until the first refresh says otherwise, so it cannot flash up in
	-- the lobby on the frame between being built and being told.
	toolButton.Visible = false
	toolButton.Parent = gui

	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0.5, 0)
	round.Parent = toolButton
	Theme.stroke(toolButton, 3, Theme.colors.outline, 0.05)

	toolIcon = Theme.icon({
		name = "Icon",
		prop = Props.FALLBACK_TOOL_ICON,
		size = UDim2.fromScale(0.82, 0.82),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		parent = toolButton,
	})

	--[[
		The name of the thing in your hand.

		The button showed a picture and a verb — PICK UP, MOW — and never once
		said what you were holding. With one icon per family that was close to
		unreadable: six mowers shared a drawing, so the only way to know
		whether you had the reel mower or the zero-turn was to remember what
		you last bought. The icons are per tool now and this says the name
		outright, which between them is the whole answer.
	]]
	toolNameLabel = Theme.text({
		name = "ToolName",
		text = "",
		size = UDim2.fromOffset(190, 24),
		position = UDim2.new(1, -5, 1, -238),
		anchor = Vector2.new(1, 1),
		parent = gui,
		align = Enum.TextXAlignment.Right,
		color = Theme.colors.text,
		textSize = 19,
	})
	RunOnly.add(toolNameLabel)

	toolStateLabel = Theme.text({
		name = "State",
		text = "",
		size = UDim2.fromOffset(120, 26),
		-- Under the button, wherever `parkTool` has put it.
		position = UDim2.new(1, -5, 1, -212),
		anchor = Vector2.new(1, 1),
		parent = gui,
		align = Enum.TextXAlignment.Center,
		color = Theme.colors.cash,
		textSize = 22,
	})
	RunOnly.add(toolStateLabel)

	-- Only now: `parkTool` moves the button and both of its labels, and until
	-- this line one of them did not exist. Called earlier it threw, and a throw
	-- here takes the rest of the HUD with it — the bag, the rate and the
	-- toasts never got built at all.
	parkTool()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(parkTool)
	task.defer(parkTool)

	fuelPanel = Instance.new("Frame")
	fuelPanel.Name = "Fuel"
	fuelPanel.Size = UDim2.fromOffset(150, 34)
	fuelPanel.Position = UDim2.new(1, -8, 0, 304)
	fuelPanel.AnchorPoint = Vector2.new(1, 0)
	fuelPanel.BackgroundTransparency = 1
	fuelPanel.Visible = false
	fuelPanel.Parent = column

	local _, fill = Theme.bar(fuelPanel, UDim2.fromOffset(140, 13), UDim2.fromOffset(6, 18), Theme.colors.warn)
	fuelFill = fill

	fuelLabel = Theme.text({
		name = "FuelLabel",
		text = "",
		size = UDim2.fromOffset(140, 18),
		position = UDim2.fromOffset(6, 0),
		parent = fuelPanel,
		align = Enum.TextXAlignment.Right,
		textSize = 15,
	})
end

local function buildBag(gui: ScreenGui)
	local holder = Instance.new("Frame")
	holder.Name = "Bag"
	holder.Size = UDim2.fromOffset(190, 74)
	--[[
		Bottom-left on a keyboard; top-left, under the objective panel, on touch.

		The bottom-left corner of a touch screen is where Roblox draws the
		movement thumbstick, and the bag sat squarely on it — measured, the
		thumbstick's rest area and the sack overlapped on every touch device.
		A readout under a thumb is a readout nobody reads and a thumbstick
		that starts on a sack. On touch it joins the stack of information at
		the top-left instead, where the objective panel already is; with a
		mouse there is no thumbstick and the corner is free.
	]]
	if UserInputService.TouchEnabled then
		holder.Position = UDim2.new(0, 20, 0, 190)
		holder.AnchorPoint = Vector2.new(0, 0)
	else
		holder.Position = UDim2.new(0, 20, 1, -22)
		holder.AnchorPoint = Vector2.new(0, 1)
	end
	holder.BackgroundTransparency = 1
	holder.Parent = gui
	RunOnly.add(holder)
	Theme.chromeScale(holder)

	-- A sack: a rounded body with a pinched neck above it.
	local sack = Instance.new("Frame")
	sack.Name = "Sack"
	sack.Size = UDim2.fromOffset(64, 56)
	sack.Position = UDim2.fromOffset(2, 16)
	sack.BackgroundColor3 = Color3.fromRGB(158, 158, 160)
	sack.BorderSizePixel = 0
	sack.Parent = holder
	Theme.corner(sack, 18)
	Theme.stroke(sack, 3, Theme.colors.outline, 0.05)

	local neck = Instance.new("Frame")
	neck.Name = "Neck"
	neck.Size = UDim2.fromOffset(26, 16)
	neck.Position = UDim2.fromOffset(21, 4)
	neck.BackgroundColor3 = Color3.fromRGB(120, 120, 124)
	neck.BorderSizePixel = 0
	neck.Parent = holder
	Theme.corner(neck, 6)
	Theme.stroke(neck, 3, Theme.colors.outline, 0.05)

	bagCapacityLabel = Theme.text({
		name = "Capacity",
		text = "0",
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0, 0),
		parent = sack,
		align = Enum.TextXAlignment.Center,
		textSize = 22,
	})

	bagCountLabel = Theme.text({
		name = "Count",
		text = "0",
		size = UDim2.fromOffset(110, 44),
		position = UDim2.fromOffset(74, 24),
		parent = holder,
		align = Enum.TextXAlignment.Left,
		textSize = 30,
	})
end

local function buildMiddle(gui: ScreenGui)
	rateLabel = Theme.text({
		name = "Rate",
		text = "",
		size = UDim2.fromOffset(340, 34),
		--[[
			A fixed drop from the top, not a twentieth of the height.

			At 0.05 of a portrait iPad that is fifty pixels down, which is
			inside the objective panel below it — the taller the screen, the
			further this slid into something that had not moved. Pinned to the
			edge it clears the panel at every height.
		]]
		position = UDim2.new(0.55, 0, 0, 14),
		anchor = Vector2.new(0.5, 0),
		parent = gui,
		align = Enum.TextXAlignment.Center,
		color = Theme.colors.cash,
		textSize = 27,
	})
	RunOnly.add(rateLabel)
	Theme.chromeScale(rateLabel)

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
			size = UDim2.fromOffset(280, 44),
			position = UDim2.fromOffset(10, 40),
			parent = gainHolder,
			align = Enum.TextXAlignment.Center,
			color = Theme.colors.tips,
			textSize = 34,
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
	toastOrder += 1

	local frame = Instance.new("Frame")
	frame.Name = "Toast"
	frame.Size = UDim2.fromOffset(520, 34)
	frame.BackgroundColor3 = Theme.colors.outline
	frame.BackgroundTransparency = 0.45
	frame.BorderSizePixel = 0
	frame.LayoutOrder = toastOrder
	frame.Parent = toastHolder
	Theme.corner(frame, 4)

	Theme.text({
		text = message,
		size = UDim2.new(1, -20, 1, 0),
		position = UDim2.fromOffset(10, 0),
		parent = frame,
		align = Enum.TextXAlignment.Center,
		color = NOTICE_COLORS[kind] or Theme.colors.text,
		textSize = 21,
	})

	task.delay(2.6, function()
		if not frame.Parent then
			return
		end
		local fade = TweenService:Create(frame, TweenInfo.new(0.35), { BackgroundTransparency = 1 })
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

local function refresh()
	local state = PlayerState.get()

	cashLabel.Text = Format.cash(state.cash)

	-- Only shown once something has actually raised it, so a brand new run is
	-- not carrying a decoration that says nothing.
	multiplierLabel.Text = if state.cashMultiplier > 1.001
		then `(×{string.format("%.2f", state.cashMultiplier)})`
		else ""

	-- Hidden at zero, like the multiplier: a new player has none and does not
	-- need a counter telling them so.
	tipsLabel.Text = if state.tips > 0 then `{Format.count(state.tips)} tips` else ""

	bagCountLabel.Text = Format.count(state.bagWeight)
	bagCapacityLabel.Text = Format.count(state.bagCapacity)
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
	toolStateLabel.Text = MowController.actionLabel()
	toolStateLabel.TextColor3 = if MowController.isMowing() then Theme.colors.cash else Theme.colors.subtext
	--[[
		A tool to show, and somewhere to use it.

		`State` — the word under the button that says PICK UP or MOWING — was
		registered with `RunOnly` and the eighty-six pixel button it belongs
		to was not, so the lobby carried a big round control with a glove on
		it that did nothing at all when pressed. Registering the button too
		does not work: this line runs five times a second and would turn it
		straight back on. So it asks.
	]]
	toolButton.Visible = tool ~= nil and RunOnly.isRunning()
	toolNameLabel.Visible = toolButton.Visible

	local burnsFuel = tool ~= nil and tool.fuelBurn > 0
	fuelPanel.Visible = burnsFuel and state.fuelCapacity > 0
	if fuelPanel.Visible then
		local fuelFraction = math.clamp(state.fuel / state.fuelCapacity, 0, 1)
		fuelFill.Size = UDim2.fromScale(fuelFraction, 1)
		fuelFill.BackgroundColor3 = if fuelFraction <= 0.15 then Theme.colors.danger else Theme.colors.warn
		fuelLabel.Text = `{math.floor(state.fuel)} / {math.floor(state.fuelCapacity)}`
	end

	local fraction = PlayerState.bagFraction()
	local rideable = tool ~= nil and tool.vehicle ~= nil
	if state.rentalSecondsLeft > 0 and state.rentalToolId ~= "" then
		local rented = Tools.get(state.rentalToolId)
		hintLabel.Text = `{if rented then rented.name else "Rental"} — {Format.clock(state.rentalSecondsLeft)} left`
	elseif fraction >= 1 then
		hintLabel.Text = "Bag full — head to the trailer"
	elseif burnsFuel and state.fuel <= 0 then
		hintLabel.Text = "Out of fuel — refill at the shed"
	elseif rideable then
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
function Hud.setJournalBadge(visible: boolean)
	journalBadge.Visible = visible
end

return Hud
