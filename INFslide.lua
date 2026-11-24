-- // Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()

-- // Config
local Config = {
	SlideBoostEnabled = false,
	SlideOnly = true,            -- true = เฉพาะตอนสไลด์/หมอบ, false = ตอนเคลื่อนที่บนพื้น
	BoostForce = 45,             -- ความเร็วเป้าหมายตอนบูสต์ (10 - 85)
	MaxSlideSpeed = 85,          -- เพดานความเร็วสูงสุด
	HipDropThreshold = 0.12,     -- ระยะ HipHeight ที่ลดลงเพื่อถือว่าสไลด์/หมอบ
	SlideSpeedThreshold = 20,    -- ความเร็วแนวนอนขั้นต่ำหากแมพไม่ลด HipHeight ชัดเจน
	GraceWindow = 0.25,          -- เผื่อเวลาหลังสไลด์ (วินาที)
	SteerBlend = 0.45,           -- ความลื่นในการหักเลี้ยวตอนสไลด์ (0.05 - 1)
	SlideKeys = {                -- ปุ่มสไลด์/หมอบยอดนิยม (ปรับเพิ่มได้)
		Enum.KeyCode.C,
		Enum.KeyCode.LeftControl,
		Enum.KeyCode.LeftShift,
	},
}

-- [FIX 1] ตรวจช่วงค่า BoostForce ตอนโหลดสคริปต์กันผู้ใช้ตั้งค่าเกินช่วงใน Config
Config.BoostForce = math.clamp(math.floor(Config.BoostForce + 0.5), 10, Config.MaxSlideSpeed)

local Connections = {}
local CharConns = {}
local IsDestroyed = false

local BodyVelocityObj = nil
local LinearVelObj = nil
local VelAttachment = nil

local DefaultHipHeight = 2
local LastSlideTime = 0
local SmoothedDir = nil
local WasSliding = false
local SlideKeyHeld = false

local function AddConnection(conn)
	if conn then
		table.insert(Connections, conn)
	end
	return conn
end

local function AddCharConnection(conn)
	if conn then
		table.insert(CharConns, conn)
	end
	return conn
end

local function ClearCharConns()
	for _, c in ipairs(CharConns) do
		pcall(function()
			if c and c.Disconnect then
				c:Disconnect()
			end
		end)
	end
	table.clear(CharConns)
end

local function IsSlideKey(keyCode)
	for _, k in ipairs(Config.SlideKeys) do
		if k == keyCode then
			return true
		end
	end
	return false
end

AddConnection(UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if IsDestroyed or gameProcessed then return end
	if input.UserInputType == Enum.UserInputType.Keyboard and IsSlideKey(input.KeyCode) then
		SlideKeyHeld = true
	end
end))

AddConnection(UserInputService.InputEnded:Connect(function(input)
	if IsDestroyed then return end
	if input.UserInputType == Enum.UserInputType.Keyboard and IsSlideKey(input.KeyCode) then
		SlideKeyHeld = false
	end
end))

AddConnection(UserInputService.WindowFocused:Connect(function()
	SlideKeyHeld = false
end))

AddConnection(UserInputService.WindowFocusReleased:Connect(function()
	SlideKeyHeld = false
end))

local function SafeUnitXZ(vec)
	if typeof(vec) ~= "Vector3" then
		return nil, 0
	end
	local flat = Vector3.new(vec.X, 0, vec.Z)
	local mag = flat.Magnitude
	if mag <= 1e-4 then
		return nil, 0
	end
	return flat / mag, mag
end

local function GetCharParts()
	local char = LocalPlayer and LocalPlayer.Character
	if not char or not char.Parent then
		return nil, nil, nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or not root or not root.Parent or not root:IsDescendantOf(workspace) then
		return nil, nil, nil
	end
	return char, hum, root
end

local function ClearMover()
	SmoothedDir = nil
	WasSliding = false

	if LinearVelObj then
		local obj = LinearVelObj
		LinearVelObj = nil
		pcall(function()
			obj.Enabled = false
			obj:Destroy()
		end)
	end
	if VelAttachment then
		local att = VelAttachment
		VelAttachment = nil
		pcall(function()
			att:Destroy()
		end)
	end
	if BodyVelocityObj then
		local obj = BodyVelocityObj
		BodyVelocityObj = nil
		pcall(function()
			obj:Destroy()
		end)
	end
end

