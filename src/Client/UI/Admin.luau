--!strict
--[[
	Admin — the owner's panel, shown to nobody else.

	Four buttons and a box. It appears only after the server has said the
	player is an admin, which is a courtesy rather than a lock: pressing
	anything here sends a request the server checks against its own list
	before acting, so a player who forces this panel open still gets refused.
	Nothing here decides anything; it only asks.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Remotes)
local Theme = require(script.Parent.Theme)

local Admin = {}

local player = Players.LocalPlayer
local gui: ScreenGui
local panel: Frame
local amountBox: TextBox
local remote: RemoteEvent
local unlocked = false
local open = false

local function ask(name: string)
	if remote then
		remote:FireServer(name, amountBox and amountBox.Text or "")
	end
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "MowAdmin"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 60
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	--[[
		A tab on the left, sat just above the bag.

		It used to float at the middle of the left edge, which on a phone is
		the middle of the screen — the one place a player is actually
		looking. The bag already owns the bottom-left corner, so directly
		above it is a piece of edge that is already furniture rather than
		lawn, and it puts the two things nobody presses mid-run together.
	]]
	local tab = Instance.new("TextButton")
	tab.Name = "Tab"
	tab.Size = UDim2.fromOffset(34, 84)
	tab.AnchorPoint = Vector2.new(0, 1)
	tab.Position = UDim2.new(0, 6, 1, -104)
	tab.BackgroundColor3 = Color3.fromRGB(184, 68, 60)
	tab.BorderSizePixel = 0
	tab.Text = "A\nD\nM\nI\nN"
	tab.Font = Theme.font
	tab.TextSize = 12
	tab.TextColor3 = Color3.fromRGB(252, 246, 238)
	tab.Parent = gui
	Theme.corner(tab, 8)
	Theme.stroke(tab, 2.5, Theme.colors.outline, 0.1)

	panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.fromOffset(232, 290)
	panel.AnchorPoint = Vector2.new(0, 1)
	-- Above the thumbstick on touch: opened at the tab's height it lay across
	-- the movement control, so pressing a command moved the character.
	panel.Position = if UserInputService.TouchEnabled then UDim2.new(0, 44, 1, -200) else UDim2.new(0, 44, 1, -104)
	panel.BackgroundColor3 = Color3.fromRGB(44, 40, 52)
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = gui
	Theme.corner(panel, 12)
	Theme.stroke(panel, 3, Theme.colors.outline, 0.1)

	local title = Theme.text({
		name = "Title",
		text = "OWNER",
		size = UDim2.new(1, -16, 0, 26),
		position = UDim2.fromOffset(12, 10),
		parent = panel,
		align = Enum.TextXAlignment.Left,
		textSize = 19,
	})
	local _ = title

	amountBox = Instance.new("TextBox")
	amountBox.Name = "Amount"
	amountBox.Size = UDim2.new(1, -24, 0, 34)
	amountBox.Position = UDim2.fromOffset(12, 40)
	amountBox.BackgroundColor3 = Color3.fromRGB(238, 236, 228)
	amountBox.BorderSizePixel = 0
	amountBox.Font = Theme.font
	amountBox.TextSize = 18
	amountBox.TextColor3 = Color3.fromRGB(38, 34, 30)
	amountBox.PlaceholderText = "amount (blank = default)"
	amountBox.Text = ""
	amountBox.ClearTextOnFocus = false
	amountBox.Parent = panel
	Theme.corner(amountBox, 7)

	-- Annotated, because a mixed array of strings and a Color3 infers as a
	-- union the type checker will not take apart again.
	type Row = { label: string, command: string, tint: Color3 }
	local rows: { Row } = {
		{ label = "Give cash", command = "cash", tint = Color3.fromRGB(96, 176, 84) },
		{ label = "Give tips", command = "tips", tint = Color3.fromRGB(226, 176, 54) },
		{ label = "Unlock every tool", command = "tools", tint = Color3.fromRGB(84, 146, 214) },
		{ label = "Everything", command = "rich", tint = Color3.fromRGB(184, 96, 196) },
		-- The way back. Every other button here is one-way, and "unlock every
		-- tool" is permanent, so without this the owner cannot see their own
		-- early game again from any account they have ever tested on.
		{ label = "Reset to new player", command = "reset", tint = Color3.fromRGB(184, 68, 60) },
	}
	for index, row in rows do
		local button = Instance.new("TextButton")
		button.Name = row.command
		button.Size = UDim2.new(1, -24, 0, 34)
		button.Position = UDim2.fromOffset(12, 84 + (index - 1) * 40)
		button.BackgroundColor3 = row.tint
		button.BorderSizePixel = 0
		button.Text = row.label
		button.Font = Theme.font
		button.TextSize = 16
		button.TextColor3 = Color3.fromRGB(252, 250, 244)
		button.AutoButtonColor = true
		button.Parent = panel
		Theme.corner(button, 7)
		Theme.stroke(button, 2, Theme.colors.outline, 0.25)
		button.Activated:Connect(function()
			ask(row.command)
		end)
	end

	local function toggle()
		open = not open
		panel.Visible = open
		Theme.holdCursor(open)
	end
	tab.Activated:Connect(toggle)

	--[[
		F4 as well as the tab.

		Roblox owns F9 for its developer console, so this is F4; on a tablet
		there is no function row at all, which is why the tab exists and is
		the primary way in.
	]]
	UserInputService.InputBegan:Connect(function(input, typing)
		if not typing and unlocked and input.KeyCode == Enum.KeyCode.F4 then
			toggle()
		end
	end)
end

function Admin.start()
	build()
	remote = Remotes.event(Remotes.ADMIN)
	remote.OnClientEvent:Connect(function(kind: string)
		if kind == "admin" then
			unlocked = true
			gui.Enabled = true
		end
	end)
end

return Admin
