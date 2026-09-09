--!strict
--[[
	Theme — one palette and a few builders, so every panel matches.

	The look is deliberately chunky: a rounded heavy face with a thick dark
	outline on every piece of text. That outline is not decoration — this UI sits
	over a bright amber sky and a floor of yellow leaves, and unoutlined white
	text simply disappears against it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local Palette = require(ReplicatedStorage:WaitForChild("Shared").Config.Palette)
local Props = require(ReplicatedStorage:WaitForChild("Shared").Config.Props)

local Theme = {}

Theme.colors = {
	panel = Palette.color(Palette.ui.panel),
	panelLight = Palette.color(Palette.ui.panelLight),
	stroke = Palette.color(Palette.ui.accent),
	text = Palette.color(Palette.ui.text),
	subtext = Color3.fromRGB(226, 208, 178),
	grass = Palette.color(Palette.grass.blade),
	grassDark = Palette.color(Palette.grass.bladeDark),
	cash = Palette.color(Palette.ui.cash),
	tips = Palette.color(Palette.ui.tips),
	warn = Palette.color(Palette.ui.warn),
	danger = Palette.color(Palette.ui.danger),
	bag = Palette.color(Palette.ui.accent),
	outline = Palette.color(Palette.ui.outline),
	progress = Palette.color(Palette.ui.progress),
	accent = Palette.color(Palette.ui.accent),
	--[[
		Three inks the redesign needs and the palette did not name.

		`label` replaces the 138,119,97 the small captions used to use, which
		measures about 3.5:1 against the dark panels — under the 4.5:1 a
		thirteen point label needs. `body` is running text on a dark panel,
		and `ink` / `inkSoft` are the two weights of dark type that sit on a
		cream card face, where white would vanish.
	]]
	label = Color3.fromRGB(179, 156, 126),
	body = Color3.fromRGB(201, 179, 148),
	ink = Color3.fromRGB(46, 36, 24),
	inkSoft = Color3.fromRGB(110, 96, 80),
}

--- Rounded and heavy, to match the storybook tone of the world.
Theme.font = Enum.Font.FredokaOne
Theme.fontRegular = Enum.Font.FredokaOne

--- Thickness of the dark outline behind body text.
Theme.OUTLINE = 2.5
Theme.OUTLINE_HEAVY = 3.5

--- Puts a heavy dark outline on a text label so it survives a bright backdrop.
function Theme.outline(label: TextLabel | TextButton, thickness: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = thickness or Theme.OUTLINE
	stroke.Color = Theme.colors.outline
	stroke.Transparency = 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label
	return stroke
end

--[[
	Dresses one of Roblox's touch buttons as one of ours.

	`ContextActionService` will draw a button for a bound action on a touch
	screen, and that is how Ride and Trailer reach a tablet at all. What it
	draws is a forty-five pixel grey ring in the engine's own style, which
	next to this game's chrome — an eighty-six pixel tool button with a thick
	ink outline, a hotbar of seventy-two pixel slots — reads as a piece of
	Roblox that wandered into the game. The two most expensive things a player
	can do, getting on the mower and parking the trailer, were the two that
	looked least like the game.

	The button belongs to the engine, so it is dressed rather than replaced:
	its ring image is dropped and our own panel, corner, outline and font go
	on instead.

	Its place in the corner is not left alone, though it used to be. The
	engine stacks these where a thumb is, which is the same corner this
	game's own tool button parks in — and the tool button carries a word
	under it, PICK UP or MOW. Photographed on a phone: "Trailer" sitting
	squarely on top of "PICK UP", with the tool button's icon behind it.
	`parkTool` measures Roblox's jump button and keeps clear of that, but
	nothing was keeping Roblox's context buttons clear of `parkTool`.

	So the caller says which slot it wants and they are stacked up the right
	edge above the tool button, where nothing else of ours goes. `slot` is
	counted from the bottom.

	It is fetched rather than assumed, because the button does not exist on
	the frame the action is bound, and a rebind makes a new one — so every
	bind calls this again.
]]
function Theme.dressActionButton(actionName: string, slot: number?, label: string?)
	task.spawn(function()
		local button: ImageButton? = nil
		for _ = 1, 24 do
			button = ContextActionService:GetButton(actionName)
			if button then
				break
			end
			task.wait(0.1)
		end
		if not button then
			return
		end
		local face = button :: ImageButton
		face.Size = UDim2.fromOffset(72, 72)
		--[[
			Stacked down from the top of the engine's own button frame.

			Measured against that frame rather than the screen, because that
			is what these are parented to: a position given in screen
			fractions comes out somewhere else entirely, since the frame is
			only the bottom-right corner of the display. Anchored to its top
			edge, the buttons land above where `parkTool` puts the tool button
			and its word, which is the collision this is here to stop, and
			they stay above it however the screen is shaped — the frame and
			the tool button both hang off the same corner.
		]]
		if slot then
			--[[
				Stacked upward from the top edge of that frame, not downward
				from it: at the second slot a downward stack finishes one
				pixel into the top of the tool button, and the frame does not
				clip, so going up costs nothing and leaves a clear gap.
			]]
			face.AnchorPoint = Vector2.new(1, 1)
			face.Position = UDim2.new(1, -26, 0, -slot * 84)
		end
		-- The engine's ring goes; ours is a filled disc like every other
		-- control on the screen.
		face.Image = ""
		face.PressedImage = ""
		face.BackgroundColor3 = Theme.colors.panelLight
		face.BackgroundTransparency = 0.12
		--[[
			Dressed once, however many times this is called.

			`Theme.corner` and `Theme.stroke` each add an instance, so calling
			this again on the same button stacks another pair on it. One
			caller was calling it about five times a second for the whole run,
			which is a few thousand UICorners on a single button; that caller
			is fixed, and so is this, because the engine hands back the same
			button for the same action and nothing here should assume it is
			the first to have touched it.
		]]
		if not face:FindFirstChildOfClass("UICorner") then
			Theme.corner(face, 36)
		end
		if not face:FindFirstChildOfClass("UIStroke") then
			Theme.stroke(face, 3, Theme.colors.outline, 0.05)
		end
		for _, child in face:GetDescendants() do
			if child:IsA("TextLabel") then
				child.Font = Theme.font
				child.TextSize = 17
				child.TextColor3 = Theme.colors.text
				child.TextScaled = false
				child.Size = UDim2.fromScale(1, 1)
				child.Position = UDim2.fromScale(0, 0)
				if label then
					child.Text = label
				end
			end
		end
	end)
end

function Theme.corner(parent: Instance, radius: number): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
	return corner
end

function Theme.stroke(parent: Instance, thickness: number, color: Color3?, transparency: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = thickness
	stroke.Color = color or Theme.colors.stroke
	stroke.Transparency = transparency or 0.4
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

function Theme.padding(parent: Instance, amount: number): UIPadding
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, amount)
	padding.PaddingBottom = UDim.new(0, amount)
	padding.PaddingLeft = UDim.new(0, amount)
	padding.PaddingRight = UDim.new(0, amount)
	padding.Parent = parent
	return parent :: any
end

export type PanelOptions = {
	name: string,
	size: UDim2,
	position: UDim2,
	anchor: Vector2?,
	parent: Instance,
	transparency: number?,
}

function Theme.panel(options: PanelOptions): Frame
	local frame = Instance.new("Frame")
	frame.Name = options.name
	frame.Size = options.size
	frame.Position = options.position
	frame.AnchorPoint = options.anchor or Vector2.new(0, 0)
	frame.BackgroundColor3 = Theme.colors.panel
	frame.BackgroundTransparency = options.transparency or 0.2
	frame.BorderSizePixel = 0
	frame.Parent = options.parent
	Theme.corner(frame, 12)
	Theme.stroke(frame, 2.5, Theme.colors.outline, 0.1)
	return frame
end

export type TextOptions = {
	name: string?,
	text: string,
	size: UDim2,
	position: UDim2,
	anchor: Vector2?,
	parent: Instance,
	color: Color3?,
	align: Enum.TextXAlignment?,
	bold: boolean?,
	textSize: number?,
}

--[[
	Every face the chrome is made of, so the night can turn them down.

	The whole HUD is built for a bright amber sky. On the churchyard the
	ground is a dark blue-green under fog, and a mid-brown panel that reads as
	*wood* at noon reads as a *lit box* at midnight — the chrome becomes the
	brightest thing on the property, brighter than the lanterns that are
	supposed to be leading you. Same hues, both stops darker, and the panels
	recede behind the light.

	Registered rather than re-created, because the chrome is built once when
	the client starts and the property changes under it every run.
]]
local faces: { { grade: UIGradient, top: Color3, bottom: Color3 } } = {}

--- Labels drawn in dark ink, which want a light halo after dark.
local haloes: { TextLabel } = {}

local nightFall = false

--- How far the chrome drops after dark. Enough to sit under the lanterns,
--- not so far that a cream card stops reading as paper.
local NIGHT_DROP = 0.74

local function dim(colour: Color3, amount: number): Color3
	return Color3.new(colour.R * amount, colour.G * amount, colour.B * amount)
end

--[[
	Turn the chrome down for a property worked in the dark.

	Called when the run's world changes. Everything it touches was built once
	at start-up, so this is a repaint rather than a rebuild — and it is
	deliberately only two moves: the faces come down a stop and dark ink
	gains a halo. The accents stay exactly as they are, because `ui.tips` is
	already candlelight and the warm things on this property are the
	landmarks.
]]
function Theme.setNight(on: boolean)
	if on == nightFall then
		return
	end
	nightFall = on

	for _, face in faces do
		if face.grade.Parent then
			face.grade.Color = if on
				then ColorSequence.new(dim(face.top, NIGHT_DROP), dim(face.bottom, NIGHT_DROP))
				else ColorSequence.new(face.top, face.bottom)
		end
	end

	for _, label in haloes do
		if not label.Parent then
			continue
		end
		local halo = label:FindFirstChild("Halo")
		if on and not halo then
			local fresh = Instance.new("UIStroke")
			fresh.Name = "Halo"
			fresh.Thickness = 2
			fresh.Color = Color3.new(1, 1, 1)
			fresh.Transparency = 0.55
			fresh.Parent = label
		elseif not on and halo then
			halo:Destroy()
		end
	end
end

function Theme.text(options: TextOptions): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = options.name or "Label"
	label.Text = options.text
	label.Size = options.size
	label.Position = options.position
	label.AnchorPoint = options.anchor or Vector2.new(0, 0)
	label.BackgroundTransparency = 1
	label.Font = if options.bold == false then Theme.fontRegular else Theme.font
	label.TextColor3 = options.color or Theme.colors.text
	label.TextXAlignment = options.align or Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.RichText = true
	if options.textSize then
		label.TextSize = options.textSize
	else
		label.TextScaled = true
	end
	label.Parent = options.parent

	--[[
		A dark outline on light lettering, and none on dark.

		Every label used to get the outline, because the world behind this UI
		is far too bright for bare white text. That is right for white text
		and wrong for everything else: dark ink with a three-and-a-half pixel
		dark outline is a solid black letter, and the captions under the
		Journal and Sound tiles and the word on the STORE pill had been exactly
		that — "you can't even see it, it's just black" — since the day they
		were given a light pill to sit on. So the outline goes on when the ink
		is light enough to need it, by luminance, and stays off otherwise.
	]]
	local ink = label.TextColor3
	local luminance = 0.299 * ink.R + 0.587 * ink.G + 0.114 * ink.B
	if luminance > 0.45 then
		Theme.outline(label, if options.bold == false then Theme.OUTLINE else Theme.OUTLINE_HEAVY)
	else
		--[[
			Dark ink gets nothing by day and a pale halo after dark.

			The rule above is right for light lettering over a sunlit lawn.
			Its opposite is true on the churchyard: dark ink sits on a cream
			card, and a cream card at midnight is the brightest thing on the
			screen — the halo is what lets the card come down without the
			words going with it.
		]]
		table.insert(haloes, label)
		if nightFall then
			local halo = Instance.new("UIStroke")
			halo.Name = "Halo"
			halo.Thickness = 2
			halo.Color = Color3.new(1, 1, 1)
			halo.Transparency = 0.55
			halo.Parent = label
		end
	end
	return label
end

--- A horizontal fill bar. Returns the fill frame so callers can size it.
function Theme.bar(parent: Instance, size: UDim2, position: UDim2, color: Color3): (Frame, Frame)
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Size = size
	track.Position = position
	track.BackgroundColor3 = Theme.colors.panelLight
	track.BorderSizePixel = 0
	track.Parent = parent
	Theme.corner(track, 6)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = track
	Theme.corner(fill, 6)

	local outline = Instance.new("UIStroke")
	outline.Thickness = 2
	outline.Color = Theme.colors.outline
	outline.Transparency = 0.15
	outline.Parent = track

	return track, fill
end

--[[
	Keeps a fixed-size panel on screen on a small viewport.

	The journal is drawn at 940x560 with its tab strip hanging off the left
	edge, so anything narrower than about 1160 pushed the tabs and the close
	button off screen entirely — which on a phone, or a windowed client, is
	most of them. Rather than reflow the layout, the whole panel is scaled to
	fit, which keeps the book a book at every size.

	`width` and `height` are the room the panel needs including anything that
	hangs outside it. `reservedY` is screen height the panel does not get — the
	gap above a column pinned below the top edge, plus any margin to leave under
	it — so a column that starts part way down the screen is measured against
	what is actually left rather than the whole of it.
]]
--[[
	`reservedX` keeps room clear either side rather than only above.

	A panel centred along an edge does not run out of room when it reaches the
	screen edge — it runs out when it reaches whatever else lives in that
	corner. The hotbar is the case: eight slots across the bottom, with the bag
	210 pixels in from the left and the clock 262 in from the right, and on a
	portrait iPad the bar met both of them long before it met the edge.
	Fitting against the width less both corners is the same sum a person does
	by eye, and it leaves the bar full size wherever there is room for all
	three.
]]
--[[
	The height at which the fixed-size HUD chrome starts standing down.

	Every desktop window and every tablet is taller than this, so the scale
	clamps at 1 and nothing outside a phone is touched.
]]
local CHROME_HEIGHT = 640
--- As small as the chrome is allowed to get. Below this the text stops being
--- readable, which is a worse problem than the one this solves.
local CHROME_FLOOR = 0.62

--- How much of its designed size the fixed HUD chrome is drawn at, for a
--- screen of this size. Used both to scale that chrome and to work out how
--- much room to leave for it.
local function chromeFactor(area: Vector2): number
	return math.clamp(area.Y / CHROME_HEIGHT, CHROME_FLOOR, 1)
end

--[[
	Where a phone starts.

	A phone held sideways is about three hundred and ninety points tall and
	eight hundred and forty wide: short and wide, which is the opposite of a
	tablet. Everything above this gets the tablet layout, shrunk by
	`chromeFactor` if it has to be; below it, the pieces that have a phone
	layout of their own use it instead of a smaller copy of the tablet one.
]]
Theme.PHONE_HEIGHT = 500

function Theme.isPhone(): boolean
	local camera = workspace.CurrentCamera
	return camera ~= nil and camera.ViewportSize.Y <= Theme.PHONE_HEIGHT
end

--[[
	Run `fn` now and again whenever the screen changes shape.

	Three panels lay themselves out differently on a phone and each of them
	needs the same three connections to notice — the camera's viewport, and
	the camera being swapped out from under it, which happens on every respawn.
]]
function Theme.onScreenChange(fn: () -> ())
	fn()
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(fn)
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local current = workspace.CurrentCamera
		if current then
			current:GetPropertyChangedSignal("ViewportSize"):Connect(fn)
		end
		fn()
	end)
end

function Theme.fitToViewport(
	panel: GuiObject,
	width: number,
	height: number,
	reservedY: number?,
	reservedX: number?,
	reservedXInset: number?,
	--- The panel has a phone layout of its own and is not to be shrunk into
	--- one. See `Theme.chromeScale`.
	ownLayout: boolean?
): UIScale
	local scale = Instance.new("UIScale")
	scale.Parent = panel

	-- The screen the panel actually gets is the ScreenGui's own area, which is
	-- the viewport less the top inset. Measuring against the raw viewport
	-- overstates the room available by that inset and leaves the panel's top
	-- edge off screen.
	local screen = panel:FindFirstAncestorWhichIsA("ScreenGui")

	local function fit()
		local area: Vector2
		if screen and screen.AbsoluteSize.Y > 0 then
			area = screen.AbsoluteSize
		else
			local camera = workspace.CurrentCamera
			area = if camera then camera.ViewportSize else Vector2.new(1280, 720)
		end
		if area.X <= 0 or area.Y <= 0 then
			return
		end
		--[[
			A reserve is a widget that scales plus a margin that does not.

			`reservedY` is the panel's own drop from the top edge. A `UIScale`
			does not move the thing it is on, so that is the same number of pixels
			on every screen and it is used as given.

			The horizontal reserve is the round timer sitting in the bottom
			corner, and that is two different measurements added together: the
			timer is `reservedX` wide and is chrome, so it shrinks; it sits
			`reservedXInset` in from the edge, and that offset does not. Leaving
			the whole 262 fixed reserved room on a phone for corners that had
			shrunk to 173, and the bar paid for it — eight slots at 53 pixels
			where there was room for 72.

			Scaling the whole 262 instead is wrong in the other direction, and
			only by enough to be missed: at 812x339 it reserves 162 for a timer
			whose left edge is 171 in, and the last slot lands 8 pixels underneath
			it. Splitting the two is the only version that holds at both ends —
			it is exactly 262 wherever the chrome is full size, so no screen
			large enough to matter sees any change at all.
		]]
		local usableY = math.max(area.Y - (reservedY or 0), 1)
		local reserve = (reservedXInset or 0) + (reservedX or 0) * chromeFactor(area)
		local usableX = math.max(area.X - reserve * 2, 1)
		if ownLayout and area.Y <= Theme.PHONE_HEIGHT then
			scale.Scale = 1
			return
		end
		scale.Scale = math.clamp(math.min(usableX / width, usableY / height), 0.35, 1)
	end

	fit()
	if screen then
		screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	end
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local current = workspace.CurrentCamera
		if current then
			current:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
		end
		fit()
	end)

	return scale
end

--[[
	Shrinks a fixed-size piece of HUD chrome on a short screen.

	This is not `fitToViewport` and could not be. That one answers "is this
	panel too big for the screen, and by how much" — so for anything that
	already fits it returns 1 and does nothing. The bag is 190x74. It fits on
	every screen ever made, and it was therefore never scaled, and on a phone it
	was three and a half percent of the picture instead of one and a half.

	The HUD was full of that. Measured against an iPhone-sized viewport, the
	toasts covered seventeen percent of the screen and sat across the middle of
	it, the zone panel ten percent of the top-left corner, and the hint ran to
	over half the width — all of them pixel-for-pixel the size they are on a
	desktop monitor three times the area. Nothing was off screen, which is why
	nothing caught it; there was simply far more furniture than lawn.

	So the measure here is the screen's height rather than the panel's size,
	because the question is how much room the player has, not whether the thing
	fits. Anchored corners stay anchored: a `UIScale` changes the size of what
	it is on and the position of what is inside it, but not that object's own
	position, so a bag pinned to the bottom-left shrinks towards the corner it
	is pinned to rather than drifting off it.
]]
--[[
	`ownLayout` elements keep their designed size on a phone.

	Shrinking is the right answer for a panel that has one shape: below six
	hundred and forty the chrome stands down rather than running off the edge.
	It is the wrong answer for the three panels that have a second shape — the
	hero bar, the bag, the rail — because a phone layout drawn at sixty-two
	per cent is a phone layout nobody can read. Those pass `true` and lay
	themselves out instead.
]]
function Theme.chromeScale(element: GuiObject, ownLayout: boolean?): UIScale
	local scale = Instance.new("UIScale")
	scale.Parent = element

	local screen = element:FindFirstAncestorWhichIsA("ScreenGui")

	local function fit()
		local area: Vector2
		if screen and screen.AbsoluteSize.Y > 0 then
			area = screen.AbsoluteSize
		else
			local camera = workspace.CurrentCamera
			area = if camera then camera.ViewportSize else Vector2.new(1280, 720)
		end
		if area.Y <= 0 then
			return
		end
		scale.Scale = if ownLayout and area.Y <= Theme.PHONE_HEIGHT then 1 else chromeFactor(area)
	end

	fit()
	if screen then
		screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	end
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local current = workspace.CurrentCamera
		if current then
			current:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
		end
		fit()
	end)

	return scale
