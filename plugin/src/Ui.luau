local TweenService = game:GetService("TweenService")

local Ui = {}
Ui.__index = Ui

local HARDCODED_SHARED_SECRET = "roblox-read-mcp-global-shared-secret-v1"
local UNIVERSAL_DEFAULTS = {
	profile = "minimal",
	maxDepth = 5,
	maxNodes = 120,
	roots = "",
	includeProps = "",
	includeAttributes = true,
	includeTags = true,
}

local THEME = {
	bg = Color3.fromRGB(24, 25, 35),
	panel = Color3.fromRGB(35, 38, 56),
	panelSoft = Color3.fromRGB(43, 47, 68),
	text = Color3.fromRGB(232, 236, 248),
	subText = Color3.fromRGB(159, 166, 189),
	accent = Color3.fromRGB(126, 87, 255),
	accentHover = Color3.fromRGB(145, 111, 255),
	border = Color3.fromRGB(73, 78, 107),
	danger = Color3.fromRGB(116, 57, 100),
}

local function applyCorner(instance: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = instance
	return corner
end

local function applyStroke(instance: Instance, thickness: number, color: Color3)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = thickness
	stroke.Color = color
	stroke.Parent = instance
	return stroke
end

local function createLabel(parent: Instance, text: string, size: number, color: Color3, bold: boolean?): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, 20)
	label.Text = text
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextSize = size
	label.TextColor3 = color
	label.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	label.Parent = parent
	return label
end

local function createHoverButton(button: TextButton, baseColor: Color3, hoverColor: Color3)
	local tweenInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	button.MouseEnter:Connect(function()
		TweenService:Create(button, tweenInfo, { BackgroundColor3 = hoverColor }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(button, tweenInfo, { BackgroundColor3 = baseColor }):Play()
	end)
end

local function createInput(parent: Instance, placeholder: string, initial: string): TextBox
	local input = Instance.new("TextBox")
	input.Size = UDim2.new(1, 0, 0, 42)
	input.BackgroundColor3 = THEME.panelSoft
	input.BorderSizePixel = 0
	input.PlaceholderText = placeholder
	input.PlaceholderColor3 = THEME.subText
	input.Text = initial
	input.TextColor3 = THEME.text
	input.TextSize = 14
	input.Font = Enum.Font.RobotoMono
	input.ClearTextOnFocus = false
	applyCorner(input, 8)
	applyStroke(input, 1, THEME.border)
	input.Parent = parent
	return input
end

local function createToggleRow(parent: Instance, title: string, description: string, defaultState: boolean)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 58)
	row.BackgroundTransparency = 1
	row.Parent = parent

	local titleLabel = createLabel(row, title, 13, THEME.text, true)
	titleLabel.Position = UDim2.fromOffset(0, 2)
	titleLabel.Size = UDim2.new(1, -54, 0, 20)

	local desc = createLabel(row, description, 11, THEME.subText, false)
	desc.Position = UDim2.fromOffset(0, 24)
	desc.Size = UDim2.new(1, -54, 0, 18)

	local toggle = Instance.new("TextButton")
	toggle.AnchorPoint = Vector2.new(1, 0)
	toggle.Position = UDim2.new(1, 0, 0, 8)
	toggle.Size = UDim2.fromOffset(38, 22)
	toggle.BorderSizePixel = 0
	toggle.Text = ""
	applyCorner(toggle, 11)
	applyStroke(toggle, 1, THEME.border)
	toggle.Parent = row

	local knob = Instance.new("Frame")
	knob.Size = UDim2.fromOffset(16, 16)
	knob.Position = UDim2.fromOffset(3, 3)
	knob.BackgroundColor3 = Color3.fromRGB(240, 240, 247)
	knob.BorderSizePixel = 0
	applyCorner(knob, 8)
	knob.Parent = toggle

	local state = defaultState
	local function refresh()
		if state then
			toggle.BackgroundColor3 = THEME.accent
			knob.Position = UDim2.fromOffset(19, 3)
		else
			toggle.BackgroundColor3 = Color3.fromRGB(64, 68, 92)
			knob.Position = UDim2.fromOffset(3, 3)
		end
	end

	refresh()
	toggle.MouseButton1Click:Connect(function()
		state = not state
		refresh()
	end)
