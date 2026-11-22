-- Delta X Mobile UI + Aimbot + Drawing API ESP/FOV + Instant Speed Sub-Menu + Floating Icon + Destroy All (Single File, Final)
-- [FIX PASS] แก้จุดที่อาจ error โดยคงค่าเดิมทุกตัว (สี/ขนาด/ตำแหน่ง/ค่า default/ข้อความเมนู)

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")

-- [FIX] ตรวจ DrawingLib แบบ nil-safe ไม่ให้เข้าถึง global ที่อาจไม่มีอยู่
local DrawingLib = rawget(_G, "Drawing")
if not DrawingLib and typeof(Drawing) == "table" then
	DrawingLib = Drawing
end
local HAS_DRAWING = type(DrawingLib) == "table" and type(DrawingLib.new) == "function"

local HUB_NAME = "DeltaMobileHub"
local DEFAULT_WALK_SPEED = 16
local DEFAULT_JUMP_POWER = 50
local isDestroyed = false
local activeConnections = {}

local function trackConnection(conn)
	if conn then
		table.insert(activeConnections, conn)
	end
	return conn
end

-- [FIX] เชื่อมต่อ signal แบบปลอดภัย: ถ้า signal หาย/ถูกทำลาย จะไม่ throw error ทั้งสคริปต์
local function safeConnect(signal, handler)
	if typeof(signal) ~= "RBXScriptSignal" then return nil end
	local ok, conn = pcall(function()
		return signal:Connect(handler)
	end)
	if ok and typeof(conn) == "RBXScriptConnection" then
		return trackConnection(conn)
	end
	return nil
end

local function untrackAndDisconnect(conn)
	if not conn then return end
	pcall(function()
		conn:Disconnect()
	end)
	for i = #activeConnections, 1, -1 do
		if activeConnections[i] == conn then
			table.remove(activeConnections, i)
		end
	end
end

local function safeParent(gui)
	if not gui then return end
	local ok = pcall(function()
		gui.Parent = CoreGui
	end)
	if (not ok or gui.Parent ~= CoreGui) and PlayerGui then
		pcall(function()
			gui.Parent = PlayerGui
		end)
	end
end

local function makeDraggable(dragHandle, targetFrame, onTapCallback)
	if not dragHandle or not targetFrame then return end

	local dragging = false
	local moved = false
	local dragStart = Vector2.zero
	local startPos = targetFrame.Position
	local moveConn = nil
	local endConn = nil

	local function cleanupDragConns()
		if moveConn then
			untrackAndDisconnect(moveConn)
			moveConn = nil
		end
		if endConn then
			untrackAndDisconnect(endConn)
			endConn = nil
		end
	end

	-- [FIX] ใช้ safeConnect กัน InputBegan หายบน executor บางตัว
	safeConnect(dragHandle.InputBegan, function(input)
		if isDestroyed then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			cleanupDragConns()
			dragging = true
			moved = false
			dragStart = Vector2.new(input.Position.X, input.Position.Y)
			startPos = targetFrame.Position

			moveConn = safeConnect(UserInputService.InputChanged, function(moveInput)
				if isDestroyed or not dragging then return end
				if moveInput.UserInputType == Enum.UserInputType.MouseMovement or moveInput.UserInputType == Enum.UserInputType.Touch then
					local delta = Vector2.new(moveInput.Position.X, moveInput.Position.Y) - dragStart
					if delta.Magnitude > 6 then
						moved = true
					end
					targetFrame.Position = UDim2.new(
						startPos.X.Scale,
						startPos.X.Offset + delta.X,
						startPos.Y.Scale,
						startPos.Y.Offset + delta.Y
					)
				end
			end)

			endConn = safeConnect(input.Changed, function()
				if input.UserInputState == Enum.UserInputState.End then
					local wasTap = dragging and (not moved)
					dragging = false
					cleanupDragConns()
					if wasTap and typeof(onTapCallback) == "function" and not isDestroyed then
						pcall(onTapCallback)
					end
				end
			end)
		end
	end)
end

-- ล้าง UI เก่าถ้ามีการรันซ้ำ
pcall(function()
	local oldCore = CoreGui:FindFirstChild(HUB_NAME)
	if oldCore then oldCore:Destroy() end
end)
if PlayerGui then
	pcall(function()
		local oldPlayer = PlayerGui:FindFirstChild(HUB_NAME)
		if oldPlayer then oldPlayer:Destroy() end
	end)
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = HUB_NAME
ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = true
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
safeParent(ScreenGui)

-- Fallback GUI (ใช้เมื่อ executor ไม่มี Drawing API)
local EspContainer = Instance.new("Folder")
EspContainer.Name = "EspContainer"
EspContainer.Parent = ScreenGui

local FovCircleGui = Instance.new("Frame")
FovCircleGui.Name = "FovCircleGui"
FovCircleGui.AnchorPoint = Vector2.new(0.5, 0.5)
FovCircleGui.Position = UDim2.new(0.5, 0, 0.5, 0)
FovCircleGui.Size = UDim2.new(0, 240, 0, 240)
FovCircleGui.BackgroundTransparency = 1
FovCircleGui.Visible = false
FovCircleGui.ZIndex = 2
FovCircleGui.Parent = ScreenGui

local FovCornerGui = Instance.new("UICorner")
FovCornerGui.CornerRadius = UDim.new(1, 0)
FovCornerGui.Parent = FovCircleGui

local FovStrokeGui = Instance.new("UIStroke")
FovStrokeGui.Color = Color3.fromRGB(80, 200, 255)
FovStrokeGui.Thickness = 1.5
FovStrokeGui.Transparency = 0.2
FovStrokeGui.Parent = FovCircleGui

-- Drawing FOV Circle (ถ้ามี Drawing API)
local FovDrawing = nil
if HAS_DRAWING then
	pcall(function()
		local c = DrawingLib.new("Circle")
		c.Visible = false
		c.Color = Color3.fromRGB(80, 200, 255)
		c.Thickness = 1.5
		c.NumSides = 64
		c.Filled = false
		c.Transparency = 0.85
		FovDrawing = c
	end)
end