end

--[[
	Whether the player has keys to press.

	The HUD is written for a touch screen first — that is what nearly every
	player holds — and mentions a key only when there is one. A tablet with a
	keyboard attached counts as having one; a laptop with a touch screen
	counts as having one. Only a device with touch and no keyboard is told
	to tap.
]]
function Theme.hasKeyboard(): boolean
	local UserInputService = game:GetService("UserInputService")
	-- What the player last touched settles it, when there is an answer: a key
	-- or a mouse means keys, a finger means tap. Studio reports a keyboard and
	-- a touch screen at once, and so does a tablet with a keyboard clipped on;
	-- the device flags alone cannot tell those two players apart.
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Keyboard or last == Enum.UserInputType.MouseButton1
		or last == Enum.UserInputType.MouseMovement or last == Enum.UserInputType.MouseWheel then
		return true
	end
	if last == Enum.UserInputType.Touch then
		return false
	end
	return UserInputService.KeyboardEnabled or not UserInputService.TouchEnabled
end

--------------------------------------------------------------------
-- The cursor
--------------------------------------------------------------------

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local panelsOpen = 0
local cursorHold: RBXScriptConnection? = nil

--[[
	Frees the mouse while a full-screen panel is open.

	The camera is pinned to first person — zoom locked at 0.5 studs — and Roblox
	locks the cursor to the middle of the screen whenever it is. Every control
	in the journal and the store therefore sat somewhere the cursor could never
	reach: its tabs, its close button, and the Buy buttons that are the only way
	in the whole game to buy a tool. A `Modal` button asks the engine for the
	cursor back, and holding `MouseBehavior` open each frame alongside it covers
	the camera module reasserting the lock — belt and braces, because a menu you
	cannot click is the same as no menu.

	Reference counted, so the journal and the store can be open in any order
	without one closing stealing the other's cursor.
]]
function Theme.holdCursor(open: boolean)
	panelsOpen = math.max(panelsOpen + (if open then 1 else -1), 0)

	if panelsOpen > 0 then
		if not cursorHold then
			cursorHold = RunService.RenderStepped:Connect(function()
				if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
					UserInputService.MouseBehavior = Enum.MouseBehavior.Default
				end
			end)
		end
	elseif cursorHold then
		cursorHold:Disconnect()
		cursorHold = nil
		-- Handing it back to the camera, which re-locks it for first person.
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	end
end

