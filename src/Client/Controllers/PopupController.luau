--!strict
--[[
	PopupController — the little `+4` that floats off a pile you just took.

	Every pickup needs to land. Without a number leaving the leaf you clicked,
	collecting reads as nothing happening until the bag counter happens to catch
	your eye; with one, each pile is a small confirmed transaction. That is most
	of why picking things up one at a time is satisfying rather than tedious.

	Purely cosmetic and entirely client-side, driven off the same prediction that
	drops the grass, so the number appears on the frame of the click rather than
	a round trip later.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Palette = require(Shared.Config.Palette)
local Theme = require(script.Parent.Parent.UI.Theme)

local PopupController = {}

local LIFETIME = 0.75
local RISE = 4.5
--- More than a handful on screen at once is noise, not feedback.
local MAX_LIVE = 14

local container: Folder? = nil
local live = 0

local function ensureContainer(): Folder
	local existing = container
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "MowPopups"
	folder.Parent = Workspace
	container = folder
	return folder
end

--[[
	Floats `text` up from `position` and fades it out.

	Popups are created and thrown away rather than pooled: at most a dozen exist
	at once and each lives under a second, so pooling would buy nothing and cost
	the bookkeeping to reset every property between uses.
]]
function PopupController.show(position: Vector3, text: string, color: Color3?)
	if live >= MAX_LIVE then
		return
	end
	live += 1

	local anchor = Instance.new("Part")
	anchor.Name = "Popup"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = ensureContainer()

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(120, 44)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Theme.font
	label.TextScaled = true
	label.Text = text
	label.TextColor3 = color or Palette.color(Palette.ui.text)
	label.Parent = gui
	Theme.outline(label, 2.5)

	local info = TweenInfo.new(LIFETIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(anchor, info, { CFrame = CFrame.new(position + Vector3.new(0, RISE, 0)) }):Play()
	TweenService:Create(label, info, { TextTransparency = 1 }):Play()

	local stroke = label:FindFirstChildOfClass("UIStroke")
	if stroke then
		TweenService:Create(stroke, info, { Transparency = 1 }):Play()
	end

	Debris:AddItem(anchor, LIFETIME)
	task.delay(LIFETIME, function()
		live -= 1
	end)
end

return PopupController
