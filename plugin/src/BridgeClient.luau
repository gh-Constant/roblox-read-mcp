local HttpService = game:GetService("HttpService")

local function safeGetService(serviceName: string): any?
	local ok, serviceOrError = pcall(function()
		return game:GetService(serviceName)
	end)
	if ok then
		return serviceOrError
	end
	return nil
end

local WebSocketService = safeGetService("WebSocketService")

local Crypto = require(script.Parent.Crypto)

local BridgeClient = {}
BridgeClient.__index = BridgeClient

local PROTOCOL_VERSION = 1
local MAX_PAYLOAD_BYTES = 128 * 1024
local DEFAULT_PORT = 3812
local DEFAULT_PORT_RANGE = "3812-3830"
local MAX_SCAN_PORTS = 128

local ALLOWED_COMMANDS = {
	search = true,
	tree = true,
	selected = true,
	inspect = true,
	ping = true,
}

local function callMethodIfExists(target: any, methodName: string, ...): (boolean, any)
	if target == nil then
		return false, "target_unavailable"
	end
	local args = table.pack(...)

	local methodOk, methodOrError = pcall(function()
		return target[methodName]
	end)
	if not methodOk then
		return false, methodOrError
	end

	if type(methodOrError) ~= "function" then
		return false, "method_missing"
	end

	return pcall(function()
		return methodOrError(target, table.unpack(args, 1, args.n))
	end)
end

local function connectSignalIfExists(target: any, signalName: string, callback): RBXScriptConnection?
	if target == nil then
		return nil
	end

	local signalOk, signalOrError = pcall(function()
		return target[signalName]
	end)
	if not signalOk or signalOrError == nil then
		return nil
	end

	local connectOk, connectionOrError = pcall(function()
		return signalOrError:Connect(callback)
	end)
	if connectOk then
		return connectionOrError
	end
	return nil
end

local function nowMs(): number
	return math.floor(os.clock() * 1000)
end

local function countResults(payload: any): number
	if type(payload) ~= "table" then
		return 0
	end
	if type(payload.results) == "table" then
		return #payload.results
	end
	return 0
end

local function safeDisconnect(connection)
	if connection then
		connection:Disconnect()
	end
end

local function normalizePort(value: any): number?
	local numeric = tonumber(value)
	if numeric == nil then
		return nil
	end

	local port = math.floor(numeric)
	if port < 1 or port > 65535 then
		return nil
	end
	return port
end

local function parsePortRange(value: any): (number?, number?)
	if type(value) == "table" then
		local startPort = normalizePort(value.start or value.min)
		local endPort = normalizePort(value.finish or value["end"] or value.max)
		if startPort and endPort then
			if startPort > endPort then
				startPort, endPort = endPort, startPort
			end
			return startPort, endPort
		end
		return nil, nil
	end

	if type(value) ~= "string" then
		return nil, nil
	end

	local normalized = string.gsub(value, "%s+", "")
	if normalized == "" then
		return nil, nil
	end

	local single = normalizePort(normalized)
	if single then
		return single, single
	end

	local startRaw, endRaw = string.match(normalized, "^(%d+)%-(%d+)$")
	if startRaw == nil then
		startRaw, endRaw = string.match(normalized, "^(%d+)%.%.(%d+)$")
	end
	if startRaw == nil then
		return nil, nil
	end

	local startPort = normalizePort(startRaw)
	local endPort = normalizePort(endRaw)
	if startPort == nil or endPort == nil then
		return nil, nil
	end
	if startPort > endPort then
		startPort, endPort = endPort, startPort
	end
	return startPort, endPort
end

local function buildPortCandidates(preferredPort: number, rangeValue: any): { number }
	local ports = {}
	local seen = {}

	local function addPort(port: number?)
		if port == nil or seen[port] then
			return
		end
		seen[port] = true
		table.insert(ports, port)
	end

	addPort(normalizePort(preferredPort) or DEFAULT_PORT)

	local startPort, endPort = parsePortRange(rangeValue)
	if startPort and endPort then
		local scanned = 0
		for port = startPort, endPort do
			addPort(port)
			scanned += 1
			if scanned >= MAX_SCAN_PORTS then
				break
			end
		end
	end

	if #ports == 0 then
		table.insert(ports, DEFAULT_PORT)
	end

	return ports
end