--------------------------------------------------------------------
-- Icons
--------------------------------------------------------------------

--[[
	An icon, which is a model on a little stage rather than a letter.

	Every icon in this game used to be an emoji — a glove, a broom, a tractor, a
	coin, a padlock. An emoji is a character in a font, so the picture is
	whichever one the player's device ships with: the same hotbar is three
	different sets of drawings on a phone, a console and a PC, and not one of
	them is this game's own art. Worse, the glove standing for bare hands and
	the broom standing for a rake were never the tool you were actually holding.

	So an icon is a `ViewportFrame` holding the model itself, lit and framed.
	The one in the hotbar is the same mesh that appears in your hands.

	The camera distance comes from the model's own size, so a padlock and a
	riding mower both end up filling their slot rather than one of them being a
	speck. `Theme.setIcon` swaps the model without rebuilding the frame, which
	is what the hotbar does every time you buy something.
]]
export type IconOptions = {
	name: string?,
	prop: string,
	size: UDim2,
	position: UDim2,
	anchor: Vector2?,
	parent: Instance,
	zIndex: number?,
}

--- How far back the camera sits, as a multiple of the model's largest side.
--[[
	How much of its frame an icon's subject fills.

	At 1.15 the camera sat far enough back that a prop occupied about three
	fifths of its frame height, and that frame is itself a fraction of the tile
	around it — so a tool icon in the journal came out roughly a third of the
	card it sat in and read as a smudge rather than a rake. The reference fills
	its icon tiles almost edge to edge, which is what makes its shelf of
	upgrades legible at a glance.

	Not pushed further than this: the subject is framed on its largest
	dimension and then turned three-quarters on, so a long prop projects wider
	than that dimension and the remaining margin is what stops a rake handle
	being cut off at the frame edge.
]]
local ICON_PULL_BACK = 1.42
--- Three-quarter view: enough turn to read a shape as a solid, not a plan.
local ICON_ANGLE = Vector3.new(0.42, 0.34, 1).Unit