end

function Ui.new(plugin: Plugin, initialSettings)
	local self = setmetatable({}, Ui)
	self._callbacks = {}
	self._requestCount = 0

	local toolbar = plugin:CreateToolbar("RbxMCP")
	local button = toolbar:CreateButton("ToggleReadMcp", "Open RbxMCP", "rbxassetid://140668545844459")
	button.ClickableWhenViewportHidden = true

	local widgetInfo = DockWidgetPluginGuiInfo.new(
		Enum.InitialDockState.Left,
		true,
		true,
		390,
		620,
		340,
		520
	)
	local widget = plugin:CreateDockWidgetPluginGui("RobloxReadMcpWidget", widgetInfo)
	widget.Title = "RbxMCP"

	button.Click:Connect(function()
		widget.Enabled = not widget.Enabled
	end)
	widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		button:SetActive(widget.Enabled)
	end)

	self._toolbarButton = button
	self._widget = widget

	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = THEME.bg
	root.BorderSizePixel = 0
	root.Parent = widget

	local rootPad = Instance.new("UIPadding")
	rootPad.PaddingTop = UDim.new(0, 14)
	rootPad.PaddingBottom = UDim.new(0, 14)
	rootPad.PaddingLeft = UDim.new(0, 14)
	rootPad.PaddingRight = UDim.new(0, 14)
	rootPad.Parent = root

	local header = Instance.new("Frame")
	header.Size = UDim2.new(1, 0, 0, 64)
	header.BackgroundTransparency = 1
	header.Parent = root

	local logo = Instance.new("ImageLabel")
	logo.Size = UDim2.fromOffset(36, 36)
	logo.Position = UDim2.fromOffset(0, 6)
	logo.BackgroundTransparency = 1
	logo.Image = "rbxassetid://140668545844459"
	logo.Parent = header

	local title = createLabel(header, "RbxMCP", 24, THEME.text, true)
	title.Position = UDim2.fromOffset(48, 4)
	title.Size = UDim2.new(1, -140, 0, 28)

	local version = createLabel(header, "v1.0.0", 12, THEME.subText, false)
	version.Position = UDim2.fromOffset(48, 32)
	version.Size = UDim2.new(1, -140, 0, 18)

	local statusBadge = Instance.new("TextLabel")
	statusBadge.AnchorPoint = Vector2.new(1, 0)
	statusBadge.Position = UDim2.new(1, 0, 0, 10)
	statusBadge.Size = UDim2.fromOffset(110, 26)
	statusBadge.BackgroundColor3 = Color3.fromRGB(90, 95, 125)
	statusBadge.Text = "OFFLINE"
	statusBadge.TextColor3 = Color3.fromRGB(223, 226, 236)
	statusBadge.TextSize = 11
	statusBadge.Font = Enum.Font.GothamBold
	statusBadge.BorderSizePixel = 0
	applyCorner(statusBadge, 8)
	statusBadge.Parent = header
	self._statusBadge = statusBadge

	local pageContainer = Instance.new("Frame")
	pageContainer.Position = UDim2.fromOffset(0, 74)
	pageContainer.Size = UDim2.new(1, 0, 1, -74)
	pageContainer.BackgroundTransparency = 1
	pageContainer.Parent = root

	local homePage = Instance.new("Frame")
	homePage.Size = UDim2.fromScale(1, 1)
	homePage.BackgroundTransparency = 1
	homePage.Parent = pageContainer

	local settingsPage = Instance.new("Frame")
	settingsPage.Size = UDim2.fromScale(1, 1)
	settingsPage.BackgroundTransparency = 1
	settingsPage.Visible = false
	settingsPage.Parent = pageContainer

	self._homePage = homePage
	self._settingsPage = settingsPage

	local homeCard = Instance.new("Frame")
	homeCard.Position = UDim2.fromOffset(0, 18)
	homeCard.Size = UDim2.new(1, 0, 0, 170)
	homeCard.BackgroundColor3 = THEME.panel
	homeCard.BorderSizePixel = 0
	applyCorner(homeCard, 10)
	applyStroke(homeCard, 1, THEME.border)
	homeCard.Parent = homePage

	local homePad = Instance.new("UIPadding")
	homePad.PaddingTop = UDim.new(0, 14)
	homePad.PaddingBottom = UDim.new(0, 14)
	homePad.PaddingLeft = UDim.new(0, 14)
	homePad.PaddingRight = UDim.new(0, 14)
	homePad.Parent = homeCard

	local homeList = Instance.new("UIListLayout")
	homeList.Padding = UDim.new(0, 10)
	homeList.SortOrder = Enum.SortOrder.LayoutOrder
	homeList.Parent = homeCard

	createLabel(homeCard, "Bridge Endpoint", 12, THEME.subText, false)

	local endpointRow = Instance.new("Frame")
	endpointRow.Size = UDim2.new(1, 0, 0, 42)
	endpointRow.BackgroundTransparency = 1
	endpointRow.Parent = homeCard

	local endpointLayout = Instance.new("UIListLayout")
	endpointLayout.FillDirection = Enum.FillDirection.Horizontal
	endpointLayout.Padding = UDim.new(0, 8)
	endpointLayout.Parent = endpointRow

	self._hostInput = createInput(endpointRow, "localhost", tostring(initialSettings.host or "127.0.0.1"))
	self._hostInput.Size = UDim2.new(0.7, -4, 1, 0)
	self._portInput = createInput(endpointRow, "3812", tostring(initialSettings.port or "3812"))
	self._portInput.Size = UDim2.new(0.3, -4, 1, 0)

	self._statusDetails = createLabel(homeCard, "Bridge disconnected", 11, THEME.subText, false)
	self._statusDetails.Size = UDim2.new(1, 0, 0, 18)

	local footer = Instance.new("Frame")
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.new(0, 0, 1, 0)
	footer.Size = UDim2.new(1, 0, 0, 42)
	footer.BackgroundTransparency = 1
	footer.Parent = homePage

	local footerLayout = Instance.new("UIListLayout")
	footerLayout.FillDirection = Enum.FillDirection.Horizontal
	footerLayout.Padding = UDim.new(0, 10)
	footerLayout.Parent = footer

	local settingsButton = Instance.new("TextButton")
	settingsButton.Size = UDim2.new(0.44, -5, 1, 0)
	settingsButton.BackgroundColor3 = THEME.panel
	settingsButton.Text = "Settings"
	settingsButton.TextSize = 13
	settingsButton.TextColor3 = THEME.text
	settingsButton.Font = Enum.Font.GothamMedium
	settingsButton.BorderSizePixel = 0
	applyCorner(settingsButton, 8)
	applyStroke(settingsButton, 1, THEME.border)
	settingsButton.Parent = footer
	createHoverButton(settingsButton, THEME.panel, THEME.panelSoft)

	local connectButton = Instance.new("TextButton")
	connectButton.Size = UDim2.new(0.56, -5, 1, 0)
	connectButton.BackgroundColor3 = THEME.accent
	connectButton.Text = "Connect"
	connectButton.TextSize = 13
	connectButton.TextColor3 = Color3.fromRGB(245, 242, 255)
	connectButton.Font = Enum.Font.GothamBold
	connectButton.BorderSizePixel = 0
	applyCorner(connectButton, 8)
	connectButton.Parent = footer
	createHoverButton(connectButton, THEME.accent, THEME.accentHover)

	local settingsHeader = Instance.new("Frame")
	settingsHeader.Size = UDim2.new(1, 0, 0, 40)
	settingsHeader.BackgroundTransparency = 1
	settingsHeader.Parent = settingsPage

	local backButton = Instance.new("TextButton")
	backButton.Size = UDim2.fromOffset(86, 30)
	backButton.Position = UDim2.fromOffset(0, 4)
	backButton.BackgroundColor3 = THEME.panel
	backButton.Text = "< Back"
	backButton.TextSize = 12
	backButton.TextColor3 = THEME.text
	backButton.Font = Enum.Font.GothamMedium
	backButton.BorderSizePixel = 0
	applyCorner(backButton, 8)
	applyStroke(backButton, 1, THEME.border)
	backButton.Parent = settingsHeader
	createHoverButton(backButton, THEME.panel, THEME.panelSoft)

	local settingsTitle = createLabel(settingsHeader, "Settings", 16, THEME.text, true)
	settingsTitle.TextXAlignment = Enum.TextXAlignment.Center
	settingsTitle.Position = UDim2.fromOffset(0, 8)
	settingsTitle.Size = UDim2.new(1, 0, 0, 22)

	local divider = Instance.new("Frame")
	divider.Position = UDim2.new(0, 0, 1, -1)
	divider.Size = UDim2.new(1, 0, 0, 1)
	divider.BackgroundColor3 = THEME.border
	divider.BorderSizePixel = 0
	divider.Parent = settingsHeader

	local settingsScroll = Instance.new("ScrollingFrame")
	settingsScroll.Position = UDim2.fromOffset(0, 50)
	settingsScroll.Size = UDim2.new(1, 0, 1, -50)
	settingsScroll.BackgroundTransparency = 1
	settingsScroll.BorderSizePixel = 0
	settingsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	settingsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	settingsScroll.ScrollBarThickness = 4
	settingsScroll.ScrollBarImageColor3 = THEME.accent
	settingsScroll.Parent = settingsPage

	local settingsList = Instance.new("UIListLayout")
	settingsList.Padding = UDim.new(0, 8)
	settingsList.SortOrder = Enum.SortOrder.LayoutOrder
	settingsList.Parent = settingsScroll

	createToggleRow(settingsScroll, "Auto reconnect", "Try to reconnect when the bridge drops.", true)
	createToggleRow(settingsScroll, "Compact logs", "Keep connection detail messages short.", true)
	createToggleRow(settingsScroll, "Show command preview", "Display last command and result stats.", true)

	local disconnectButton = Instance.new("TextButton")
	disconnectButton.Size = UDim2.new(1, 0, 0, 38)
	disconnectButton.BackgroundColor3 = THEME.danger
	disconnectButton.Text = "Disconnect"
	disconnectButton.TextSize = 13
	disconnectButton.TextColor3 = THEME.text
	disconnectButton.Font = Enum.Font.GothamBold
	disconnectButton.BorderSizePixel = 0
	applyCorner(disconnectButton, 8)
	disconnectButton.Parent = settingsScroll
	createHoverButton(disconnectButton, THEME.danger, Color3.fromRGB(136, 66, 118))

	local telemetry = Instance.new("Frame")
	telemetry.Size = UDim2.new(1, 0, 0, 168)
	telemetry.BackgroundColor3 = THEME.panel
	telemetry.BorderSizePixel = 0
	applyCorner(telemetry, 10)
	applyStroke(telemetry, 1, THEME.border)
	telemetry.Parent = settingsScroll

	local telemetryPad = Instance.new("UIPadding")
	telemetryPad.PaddingTop = UDim.new(0, 12)
	telemetryPad.PaddingBottom = UDim.new(0, 12)
	telemetryPad.PaddingLeft = UDim.new(0, 12)
	telemetryPad.PaddingRight = UDim.new(0, 12)
	telemetryPad.Parent = telemetry

	local telemetryList = Instance.new("UIListLayout")
	telemetryList.Padding = UDim.new(0, 6)
	telemetryList.SortOrder = Enum.SortOrder.LayoutOrder
	telemetryList.Parent = telemetry

	createLabel(telemetry, "Telemetry", 13, THEME.text, true)
	self._requestsValue = createLabel(telemetry, "Requests: 0", 12, THEME.text, false)
	self._latencyValue = createLabel(telemetry, "Latency: - ms", 12, THEME.text, false)
	self._resultsValue = createLabel(telemetry, "Last Results: -", 12, THEME.text, false)
	self._indexValue = createLabel(telemetry, "Index Size: -", 12, THEME.text, false)
	self._lastCommand = createLabel(telemetry, "Last Command: -", 11, THEME.subText, false)

	settingsButton.MouseButton1Click:Connect(function()
		homePage.Visible = false
		settingsPage.Visible = true
	end)

	backButton.MouseButton1Click:Connect(function()
		settingsPage.Visible = false
		homePage.Visible = true
	end)

	connectButton.MouseButton1Click:Connect(function()
		if self._callbacks.saveSettings then
			self._callbacks.saveSettings(self:getSettingsSnapshot())
		end
		if self._callbacks.reconnect then
			self._callbacks.reconnect(true)
		end
	end)

	disconnectButton.MouseButton1Click:Connect(function()
		if self._callbacks.disconnect then
			self._callbacks.disconnect()
		end
	end)

	return self
