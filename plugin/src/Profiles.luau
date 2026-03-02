local Profiles = {}

Profiles.DEFAULT_ROOTS = {
	"StarterGui",
	"Players",
	"ReplicatedStorage",
	"Workspace",
}

Profiles.HARD_CAPS = {
	maxDepth = 12,
	maxNodes = 500,
	maxRoots = 16,
	maxProps = 32,
	maxClasses = 32,
	maxScanNodes = 5000,
}

local PROFILE_DEFS = {
	ui = {
		includeAttributes = true,
		includeTags = true,
		defaultIncludeProps = {},
		excludeClasses = {},
	},
	gameplay = {
		includeAttributes = true,
		includeTags = true,
		defaultIncludeProps = {
			"Anchored",
			"CanCollide",
			"CanTouch",
			"Transparency",
			"Position",
			"Orientation",
			"CFrame",
		},
		excludeClasses = {
			"ScreenGui",
			"Frame",
			"TextLabel",
			"TextButton",
			"ImageLabel",
			"ImageButton",
		},
	},
	minimal = {
		includeAttributes = true,
		includeTags = false,
		defaultIncludeProps = {},
		excludeClasses = {},
	},
}

local function clamp(value, minValue, maxValue)
	if value < minValue then
		return minValue
	end
	if value > maxValue then
		return maxValue
	end
	return value
end

local function normalizedStringList(rawList, maxItems)
	if type(rawList) ~= "table" then
		return {}
	end

	local out = {}
	local seen = {}

	for _, value in ipairs(rawList) do
		if type(value) == "string" then
			local trimmed = string.gsub(value, "^%s*(.-)%s*$", "%1")
			if trimmed ~= "" then
				local key = string.lower(trimmed)
				if not seen[key] then
					seen[key] = true
					table.insert(out, trimmed)
					if #out >= maxItems then
						break
					end
				end
			end
		end
	end

	return out
end

local function parseCommaSeparatedList(raw)
	if type(raw) ~= "string" then
		return {}
	end

	local out = {}
	for part in string.gmatch(raw, "[^,]+") do
		table.insert(out, part)
	end
	return out
end

local function mergeLists(maxItems, ...)
	local merged = {}
	local seen = {}

	for _, list in ipairs({ ... }) do
		for _, item in ipairs(normalizedStringList(list, maxItems)) do
			local key = string.lower(item)
			if not seen[key] then
				seen[key] = true
				table.insert(merged, item)
				if #merged >= maxItems then
					return merged
				end
			end
		end
	end

	return merged
end

local function firstNonNil(...)
	for _, value in ipairs({ ... }) do
		if value ~= nil then
			return value
		end
	end
	return nil
end

function Profiles.resolve(options, runtimeDefaults)
	options = options or {}
	runtimeDefaults = runtimeDefaults or {}

	local rawProfile = firstNonNil(options.profile, runtimeDefaults.profile, "minimal")
	local profile = string.lower(tostring(rawProfile))
	if not PROFILE_DEFS[profile] then
		profile = "minimal"
	end

	local base = PROFILE_DEFS[profile]

	local runtimeRoots = runtimeDefaults.roots
	if type(runtimeRoots) == "string" then
		runtimeRoots = parseCommaSeparatedList(runtimeRoots)
	end

	local requestedRoots = options.roots
	if type(requestedRoots) == "string" then
		requestedRoots = parseCommaSeparatedList(requestedRoots)
	end

	local runtimeIncludeProps = runtimeDefaults.includeProps
	if type(runtimeIncludeProps) == "string" then
		runtimeIncludeProps = parseCommaSeparatedList(runtimeIncludeProps)
	end

	local requestedIncludeProps = options.includeProps
	if type(requestedIncludeProps) == "string" then
		requestedIncludeProps = parseCommaSeparatedList(requestedIncludeProps)
	end

	local runtimeExcludeClasses = runtimeDefaults.excludeClasses
	if type(runtimeExcludeClasses) == "string" then
		runtimeExcludeClasses = parseCommaSeparatedList(runtimeExcludeClasses)
	end

	local requestedExcludeClasses = options.excludeClasses
	if type(requestedExcludeClasses) == "string" then
		requestedExcludeClasses = parseCommaSeparatedList(requestedExcludeClasses)
	end

	local resolvedRoots = mergeLists(
		Profiles.HARD_CAPS.maxRoots,
		requestedRoots,
		runtimeRoots,
		Profiles.DEFAULT_ROOTS
	)

	if #resolvedRoots == 0 then
		resolvedRoots = table.clone(Profiles.DEFAULT_ROOTS)
	end

	local includeProps = mergeLists(
		Profiles.HARD_CAPS.maxProps,
		base.defaultIncludeProps,
		runtimeIncludeProps,
		requestedIncludeProps
	)

	local excludeClasses = mergeLists(
		Profiles.HARD_CAPS.maxClasses,
		base.excludeClasses,
		runtimeExcludeClasses,
		requestedExcludeClasses
	)

	local includeAttributes = firstNonNil(options.includeAttributes, runtimeDefaults.includeAttributes, base.includeAttributes)
	local includeTags = firstNonNil(options.includeTags, runtimeDefaults.includeTags, base.includeTags)

	local rawDepth = tonumber(firstNonNil(options.maxDepth, runtimeDefaults.maxDepth, 5)) or 5
	local rawNodes = tonumber(firstNonNil(options.maxNodes, runtimeDefaults.maxNodes, 100)) or 100
	local rawTimeout = tonumber(firstNonNil(options.timeoutMs, runtimeDefaults.timeoutMs, 6000)) or 6000

	local maxDepth = clamp(math.floor(rawDepth), 1, Profiles.HARD_CAPS.maxDepth)
	local maxNodes = clamp(math.floor(rawNodes), 1, Profiles.HARD_CAPS.maxNodes)
	local timeoutMs = clamp(math.floor(rawTimeout), 500, 15_000)

	local maxScanNodes = clamp(maxNodes * 25, maxNodes, Profiles.HARD_CAPS.maxScanNodes)

	return {
		profile = profile,
		roots = resolvedRoots,
		includeAttributes = includeAttributes == true,
		includeTags = includeTags == true,
		includeProps = includeProps,
		excludeClasses = excludeClasses,
		maxDepth = maxDepth,
		maxNodes = maxNodes,
		timeoutMs = timeoutMs,
		maxScanNodes = maxScanNodes,
	}
end

function Profiles.makeExcludeLookup(excludeClasses)
	local lookup = {}
	for _, className in ipairs(excludeClasses or {}) do
		lookup[string.lower(className)] = true
	end
	return lookup
end

return Profiles