local function portCandidateLabel(ports: { number }): string
	if #ports == 0 then
		return tostring(DEFAULT_PORT)
	end
	if #ports == 1 then
		return tostring(ports[1])
	end

	local minPort = ports[1]
	local maxPort = ports[1]
	for index = 2, #ports do
		local port = ports[index]
		minPort = math.min(minPort, port)
		maxPort = math.max(maxPort, port)
	end
	return string.format("%d-%d (%d ports)", minPort, maxPort, #ports)
end

function BridgeClient.new(options)
	local self = setmetatable({}, BridgeClient)
	self._options = options
	self._ws = nil
	self._running = false
	self._sessionToken = nil
	self._reconnectDelay = 1
	self._maxReconnectDelay = 10
	self._connections = {}
	self._lastStatus = "disconnected"
	self._connectedUrl = nil
	return self
end

function BridgeClient:start()
	if self._running then
		return
	end
	self._running = true
	self:_setStatus("connecting", "Connecting to localhost bridge")
	task.spawn(function()
		self:_connectLoop()
	end)
end

function BridgeClient:disconnect()
	self._running = false
	self._sessionToken = nil
	self:_closeSocket()
	self:_setStatus("disconnected", "Disconnected")
end

function BridgeClient:destroy()
	self:disconnect()
end

function BridgeClient:reconnect(force: boolean?)
	if force then
		self:_closeSocket()
	end
	if not self._running then
		self._running = true
	end
	self._reconnectDelay = 1
	task.spawn(function()
		self:_connectLoop()
	end)
end

function BridgeClient:_connectLoop()
	while self._running and self._ws == nil do
		local host = tostring(self._options.getHost())
		local preferredPort = tonumber(self._options.getPort()) or DEFAULT_PORT
		local rangeSetting = DEFAULT_PORT_RANGE
		if self._options.getPortRange then
			local rangeOk, rangeOrError = pcall(function()
				return self._options.getPortRange()
			end)
			if rangeOk then
				rangeSetting = rangeOrError
			end
		end

		local candidates = buildPortCandidates(preferredPort, rangeSetting)
		local candidateLabel = portCandidateLabel(candidates)
		local lastError = "unknown"

		self:_setStatus("connecting", string.format("Scanning ws://%s ports %s", host, candidateLabel))
		for _, port in ipairs(candidates) do
			local url = string.format("ws://%s:%d", host, port)
			local ok, wsOrError = self:_createSocket(url)
			if ok then
				self._ws = wsOrError
				self._connectedUrl = url
				self:_bindWebSocketSignals(wsOrError)
				self:_setStatus("connected_socket", "Socket created on " .. url .. ". Waiting for open/auth challenge")
				self._reconnectDelay = 1
				return
			end
			lastError = tostring(wsOrError)
		end

		self:_setStatus(
			"connect_error",
			string.format("No bridge found on ws://%s ports %s. Last error: %s", host, candidateLabel, lastError)
		)
		task.wait(self._reconnectDelay)
		self._reconnectDelay = math.min(self._reconnectDelay * 2, self._maxReconnectDelay)
	end
end

function BridgeClient:_createSocket(url: string): (boolean, any)
	local errors = {}

	local webStreamType = nil
	local enumOk, enumOrError = pcall(function()
		return Enum.WebStreamClientType.WebSocket
	end)
	if enumOk then
		webStreamType = enumOrError
	end

	if webStreamType ~= nil then
		local createOptions = {
			Url = url,
		}
		local wsOk, wsOrError = callMethodIfExists(HttpService, "CreateWebStreamClient", webStreamType, createOptions)
		if wsOk and wsOrError ~= nil then
			return true, wsOrError
		end
		table.insert(errors, "CreateWebStreamClient failed: " .. tostring(wsOrError))
	else
		table.insert(errors, "Enum.WebStreamClientType.WebSocket unavailable")
	end

	do
		local wsOk, wsOrError = callMethodIfExists(HttpService, "ConnectWebSocket", url)
		if wsOk and wsOrError ~= nil then
			return true, wsOrError
		end
		table.insert(errors, "ConnectWebSocket failed: " .. tostring(wsOrError))
	end

	if WebSocketService ~= nil then
		local wsOk, wsOrError = callMethodIfExists(WebSocketService, "CreateClient", url)
		if wsOk and wsOrError ~= nil then
			return true, wsOrError
		end
		table.insert(errors, "WebSocketService.CreateClient failed: " .. tostring(wsOrError))
	else
		table.insert(errors, "WebSocketService unavailable")
	end

	return false, table.concat(errors, " | ")
end

function BridgeClient:_bindWebSocketSignals(ws)
	for _, connection in ipairs(self._connections) do
		safeDisconnect(connection)
	end
	self._connections = {}

	local function onMessage(message)
		task.spawn(function()
			self:_onMessage(message)
		end)
	end

	local messageConnection = connectSignalIfExists(ws, "MessageReceived", onMessage)
		or connectSignalIfExists(ws, "OnMessage", onMessage)
	if messageConnection then
		table.insert(self._connections, messageConnection)
	end

	local openedConnection = connectSignalIfExists(ws, "Opened", function()
		local detail = "Socket open. Waiting for auth challenge"
		if self._connectedUrl then
			detail = "Socket open on " .. self._connectedUrl .. ". Waiting for auth challenge"
		end
		self:_setStatus("connected_socket", detail)
	end) or connectSignalIfExists(ws, "Open", function()
		local detail = "Socket open. Waiting for auth challenge"
		if self._connectedUrl then
			detail = "Socket open on " .. self._connectedUrl .. ". Waiting for auth challenge"
		end
		self:_setStatus("connected_socket", detail)
	end) or connectSignalIfExists(ws, "OnOpen", function()
		local detail = "Socket open. Waiting for auth challenge"
		if self._connectedUrl then
			detail = "Socket open on " .. self._connectedUrl .. ". Waiting for auth challenge"
		end
		self:_setStatus("connected_socket", detail)
	end)
	if openedConnection then
		table.insert(self._connections, openedConnection)
	end

	local closedConnection = connectSignalIfExists(ws, "Closed", function(...)
		self:_onClosed(...)
	end) or connectSignalIfExists(ws, "Close", function(...)
		self:_onClosed(...)
	end) or connectSignalIfExists(ws, "OnClose", function(...)
		self:_onClosed(...)
	end)
	if closedConnection then
		table.insert(self._connections, closedConnection)
	end
end

function BridgeClient:_onClosed(...)
	local reason = "socket closed"
	local args = { ... }
	if #args >= 1 then
		reason = tostring(args[1])
	end

	self:_closeSocket()
	self._sessionToken = nil

	if self._running then
		self:_setStatus("disconnected", reason)
		task.spawn(function()
			self:_connectLoop()
		end)
	else
		self:_setStatus("disconnected", reason)
	end
end

function BridgeClient:_closeSocket()
	for _, connection in ipairs(self._connections) do
		safeDisconnect(connection)
	end
	self._connections = {}

	if self._ws then
		local closed, _ = callMethodIfExists(self._ws, "Close")
		if not closed then
			callMethodIfExists(self._ws, "close")
		end
	end
	self._ws = nil
	self._connectedUrl = nil
end

function BridgeClient:_onMessage(rawMessage: string)
	local envelope = self:_decodeEnvelope(rawMessage)
	if envelope == nil then
		return
	end

	local messageType = envelope.type
	if messageType == "hello_challenge" then
		self:_handleChallenge(envelope)
	elseif messageType == "auth_ok" then
		self:_handleAuthOk(envelope)
	elseif messageType == "command" then
		self:_handleCommand(envelope)
	elseif messageType == "ping" then
		self:_sendEnvelope("pong", envelope.requestId, {})
	elseif messageType == "error" then
		local message = "Bridge error"
		if type(envelope.payload) == "table" then
			message = tostring(envelope.payload.message or message)
		end
		self:_setStatus("server_error", message)
	else
		self:_setStatus("protocol_warning", "Unknown message type: " .. tostring(messageType))
	end
end

function BridgeClient:_decodeEnvelope(rawMessage: string): { [string]: any }?
	if type(rawMessage) ~= "string" then
		return nil
	end

	if #rawMessage > MAX_PAYLOAD_BYTES then
		self:_setStatus("protocol_error", "Incoming payload exceeded max size")
		return nil
	end

	local ok, payload = pcall(function()
		return HttpService:JSONDecode(rawMessage)
	end)
	if not ok or type(payload) ~= "table" then
		self:_setStatus("protocol_error", "Failed to parse bridge JSON envelope")
		return nil
	end

	if payload.protocolVersion ~= PROTOCOL_VERSION then
		self:_setStatus("protocol_error", "Protocol version mismatch")
		return nil
	end

	if type(payload.type) ~= "string" or payload.type == "" then
		self:_setStatus("protocol_error", "Envelope missing type")
		return nil
	end

	return payload
end

function BridgeClient:_handleChallenge(envelope: { [string]: any })
	local payload = envelope.payload
	if type(payload) ~= "table" then
		self:_setStatus("auth_error", "Invalid auth challenge payload")
		return
	end

	local nonce = payload.nonce
	if type(nonce) ~= "string" or nonce == "" then
		self:_setStatus("auth_error", "Challenge is missing nonce")
		return
	end

	local secret = tostring(self._options.getSecret())
	if secret == "" then
		self:_setStatus("auth_error", "Shared secret is empty. Configure it in the plugin UI")
		return
	end

	local clientId = tostring(self._options.getClientId())
	local timestamp = math.floor(os.time() * 1000)
	local message = string.format("%s:%s:%d", nonce, clientId, timestamp)
	local signature = Crypto.hmacSha256Hex(secret, message)

	self:_sendEnvelope("auth_response", envelope.requestId, {
		clientId = clientId,
		clientTimestampMs = timestamp,
		signature = signature,
	})
	self:_setStatus("auth_pending", "Authenticating with bridge")
end

function BridgeClient:_handleAuthOk(envelope: { [string]: any })
	local payload = envelope.payload
	if type(payload) ~= "table" then
		self:_setStatus("auth_error", "Invalid auth_ok payload")
		return
	end

	local token = payload.sessionToken
	if type(token) ~= "string" or token == "" then
		self:_setStatus("auth_error", "Bridge auth_ok payload missing session token")
		return
	end

	self._sessionToken = token
	local detail = "Authenticated and ready"
	if self._connectedUrl then
		detail = "Authenticated and ready on " .. self._connectedUrl
	end
	self:_setStatus("ready", detail)
end

function BridgeClient:_handleCommand(envelope: { [string]: any })
	if self._sessionToken == nil then
		self:_sendCommandError(envelope.requestId, "unauthorized", "Session token is missing")
		return
	end

	if envelope.sessionToken ~= self._sessionToken then
		self:_sendCommandError(envelope.requestId, "unauthorized", "Session token mismatch")
		return
	end

	local payload = envelope.payload
	if type(payload) ~= "table" then
		self:_sendCommandError(envelope.requestId, "bad_request", "Command payload must be an object")
		return
	end

	local command = payload.command
	if type(command) ~= "string" or command == "" then
		self:_sendCommandError(envelope.requestId, "bad_request", "Command is missing")
		return
	end

	if not ALLOWED_COMMANDS[command] then
		self:_sendCommandError(envelope.requestId, "forbidden", "Command is not allowed in read-only mode")
		return
	end

	local args = payload.args
	if type(args) ~= "table" then
		args = {}
	end

	task.spawn(function()
		local startedAt = nowMs()
		local ok, resultOrError = pcall(function()
			return self._options.onCommand(command, args)
		end)
		local latencyMs = nowMs() - startedAt

		if ok then
			local telemetry = {
				command = command,
				latencyMs = latencyMs,
				resultCount = countResults(resultOrError),
			}
			if type(resultOrError) == "table" and type(resultOrError.meta) == "table" then
				telemetry.indexSize = resultOrError.meta.indexSize
			end
			if self._options.onTelemetry then
				self._options.onTelemetry(telemetry)
			end

			self:_sendEnvelope("command_result", envelope.requestId, {
				ok = true,
				data = resultOrError,
				telemetry = telemetry,
			}, self._sessionToken)
		else
			self:_sendEnvelope("command_result", envelope.requestId, {
				ok = false,
				error = {
					code = "command_failed",
					message = tostring(resultOrError),
				},
				telemetry = {
					command = command,
					latencyMs = latencyMs,
					resultCount = 0,
				},
			}, self._sessionToken)
		end
	end)
end

function BridgeClient:_sendCommandError(requestId: string?, code: string, message: string)
	self:_sendEnvelope("command_result", requestId, {
		ok = false,
		error = {
			code = code,
			message = message,
		},
	}, self._sessionToken)
end

function BridgeClient:_sendEnvelope(messageType: string, requestId: string?, payload: any, sessionToken: string?)
	if not self._ws then
		return
	end

	local envelope = {
		protocolVersion = PROTOCOL_VERSION,
		type = messageType,
		requestId = requestId,
		timestampMs = math.floor(os.time() * 1000),
		sessionToken = sessionToken,
		payload = payload,
	}

	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(envelope)
	end)
	if not ok then
		self:_setStatus("protocol_error", "Failed to encode outgoing envelope")
		return
	end

	if #encoded > MAX_PAYLOAD_BYTES then
		self:_setStatus("protocol_error", "Outgoing payload exceeded max size")
		return
	end

	local sent, errorMessage = callMethodIfExists(self._ws, "Send", encoded)
	if not sent then
		sent, errorMessage = callMethodIfExists(self._ws, "send", encoded)
	end
	if not sent then
		self:_setStatus("send_error", tostring(errorMessage))
	end
end

function BridgeClient:_setStatus(status: string, detail: string)
	if status ~= self._lastStatus or detail ~= nil then
		self._lastStatus = status
		if self._options.onStatus then
			self._options.onStatus(status, detail)
		end
	end
end

return BridgeClient