-- ปุ่มไอคอนลอยสำหรับเปิด/ปิด UI (ลากย้ายได้ + แตะเพื่อเปิดหน้าต่าง)
local FloatingIcon = Instance.new("TextButton")
FloatingIcon.Name = "FloatingIcon"
FloatingIcon.Size = UDim2.new(0, 46, 0, 46)
FloatingIcon.Position = UDim2.new(0, 18, 0.45, -23)
FloatingIcon.BackgroundColor3 = Color3.fromRGB(28, 31, 40)
FloatingIcon.Text = "HUB"
FloatingIcon.TextColor3 = Color3.fromRGB(130, 220, 255)
FloatingIcon.TextSize = 12
FloatingIcon.Font = Enum.Font.GothamBold
FloatingIcon.AutoButtonColor = false
FloatingIcon.Visible = false
FloatingIcon.ZIndex = 10
FloatingIcon.Parent = ScreenGui

local FloatCorner = Instance.new("UICorner")
FloatCorner.CornerRadius = UDim.new(1, 0)
FloatCorner.Parent = FloatingIcon

local FloatStroke = Instance.new("UIStroke")
FloatStroke.Color = Color3.fromRGB(80, 200, 255)
FloatStroke.Thickness = 1.5
FloatStroke.Parent = FloatingIcon

-- หน้าต่างหลัก (ขนาดพอดีมือถือ เลื่อนดูเมนูย่อยได้ครบ)
local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, 295, 0, 285)
MainFrame.Position = UDim2.new(0.5, -147, 0.5, -142)
MainFrame.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.ZIndex = 5
MainFrame.Parent = ScreenGui

local MainCorner = Instance.new("UICorner")
MainCorner.CornerRadius = UDim.new(0, 10)
MainCorner.Parent = MainFrame

local MainStroke = Instance.new("UIStroke")
MainStroke.Color = Color3.fromRGB(65, 72, 92)
MainStroke.Thickness = 1
MainStroke.Parent = MainFrame

-- แถบหัวข้อสำหรับลากย้าย
local TopBar = Instance.new("Frame")
TopBar.Name = "TopBar"
TopBar.Size = UDim2.new(1, 0, 0, 34)
TopBar.BackgroundColor3 = Color3.fromRGB(28, 31, 40)
TopBar.BorderSizePixel = 0
-- [FIX] Frame ปกติ Active=false ทำให้ InputBegan ไม่ยิงบนบาง executor; เปิด Active เพื่อให้ลากแถบหัวข้อได้จริง (ไม่กระทบสี/ขนาด/ตำแหน่ง)
TopBar.Active = true
TopBar.Parent = MainFrame

local TopCorner = Instance.new("UICorner")
TopCorner.CornerRadius = UDim.new(0, 10)
TopCorner.Parent = TopBar

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Name = "TitleLabel"
TitleLabel.Size = UDim2.new(1, -76, 1, 0)
TitleLabel.Position = UDim2.new(0, 12, 0, 0)
TitleLabel.BackgroundTransparency = 1
TitleLabel.Text = "MOBILE HUB"
TitleLabel.TextColor3 = Color3.fromRGB(235, 240, 250)
TitleLabel.TextSize = 13
TitleLabel.Font = Enum.Font.GothamBold
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Parent = TopBar

-- ปุ่ม - (ปิดหน้าต่างหลัก และแสดงไอคอนลอย)
local MinimizeBtn = Instance.new("TextButton")
MinimizeBtn.Name = "MinimizeBtn"
MinimizeBtn.Size = UDim2.new(0, 26, 0, 24)
MinimizeBtn.Position = UDim2.new(1, -62, 0.5, -12)
MinimizeBtn.BackgroundColor3 = Color3.fromRGB(45, 50, 65)
MinimizeBtn.Text = "-"
MinimizeBtn.TextColor3 = Color3.fromRGB(235, 240, 250)
MinimizeBtn.TextSize = 16
MinimizeBtn.Font = Enum.Font.GothamBold
MinimizeBtn.Parent = TopBar

local MinCorner = Instance.new("UICorner")
MinCorner.CornerRadius = UDim.new(0, 6)
MinCorner.Parent = MinimizeBtn

-- ปุ่ม × (ลบทุกอย่าง ทั้งไอคอน UI เมนู Drawing ความเร็ว และการทำงานทั้งหมด)
local CloseBtn = Instance.new("TextButton")
CloseBtn.Name = "CloseBtn"
CloseBtn.Size = UDim2.new(0, 26, 0, 24)
CloseBtn.Position = UDim2.new(1, -32, 0.5, -12)
CloseBtn.BackgroundColor3 = Color3.fromRGB(165, 45, 55)
CloseBtn.Text = "×"
CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
CloseBtn.TextSize = 15
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.Parent = TopBar

local CloseCorner = Instance.new("UICorner")
CloseCorner.CornerRadius = UDim.new(0, 6)
CloseCorner.Parent = CloseBtn

-- พื้นที่ใส่เมนู (รองรับการเลื่อนบนมือถือ)
local ContentFrame = Instance.new("ScrollingFrame")
ContentFrame.Name = "ContentFrame"
ContentFrame.Size = UDim2.new(1, -16, 1, -46)
ContentFrame.Position = UDim2.new(0, 8, 0, 40)
ContentFrame.BackgroundTransparency = 1
ContentFrame.ScrollBarThickness = 3
ContentFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
ContentFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
ContentFrame.Parent = MainFrame

local ListLayout = Instance.new("UIListLayout")
ListLayout.Padding = UDim.new(0, 6)
ListLayout.SortOrder = Enum.SortOrder.LayoutOrder
ListLayout.Parent = ContentFrame

-- สถานะและการทำงานของ Aimbot, ESP และ Speed (ปรับแล้วติดทันที ไม่รอเกิดใหม่)
local AimbotConfig = {
	Enabled = false,
	ShowFov = false,
	FovRadius = 120,
	TargetPart = "Head" -- "Head" หรือ "HumanoidRootPart"
}

local EspConfig = {
	Enabled = false,
	ShowDistance = false,
	ShowName = false,
	ShowTracer = false
}