end

function Ui:setCallbacks(callbacks)
	self._callbacks = callbacks or {}
end

function Ui:setConnectionStatus(status: string, detail: string?)
	self._statusBadge.Text = string.upper(status)
	if string.find(status, "ready") then
		self._statusBadge.BackgroundColor3 = Color3.fromRGB(86, 134, 113)
	elseif string.find(status, "error") or string.find(status, "fail") then
		self._statusBadge.BackgroundColor3 = Color3.fromRGB(138, 76, 112)
	elseif string.find(status, "connect") or string.find(status, "auth") then
		self._statusBadge.BackgroundColor3 = Color3.fromRGB(111, 89, 151)
	else
		self._statusBadge.BackgroundColor3 = Color3.fromRGB(90, 95, 125)
	end
	self._statusDetails.Text = detail or ""
end

function Ui:updateTelemetry(telemetry)
	if type(telemetry) ~= "table" then
		return
	end

	self._requestCount += 1
	self._requestsValue.Text = "Requests: " .. tostring(self._requestCount)
	self._latencyValue.Text = "Latency: " .. tostring(math.floor(tonumber(telemetry.latencyMs) or 0)) .. " ms"
	self._resultsValue.Text = "Last Results: " .. tostring(math.floor(tonumber(telemetry.resultCount) or 0))
	if telemetry.indexSize ~= nil then
		self._indexValue.Text = "Index Size: " .. tostring(telemetry.indexSize)
	end
	self._lastCommand.Text = "Last Command: " .. tostring(telemetry.command or "-")
end

function Ui:getHost(): string
	return self._hostInput.Text ~= "" and self._hostInput.Text or "127.0.0.1"
end

function Ui:getPort(): number
	return tonumber(self._portInput.Text) or 3812
end

function Ui:getSecret(): string
	return HARDCODED_SHARED_SECRET
end

function Ui:getRuntimeOptions()
	return {
		profile = UNIVERSAL_DEFAULTS.profile,
		maxDepth = UNIVERSAL_DEFAULTS.maxDepth,
		maxNodes = UNIVERSAL_DEFAULTS.maxNodes,
		roots = UNIVERSAL_DEFAULTS.roots,
		includeProps = UNIVERSAL_DEFAULTS.includeProps,
		includeAttributes = UNIVERSAL_DEFAULTS.includeAttributes,
		includeTags = UNIVERSAL_DEFAULTS.includeTags,
	}
end

function Ui:getSettingsSnapshot()
	local runtime = self:getRuntimeOptions()
	runtime.host = self:getHost()
	runtime.port = self:getPort()
	runtime.secret = self:getSecret()
	return runtime
end

function Ui:destroy()
	if self._widget then
		self._widget:Destroy()
	end
end

return Ui
