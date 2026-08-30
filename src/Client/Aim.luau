--!strict
--[[
	Aim — where the player is pointing.

	One place, because three things need the same answer and they must agree:
	the intent sent to the server, the outline drawn on the pile that intent will
	take, and the tool drawn pointing at it. If any of them read a different
	source, the crosshair would stop being a promise.

	The heading is flattened to the ground plane. Tiles lie flat, so pitch says
	nothing about which one is covered — only how far down the barrel is tipped,
	which is a matter for the viewmodel.
]]

local Workspace = game:GetService("Workspace")

local Aim = {}

--- The flat direction the camera is facing, always a unit vector.
function Aim.direction(): Vector3
	local camera = Workspace.CurrentCamera
	if not camera then
		return Vector3.new(0, 0, 1)
	end
	local look = camera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		return Vector3.new(0, 0, 1)
	end
	return flat.Unit
end

return Aim