local SpeedConfig = {
	Enabled = false,
	WalkSpeed = 32,
	JumpBoostEnabled = false,
	JumpPower = 50
}

local espObjects = {}

local function getCurrentHumanoid()
	-- [FIX] กัน LocalPlayer เป็น nil
	if not LocalPlayer then return nil end
	local char = LocalPlayer.Character
	if not char or not char.Parent then return nil end
	return char:FindFirstChildOfClass("Humanoid")
end

local function applyWalkSpeedNow()
	if isDestroyed then return end
	local humanoid = getCurrentHumanoid()
	if not humanoid then return end
	pcall(function()
		humanoid.WalkSpeed = SpeedConfig.Enabled and SpeedConfig.WalkSpeed or DEFAULT_WALK_SPEED
	end)
end

local function applyJumpPowerNow()
	if isDestroyed then return end
	local humanoid = getCurrentHumanoid()
	if not humanoid then return end
	pcall(function()
		local targetJump = SpeedConfig.JumpBoostEnabled and SpeedConfig.JumpPower or DEFAULT_JUMP_POWER
		if humanoid.UseJumpPower then
			humanoid.JumpPower = targetJump
		else
			humanoid.JumpHeight = SpeedConfig.JumpBoostEnabled and math.max(7.2, SpeedConfig.JumpPower * 0.144) or 7.2
		end
	end)
end

local function resetMovementNow()
	local humanoid = getCurrentHumanoid()
	if not humanoid then return end
	pcall(function()
		humanoid.WalkSpeed = DEFAULT_WALK_SPEED
		if humanoid.UseJumpPower then
			humanoid.JumpPower = DEFAULT_JUMP_POWER
		else
			humanoid.JumpHeight = 7.2
		end
	end)
end

local function safeRemoveDrawing(obj)
	if not obj then return end
	pcall(function()
		obj.Visible = false
	end)
	pcall(function()
		if obj.Remove then
			obj:Remove()
		elseif obj.Destroy then
			obj:Destroy()
		end
	end)
end

local function clearAllEspVisuals()
	for plr, entry in pairs(espObjects) do
		if entry then
			if entry.UseDrawing then
				safeRemoveDrawing(entry.Box)
				safeRemoveDrawing(entry.InfoText)
				safeRemoveDrawing(entry.Tracer)
			else
				if entry.Box then pcall(function() entry.Box:Destroy() end) end
				if entry.InfoLabel then pcall(function() entry.InfoLabel:Destroy() end) end
				if entry.TracerLine then pcall(function() entry.TracerLine:Destroy() end) end
			end
		end
		espObjects[plr] = nil
	end
	if EspContainer then
		for _, child in ipairs(EspContainer:GetChildren()) do
			pcall(function() child:Destroy() end)
		end
	end
	-- [FIX] เคลียร์ตาราง reference ที่เหลือหลังลบ visual แล้ว
	table.clear(espObjects)
end

local function removePlayerEsp(plr)
	local entry = espObjects[plr]
	if entry then
		if entry.UseDrawing then
			safeRemoveDrawing(entry.Box)
			safeRemoveDrawing(entry.InfoText)
			safeRemoveDrawing(entry.Tracer)
		else
			if entry.Box then pcall(function() entry.Box:Destroy() end) end
			if entry.InfoLabel then pcall(function() entry.InfoLabel:Destroy() end) end
			if entry.TracerLine then pcall(function() entry.TracerLine:Destroy() end) end
		end
		espObjects[plr] = nil
	end
end

local function hidePlayerEspEntry(entry)
	if not entry then return end
	if entry.UseDrawing then
		pcall(function()
			if entry.Box then entry.Box.Visible = false end
			if entry.InfoText then entry.InfoText.Visible = false end
			if entry.Tracer then entry.Tracer.Visible = false end
		end)
	else
		-- [FIX] ครอบ pcall กัน assignment property บน GUI ที่ถูกทำลายแล้ว
		pcall(function()
			if entry.Box then entry.Box.Visible = false end
			if entry.InfoLabel then entry.InfoLabel.Visible = false end
			if entry.TracerLine then entry.TracerLine.Visible = false end
		end)
	end
end

local function getOrCreatePlayerEsp(plr)
	if espObjects[plr] then
		return espObjects[plr]
	end

	if HAS_DRAWING then
		-- [FIX] สร้างทีละตัวแบบเก็บ reference; ถ้าตัวใดตัวหนึ่งล้มเหลว ให้ลบตัวที่สร้างไปแล้ว ไม่ให้ค้างในหน่วยความจำ
		local boxDraw, textDraw, tracerDraw = nil, nil, nil
		local okDraw = pcall(function()
			local sq = DrawingLib.new("Square")
			sq.Visible = false
			sq.Color = Color3.fromRGB(45, 255, 95)
			sq.Thickness = 1.6
			sq.Filled = false
			sq.Transparency = 1
			boxDraw = sq

			local txt = DrawingLib.new("Text")
			txt.Visible = false
			txt.Color = Color3.fromRGB(160, 255, 180)
			txt.Size = 13
			txt.Center = true
			txt.Outline = true
			txt.OutlineColor = Color3.fromRGB(0, 0, 0)
			txt.Transparency = 1
			textDraw = txt

			local tr = DrawingLib.new("Line")
			tr.Visible = false
			tr.Color = Color3.fromRGB(45, 255, 95)
			tr.Thickness = 1.2
			tr.Transparency = 0.85
			tracerDraw = tr
		end)

		if okDraw and boxDraw and textDraw and tracerDraw then
			local entry = {
				UseDrawing = true,
				Box = boxDraw,
				InfoText = textDraw,
				Tracer = tracerDraw
			}
			espObjects[plr] = entry
			return entry
		end

		safeRemoveDrawing(boxDraw)
		safeRemoveDrawing(textDraw)
		safeRemoveDrawing(tracerDraw)
	end

	-- Fallback GUI
	local box = Instance.new("Frame")
	box.Name = "EspBox_" .. tostring(plr.UserId)
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.Visible = false
	box.ZIndex = 1
	box.Parent = EspContainer

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(45, 255, 95)
	stroke.Thickness = 1.5
	stroke.Transparency = 0.05
	stroke.Parent = box

	local infoLabel = Instance.new("TextLabel")
	infoLabel.Name = "EspInfo_" .. tostring(plr.UserId)
	infoLabel.BackgroundTransparency = 1
	infoLabel.Text = ""
	infoLabel.TextColor3 = Color3.fromRGB(160, 255, 180)
	infoLabel.TextStrokeTransparency = 0.25
	infoLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	infoLabel.TextSize = 11
	infoLabel.Font = Enum.Font.GothamBold
	infoLabel.TextYAlignment = Enum.TextYAlignment.Bottom
	infoLabel.Visible = false
	infoLabel.ZIndex = 2
	infoLabel.Parent = EspContainer

	local tracerLine = Instance.new("Frame")
	tracerLine.Name = "EspTracer_" .. tostring(plr.UserId)
	tracerLine.BackgroundColor3 = Color3.fromRGB(45, 255, 95)
	tracerLine.BorderSizePixel = 0
	tracerLine.AnchorPoint = Vector2.new(0.5, 0.5)
	tracerLine.Visible = false
	tracerLine.ZIndex = 1
	tracerLine.Parent = EspContainer

	local entry = {
		UseDrawing = false,
		Box = box,
		InfoLabel = infoLabel,
		TracerLine = tracerLine
	}
	espObjects[plr] = entry
	return entry