local function EnsureMover(root)
	if not root or not root:IsDescendantOf(workspace) then
		return nil, nil
	end

	if not VelAttachment or VelAttachment.Parent ~= root then
		if VelAttachment then
			pcall(function() VelAttachment:Destroy() end)
			VelAttachment = nil
		end
		local okAtt, att = pcall(function()
			local a = Instance.new("Attachment")
			a.Name = "SlideAssistAttachment"
			a.Parent = root
			return a
		end)
		VelAttachment = okAtt and att or nil
	end

	if VelAttachment then
		if LinearVelObj and LinearVelObj.Parent == root and LinearVelObj.Attachment0 == VelAttachment then
			LinearVelObj.Enabled = true
			return "LinearVelocity", LinearVelObj
		end
		if LinearVelObj then
			pcall(function() LinearVelObj:Destroy() end)
			LinearVelObj = nil
		end
		local okLv, lv = pcall(function()
			local v = Instance.new("LinearVelocity")
			v.Name = "SlideAssistLinearVel"
			v.Attachment0 = VelAttachment
			v.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
			v.ForceLimitMode = Enum.ForceLimitMode.PerAxis
			v.MaxAxesForce = Vector3.new(120000, 0, 120000)
			v.VectorVelocity = Vector3.zero
			v.Enabled = true
			v.Parent = root
			return v
		end)
		if okLv and lv then
			LinearVelObj = lv
			return "LinearVelocity", LinearVelObj
		end
	end

	-- [FIX 2] ก่อนสร้าง BodyVelocity fallback ต้องล้าง LinearVelocity เก่าที่ค้างอยู่ด้วย
	if LinearVelObj then
		pcall(function() LinearVelObj:Destroy() end)
		LinearVelObj = nil
	end

	if BodyVelocityObj and BodyVelocityObj.Parent == root then
		return "BodyVelocity", BodyVelocityObj
	end
	if BodyVelocityObj then
		pcall(function() BodyVelocityObj:Destroy() end)
	end

	local okBv, bv = pcall(function()
		local v = Instance.new("BodyVelocity")
		v.Name = "SlideAssistVelocity"
		v.MaxForce = Vector3.new(120000, 0, 120000)
		v.P = 7500
		v.Velocity = Vector3.zero
		v.Parent = root
		return v
	end)
	if okBv and bv then
		BodyVelocityObj = bv
		return "BodyVelocity", BodyVelocityObj
	end

	return nil, nil
end

local function ApplyBoostVelocity(root, dirUnit, speed)
	if not dirUnit or not speed or speed <= 0 then
		return
	end

	local mode, mover = EnsureMover(root)
	if not mode or not mover then
		return
	end

	local targetVel = Vector3.new(dirUnit.X * speed, 0, dirUnit.Z * speed)
	if mode == "LinearVelocity" then
		mover.VectorVelocity = targetVel
	elseif mode == "BodyVelocity" then
		mover.Velocity = targetVel
	end
end

local function ComputeDesiredDir(hum, root, dt)
	local moveUnit, moveMag = SafeUnitXZ(hum.MoveDirection)
	local velUnit, velMag = SafeUnitXZ(root.AssemblyLinearVelocity)

	local rawDir = nil
	if moveMag > 0.05 and velMag > 1 then
		local blend = math.clamp(Config.SteerBlend * math.clamp(dt * 60, 0.3, 2), 0.1, 1)
		local mixed = velUnit:Lerp(moveUnit, blend)
		rawDir = SafeUnitXZ(mixed) or moveUnit
	elseif moveMag > 0.05 then
		rawDir = moveUnit
	elseif velMag > 0.5 then
		rawDir = velUnit
	end

	if rawDir then
		if not SmoothedDir then
			SmoothedDir = rawDir
		else
			local sBlend = math.clamp(0.55 * math.clamp(dt * 60, 0.3, 2), 0.15, 1)
			SmoothedDir = SafeUnitXZ(SmoothedDir:Lerp(rawDir, sBlend)) or rawDir
		end
		return SmoothedDir
	end

	-- [FIX 3] ช่วงที่ไม่มีอินพุต/ความเร็วชั่วคราว ให้ใช้ทิศทางล่าสุดที่เก็บไว้
	-- แทนการคืนว่าไม่มีทิศทาง (เดิมทำให้ mover ถูกทำลาย/สร้างใหม่ทุกเฟรม)
	return SmoothedDir
end

