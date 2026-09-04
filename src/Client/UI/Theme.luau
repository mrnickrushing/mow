--!strict
--[[
	Theme — one palette and a few builders, so every panel matches.

	The look is deliberately chunky: a rounded heavy face with a thick dark
	outline on every piece of text. That outline is not decoration — this UI sits
	over a bright amber sky and a floor of yellow leaves, and unoutlined white
	text simply disappears against it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
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

	-- Every label gets the outline; the world behind this UI is far too bright
	-- for plain white text to read against.
	label.TextStrokeTransparency = 1
	Theme.outline(label, if options.bold == false then Theme.OUTLINE else Theme.OUTLINE_HEAVY)
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

function Theme.fitToViewport(
	panel: GuiObject,
	width: number,
	height: number,
	reservedY: number?,
	reservedX: number?,
	reservedXInset: number?
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
function Theme.chromeScale(element: GuiObject): UIScale
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
		scale.Scale = chromeFactor(area)
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

return Theme