--- Points an icon's camera at whatever model it is now showing.
local function frameIcon(viewport: ViewportFrame, native: Vector3)
	local camera = viewport.CurrentCamera
	if not camera then
		return
	end
	local reach = math.max(native.X, native.Y, native.Z, 0.05)
	-- Half the subject over the tangent of half the field of view is the
	-- distance at which it exactly fills the frame; the rest is margin.
	local distance = (reach * 0.5) / math.tan(math.rad(camera.FieldOfView * 0.5))
	camera.CFrame = CFrame.lookAt(ICON_ANGLE * (distance / ICON_PULL_BACK * 1.9), Vector3.zero)
end

--- Shows `propName` in an icon frame built by `Theme.icon`. Silent on an
--- unknown name, so a new tool category cannot blank the hotbar.
function Theme.setIcon(frame: GuiObject, propName: string)
	--[[
		A drawn image, given by id rather than by prop name.

		Every icon in the game used to belong to a prop — a mesh with a name
		in the catalogue — and this looked one up. The per-tool icons have no
		prop behind them and never will: there is no `ReelMower` model, only a
		picture of one, and inventing sixteen catalogue entries with fake mesh
		ids and native sizes to hang sixteen images on would be a lie told to
		a lookup table. So an id is allowed to arrive directly. Anything that
		is not an id is still a prop name, exactly as before.

		Without this the call quietly did nothing: `Props.get` returned nil for
		an id, the function returned early, and every tool kept whatever icon
		it happened to have — which is how six mowers went on sharing one
		picture after they had each been given their own.
	]]
	if string.sub(propName, 1, 13) == "rbxassetid://" then
		local drawn = frame:FindFirstChild("Picture") :: ImageLabel?
		if drawn then
			drawn.Image = propName
			drawn.Visible = true
		end
		local spun = if frame:IsA("ViewportFrame")
			then frame
			else frame:FindFirstChildWhichIsA("ViewportFrame")
		if spun then
			spun.Visible = false
		end
		return
	end

	local def = Props.get(propName)
	if not def then
		return
	end

	--[[
		A drawn icon if the prop has one, and the spun mesh if it does not.

		Both live under the same frame: the picture on top, the viewport
		underneath. Swapping which is visible keeps one call site for every
		icon in the game, and means a prop nobody has drawn yet still shows
		something rather than a hole.
	]]
	local picture = frame:FindFirstChild("Picture") :: ImageLabel?
	if picture then
		picture.Image = def.icon or ""
		picture.Visible = def.icon ~= nil
	end

	local viewport = if frame:IsA("ViewportFrame") then frame else frame:FindFirstChildWhichIsA("ViewportFrame")
	if not viewport then
		return
	end
	viewport.Visible = def.icon == nil
	if def.icon then
		return
	end

	local part = viewport:FindFirstChild("Model") :: BasePart?
	local mesh = if part then part:FindFirstChildWhichIsA("SpecialMesh") else nil
	if not part or not mesh then
		return
	end
	if mesh.MeshId ~= def.mesh then
		mesh.MeshId = def.mesh
		mesh.TextureId = def.texture or ""
	end
	part.Color = def.color or Color3.new(1, 1, 1)
	frameIcon(viewport, def.native)