-- ตรวจจับว่าผู้เล่นกำลังสไลด์หรือเคลื่อนที่บนพื้นหรือไม่
local function IsPlayerSliding(hum, root)
	if not hum or not root or hum.Health <= 0 then
		return false
	end

	local state = hum:GetState()
	if state == Enum.HumanoidStateType.Swimming
		or state == Enum.HumanoidStateType.Dead
		or state == Enum.HumanoidStateType.Seated
		or state == Enum.HumanoidStateType.Physics
		or state == Enum.HumanoidStateType.Climbing
		or state == Enum.HumanoidStateType.PlatformStanding
		or state == Enum.HumanoidStateType.Freefall
		or state == Enum.HumanoidStateType.Jumping then
		return false
	end

	if hum.FloorMaterial == Enum.Material.Air then
		return false
	end

	if math.abs(root.AssemblyLinearVelocity.Y) > 25 then
		return false
	end

	local now = os.clock()
	local _, moveMag = SafeUnitXZ(hum.MoveDirection)
	local _, velMag = SafeUnitXZ(root.AssemblyLinearVelocity)

	if not Config.SlideOnly then
		-- [FIX 4] โหมด ALL GROUND ต้องไม่บูสต์ตอน WalkSpeed = 0 (โดนสตัน/แช่แข็ง ฯลฯ)
		if hum.WalkSpeed <= 0 then
			return false
		end
		if moveMag < 0.05 and velMag < 4 then
			return false
		end
		LastSlideTime = now
		return true
	end

	local loweredHip = hum.HipHeight < (DefaultHipHeight - Config.HipDropThreshold)
	local highSpeedSlide = velMag >= Config.SlideSpeedThreshold
		and hum.WalkSpeed > 0
		and velMag > (hum.WalkSpeed * 1.15)
	local keySlide = SlideKeyHeld and (moveMag >= 0.05 or velMag >= 12)
	local recentSlideMomentum = (now - LastSlideTime) <= Config.GraceWindow
		and velMag >= (Config.SlideSpeedThreshold * 0.55)

	if (loweredHip or highSpeedSlide or keySlide or recentSlideMomentum)
		and (moveMag >= 0.05 or velMag >= (Config.SlideSpeedThreshold * 0.75)) then
		LastSlideTime = now
		return true
	end

	return false
end

-- อัปเดตค่า HipHeight ปกติเมื่อ Spawn
local function HookCharacter(char)
	ClearMover()
	ClearCharConns() -- [FIX 5] ตัด connection ของตัวละครเก่าตอนเกิดใหม่ กันค้างสะสม
	LastSlideTime = 0
	if not char then return end

	local hum = char:WaitForChild("Humanoid", 5)
	if hum then
		if hum.HipHeight > 0 and hum.HipHeight < 15 then
			DefaultHipHeight = hum.HipHeight
		else
			DefaultHipHeight = 2
		end

		AddCharConnection(hum:GetPropertyChangedSignal("HipHeight"):Connect(function()
			local st = hum:GetState()
			if hum.HipHeight > DefaultHipHeight and hum.HipHeight < 15
				and hum.FloorMaterial ~= Enum.Material.Air
				and st ~= Enum.HumanoidStateType.Freefall
				and st ~= Enum.HumanoidStateType.Jumping
				and st ~= Enum.HumanoidStateType.Swimming then
				DefaultHipHeight = hum.HipHeight
			end
		end))

		AddCharConnection(hum.StateChanged:Connect(function(_, newState)
			if newState == Enum.HumanoidStateType.Dead
				or newState == Enum.HumanoidStateType.Seated
				or newState == Enum.HumanoidStateType.Swimming
				or newState == Enum.HumanoidStateType.Climbing then
				LastSlideTime = 0
				ClearMover()
			end
		end))
	end
end

if LocalPlayer.Character then
	HookCharacter(LocalPlayer.Character)
end
AddConnection(LocalPlayer.CharacterAdded:Connect(HookCharacter))

-- // UI Parent
local GuiParent
local okGui = pcall(function()
	local test = Instance.new("ScreenGui")
	test.Parent = CoreGui
	test:Destroy()
	GuiParent = CoreGui
end)
if not okGui or not GuiParent then
	GuiParent = LocalPlayer:WaitForChild("PlayerGui")
end

if GuiParent:FindFirstChild("EvadeSlideHub") then
	pcall(function()
		GuiParent.EvadeSlideHub:Destroy()
	end)
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "EvadeSlideHub"
ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = true
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = GuiParent

