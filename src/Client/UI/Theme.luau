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

return Theme
