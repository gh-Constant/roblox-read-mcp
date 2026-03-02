-- Luau-side contract smoke checks.
-- This file can be executed in Studio test environments with script descendants arranged like plugin/src.

local Profiles = require(script.Parent.Parent.src.Profiles)

local options = Profiles.resolve({
	profile = "ui",
	maxDepth = 999,
	maxNodes = 999,
	roots = { "StarterGui", "Players" },
}, {
	includeProps = { "Text", "Visible" },
})

assert(options.profile == "ui", "profile should be normalized")
assert(options.maxDepth <= Profiles.HARD_CAPS.maxDepth, "maxDepth should be capped")
assert(options.maxNodes <= Profiles.HARD_CAPS.maxNodes, "maxNodes should be capped")
assert(#options.roots > 0, "roots should not be empty")
assert(type(options.includeAttributes) == "boolean", "includeAttributes should be boolean")
assert(type(options.includeTags) == "boolean", "includeTags should be boolean")