local MainFrame = Instance.new("Frame")
MainFrame.Size = UDim2.new(0, 205, 0, 146)
MainFrame.Position = UDim2.new(0.5, -102, 0.32, 0)
MainFrame.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Parent = ScreenGui
Instance.new("UICorner", MainFrame).CornerRadius = UDim2.new(0, 8)

local TopBar = Instance.new("Frame")
TopBar.Size = UDim2.new(1, 0, 0, 26)
TopBar.BackgroundColor3 = Color3.fromRGB(32, 32, 42)
TopBar.BorderSizePixel = 0
TopBar.Active = true
TopBar.Parent = MainFrame
Instance.new("UICorner", TopBar).CornerRadius = UDim2.new(0, 8)

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -54, 1, 0)
Title.Position = UDim2.new(0, 8, 0, 0)
Title.BackgroundTransparency = 1
Title.Text = "Evade Slide Assist"
Title.TextColor3 = Color3.fromRGB(240, 240, 240)
Title.TextSize = 11
Title.Font = Enum.Font.GothamBold
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = TopBar

local MinBtn = Instance.new("TextButton")
MinBtn.Size = UDim2.new(0, 20, 0, 18)
MinBtn.Position = UDim2.new(1, -44, 0, 4)
MinBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 62)
MinBtn.Text = "-"
MinBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
MinBtn.TextSize = 13
MinBtn.Font = Enum.Font.GothamBold
MinBtn.Parent = TopBar
Instance.new("UICorner", MinBtn).CornerRadius = UDim2.new(0, 4)

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, 20, 0, 18)
CloseBtn.Position = UDim2.new(1, -22, 0, 4)
CloseBtn.BackgroundColor3 = Color3.fromRGB(185, 55, 55)
CloseBtn.Text = "X"
CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
CloseBtn.TextSize = 11
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.Parent = TopBar
Instance.new("UICorner", CloseBtn).CornerRadius = UDim2.new(0, 4)

local FloatBtn = Instance.new("TextButton")
FloatBtn.Size = UDim2.new(0, 40, 0, 40)
FloatBtn.Position = UDim2.new(0.06, 0, 0.3, 0)
FloatBtn.BackgroundColor3 = Color3.fromRGB(25, 25, 32)
FloatBtn.Text = "⚡"
FloatBtn.TextSize = 18
FloatBtn.Active = true
FloatBtn.Visible = false
FloatBtn.Parent = ScreenGui
Instance.new("UICorner", FloatBtn).CornerRadius = UDim2.new(1, 0)

-- ลากหน้าต่างรองรับทัชสกรีนและเมาส์ พร้อมคืนค่าว่ามีการลากจริงหรือไม่
-- [FIX 6] รองรับ ignoreTargets: กดบนปุ่มใน TopBar จะได้ไม่ลากหน้าต่าง
local function MakeDraggable(handle, target, ignoreTargets)
	local dragging = false
	local moved = false
	local activeInput = nil
	local dragStart = Vector3.zero
	local startPos = target.Position

	AddConnection(handle.InputBegan:Connect(function(input)
		if IsDestroyed then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if ignoreTargets and input.Target and table.find(ignoreTargets, input.Target) then
				return
			end
			dragging = true
			moved = false
			activeInput = input
			dragStart = input.Position
			startPos = target.Position
		end
	end))

	AddConnection(UserInputService.InputChanged:Connect(function(input)
		if IsDestroyed or not dragging then return end
		if activeInput and input ~= activeInput then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		local delta = input.Position - dragStart
		if delta.Magnitude > 6 then
			moved = true
		end
		target.Position = UDim2.new(
			startPos.X.Scale,
			startPos.X.Offset + delta.X,
			startPos.Y.Scale,
			startPos.Y.Offset + delta.Y
		)
	end))

	AddConnection(UserInputService.InputEnded:Connect(function(input)
		if input == activeInput or (not activeInput and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch)) then
			dragging = false
			activeInput = nil
		end
	end))

	return function()
		local wasMoved = moved
		moved = false
		return wasMoved
	end
end

MakeDraggable(TopBar, MainFrame, { MinBtn, CloseBtn })
local WasFloatBtnDragged = MakeDraggable(FloatBtn, FloatBtn)

