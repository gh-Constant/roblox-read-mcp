local IndexStore = {}
IndexStore.__index = IndexStore

type Entry = {
	name: string,
	className: string,
	lastSeenAt: number,
}

local function nowMs(): number
	return math.floor(os.clock() * 1000)
end

local function makeRootLookup(roots: { string }): { [string]: boolean }
	local lookup = {}
	for _, rootName in ipairs(roots) do
		lookup[rootName] = true
	end
	return lookup
end

function IndexStore.new(defaultRoots: { string })
	local self = setmetatable({}, IndexStore)
	self._defaultRoots = defaultRoots
	self._entries = setmetatable({}, { __mode = "k" })
	self._instanceConnections = setmetatable({}, { __mode = "k" })
	self._ordered = {}
	self._connections = {}
	self._version = 0

	self:_bootstrap(defaultRoots)
	self:_connectGlobalSignals()

	return self
end

function IndexStore:destroy()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}

	for instance, _ in pairs(self._instanceConnections) do
		self:_disconnectInstance(instance)
	end

	self._entries = setmetatable({}, { __mode = "k" })
	self._ordered = {}
end

function IndexStore:getCount(): number
	local count = 0
	for instance, _ in pairs(self._entries) do
		if instance and instance.Parent ~= nil then
			count += 1
		end
	end
	return count
end

function IndexStore:getVersion(): number
	return self._version
end

function IndexStore:getCandidates(roots: { string }, maxDepth: number, maxScanNodes: number): { Instance }
	local rootLookup = makeRootLookup(roots)
	local candidates = {}
	local seen = setmetatable({}, { __mode = "k" })

	local scanned = 0
	for _, instance in ipairs(self._ordered) do
		if scanned >= maxScanNodes then
			break
		end
		scanned += 1

		if self._entries[instance] ~= nil and self:_isWithinRoots(instance, rootLookup, maxDepth) then
			table.insert(candidates, instance)
			seen[instance] = true
		end
	end

	if #candidates < math.floor(maxScanNodes / 3) then
		local missingBudget = maxScanNodes - #candidates
		if missingBudget > 0 then
			local fallback = self:_fallbackTraverse(rootLookup, maxDepth, missingBudget, seen)
			for _, instance in ipairs(fallback) do
				table.insert(candidates, instance)
			end
		end
	end

	return candidates
end

function IndexStore:_bootstrap(roots: { string })
	for _, rootName in ipairs(roots) do
		local root = game:FindFirstChild(rootName)
		if root then
			self:_indexTree(root, 0, 4000)
		end
	end
end

function IndexStore:_indexTree(root: Instance, startDepth: number, maxNodes: number)
	local queue = {
		{
			instance = root,
			depth = startDepth,
		},
	}
	local head = 1
	local scanned = 0

	while head <= #queue and scanned < maxNodes do
		local item = queue[head]
		head += 1
		scanned += 1

		local instance = item.instance
		if instance then
			self:_upsert(instance)

			for _, child in ipairs(instance:GetChildren()) do
				table.insert(queue, {
					instance = child,
					depth = item.depth + 1,
				})
			end
		end
	end
end

function IndexStore:_connectGlobalSignals()
	table.insert(self._connections, game.DescendantAdded:Connect(function(instance: Instance)
		self:_upsert(instance)
	end))

	table.insert(self._connections, game.DescendantRemoving:Connect(function(instance: Instance)
		self:_remove(instance)
		for _, descendant in ipairs(instance:GetDescendants()) do
			self:_remove(descendant)
		end
	end))
end

function IndexStore:_connectInstanceSignals(instance: Instance)
	if self._instanceConnections[instance] ~= nil then
		return
	end

	local connections = {}

	table.insert(connections, instance.Changed:Connect(function(propName: string)
		local entry: Entry? = self._entries[instance]
		if not entry then
			return
		end

		if propName == "Name" then
			entry.name = instance.Name
			entry.lastSeenAt = nowMs()
			self._version += 1
		elseif propName == "Parent" and instance.Parent == nil then
			self:_remove(instance)
		end
	end))

	if instance.AttributeChanged then
		table.insert(connections, instance.AttributeChanged:Connect(function()
			local entry: Entry? = self._entries[instance]
			if entry then
				entry.lastSeenAt = nowMs()
				self._version += 1
			end
		end))
	end

	self._instanceConnections[instance] = connections
end

function IndexStore:_disconnectInstance(instance: Instance)
	local connections = self._instanceConnections[instance]
	if connections then
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		self._instanceConnections[instance] = nil
	end
end

function IndexStore:_upsert(instance: Instance)
	local entry: Entry? = self._entries[instance]
	if entry then
		entry.name = instance.Name
		entry.className = instance.ClassName
		entry.lastSeenAt = nowMs()
		self._version += 1
		return
	end

	self._entries[instance] = {
		name = instance.Name,
		className = instance.ClassName,
		lastSeenAt = nowMs(),
	}
	table.insert(self._ordered, instance)
	self:_connectInstanceSignals(instance)
	self._version += 1
end

function IndexStore:_remove(instance: Instance)
	if self._entries[instance] ~= nil then
		self._entries[instance] = nil
		self:_disconnectInstance(instance)
		self._version += 1
	end
end

function IndexStore:_isWithinRoots(instance: Instance, rootLookup: { [string]: boolean }, maxDepth: number): boolean
	if instance == game then
		return false
	end

	local depth = 0
	local current: Instance? = instance

	while current ~= nil do
		local parent = current.Parent
		if parent == nil then
			return false
		end

		if parent == game then
			return rootLookup[current.Name] == true and depth <= maxDepth
		end

		depth += 1
		if depth > maxDepth then
			return false
		end

		current = parent
	end

	return false
end

function IndexStore:_fallbackTraverse(
	rootLookup: { [string]: boolean },
	maxDepth: number,
	limit: number,
	seen: { [Instance]: boolean }
): { Instance }
	local results = {}
	if limit <= 0 then
		return results
	end

	local queue = {}
	for rootName, _ in pairs(rootLookup) do
		local root = game:FindFirstChild(rootName)
		if root then
			table.insert(queue, {
				instance = root,
				depth = 0,
			})
		end
	end

	local head = 1
	while head <= #queue and #results < limit do
		local item = queue[head]
		head += 1

		local instance = item.instance
		local depth = item.depth

		if not seen[instance] then
			seen[instance] = true
			self:_upsert(instance)
			table.insert(results, instance)
		end

		if depth < maxDepth then
			for _, child in ipairs(instance:GetChildren()) do
				table.insert(queue, {
					instance = child,
					depth = depth + 1,
				})
			end
		end
	end

	return results
end

return IndexStore
