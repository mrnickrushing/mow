--!strict
--[[
	RateLimiter — a token bucket, used to keep a hostile client from turning a
	high-frequency remote into free money.

	The bucket refills at `rate` tokens per second up to `burst`, so honest
	clients with jittery frame times are never punished while a flood is cut off
	at exactly the intended rate.
]]

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type RateLimiter = typeof(setmetatable(
	{} :: {
		rate: number,
		burst: number,
		tokens: number,
		updatedAt: number,
	},
	RateLimiter
))

function RateLimiter.new(rate: number, burst: number?): RateLimiter
	local cap = burst or math.max(rate, 1)
	return setmetatable({
		rate = rate,
		burst = cap,
		tokens = cap,
		updatedAt = os.clock(),
	}, RateLimiter)
end

--- Consumes one token. Returns false when the caller is going too fast.
function RateLimiter.tryConsume(self: RateLimiter, now: number?): boolean
	local at = now or os.clock()
	local elapsed = math.max(at - self.updatedAt, 0)
	self.updatedAt = at
	self.tokens = math.min(self.tokens + elapsed * self.rate, self.burst)

	if self.tokens < 1 then
		return false
	end
	self.tokens -= 1
	return true
end

function RateLimiter.reset(self: RateLimiter)
	self.tokens = self.burst
	self.updatedAt = os.clock()
end

return RateLimiter