-- แถวที่ 1: เปิด/ปิด Slide Boost
local ToggleRow = Instance.new("Frame")
ToggleRow.Size = UDim2.new(1, -14, 0, 26)
ToggleRow.Position = UDim2.new(0, 7, 0, 32)
ToggleRow.BackgroundColor3 = Color3.fromRGB(32, 32, 40)
ToggleRow.BorderSizePixel = 0
ToggleRow.Parent = MainFrame
Instance.new("UICorner", ToggleRow).CornerRadius = UDim2.new(0, 6)

local ToggleLabel = Instance.new("TextLabel")
ToggleLabel.Size = UDim2.new(1, -54, 1, 0)
ToggleLabel.Position = UDim2.new(0, 8, 0, 0)
ToggleLabel.BackgroundTransparency = 1
ToggleLabel.Text = "Slide Boost"
ToggleLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
ToggleLabel.TextSize = 11
ToggleLabel.Font = Enum.Font.Gotham
ToggleLabel.TextXAlignment = Enum.TextXAlignment.Left
ToggleLabel.Parent = ToggleRow

local ToggleBtn = Instance.new("TextButton")
ToggleBtn.Size = UDim2.new(0, 40, 0, 18)
ToggleBtn.Position = UDim2.new(1, -46, 0.5, -9)
ToggleBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 80)
ToggleBtn.Text = "OFF"
ToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
ToggleBtn.TextSize = 10
ToggleBtn.Font = Enum.Font.GothamBold
ToggleBtn.Parent = ToggleRow
Instance.new("UICorner", ToggleBtn).CornerRadius = UDim2.new(1, 0)

local function RefreshToggleUI()
	ToggleBtn.BackgroundColor3 = Config.SlideBoostEnabled and Color3.fromRGB(0, 190, 95) or Color3.fromRGB(70, 70, 80)
	ToggleBtn.Text = Config.SlideBoostEnabled and "ON" or "OFF"
	if not Config.SlideBoostEnabled then
		ClearMover()
	end
end

AddConnection(ToggleBtn.MouseButton1Click:Connect(function()
	if IsDestroyed then return end
	Config.SlideBoostEnabled = not Config.SlideBoostEnabled
	RefreshToggleUI()
end))

-- แถวที่ 2: โหมดตรวจจับ (Slide Only / Ground Move)
local ModeRow = Instance.new("Frame")
ModeRow.Size = UDim2.new(1, -14, 0, 26)
ModeRow.Position = UDim2.new(0, 7, 0, 62)
ModeRow.BackgroundColor3 = Color3.fromRGB(32, 32, 40)
ModeRow.BorderSizePixel = 0
ModeRow.Parent = MainFrame
Instance.new("UICorner", ModeRow).CornerRadius = UDim2.new(0, 6)

local ModeLabel = Instance.new("TextLabel")
ModeLabel.Size = UDim2.new(1, -78, 1, 0)
ModeLabel.Position = UDim2.new(0, 8, 0, 0)
ModeLabel.BackgroundTransparency = 1
ModeLabel.Text = "Detect Mode"
ModeLabel.TextColor3 = Color3.fromRGB(220, 220, 225)
ModeLabel.TextSize = 10
ModeLabel.Font = Enum.Font.Gotham
ModeLabel.TextXAlignment = Enum.TextXAlignment.Left
ModeLabel.Parent = ModeRow

local ModeBtn = Instance.new("TextButton")
ModeBtn.Size = UDim2.new(0, 68, 0, 18)
ModeBtn.Position = UDim2.new(1, -74, 0.5, -9)
ModeBtn.BackgroundColor3 = Color3.fromRGB(48, 58, 82)
ModeBtn.Text = Config.SlideOnly and "SLIDE ONLY" or "ALL GROUND"
ModeBtn.TextColor3 = Color3.fromRGB(160, 210, 255)
ModeBtn.TextSize = 9
ModeBtn.Font = Enum.Font.GothamBold
ModeBtn.Parent = ModeRow
Instance.new("UICorner", ModeBtn).CornerRadius = UDim2.new(0, 4)

AddConnection(ModeBtn.MouseButton1Click:Connect(function()
	if IsDestroyed then return end
	Config.SlideOnly = not Config.SlideOnly
	ModeBtn.Text = Config.SlideOnly and "SLIDE ONLY" or "ALL GROUND"
end))

