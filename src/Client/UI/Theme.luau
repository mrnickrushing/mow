--!strict
--[[ Theme — one palette and a few builders, so every panel matches. ]]

local Theme = {}

Theme.colors = {
	panel = Color3.fromRGB(24, 30, 26),
	panelLight = Color3.fromRGB(36, 45, 38),
	stroke = Color3.fromRGB(96, 132, 92),
	text = Color3.fromRGB(240, 246, 238),
	subtext = Color3.fromRGB(168, 184, 166),
	grass = Color3.fromRGB(112, 186, 74),
	grassDark = Color3.fromRGB(62, 122, 46),
	cash = Color3.fromRGB(126, 214, 108),
	tips = Color3.fromRGB(246, 200, 88),
	warn = Color3.fromRGB(238, 132, 76),
	danger = Color3.fromRGB(226, 90, 84),
	bag = Color3.fromRGB(196, 158, 96),
}

Theme.font = Enum.Font.GothamBold
Theme.fontRegular = Enum.Font.Gotham

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
	frame.BackgroundTransparency = options.transparency or 0.15
	frame.BorderSizePixel = 0
	frame.Parent = options.parent
	Theme.corner(frame, 10)
	Theme.stroke(frame, 1.5)
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

	return track, fill
end

return Theme