end

local function getCharacterBounds(character)
	if not character or not character.Parent then return nil, nil end
	local ok, cf, size = pcall(function()
		return character:GetBoundingBox()
	end)
	if ok and typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
		local clampedX = math.clamp(size.X, 1.5, 6)
		local clampedY = math.clamp(size.Y, 2.5, 8)
		local clampedZ = math.clamp(size.Z, 1.5, 6)
		return cf, Vector3.new(clampedX, clampedY, clampedZ)
	end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp.CFrame, Vector3.new(4, 5.5, 2)
	end
	return nil, nil
end

local function updateEsp(camera)
	if not EspConfig.Enabled or isDestroyed or not camera then
		for _, entry in pairs(espObjects) do
			hidePlayerEspEntry(entry)
		end
		return
	end

	local myChar = LocalPlayer and LocalPlayer.Character
	local myHrp = myChar and myChar:FindFirstChild("HumanoidRootPart")
	local myPos = (myHrp and myHrp:IsA("BasePart")) and myHrp.Position or camera.CFrame.Position
	local vp = camera.ViewportSize
	local bottomCenter = Vector2.new(vp.X * 0.5, vp.Y)

	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LocalPlayer then
			local entry = getOrCreatePlayerEsp(plr)
			local char = plr.Character
			local humanoid = char and char:FindFirstChildOfClass("Humanoid")
			local cf, size = getCharacterBounds(char)

			if char and humanoid and humanoid.Health > 0 and cf and size then
				local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
				local corners = {
					cf * Vector3.new(-hx, -hy, -hz),
					cf * Vector3.new(-hx, -hy, hz),
					cf * Vector3.new(-hx, hy, -hz),
					cf * Vector3.new(-hx, hy, hz),
					cf * Vector3.new(hx, -hy, -hz),
					cf * Vector3.new(hx, -hy, hz),
					cf * Vector3.new(hx, hy, -hz),
					cf * Vector3.new(hx, hy, hz)
				}

				local minX, maxX = math.huge, -math.huge
				local minY, maxY = math.huge, -math.huge
				local anyBehind = false

				for _, cornerWorld in ipairs(corners) do
					local screenPt, _ = camera:WorldToViewportPoint(cornerWorld)
					if screenPt.Z <= 0 then
						anyBehind = true
						break
					end
					if screenPt.X < minX then minX = screenPt.X end
					if screenPt.X > maxX then maxX = screenPt.X end
					if screenPt.Y < minY then minY = screenPt.Y end
					if screenPt.Y > maxY then maxY = screenPt.Y end
				end

				local onScreen = (not anyBehind) and (maxX >= 0) and (minX <= vp.X) and (maxY >= 0) and (minY <= vp.Y)

				if onScreen and (maxX - minX) > 2 and (maxY - minY) > 4 then
					local boxW = math.floor(maxX - minX + 0.5)
					local boxH = math.floor(maxY - minY + 0.5)
					local boxX = math.floor(minX + 0.5)
					local boxY = math.floor(minY + 0.5)
					local targetBottom2D = Vector2.new(boxX + (boxW * 0.5), boxY + boxH)

					local partsText = {}
					if EspConfig.ShowName then
						table.insert(partsText, tostring(plr.DisplayName or plr.Name))
					end
					if EspConfig.ShowDistance then
						local studsDist = (cf.Position - myPos).Magnitude
						local metersDist = math.floor((studsDist * 0.28) + 0.5)
						table.insert(partsText, tostring(metersDist) .. "m")
					end

					if entry.UseDrawing then
						pcall(function()
							entry.Box.Size = Vector2.new(boxW, boxH)
							entry.Box.Position = Vector2.new(boxX, boxY)
							entry.Box.Visible = true

							if #partsText > 0 then
								entry.InfoText.Text = table.concat(partsText, " | ")
								entry.InfoText.Position = Vector2.new(boxX + (boxW * 0.5), boxY - 16)
								entry.InfoText.Visible = true
							else
								entry.InfoText.Visible = false
							end

							if EspConfig.ShowTracer then
								entry.Tracer.From = bottomCenter
								entry.Tracer.To = targetBottom2D
								entry.Tracer.Visible = true
							else
								entry.Tracer.Visible = false
							end
						end)
					else
						-- [FIX] ครอบ pcall กัน assignment property บน GUI ที่ถูกทำลายแล้ว
		pcall(function()
			if entry.Box then entry.Box.Visible = false end
			if entry.InfoLabel then entry.InfoLabel.Visible = false end
			if entry.TracerLine then entry.TracerLine.Visible = false end
		end)
	end
end