end

--[[
	Fades an icon, whichever of the two it is showing.

	A `ViewportFrame` and an `ImageLabel` both fade through
	`ImageTransparency`, but they are different instances under the holder, so
	a caller that used to hold the viewport directly needs one call that
	reaches whichever is up.
]]
function Theme.setIconTransparency(frame: GuiObject, transparency: number)
	local picture = frame:FindFirstChild("Picture")
	if picture and picture:IsA("ImageLabel") then
		picture.ImageTransparency = transparency
	end
	local viewport = frame:FindFirstChildWhichIsA("ViewportFrame")
	if viewport then
		viewport.ImageTransparency = transparency
	end
end

function Theme.icon(options: IconOptions): Frame
	--[[
		A holder carrying both ways of showing a prop.

		Callers name a prop and a size and get one frame back, exactly as
		before; which of the two is visible is `setIcon`'s business.
	]]
	local holder = Instance.new("Frame")
	holder.Name = options.name or "Icon"
	holder.Size = options.size
	holder.Position = options.position
	holder.AnchorPoint = options.anchor or Vector2.new(0, 0)
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	if options.zIndex then
		holder.ZIndex = options.zIndex
	end

	local picture = Instance.new("ImageLabel")
	picture.Name = "Picture"
	picture.Size = UDim2.fromScale(1, 1)
	picture.BackgroundTransparency = 1
	picture.BorderSizePixel = 0
	picture.ScaleType = Enum.ScaleType.Fit
	picture.Visible = false
	if options.zIndex then
		picture.ZIndex = options.zIndex
	end
	picture.Parent = holder

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Mesh"
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.BackgroundTransparency = 1
	viewport.BorderSizePixel = 0
	if options.zIndex then
		viewport.ZIndex = options.zIndex
	end

	-- Lit from the front rather than by the world, so an icon reads the same in
	-- a basement at night as on the lawn at noon.
	viewport.Ambient = Color3.fromRGB(190, 190, 190)
	viewport.LightColor = Color3.fromRGB(255, 250, 240)
	viewport.LightDirection = Vector3.new(-0.3, -0.8, -0.6)

	local part = Instance.new("Part")
	part.Name = "Model"
	part.Anchored = true
	part.CanCollide = false
	part.CFrame = CFrame.new()
	part.Parent = viewport

	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.FileMesh
	mesh.Parent = part

	local camera = Instance.new("Camera")
	camera.FieldOfView = 30
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	viewport.Parent = holder
	holder.Parent = options.parent
	Theme.setIcon(holder, options.prop)
	return holder
