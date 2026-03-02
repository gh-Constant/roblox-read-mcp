if not plugin then
	warn("Roblox Read MCP must run as a Roblox Studio plugin")
	return
end

local HttpService = game:GetService("HttpService")

local BridgeClient = require(script.Parent.BridgeClient)
local SearchEngine = require(script.Parent.SearchEngine)
local Ui = require(script.Parent.Ui)

local HARDCODED_SHARED_SECRET = "roblox-read-mcp-global-shared-secret-v1"

local function safeGetSetting(key: string, defaultValue)
	local ok, value = pcall(function()
		return plugin:GetSetting(key)
	end)
	if ok and value ~= nil then
		return value
	end
	return defaultValue
end

local function safeSetSetting(key: string, value)
	pcall(function()
		plugin:SetSetting(key, value)
	end)
end

local storedClientId = safeGetSetting("roblox_read_mcp_client_id", nil)
if type(storedClientId) ~= "string" or storedClientId == "" then
	storedClientId = HttpService:GenerateGUID(false)
	safeSetSetting("roblox_read_mcp_client_id", storedClientId)
end

local initialSettings = {
	host = safeGetSetting("roblox_read_mcp_host", "127.0.0.1"),
	port = safeGetSetting("roblox_read_mcp_port", 3812),
	portRange = safeGetSetting("roblox_read_mcp_port_range", "3812-3830"),
	secret = HARDCODED_SHARED_SECRET,
}

local ui = Ui.new(plugin, initialSettings)
local searchEngine = SearchEngine.new()

local bridge = BridgeClient.new({
	getHost = function()
		return ui:getHost()
	end,
	getPort = function()
		return ui:getPort()
	end,
	getPortRange = function()
		return ui:getPortRange()
	end,
	getSecret = function()
		return ui:getSecret()
	end,
	getClientId = function()
		return storedClientId
	end,
	onStatus = function(status: string, detail: string?)
		ui:setConnectionStatus(status, detail)
	end,
	onTelemetry = function(telemetry)
		ui:updateTelemetry(telemetry)
	end,
	onCommand = function(command: string, args)
		local runtimeDefaults = ui:getRuntimeOptions()
		local result = searchEngine:handleCommand(command, args, runtimeDefaults)
		if type(result) == "table" and type(result.meta) == "table" then
			result.meta.clientId = storedClientId
		end
		return result
	end,
})

ui:setCallbacks({
	saveSettings = function(newSettings)
		safeSetSetting("roblox_read_mcp_host", newSettings.host)
		safeSetSetting("roblox_read_mcp_port", newSettings.port)
		safeSetSetting("roblox_read_mcp_port_range", newSettings.portRange)
	end,
	reconnect = function(force)
		bridge:reconnect(force)
	end,
	disconnect = function()
		bridge:disconnect()
	end,
})

bridge:start()

plugin.Unloading:Connect(function()
	bridge:destroy()
	searchEngine:destroy()
	ui:destroy()
end)