local function getOrCreatePlayerEsp(plr)
	if espObjects[plr] then
		return espObjects[plr]
	end

	if HAS_DRAWING then
		-- [FIX] สร้างทีละตัวแบบเก็บ reference; ถ้าตัวใดตัวหนึ่งล้มเหลว ให้ลบตัวที่สร้างไปแล้ว ไม่ให้ค้างในหน่วยความจำ
		local boxDraw, textDraw, tracerDraw = nil, nil, nil
		local okDraw = pcall(function()
			local sq = DrawingLib.new("Square")
			sq.Visible = false
			sq.Color = Color3.fromRGB(45, 255, 95)
			sq.Thickness = 1.6
			sq.Filled = false
			sq.Transparency = 1
			boxDraw = sq

			local txt = DrawingLib.new("Text")
			txt.Visible = false
			txt.Color = Color3.fromRGB(160, 255, 180)
			txt.Size = 13
			txt.Center = true
			txt.Outline = true
			txt.OutlineColor = Color3.fromRGB(0, 0, 0)
			txt.Transparency = 1
			textDraw = txt

			local tr = DrawingLib.new("Line")
			tr.Visible = false
			tr.Color = Color3.fromRGB(45, 255, 95)
			tr.Thickness = 1.2
			tr.Transparency = 0.85
			tracerDraw = tr
		end)

		if okDraw and boxDraw and textDraw and tracerDraw then
			local entry = {
				UseDrawing = true,
				Box = boxDraw,
				InfoText = textDraw,
				Tracer = tracerDraw
			}
			espObjects[plr] = entry
			return entry
		end

		safeRemoveDrawing(boxDraw)
		safeRemoveDrawing(textDraw)
		safeRemoveDrawing(tracerDraw)
	end

	-- Fallback GUI
	local box = Instance.new("Frame")
	box.Name = "EspBox_" .. tostring(plr.UserId)
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.Visible = false
	box.ZIndex = 1
	box.Parent = EspContainer

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(45, 255, 95)
	stroke.Thickness = 1.5
	stroke.Transparency = 0.05
	stroke.Parent = box

	local infoLabel = Instance.new("TextLabel")
	infoLabel.Name = "EspInfo_" .. tostring(plr.UserId)
	infoLabel.BackgroundTransparency = 1
	infoLabel.Text = ""
	infoLabel.TextColor3 = Color3.fromRGB(160, 255, 180)
	infoLabel.TextStrokeTransparency = 0.25
	infoLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	infoLabel.TextSize = 11
	infoLabel.Font = Enum.Font.GothamBold
	infoLabel.TextYAlignment = Enum.TextYAlignment.Bottom
	infoLabel.Visible = false
	infoLabel.ZIndex = 2
	infoLabel.Parent = EspContainer

	local tracerLine = Instance.new("Frame")
	tracerLine.Name = "EspTracer_" .. tostring(plr.UserId)
	tracerLine.BackgroundColor3 = Color3.fromRGB(45, 255, 95)
	tracerLine.BorderSizePixel = 0
	tracerLine.AnchorPoint = Vector2.new(0.5, 0.5)
	tracerLine.Visible = false
	tracerLine.ZIndex = 1
	tracerLine.Parent = EspContainer

	local entry = {
		UseDrawing = false,
		Box = box,
		InfoLabel = infoLabel,
		TracerLine = tracerLine
	}
	espObjects[plr] = entry
	return entry
end

local function getCharacterBounds(character)
	if not character or not character.Parent then return nil, nil end
	local ok, cf, size = pcall(function()
		return character:GetBoundingBox()
	end)
	if ok and typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
		local clampedX = math.clamp(size.X, 1.5, 6)
		local clampedY = math.clamp(size.Y, 2.5, 8)
		local clampedZ = math.clamp(size.Z, 1.5, 6)
		return cf, Vector3.new(clampedX, clampedY, clampedZ)
	end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp.CFrame, Vector3.new(4, 5.5, 2)
	end
	return nil, nil
end