end

--------------------------------------------------------------------
-- Chunk chrome
--------------------------------------------------------------------

--[[
	The vocabulary everything in the redesign is cut from.

	The HUD used to be panel-less — outlined text floating over the lawn — and
	that is the single thing that read as unfinished beside the games in this
	genre. Those put every element on a bevelled, hard-outlined panel with a
	visible drop, and use colour to mean one thing consistently.

	Roblox has neither `box-shadow` nor `linear-gradient` on a frame, so a
	panel is composed of four pieces:

	1. a shadow behind it, the same size, six pixels down;
	2. the body, with a `UIGradient` running top to bottom;
	3. a four-pixel border in the ink colour;
	4. a three-pixel white bevel pinned inside the top edge at fourteen per
	   cent, which is most of what makes the panel look moulded rather than
	   flat.

	The shadow has to be a *sibling*: a child always draws over its parent
	whatever its `ZIndex`, so it cannot go behind the thing it belongs to. To
	keep that out of every caller's layout, the builder makes a transparent
	holder, puts the shadow and the body inside it, and hands back the body.
	The holder is what a `UIListLayout` sees and what carries the size — reach
	it with `body.Parent` if you need to reorder or reposition one later.
]]
export type ChunkOptions = {
	name: string?,
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	parent: Instance,
	--- 18 for a panel, `Theme.PILL` for a capsule.
	radius: number?,
	--- How far the drop falls. 6 for panels and tiles, 5 for cards.
	drop: number?,
	outline: number?,
	--- Height follows the contents, which is what an auto panel wants.
	autoSize: Enum.AutomaticSize?,
	zIndex: number?,
	top: Color3?,
	bottom: Color3?,
	shadow: Color3?,
	--- Off for a face that is already light, where a white bevel does nothing.
	bevel: boolean?,
}

--- A pill's radius. `UICorner` takes a scale, and half of the shorter side is
--- what makes a capsule at any height.
Theme.PILL = -1

