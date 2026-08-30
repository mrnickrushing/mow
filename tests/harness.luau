--!strict
--[[
	A minimal test harness. No dependencies, runs under the standalone `luau`
	CLI, prints a readable report and exits non-zero on any failure.
]]

local harness = {}

-- The stored fn returns a value so that `pcall` types as (boolean, any).
type Case = { name: string, fn: () -> any }

local suites: { { name: string, cases: { Case } } } = {}
local current: { name: string, cases: { Case } }? = nil

local failures: { string } = {}
local passed = 0

function harness.describe(name: string, body: () -> ())
	local suite = { name = name, cases = {} }
	table.insert(suites, suite)
	current = suite
	body()
	current = nil
end

function harness.it(name: string, fn: () -> ())
	local suite = current
	assert(suite, "it() called outside describe()")
	table.insert(suite.cases, {
		name = name,
		fn = function(): any
			fn()
			return nil
		end,
	})
end

--------------------------------------------------------------------
-- Assertions
--------------------------------------------------------------------

function harness.expectEqual(actual: any, expected: any, message: string?)
	if actual ~= expected then
		error(
			string.format(
				"%sexpected %s, got %s",
				if message then message .. ": " else "",
				tostring(expected),
				tostring(actual)
			),
			2
		)
	end
end

function harness.expectClose(actual: number, expected: number, tolerance: number?, message: string?)
	local tol = tolerance or 1e-6
	if math.abs(actual - expected) > tol then
		error(
			string.format(
				"%sexpected %.6f (+/- %.6f), got %.6f",
				if message then message .. ": " else "",
				expected,
				tol,
				actual
			),
			2
		)
	end
end

function harness.expectTrue(value: boolean, message: string?)
	if not value then
		error(message or "expected true, got false", 2)
	end
end

function harness.expectFalse(value: boolean, message: string?)
	if value then
		error(message or "expected false, got true", 2)
	end
end

--- Asserts two arrays hold the same values, order-insensitively.
function harness.expectSameSet(actual: { number }, expected: { number }, message: string?)
	local a, b = table.clone(actual), table.clone(expected)
	table.sort(a)
	table.sort(b)
	local prefix = if message then message .. ": " else ""
	if #a ~= #b then
		error(string.format("%sexpected %d entries, got %d", prefix, #b, #a), 2)
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			error(string.format("%sentry %d: expected %s, got %s", prefix, i, tostring(b[i]), tostring(a[i])), 2)
		end
	end
end

--------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------

--- Runs one case, returning nil on success or the error text on failure.
local function runCase(fn: () -> any): string?
	local ok, err = pcall(fn)
	if ok then
		return nil
	end
	return tostring(err)
end

function harness.run(): number
	for _, suite in suites do
		print(suite.name)
		for _, case in suite.cases do
			local err = runCase(case.fn)
			if err == nil then
				passed += 1
				print(string.format("  PASS  %s", case.name))
			else
				table.insert(failures, string.format("%s > %s\n        %s", suite.name, case.name, err))
				print(string.format("  FAIL  %s", case.name))
				print(string.format("        %s", err))
			end
		end
	end

	print("")
	if #failures == 0 then
		print(string.format("%d passed", passed))
		return 0
	end

	print(string.format("%d passed, %d FAILED", passed, #failures))
	for _, failure in failures do
		print("  " .. failure)
	end
	return 1
end

return harness