local function updateEsp(camera)
	if not EspConfig.Enabled or isDestroyed or not camera then
		for _, entry in pairs(espObjects) do
			hidePlayerEspEntry(entry)
		end
		return
	end

	local myChar = LocalPlayer and LocalPlayer.Character
	local myHrp = myChar and myChar:FindFirstChild("HumanoidRootPart")
	local myPos = (myHrp and myHrp:IsA("BasePart")) and myHrp.Position or camera.CFrame.Position
	local vp = camera.ViewportSize
	local bottomCenter = Vector2.new(vp.X * 0.5, vp.Y)

	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LocalPlayer then
			local entry = getOrCreatePlayerEsp(plr)
			local char = plr.Character
			local humanoid = char and char:FindFirstChildOfClass("Humanoid")
			local cf, size = getCharacterBounds(char)

			if char and humanoid and humanoid.Health > 0 and cf and size then
				local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
				local corners = {
					cf * Vector3.new(-hx, -hy, -hz),
					cf * Vector3.new(-hx, -hy, hz),
					cf * Vector3.new(-hx, hy, -hz),
					cf * Vector3.new(-hx, hy, hz),
					cf * Vector3.new(hx, -hy, -hz),
					cf * Vector3.new(hx, -hy, hz),
					cf * Vector3.new(hx, hy, -hz),
					cf * Vector3.new(hx, hy, hz)
				}

				local minX, maxX = math.huge, -math.huge
				local minY, maxY = math.huge, -math.huge
				local anyBehind = false

				for _, cornerWorld in ipairs(corners) do
					local screenPt, _ = camera:WorldToViewportPoint(cornerWorld)
					if screenPt.Z <= 0 then
						anyBehind = true
						break
					end
					if screenPt.X < minX then minX = screenPt.X end
					if screenPt.X > maxX then maxX = screenPt.X end
					if screenPt.Y < minY then minY = screenPt.Y end
					if screenPt.Y > maxY then maxY = screenPt.Y end
				end

				local onScreen = (not anyBehind) and (maxX >= 0) and (minX <= vp.X) and (maxY >= 0) and (minY <= vp.Y)

				if onScreen and (maxX - minX) > 2 and (maxY - minY) > 4 then
					local boxW = math.floor(maxX - minX + 0.5)
					local boxH = math.floor(maxY - minY + 0.5)
					local boxX = math.floor(minX + 0.5)
					local boxY = math.floor(minY + 0.5)
					local targetBottom2D = Vector2.new(boxX + (boxW * 0.5), boxY + boxH)

					local partsText = {}
					if EspConfig.ShowName then
						table.insert(partsText, tostring(plr.DisplayName or plr.Name))
					end
					if EspConfig.ShowDistance then
						local studsDist = (cf.Position - myPos).Magnitude
						local metersDist = math.floor((studsDist * 0.28) + 0.5)
						table.insert(partsText, tostring(metersDist) .. "m")
					end

					if entry.UseDrawing then
						pcall(function()
							entry.Box.Size = Vector2.new(boxW, boxH)
							entry.Box.Position = Vector2.new(boxX, boxY)
							entry.Box.Visible = true

							if #partsText > 0 then
								entry.InfoText.Text = table.concat(partsText, " | ")
								entry.InfoText.Position = Vector2.new(boxX + (boxW * 0.5), boxY - 16)
								entry.InfoText.Visible = true
							else
								entry.InfoText.Visible = false
							end

							if EspConfig.ShowTracer then
								entry.Tracer.From = bottomCenter
								entry.Tracer.To = targetBottom2D
								entry.Tracer.Visible = true
							else
								entry.Tracer.Visible = false
							end
						end)
					else
						-- [FIX] ครอบ assignment ของ fallback GUI ทั้งก้อนด้วย pcall
						pcall(function()
							entry.Box.Position = UDim2.new(0, boxX, 0, boxY)
							entry.Box.Size = UDim2.new(0, boxW, 0, boxH)
							entry.Box.Visible = true

							if #partsText > 0 then
								entry.InfoLabel.Text = table.concat(partsText, " | ")
								local labelWidth = math.max(boxW + 40, 90)
								entry.InfoLabel.Size = UDim2.new(0, labelWidth, 0, 16)
								entry.InfoLabel.Position = UDim2.new(0, boxX + (boxW * 0.5) - (labelWidth * 0.5), 0, boxY - 18)
								entry.InfoLabel.Visible = true
							else
								entry.InfoLabel.Visible = false
							end

							if EspConfig.ShowTracer then
								local diff = targetBottom2D - bottomCenter
								local dist = diff.Magnitude
								if dist > 1 then
									local mid = (bottomCenter + targetBottom2D) * 0.5
									local angleDeg = math.deg(math.atan2(diff.Y, diff.X))
									entry.TracerLine.Size = UDim2.new(0, dist, 0, 1.5)
									entry.TracerLine.Position = UDim2.new(0, mid.X, 0, mid.Y)
									entry.TracerLine.Rotation = angleDeg
									entry.TracerLine.Visible = true
								else
									entry.TracerLine.Visible = false
								end
							else
								entry.TracerLine.Visible = false
							end
						end)
					end
				else
					hidePlayerEspEntry(entry)
				end
			else
				hidePlayerEspEntry(entry)
			end
		end
	end

	for plr in pairs(espObjects) do
		if plr ~= LocalPlayer and (not plr.Parent or not Players:FindFirstChild(plr.Name)) then
			removePlayerEsp(plr)
		end
	end
end

local function updateFovVisual(camera)
	if isDestroyed then return end
	local vp = camera and camera.ViewportSize or Vector2.new(1280, 720)
	local center = Vector2.new(vp.X * 0.5, vp.Y * 0.5)

	if FovDrawing then
		pcall(function()
			FovDrawing.Position = center
			FovDrawing.Radius = AimbotConfig.FovRadius
			FovDrawing.Visible = AimbotConfig.ShowFov
		end)
		FovCircleGui.Visible = false
	else
		-- [FIX] ครอบ pcall assignment ของ fallback FOV circle
		pcall(function()
			local diameter = AimbotConfig.FovRadius * 2
			FovCircleGui.Size = UDim2.new(0, diameter, 0, diameter)
			FovCircleGui.Position = UDim2.new(0, center.X, 0, center.Y)
			FovCircleGui.Visible = AimbotConfig.ShowFov
		end)
	end
end

local function destroyAll()
	if isDestroyed then return end
	isDestroyed = true

	AimbotConfig.Enabled = false
	AimbotConfig.ShowFov = false
	EspConfig.Enabled = false
	EspConfig.ShowDistance = false
	EspConfig.ShowName = false
	EspConfig.ShowTracer = false
	SpeedConfig.Enabled = false
	SpeedConfig.JumpBoostEnabled = false

	resetMovementNow()
	clearAllEspVisuals()
	if FovDrawing then
		safeRemoveDrawing(FovDrawing)
		FovDrawing = nil
	end

	local snapshot = {}
	for _, conn in ipairs(activeConnections) do
		table.insert(snapshot, conn)
	end
	table.clear(activeConnections)

	for _, conn in ipairs(snapshot) do
		pcall(function()
			conn:Disconnect()
		end)
	end

	pcall(function()
		if ScreenGui then
			ScreenGui:Destroy()
		end
	end)
end

local function setHubVisible(visible)
	if isDestroyed then return end
	pcall(function()
		MainFrame.Visible = visible
		FloatingIcon.Visible = not visible
	end)
end

safeConnect(MinimizeBtn.MouseButton1Click, function()
	setHubVisible(false)
end)

safeConnect(CloseBtn.MouseButton1Click, function()
	destroyAll()
end)

safeConnect(Players.PlayerRemoving, function(plr)
	removePlayerEsp(plr)
end)

makeDraggable(TopBar, MainFrame)
makeDraggable(FloatingIcon, FloatingIcon, function()
	setHubVisible(true)
end)

-- ระบบต่อยอดเมนู
local HubAPI = {}

function HubAPI:AddSection(titleText)
	local header = Instance.new("TextLabel")
	header.Size = UDim2.new(1, -4, 0, 20)
	header.BackgroundTransparency = 1
	header.Text = tostring(titleText or "Section")
	header.TextColor3 = Color3.fromRGB(130, 220, 255)
	header.TextSize = 11
	header.Font = Enum.Font.GothamBold
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Parent = ContentFrame
	return header
