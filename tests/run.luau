--!strict
--[[
	Test entry point.

	Run `python3 scripts/build_tests.py` first (scripts/check.sh does it for
	you) so that tests/.build holds a CLI-loadable mirror of src/.
]]

local harness = require("./harness")

local suites = {
	require("./Grid.spec"),
	require("./Stripe.spec"),
	require("./ChunkCodec.spec"),
	require("./Balance.spec"),
	require("./Config.spec"),
	require("./Cutting.spec"),
}

for _, suite in suites do
	suite()
end

local code = harness.run()
if code ~= 0 then
	error("test failures", 0)
end