local function cornerFor(parent: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = if radius == Theme.PILL then UDim.new(0.5, 0) else UDim.new(0, radius)
	corner.Parent = parent
end

local function gradient(parent: Instance, top: Color3, bottom: Color3)
	local grade = Instance.new("UIGradient")
	grade.Color = ColorSequence.new(top, bottom)
	grade.Rotation = 90
	grade.Parent = parent
	table.insert(faces, { grade = grade, top = top, bottom = bottom })
	if nightFall then
		grade.Color = ColorSequence.new(dim(top, NIGHT_DROP), dim(bottom, NIGHT_DROP))
	end
	return grade
end

--- The inner highlight along the top edge. Three pixels of white at fourteen
--- per cent on dark chrome, seventy on a cream face.
local function bevel(parent: GuiObject, strength: number)
	local light = Instance.new("Frame")
	light.Name = "Bevel"
	light.Size = UDim2.new(1, -8, 0, 3)
	light.Position = UDim2.fromOffset(4, 3)
	light.BackgroundColor3 = Color3.new(1, 1, 1)
	light.BackgroundTransparency = 1 - strength
	light.BorderSizePixel = 0
	--[[
		The same layer as the face it sits on, not one above it.

		This project's `ScreenGui`s run `ZIndexBehavior = Global`, where a
		number is compared across the whole tree rather than among siblings —
		so anything a caller parents into a panel at the default `ZIndex` of
		one lands *behind* a panel body set to two, and the first build of
		this came out as four black rectangles with no text in them. On a tie
		the tree order decides, and children are walked after their parent, so
		the face is drawn first and everything put inside it lands on top.
	]]
	light.ZIndex = parent.ZIndex
	light.Parent = parent
	cornerFor(light, 2)
	return light
end

function Theme.chunkPanel(options: ChunkOptions): Frame
	local radius = options.radius or 18
	local drop = options.drop or 6
	local z = options.zIndex or 1

	local holder = Instance.new("Frame")
	holder.Name = (options.name or "Panel") .. "Holder"
	holder.Size = options.size or UDim2.fromOffset(100, 100)
	holder.Position = options.position or UDim2.fromOffset(0, 0)
	holder.AnchorPoint = options.anchor or Vector2.zero
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.ZIndex = z
	if options.autoSize then
		holder.AutomaticSize = options.autoSize
	end
	holder.Parent = options.parent

	local shade = Instance.new("Frame")
	shade.Name = "Drop"
	shade.Size = UDim2.fromScale(1, 1)
	shade.Position = UDim2.fromOffset(0, drop)
	shade.BackgroundColor3 = options.shadow or Theme.colors.outline
	shade.BorderSizePixel = 0
	--- One below the face, so it is the drop and not a lid. See `bevel`.
	shade.ZIndex = z - 1
	shade.Parent = holder
	cornerFor(shade, radius)

	local body = Instance.new("Frame")
	body.Name = options.name or "Panel"
	body.Size = UDim2.fromScale(1, 1)
	body.BackgroundColor3 = options.top or Theme.colors.panelLight
	body.BorderSizePixel = 0
	body.ZIndex = z
	if options.autoSize then
		body.Size = UDim2.fromScale(1, 0)
		body.AutomaticSize = options.autoSize
	end
	body.Parent = holder
	cornerFor(body, radius)
	gradient(body, options.top or Theme.colors.panelLight, options.bottom or Theme.colors.panel)
	Theme.stroke(body, options.outline or 4, Theme.colors.outline, 0)
	if options.bevel ~= false then
		bevel(body, 0.14)
	end
	return body
end

--[[
	A cream card face — the Journal's tool cards, the world cards.

	Same four pieces, a light gradient, and a stronger bevel because white on
	cream at fourteen per cent is not there at all.
]]
--[[
	Re-rounds a chunk panel or button, drop included.

	The radius is set when the piece is built, and two of them change shape on
	a phone: the rail's tiles go from twenty to fourteen, and the store stops
	being a capsule. Missing the drop leaves a rounder shadow sticking out from
	under a squarer face, which is the sort of thing nobody names and everybody
	sees.
]]
function Theme.reround(face: GuiObject, radius: number)
	local shape = if radius == Theme.PILL then UDim.new(0.5, 0) else UDim.new(0, radius)
	local holder = face.Parent
	local pieces: { Instance } = { face }
	local drop = if holder then holder:FindFirstChild("Drop") else nil
	if drop then
		table.insert(pieces, drop)
	end
	for _, object in pieces do
		local corner = object:FindFirstChildOfClass("UICorner")
		if corner then
			corner.CornerRadius = shape
		end
	end
end

function Theme.cardFace(options: ChunkOptions): Frame
	local card = Theme.chunkPanel({
		name = options.name or "Card",
		size = options.size,
		position = options.position,
		anchor = options.anchor,
		parent = options.parent,
		radius = options.radius or 16,
		drop = options.drop or 5,
		outline = options.outline or 4,
		autoSize = options.autoSize,
		zIndex = options.zIndex,
		top = options.top or Color3.fromRGB(255, 252, 241),
		bottom = options.bottom or Color3.fromRGB(237, 225, 200),
		bevel = false,
	})
	bevel(card, 0.7)
	return card
end

--[[
	One button language, and colour that means one thing everywhere.

	Green is always run cash. Blue is always "Robux, this run". Purple is
	always "Robux, forever". The store reading as spending real money is the
	whole reason for that rule — the shipped UI puts the same green Buy button
	on all three, so nothing on the screen tells a player which of their two
	currencies is about to go.

	The drop under a button is a darker shade of the button's own colour
	rather than the ink outline. That is what makes it read as a slab you can
	press rather than a label with a shadow.
]]
export type ButtonVariant = "primary" | "gold" | "robuxRun" | "robuxKeep" | "danger" | "disabled"

local VARIANTS: {
	[string]: { top: Color3, bottom: Color3, shadow: Color3, ink: Color3 },
} = {
	primary = {
		top = Color3.fromRGB(143, 224, 124),
		bottom = Color3.fromRGB(79, 184, 60),
		shadow = Color3.fromRGB(46, 122, 36),
		ink = Color3.fromRGB(18, 58, 12),
	},
	gold = {
		top = Color3.fromRGB(255, 217, 104),
		bottom = Color3.fromRGB(245, 168, 28),
		shadow = Color3.fromRGB(169, 110, 8),
		ink = Color3.fromRGB(24, 18, 10),
	},
	robuxRun = {
		top = Color3.fromRGB(127, 198, 245),
		bottom = Color3.fromRGB(62, 147, 216),
		shadow = Color3.fromRGB(31, 94, 146),
		ink = Color3.fromRGB(8, 36, 61),
	},
	robuxKeep = {
		top = Color3.fromRGB(199, 155, 240),
		bottom = Color3.fromRGB(142, 86, 200),
		shadow = Color3.fromRGB(92, 50, 134),
		ink = Color3.fromRGB(34, 9, 58),
	},
	danger = {
		top = Color3.fromRGB(242, 102, 92),
		bottom = Color3.fromRGB(208, 58, 48),
		shadow = Color3.fromRGB(142, 36, 28),
		ink = Color3.fromRGB(255, 255, 255),
	},
	--- Flat, and no drop: a dead button should not look pressable.
	disabled = {
		top = Color3.fromRGB(179, 166, 142),
		bottom = Color3.fromRGB(179, 166, 142),
		shadow = Color3.fromRGB(179, 166, 142),
		ink = Color3.fromRGB(74, 64, 52),
	},
}

export type ChunkButtonOptions = {
	name: string?,
	text: string?,
	textSize: number?,
	variant: ButtonVariant?,
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	parent: Instance,
	radius: number?,
	drop: number?,
	outline: number?,
	autoSize: Enum.AutomaticSize?,
	zIndex: number?,
}

--- Returns the button. Its holder is `button.Parent`, which is what a layout
--- sees; parent anything you want inside the slab to the button itself.
function Theme.chunkButton(options: ChunkButtonOptions): TextButton
	local look = VARIANTS[options.variant or "primary"] or VARIANTS.primary
	local radius = options.radius or 14
	local drop = if options.variant == "disabled" then 0 else (options.drop or 5)
	local z = options.zIndex or 1

	local holder = Instance.new("Frame")
	holder.Name = (options.name or "Button") .. "Holder"
	holder.Size = options.size or UDim2.fromOffset(120, 44)
	holder.Position = options.position or UDim2.fromOffset(0, 0)
	holder.AnchorPoint = options.anchor or Vector2.zero
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.ZIndex = z
	if options.autoSize then
		holder.AutomaticSize = options.autoSize
	end
	holder.Parent = options.parent

	if drop > 0 then
		local shade = Instance.new("Frame")
		shade.Name = "Drop"
		shade.Size = UDim2.fromScale(1, 1)
		shade.Position = UDim2.fromOffset(0, drop)
		shade.BackgroundColor3 = look.shadow
		shade.BorderSizePixel = 0
		shade.ZIndex = z - 1
		shade.Parent = holder
		cornerFor(shade, radius)
	end

	local button = Instance.new("TextButton")
	button.Name = options.name or "Button"
	button.Size = UDim2.fromScale(1, 1)
	button.BackgroundColor3 = look.top
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.ZIndex = z
	button.Font = Theme.font
	button.Text = options.text or ""
	button.TextColor3 = look.ink
	button.TextSize = options.textSize or 18
	if options.autoSize then
		button.Size = UDim2.fromScale(1, 0)
		button.AutomaticSize = options.autoSize
	end
	button.Parent = holder
	cornerFor(button, radius)
	if look.top ~= look.bottom then
		gradient(button, look.top, look.bottom)
	end
	Theme.stroke(button, options.outline or 3, Theme.colors.outline, 0)
	if options.variant ~= "disabled" then
		bevel(button, 0.4)
	end
	return button
end

--[[
	A dark chip: the clock, the tips count, the rail captions, the state word.

	Always `ui.outline` with a pill radius, so a small piece of text on the
	world reads without needing a whole panel behind it.
]]
export type ChipOptions = {
	name: string?,
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	parent: Instance,
	autoSize: Enum.AutomaticSize?,
	radius: number?,
	transparency: number?,
	zIndex: number?,
}

function Theme.chip(options: ChipOptions): Frame
	local chip = Instance.new("Frame")
	chip.Name = options.name or "Chip"
	chip.Size = options.size or UDim2.fromOffset(60, 24)
	chip.Position = options.position or UDim2.fromOffset(0, 0)
	chip.AnchorPoint = options.anchor or Vector2.zero
	chip.BackgroundColor3 = Theme.colors.outline
	chip.BackgroundTransparency = options.transparency or 0
	chip.BorderSizePixel = 0
	chip.ZIndex = options.zIndex or 1
	if options.autoSize then
		chip.AutomaticSize = options.autoSize
	end
	chip.Parent = options.parent
	cornerFor(chip, options.radius or Theme.PILL)
	return chip
end

--- Padding that is not the same on all four sides, which most of the
--- redesign's boxes need.
function Theme.pad(
	parent: Instance,
	top: number,
	right: number,
	bottom: number,
	left: number
): UIPadding
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, top)
	padding.PaddingRight = UDim.new(0, right)
	padding.PaddingBottom = UDim.new(0, bottom)
	padding.PaddingLeft = UDim.new(0, left)
	padding.Parent = parent
	return padding