-- แถวที่ 3: ปรับแรง Boost (10 - 85)
local ForceRow = Instance.new("Frame")
ForceRow.Size = UDim2.new(1, -14, 0, 26)
ForceRow.Position = UDim2.new(0, 7, 0, 92)
ForceRow.BackgroundColor3 = Color3.fromRGB(32, 32, 40)
ForceRow.BorderSizePixel = 0
ForceRow.Parent = MainFrame
Instance.new("UICorner", ForceRow).CornerRadius = UDim2.new(0, 6)

local ForceLabel = Instance.new("TextLabel")
ForceLabel.Size = UDim2.new(1, -60, 1, 0)
ForceLabel.Position = UDim2.new(0, 8, 0, 0)
ForceLabel.BackgroundTransparency = 1
ForceLabel.Text = "Boost (10-85)"
ForceLabel.TextColor3 = Color3.fromRGB(220, 220, 225)
ForceLabel.TextSize = 10
ForceLabel.Font = Enum.Font.Gotham
ForceLabel.TextXAlignment = Enum.TextXAlignment.Left
ForceLabel.Parent = ForceRow

local ForceBox = Instance.new("TextBox")
ForceBox.Size = UDim2.new(0, 46, 0, 20)
ForceBox.Position = UDim2.new(1, -52, 0.5, -10)
ForceBox.BackgroundColor3 = Color3.fromRGB(48, 48, 60)
ForceBox.Text = tostring(Config.BoostForce)
ForceBox.TextColor3 = Color3.fromRGB(0, 255, 130)
ForceBox.TextSize = 11
ForceBox.Font = Enum.Font.GothamBold
ForceBox.ClearTextOnFocus = false
ForceBox.Parent = ForceRow
Instance.new("UICorner", ForceBox).CornerRadius = UDim2.new(0, 4)

local function ApplyBoostValue()
	if IsDestroyed then return end
	local num = tonumber(ForceBox.Text)
	if num and num == num then
		Config.BoostForce = math.clamp(math.floor(num + 0.5), 10, Config.MaxSlideSpeed)
	end
	ForceBox.Text = tostring(Config.BoostForce)
end

AddConnection(ForceBox.FocusLost:Connect(function()
	ApplyBoostValue()
end))

-- [FIX 7] ซิงก์ UI กับ Config ตอนเปิดสคริปต์ครั้งแรก (สี/ข้อความปุ่ม ON-OFF และช่องตัวเลข)
RefreshToggleUI()
ForceBox.Text = tostring(Config.BoostForce)

-- ลูปอัปเดตแรงผลัก
AddConnection(RunService.Heartbeat:Connect(function(dt)
	if IsDestroyed then return end

	local _, hum, root = GetCharParts()
	if not hum or not root or hum.Health <= 0 then
		if WasSliding or LinearVelObj or BodyVelocityObj then
			ClearMover()
		end
		return
	end

	if not Config.SlideBoostEnabled then
		if WasSliding or LinearVelObj or BodyVelocityObj then
			ClearMover()
		end
		return
	end

	if IsPlayerSliding(hum, root) then
		local dirUnit = ComputeDesiredDir(hum, root, dt)
		if dirUnit then
			WasSliding = true
			local speed = math.clamp(Config.BoostForce, 10, Config.MaxSlideSpeed)
			ApplyBoostVelocity(root, dirUnit, speed)
		end
		-- [FIX 8] ไม่เรียก ClearMover() ในเฟรมที่ยังถือว่าสไลด์แต่ยังไม่มีทิศทางชั่วคราว
		-- เดิมทำลาย+สร้าง mover ใหม่ทุกเฟรม (กระชากความเร็ว/เปลืองทรัพยากร)
	elseif WasSliding or LinearVelObj or BodyVelocityObj then
		ClearMover()
	end
end))

AddConnection(MinBtn.MouseButton1Click:Connect(function()
	if IsDestroyed then return end
	MainFrame.Visible = false
	FloatBtn.Visible = true
end))

AddConnection(FloatBtn.MouseButton1Click:Connect(function()
	if IsDestroyed then return end
	if WasFloatBtnDragged() then return end
	FloatBtn.Visible = false
	MainFrame.Visible = true
end))

AddConnection(CloseBtn.MouseButton1Click:Connect(function()
	if IsDestroyed then return end
	IsDestroyed = true
	Config.SlideBoostEnabled = false
	SlideKeyHeld = false
	ClearMover()

	for _, conn in ipairs(Connections) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	table.clear(Connections)
	ClearCharConns()

	pcall(function()
		ScreenGui:Destroy()
	end)
end))