end

function HubAPI:AddToggle(text, defaultState, callback)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, -4, 0, 32)
	btn.BackgroundColor3 = Color3.fromRGB(34, 38, 49)
	btn.Text = ""
	btn.AutoButtonColor = false
	btn.Parent = ContentFrame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 7)
	corner.Parent = btn

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -56, 1, 0)
	label.Position = UDim2.new(0, 10, 0, 0)
	label.BackgroundTransparency = 1
	label.Text = tostring(text or "Feature")
	label.TextColor3 = Color3.fromRGB(225, 230, 240)
	label.TextSize = 12
	label.Font = Enum.Font.GothamMedium
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = btn

	local state = defaultState == true
	local badge = Instance.new("TextLabel")
	badge.Size = UDim2.new(0, 40, 0, 20)
	badge.Position = UDim2.new(1, -46, 0.5, -10)
	badge.TextSize = 11
	badge.Font = Enum.Font.GothamBold
	badge.Parent = btn

	local bCorner = Instance.new("UICorner")
	bCorner.CornerRadius = UDim.new(0, 5)
	bCorner.Parent = badge

	local function refreshVisual()
		if state then
			badge.Text = "ON"
			badge.BackgroundColor3 = Color3.fromRGB(46, 160, 95)
			badge.TextColor3 = Color3.fromRGB(255, 255, 255)
		else
			badge.Text = "OFF"
			badge.BackgroundColor3 = Color3.fromRGB(60, 65, 80)
			badge.TextColor3 = Color3.fromRGB(190, 195, 210)
		end
	end

	refreshVisual()

	safeConnect(btn.MouseButton1Click, function()
		if isDestroyed then return end
		state = not state
		refreshVisual()
		if typeof(callback) == "function" then
			pcall(callback, state)
		end
	end)

	return {
		Set = function(_, newVal)
			state = newVal == true
			refreshVisual()
		end,
		Get = function()
			return state
		end
	}
end

function HubAPI:AddCycleButton(text, options, defaultOption, callback)
	local list = (type(options) == "table" and #options > 0) and options or { "Head", "HumanoidRootPart" }
	local currentIndex = 1
	for i, opt in ipairs(list) do
		if tostring(opt) == tostring(defaultOption) then
			currentIndex = i
			break
		end
	end

	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, -4, 0, 32)
	btn.BackgroundColor3 = Color3.fromRGB(34, 38, 49)
	btn.Text = ""
	btn.AutoButtonColor = false
	btn.Parent = ContentFrame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 7)
	corner.Parent = btn

  local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -96, 1, 0)
	label.Position = UDim2.new(0, 10, 0, 0)
	label.BackgroundTransparency = 1
	label.Text = tostring(text or "Option")
	label.TextColor3 = Color3.fromRGB(225, 230, 240)
	label.TextSize = 12
	label.Font = Enum.Font.GothamMedium
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = btn

	local pill = Instance.new("TextLabel")
	pill.Size = UDim2.new(0, 80, 0, 20)
	pill.Position = UDim2.new(1, -86, 0.5, -10)
	pill.BackgroundColor3 = Color3.fromRGB(48, 86, 130)
	pill.TextColor3 = Color3.fromRGB(220, 245, 255)
	pill.TextSize = 11
	pill.Font = Enum.Font.GothamBold
	pill.Parent = btn

	local pCorner = Instance.new("UICorner")
	pCorner.CornerRadius = UDim.new(0, 5)
	pCorner.Parent = pill

	local function refreshCycle()
		local val = tostring(list[currentIndex])
		pill.Text = (val == "HumanoidRootPart") and "HRP" or val
	end

	refreshCycle()

	safeConnect(btn.MouseButton1Click, function()
		if isDestroyed then return end
		currentIndex = (currentIndex % #list) + 1
		local selected = tostring(list[currentIndex])
		refreshCycle()
		if typeof(callback) == "function" then
			pcall(callback, selected)
		end
	end)

	return {
		Get = function()
			return tostring(list[currentIndex])
		end
	}
end

function HubAPI:AddNumberInput(text, defaultValue, minVal, maxVal, callback)
	local minNum = tonumber(minVal) or 16
	local maxNum = tonumber(maxVal) or 300

	local function clampValue(v)
		local n = tonumber(v)
		if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
		n = math.floor(n + 0.5)
		if n < minNum then n = minNum end
		if n > maxNum then n = maxNum end
		return n
	end

	local currentVal = clampValue(defaultValue) or minNum

	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -4, 0, 32)
	row.BackgroundColor3 = Color3.fromRGB(34, 38, 49)
	row.Parent = ContentFrame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 7)
	corner.Parent = row

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -82, 1, 0)
	label.Position = UDim2.new(0, 10, 0, 0)
	label.BackgroundTransparency = 1
	label.Text = tostring(text or "Value")
	label.TextColor3 = Color3.fromRGB(225, 230, 240)
	label.TextSize = 12
	label.Font = Enum.Font.GothamMedium
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row

	local box = Instance.new("TextBox")
	box.Size = UDim2.new(0, 64, 0, 22)
	box.Position = UDim2.new(1, -70, 0.5, -11)
	box.BackgroundColor3 = Color3.fromRGB(22, 25, 33)
	box.Text = tostring(currentVal)
	box.TextColor3 = Color3.fromRGB(130, 220, 255)
	box.TextSize = 12
	box.Font = Enum.Font.GothamBold
	box.ClearTextOnFocus = false
	box.Parent = row

	local boxCorner = Instance.new("UICorner")
	boxCorner.CornerRadius = UDim.new(0, 5)
	boxCorner.Parent = box

	local function applyInput()
		if isDestroyed then return end
		local parsed = clampValue(box.Text)
		if parsed ~= nil then
			currentVal = parsed
			pcall(function()
				box.Text = tostring(currentVal)
			end)
			if typeof(callback) == "function" then
				pcall(callback, currentVal)
			end
		else
			pcall(function()
				box.Text = tostring(currentVal)
			end)
		end
	end

	safeConnect(box.FocusLost, applyInput)
	safeConnect(box:GetPropertyChangedSignal("Text"), function()
		if isDestroyed then return end
		local parsed = clampValue(box.Text)
		if parsed ~= nil then
			currentVal = parsed
			if typeof(callback) == "function" then
				pcall(callback, currentVal)
			end
		end
	end)

	return {
		Set = function(_, newVal)
			local parsed = clampValue(newVal)
			if parsed ~= nil then
				currentVal = parsed
				pcall(function()
					box.Text = tostring(currentVal)
				end)
				if typeof(callback) == "function" then
					pcall(callback, currentVal)
				end
			end
		end,
		Get = function()
			return currentVal
		end
	}