end

--- A row or column of children with a fixed gap, which every box here wants.
function Theme.flow(
	parent: Instance,
	direction: Enum.FillDirection,
	gap: number,
	align: Enum.VerticalAlignment?
): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = direction
	layout.Padding = UDim.new(0, gap)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.VerticalAlignment = align or Enum.VerticalAlignment.Center
	layout.Parent = parent
	return layout
end

--[[
	The full-bleed ground the two destination screens stand on.

	World select and the store are not overlays — the handoff is explicit that
	the store "is a destination, not a modal" and gives both the same treatment:
	a dark vertical gradient with a slow diagonal of amber laid over it at five
	per cent. The diagonal is what stops eight hundred pixels of brown reading
	as a loading screen; it is faint enough that nothing in front of it has to
	fight it, and it runs the same way as the mow stripes so the two screens
	feel cut by the same machine.

	Nine bands rather than a repeating gradient, because `UIGradient` cannot
	repeat: a band is a rotated frame two and a half screens wide, which is the
	only width that still reaches both corners at twenty-five degrees. Band and
	gap are the same width, which is the whole of the effect — a narrow bright
	line against a wide dark one reads as bunting, and the first build of this
	was exactly that.
]]
function Theme.backdrop(parent: Instance): Frame
	local back = Instance.new("Frame")
	back.Name = "Backdrop"
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(42, 31, 21)
	back.BorderSizePixel = 0
	back.ZIndex = 0
	back.Parent = parent

	local grade = Instance.new("UIGradient")
	grade.Color = ColorSequence.new(Color3.fromRGB(42, 31, 21), Color3.fromRGB(26, 19, 13))
	grade.Rotation = 90
	grade.Parent = back

	for index = 1, 9 do
		local band = Instance.new("Frame")
		band.Name = `Band{index}`
		band.AnchorPoint = Vector2.new(0.5, 0.5)
		band.Size = UDim2.fromScale(2.5, 0.115)
		band.Position = UDim2.fromScale(0.5, index * 0.235 - 0.6)
		band.Rotation = -25
		band.BackgroundColor3 = Color3.fromRGB(255, 206, 74)
		band.BackgroundTransparency = 0.95
		band.BorderSizePixel = 0
		band.ZIndex = 0
		band.Parent = back
	end

	return back
end

return Theme
