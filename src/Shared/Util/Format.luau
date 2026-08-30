--!strict
--[[ Format — number and time formatting for every piece of UI. ]]

local Format = {}

local SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp" }

--[[
	Compact cash for HUD display: 1234567 -> "1.23M".

	Values under 1,000 keep two decimals when they are fractional, because early
	play is measured in cents and "$0.25" reading as "$0" would be baffling.
]]
function Format.cash(value: number): string
	local sign = if value < 0 then "-" else ""
	local n = math.abs(value)

	if n < 1000 then
		if n > 0 and n < 100 and n % 1 ~= 0 then
			return string.format("%s$%.2f", sign, n)
		end
		return string.format("%s$%d", sign, math.floor(n))
	end

	local tier = math.min(math.floor(math.log(n, 1000)), #SUFFIXES - 1)
	local scaled = n / 1000 ^ tier
	local text = if scaled < 10 then string.format("%.2f", scaled) else string.format("%.1f", scaled)
	return string.format("%s$%s%s", sign, text, SUFFIXES[tier + 1])
end

--[[
	Money with the sign trailing, as the reference writes it: `0.01$ / leaf`.

	Two forms exist on purpose. A running total reads as `$5.41`, because that is
	what a total looks like everywhere; a rate or a gain reads as `4.36$`, which
	is how the reference writes the numbers that fly past you while you work.
]]
function Format.cashSuffix(value: number): string
	local sign = if value < 0 then "-" else ""
	local n = math.abs(value)
	if n < 1000 then
		return string.format("%s%.2f$", sign, n)
	end
	local compact = Format.cash(value)
	return `{string.gsub(compact, "%$", "")}$`
end

--- Compact count without a currency symbol: 15400 -> "15.4K".
function Format.count(value: number): string
	local n = math.abs(value)
	if n < 1000 then
		return tostring(math.floor(value))
	end
	local tier = math.min(math.floor(math.log(n, 1000)), #SUFFIXES - 1)
	local scaled = value / 1000 ^ tier
	local text = if math.abs(scaled) < 10 then string.format("%.2f", scaled) else string.format("%.1f", scaled)
	return text .. SUFFIXES[tier + 1]
end

--- Seconds as M:SS, or H:MM:SS past an hour.
function Format.clock(seconds: number): string
	local total = math.max(math.floor(seconds), 0)
	local hours = total // 3600
	local minutes = (total % 3600) // 60
	local secs = total % 60
	if hours > 0 then
		return string.format("%02d:%02d:%02d", hours, minutes, secs)
	end
	return string.format("%d:%02d", minutes, secs)
end

--- A 0..1 fraction as a percentage string with one decimal below 100%.
function Format.percent(fraction: number): string
	local pct = math.clamp(fraction, 0, 1) * 100
	if pct >= 100 then
		return "100%"
	end
	if pct >= 10 then
		return string.format("%.1f%%", pct)
	end
	return string.format("%.2f%%", pct)
end

return Format