end

local function getTargetPart(character)
	if not character or not character.Parent then return nil end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return nil end

	local preferredName = (AimbotConfig.TargetPart == "HumanoidRootPart") and "HumanoidRootPart" or "Head"
	local fallbackName = (preferredName == "Head") and "HumanoidRootPart" or "Head"

	local preferredPart = character:FindFirstChild(preferredName)
	if preferredPart and preferredPart:IsA("BasePart") then
		return preferredPart
	end

	local fallbackPart = character:FindFirstChild(fallbackName)
	if fallbackPart and fallbackPart:IsA("BasePart") then
		return fallbackPart
	end

	return nil
end

local function getClosestTargetInFov(camera)
	if not camera then return nil end
	local viewportSize = camera.ViewportSize
	local screenCenter = Vector2.new(viewportSize.X * 0.5, viewportSize.Y * 0.5)

	local closestPart = nil
	local bestScreenDist = AimbotConfig.FovRadius

	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LocalPlayer then
			local char = plr.Character
			local targetPart = getTargetPart(char)
			-- [FIX] เช็ค IsA("BasePart") ก่อนเข้าถึง .Position
			if targetPart and targetPart:IsA("BasePart") then
				local screenPos, onScreen = camera:WorldToViewportPoint(targetPart.Position)
				if onScreen and screenPos.Z > 0 then
					local pos2D = Vector2.new(screenPos.X, screenPos.Y)
					local distFromCenter = (pos2D - screenCenter).Magnitude
					if distFromCenter <= bestScreenDist then
						bestScreenDist = distFromCenter
						closestPart = targetPart
					end
				end
			end
		end
	end

	return closestPart
end

-- อัปเดต Aimbot และ ESP ทุกเฟรม
safeConnect(RunService.RenderStepped, function()
	if isDestroyed then return end
	local camera = Workspace.CurrentCamera
	if not camera then return end

	if AimbotConfig.ShowFov then
		updateFovVisual(camera)
	else
		if FovDrawing then
			pcall(function() FovDrawing.Visible = false end)
		end
		FovCircleGui.Visible = false
	end

	pcall(function()
		updateEsp(camera)
	end)

	if not AimbotConfig.Enabled then return end

	pcall(function()
		local targetPart = getClosestTargetInFov(camera)
		-- [FIX] กัน CFrame.new(eye, eye) ซึ่ง throw error เมื่อเป้าหมายอยู่ที่เดียวกับตำแหน่งกล้องเป๊ะ ๆ
		if targetPart and targetPart:IsA("BasePart") then
			local eyePos = camera.CFrame.Position
			if (targetPart.Position - eyePos).Magnitude > 0.1 then
				camera.CFrame = CFrame.new(eyePos, targetPart.Position)
			end
		end
	end)
end)

-- เมนูย่อย Aimbot (1.1, 1.2, 1.3)
HubAPI:AddSection("[ AIMBOT ]")

HubAPI:AddToggle("1.1 Aimbot", false, function(state)
	AimbotConfig.Enabled = state
end)

HubAPI:AddToggle("1.2 Show FOV", false, function(state)
	AimbotConfig.ShowFov = state
	updateFovVisual(Workspace.CurrentCamera)
end)

HubAPI:AddNumberInput("1.2 FOV Size (20-300)", AimbotConfig.FovRadius, 20, 300, function(val)
	AimbotConfig.FovRadius = val
	updateFovVisual(Workspace.CurrentCamera)
end)

HubAPI:AddCycleButton("1.3 Target Part", { "Head", "HumanoidRootPart" }, AimbotConfig.TargetPart, function(selected)
	AimbotConfig.TargetPart = selected
end)

-- เมนูย่อย ESP (3.1, 3.2, 3.3, 3.4)
HubAPI:AddSection("[ ESP ]")

HubAPI:AddToggle("3.1 ESP Box (Green)", false, function(state)
	EspConfig.Enabled = state
	if not state then
		for _, entry in pairs(espObjects) do
			hidePlayerEspEntry(entry)
		end
	end
end)

HubAPI:AddToggle("3.2 ESP Distance (m)", false, function(state)
	EspConfig.ShowDistance = state
end)

HubAPI:AddToggle("3.3 ESP Name", false, function(state)
	EspConfig.ShowName = state
end)

HubAPI:AddToggle("3.4 ESP Tracer", false, function(state)
	EspConfig.ShowTracer = state
end)

-- เมนูย่อย Speed (ปรับแล้วติดทันที ไม่รอเกิดใหม่)
HubAPI:AddSection("[ SPEED & MOVEMENT ]")

HubAPI:AddToggle("4.1 Speed Boost", false, function(state)
	SpeedConfig.Enabled = state
	applyWalkSpeedNow()
end)

HubAPI:AddNumberInput("4.2 WalkSpeed (16-250)", SpeedConfig.WalkSpeed, 16, 250, function(val)
	SpeedConfig.WalkSpeed = val
	if SpeedConfig.Enabled then
		applyWalkSpeedNow()
	end
end)

HubAPI:AddToggle("4.3 Jump Boost", false, function(state)
	SpeedConfig.JumpBoostEnabled = state
	applyJumpPowerNow()
end)

HubAPI:AddNumberInput("4.4 JumpPower (50-250)", SpeedConfig.JumpPower, 50, 250, function(val)
	SpeedConfig.JumpPower = val
	if SpeedConfig.JumpBoostEnabled then
		applyJumpPowerNow()
	end
end)
