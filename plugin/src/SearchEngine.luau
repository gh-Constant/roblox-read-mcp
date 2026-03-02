local CollectionService = game:GetService("CollectionService")
local Selection = game:GetService("Selection")

local IndexStore = require(script.Parent.IndexStore)
local Profiles = require(script.Parent.Profiles)

local SearchEngine = {}
SearchEngine.__index = SearchEngine

local TEXT_QUERY_PROPS = {
	"Text",
	"Image",
	"ToolTip",
	"PlaceholderText",
	"Name",
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

local function safeRead(instance: Instance, propertyName: string)
	local ok, value = pcall(function()
		return instance[propertyName]
	end)
	if ok then
		return value
	end
	return nil
end

local function safeChildren(instance: Instance): { Instance }
	local ok, children = pcall(function()
		return instance:GetChildren()
	end)
	if ok and type(children) == "table" then
		return children
	end
	return {}
end

local function toHexComponent(value: number): string
	local byte = clamp(math.floor(value * 255 + 0.5), 0, 255)
	return string.format("%02X", byte)
end

local function truncateString(value: string, maxLength: number): string
	if #value <= maxLength then
		return value
	end
	return string.sub(value, 1, maxLength) .. "…"
end

local function serializeValue(value: any, depth: number?): any
	depth = depth or 0
	if depth > 2 then
		return "<depth-limit>"
	end

	local valueType = typeof(value)
	if valueType == "string" then
		return truncateString(value, 320)
	end
	if valueType == "number" or valueType == "boolean" then
		return value
	end
	if valueType == "Color3" then
		return "#" .. toHexComponent(value.R) .. toHexComponent(value.G) .. toHexComponent(value.B)
	end
	if valueType == "Vector3" or valueType == "Vector2" then
		return tostring(value)
	end
	if valueType == "UDim2" or valueType == "UDim" then
		return tostring(value)
	end
	if valueType == "CFrame" then
		return tostring(value)
	end
	if valueType == "EnumItem" then
		return tostring(value)
	end
	if valueType == "Instance" then
		return value:GetFullName()
	end
	if valueType == "table" then
		local out = {}
		local count = 0
		for key, nestedValue in pairs(value) do
			count += 1
			if count > 16 then
				out["__truncated"] = true
				break
			end
			out[tostring(key)] = serializeValue(nestedValue, depth + 1)
		end
		return out
	end

	if value == nil then
		return nil
	end

	return truncateString(tostring(value), 320)
end

local function getPath(instance: Instance): string
	local segments = {}
	local current: Instance? = instance

	while current and current ~= game do
		table.insert(segments, 1, current.Name)
		current = current.Parent
	end

	return table.concat(segments, ".")
end

local function resolvePath(path: string): Instance?
	local segments = {}
	for segment in string.gmatch(path, "[^%.]+") do
		table.insert(segments, segment)
	end

	if #segments == 0 then
		return nil
	end

	if string.lower(segments[1]) == "game" then
		table.remove(segments, 1)
	end

	if #segments == 0 then
		return nil
	end

	local current = game:FindFirstChild(segments[1])
	if not current then
		return nil
	end

	for i = 2, #segments do
		current = current:FindFirstChild(segments[i])
		if not current then
			return nil
		end
	end

	return current
end

local function toSearchText(value: any): string
	if value == nil then
		return ""
	end
	return string.lower(tostring(serializeValue(value)))
end

local function containsQuery(haystack: string, query: string): boolean
	if haystack == "" then
		return false
	end
	return string.find(haystack, query, 1, true) ~= nil
end

local function safeGetTags(instance: Instance): { string }
	local ok, tags = pcall(function()
		return CollectionService:GetTags(instance)
	end)
	if ok and type(tags) == "table" then
		return tags
	end
	return {}
end

local function safeGetAttributes(instance: Instance): { [string]: any }
	local ok, attributes = pcall(function()
		return instance:GetAttributes()
	end)
	if ok and type(attributes) == "table" then
		return attributes
	end
	return {}
end

function SearchEngine.new()
	local self = setmetatable({}, SearchEngine)
	self._index = IndexStore.new(Profiles.DEFAULT_ROOTS)
	return self
end

function SearchEngine:destroy()
	if self._index then
		self._index:destroy()
	end
end

function SearchEngine:handleCommand(command: string, args: { [string]: any }, runtimeDefaults: { [string]: any }?): { [string]: any }
	args = args or {}
	runtimeDefaults = runtimeDefaults or {}

	if command == "search" then
		return self:_search(args, runtimeDefaults)
	elseif command == "tree" then
		return self:_tree(args, runtimeDefaults)
	elseif command == "selected" then
		return self:_selected(args, runtimeDefaults)
	elseif command == "inspect" then
		return self:_inspect(args, runtimeDefaults)
	elseif command == "ping" then
		return {
			ok = true,
			timestampMs = math.floor(os.clock() * 1000),
		}
	end

	error("Unsupported read-only command: " .. tostring(command))
end

function SearchEngine:_search(args: { [string]: any }, runtimeDefaults: { [string]: any }): { [string]: any }
	local query = string.lower(tostring(args.query or ""))
	local offset = math.max(0, math.floor(tonumber(args.cursorOffset) or 0))
	local options = Profiles.resolve(args.options, runtimeDefaults)
	local excluded = Profiles.makeExcludeLookup(options.excludeClasses)

	local candidates = self._index:getCandidates(options.roots, options.maxDepth, options.maxScanNodes)
	local descriptors = {}

	for _, instance in ipairs(candidates) do
		if not excluded[string.lower(instance.ClassName)] then
			local path = getPath(instance)
			if path ~= "" then
				table.insert(descriptors, {
					instance = instance,
					path = path,
				})
			end
		end
	end

	table.sort(descriptors, function(a, b)
		return a.path < b.path
	end)

	local matched = 0
	local results = {}
	local hasMore = false

	for _, descriptor in ipairs(descriptors) do
		local instance = descriptor.instance
		if self:_matchesQuery(instance, query, options) then
			matched += 1
			if matched > offset then
				if #results < options.maxNodes then
					table.insert(results, self:_serializeInstance(instance, options, descriptor.path))
				else
					hasMore = true
					break
				end
			end
		end
	end

	local nextOffset = nil
	if hasMore then
		nextOffset = offset + #results
	end

	return {
		results = results,
		nextOffset = nextOffset,
		meta = {
			matched = matched,
			indexSize = self._index:getCount(),
			indexVersion = self._index:getVersion(),
			profile = options.profile,
		},
	}
end

function SearchEngine:_tree(args: { [string]: any }, runtimeDefaults: { [string]: any }): { [string]: any }
	local offset = math.max(0, math.floor(tonumber(args.cursorOffset) or 0))
	local options = Profiles.resolve(args.options, runtimeDefaults)
	local excluded = Profiles.makeExcludeLookup(options.excludeClasses)

	local roots = {}
	if type(args.path) == "string" and args.path ~= "" then
		local root = resolvePath(args.path)
		if not root then
			error("tree path not found: " .. args.path)
		end
		table.insert(roots, root)
	else
		for _, rootName in ipairs(options.roots) do
			local root = game:FindFirstChild(rootName)
			if root then
				table.insert(roots, root)
			end
		end
	end

	local queue = {}
	for _, root in ipairs(roots) do
		table.insert(queue, {
			instance = root,
			depth = 0,
		})
	end

	local flattened = {}
	local head = 1
	while head <= #queue and #flattened < options.maxScanNodes do
		local item = queue[head]
		head += 1

		local instance = item.instance
		local depth = item.depth
		if not excluded[string.lower(instance.ClassName)] then
			table.insert(flattened, {
				instance = instance,
				depth = depth,
				path = getPath(instance),
			})
		end

		if depth < options.maxDepth then
			for _, child in ipairs(safeChildren(instance)) do
				table.insert(queue, {
					instance = child,
					depth = depth + 1,
				})
			end
		end
	end

	table.sort(flattened, function(a, b)
		return a.path < b.path
	end)

	local results = {}
	for index = offset + 1, math.min(#flattened, offset + options.maxNodes) do
		local item = flattened[index]
		table.insert(results, {
			path = item.path,
			className = item.instance.ClassName,
			name = item.instance.Name,
			depth = item.depth,
			childCount = #safeChildren(item.instance),
		})
	end

	local nextOffset = nil
	if offset + options.maxNodes < #flattened then
		nextOffset = offset + #results
	end

	return {
		results = results,
		nextOffset = nextOffset,
		meta = {
			total = #flattened,
			indexSize = self._index:getCount(),
			indexVersion = self._index:getVersion(),
		},
	}
end

function SearchEngine:_selected(args: { [string]: any }, runtimeDefaults: { [string]: any }): { [string]: any }
	local offset = math.max(0, math.floor(tonumber(args.cursorOffset) or 0))
	local options = Profiles.resolve(args.options, runtimeDefaults)
	local excluded = Profiles.makeExcludeLookup(options.excludeClasses)

	local selected = Selection:Get()
	local descriptors = {}
	for _, instance in ipairs(selected) do
		if not excluded[string.lower(instance.ClassName)] then
			table.insert(descriptors, {
				instance = instance,
				path = getPath(instance),
			})
		end
	end

	table.sort(descriptors, function(a, b)
		return a.path < b.path
	end)

	local results = {}
	for index = offset + 1, math.min(#descriptors, offset + options.maxNodes) do
		local descriptor = descriptors[index]
		table.insert(results, self:_serializeInstance(descriptor.instance, options, descriptor.path))
	end

	local nextOffset = nil
	if offset + options.maxNodes < #descriptors then
		nextOffset = offset + #results
	end

	return {
		results = results,
		nextOffset = nextOffset,
		meta = {
			total = #descriptors,
			selectionCount = #selected,
			indexVersion = self._index:getVersion(),
		},
	}
end

function SearchEngine:_inspect(args: { [string]: any }, runtimeDefaults: { [string]: any }): { [string]: any }
	local options = Profiles.resolve(args.options, runtimeDefaults)
	if type(args.path) ~= "string" or args.path == "" then
		error("inspect requires a non-empty path")
	end

	local instance = resolvePath(args.path)
	if not instance then
		error("inspect path not found: " .. tostring(args.path))
	end

	local childrenPreview = {}
	for index, child in ipairs(safeChildren(instance)) do
		if index > 64 then
			break
		end
		table.insert(childrenPreview, {
			name = child.Name,
			className = child.ClassName,
			path = getPath(child),
		})
	end

	local descendantCount = 0
	local bounded = false
	local queue = { instance }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		for _, child in ipairs(safeChildren(current)) do
			descendantCount += 1
			if descendantCount > options.maxScanNodes then
				bounded = true
				break
			end
			table.insert(queue, child)
		end
		if bounded then
			break
		end
	end

	return {
		instance = self:_serializeInstance(instance, options, getPath(instance)),
		children = childrenPreview,
		meta = {
			childCount = #safeChildren(instance),
			descendantCount = descendantCount,
			descendantCountBounded = bounded,
			indexVersion = self._index:getVersion(),
			indexSize = self._index:getCount(),
		},
	}
end

function SearchEngine:_matchesQuery(instance: Instance, query: string, options: { [string]: any }): boolean
	if query == "" then
		return true
	end

	if containsQuery(string.lower(instance.Name), query) then
		return true
	end
	if containsQuery(string.lower(instance.ClassName), query) then
		return true
	end

	if options.includeAttributes then
		for key, value in pairs(safeGetAttributes(instance)) do
			if containsQuery(string.lower(tostring(key)), query) then
				return true
			end
			if containsQuery(toSearchText(value), query) then
				return true
			end
		end
	end

	if options.includeTags then
		for _, tag in ipairs(safeGetTags(instance)) do
			if containsQuery(string.lower(tag), query) then
				return true
			end
		end
	end

	for _, propName in ipairs(TEXT_QUERY_PROPS) do
		local value = safeRead(instance, propName)
		if value ~= nil and containsQuery(toSearchText(value), query) then
			return true
		end
	end

	for _, propName in ipairs(options.includeProps) do
		local value = safeRead(instance, propName)
		if value ~= nil and containsQuery(toSearchText(value), query) then
			return true
		end
	end

	return false
end

function SearchEngine:_serializeInstance(
	instance: Instance,
	options: { [string]: any },
	knownPath: string?
): { [string]: any }
	local payload = {
		path = knownPath or getPath(instance),
		className = instance.ClassName,
		name = instance.Name,
	}

	if options.includeAttributes then
		local attrs = {}
		local count = 0
		for key, value in pairs(safeGetAttributes(instance)) do
			count += 1
			if count > 48 then
				attrs["__truncated"] = true
				break
			end
			attrs[tostring(key)] = serializeValue(value)
		end
		payload.attributes = attrs
	end

	if options.includeTags then
		local tags = safeGetTags(instance)
		if #tags > 32 then
			local trimmed = {}
			for index = 1, 32 do
				trimmed[index] = tags[index]
			end
			table.insert(trimmed, "__truncated__")
			tags = trimmed
		end
		payload.tags = tags
	end

	local props = {}
	for _, propName in ipairs(options.includeProps) do
		local value = safeRead(instance, propName)
		if value ~= nil then
			props[propName] = serializeValue(value)
		end
	end
	payload.props = props

	return payload
end

return SearchEngine
