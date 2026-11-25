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

-- ตรวจช่วงค่า BoostForce ตอนโหลดสคริปต์กันผู้ใช้ตั้งค่าเกินช่วงใน Config
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

-- UI references (ประกาศไว้ก่อน เพื่อกัน nil ถ้าส่วนสร้าง UI มี error บางส่วน)
local ScreenGui = nil
local MainFrame = nil
local ToggleBtn = nil
local ModeBtn = nil
local ForceBox = nil
local StatusLabel = nil
local FloatBtn = nil

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

-- [FIX หลัก] UICorner.CornerRadius เป็นชนิด UDim ห้ามใช้ UDim2
-- ห่อด้วย pcall เพื่อกัน error จุดเดียวที่ทำให้ UI ทั้งกรอบไม่ขึ้น
local function AddCorner(parent, scale, offset)
	if not parent then return nil end
	local ok, corner = pcall(function()
		local u = Instance.new("UICorner")
		u.CornerRadius = UDim.new(scale or 0, offset or 0)
		u.Parent = parent
		return u
	end)
	if ok then
		return corner
	end
	return nil
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

	-- ก่อนสร้าง BodyVelocity fallback ต้องล้าง LinearVelocity เก่าที่ค้างอยู่ด้วย
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

	-- ช่วงที่ไม่มีอินพุต/ความเร็วชั่วคราว ให้ใช้ทิศทางล่าสุดที่เก็บไว้
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
		-- โหมด ALL GROUND ต้องไม่บูสต์ตอน WalkSpeed = 0 (โดนสตัน/แช่แข็ง ฯลฯ)
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
	ClearCharConns() -- ตัด connection ของตัวละครเก่าตอนเกิดใหม่ กันค้างสะสม
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

-- // UI Parent: ลำดับปลอดภัย gethui() -> CoreGui -> PlayerGui
local GuiParent = nil
do
	local candidates = {}
	if typeof(gethui) == "function" then
		local ok, h = pcall(gethui)
		if ok and h then
			table.insert(candidates, h)
		end
	end
	table.insert(candidates, CoreGui)
	table.insert(candidates, LocalPlayer:WaitForChild("PlayerGui"))

	for _, cand in ipairs(candidates) do
		local ok = pcall(function()
			local test = Instance.new("ScreenGui")
			test.Parent = cand
			test:Destroy()
		end)
		if ok and cand then
			GuiParent = cand
			break
		end
	end
	if not GuiParent then
		GuiParent = LocalPlayer:WaitForChild("PlayerGui")
	end
end

if GuiParent:FindFirstChild("EvadeSlideHub") then
	pcall(function()
		GuiParent.EvadeSlideHub:Destroy()
	end)
end

-- สร้าง UI ทั้งหมดใน pcall; ถ้า error จะมี GUI แจ้งข้อความให้อ่านได้
local BuildOk, BuildErr = pcall(function()
	ScreenGui = Instance.new("ScreenGui")
	ScreenGui.Name = "EvadeSlideHub"
	ScreenGui.ResetOnSpawn = false
	ScreenGui.IgnoreGuiInset = true
	ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	ScreenGui.DisplayOrder = 999
	ScreenGui.Parent = GuiParent

	MainFrame = Instance.new("Frame")
	MainFrame.Name = "MainFrame"
	MainFrame.Size = UDim2.new(0, 210, 0, 150)
	MainFrame.Position = UDim2.new(0.5, -105, 0.32, 0)
	MainFrame.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
	MainFrame.BackgroundTransparency = 0
	MainFrame.BorderSizePixel = 0
	MainFrame.Active = true
	MainFrame.Visible = true
	MainFrame.ZIndex = 2
	MainFrame.Parent = ScreenGui
	AddCorner(MainFrame, 0, 8)

	local TopBar = Instance.new("Frame")
	TopBar.Name = "TopBar"
	TopBar.Size = UDim2.new(1, 0, 0, 26)
	TopBar.BackgroundColor3 = Color3.fromRGB(38, 38, 52)
	TopBar.BackgroundTransparency = 0
	TopBar.BorderSizePixel = 0
	TopBar.Active = true
	TopBar.Visible = true
	TopBar.ZIndex = 3
	TopBar.Parent = MainFrame
	AddCorner(TopBar, 0, 8)

	local Title = Instance.new("TextLabel")
	Title.Size = UDim2.new(1, -58, 1, 0)
	Title.Position = UDim2.new(0, 8, 0, 0)
	Title.BackgroundTransparency = 1
	Title.Visible = true
	Title.ZIndex = 4
	Title.Text = "Evade Slide Assist"
	Title.TextColor3 = Color3.fromRGB(245, 245, 245)
	Title.TextSize = 11
	Title.Font = Enum.Font.GothamBold
	Title.TextXAlignment = Enum.TextXAlignment.Left
	Title.Parent = TopBar

	local MinBtn = Instance.new("TextButton")
	MinBtn.Size = UDim2.new(0, 22, 0, 20)
	MinBtn.Position = UDim2.new(1, -48, 0.5, -10)
	MinBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 88)
	MinBtn.Visible = true
	MinBtn.ZIndex = 4
	MinBtn.Text = "-"
	MinBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	MinBtn.TextSize = 14
	MinBtn.Font = Enum.Font.GothamBold
	MinBtn.AutoButtonColor = true
	MinBtn.Parent = TopBar
	AddCorner(MinBtn, 0, 4)

	local CloseBtn = Instance.new("TextButton")
	CloseBtn.Size = UDim2.new(0, 22, 0, 20)
	CloseBtn.Position = UDim2.new(1, -24, 0.5, -10)
	CloseBtn.BackgroundColor3 = Color3.fromRGB(190, 60, 60)
	CloseBtn.Visible = true
	CloseBtn.ZIndex = 4
	CloseBtn.Text = "X"
	CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	CloseBtn.TextSize = 11
	CloseBtn.Font = Enum.Font.GothamBold
	CloseBtn.AutoButtonColor = true
	CloseBtn.Parent = TopBar
	AddCorner(CloseBtn, 0, 4)

	FloatBtn = Instance.new("TextButton")
	FloatBtn.Size = UDim2.new(0, 44, 0, 44)
	FloatBtn.Position = UDim2.new(0.06, 0, 0.3, 0)
	FloatBtn.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
	FloatBtn.Text = "⚡"
	FloatBtn.TextColor3 = Color3.fromRGB(255, 230, 120)
	FloatBtn.TextSize = 20
	FloatBtn.AutoButtonColor = true
	FloatBtn.Active = true
	FloatBtn.Visible = false
	FloatBtn.ZIndex = 5
	FloatBtn.Parent = ScreenGui
	AddCorner(FloatBtn, 1, 0)

	-- ลากหน้าต่าง รองรับทัชสกรีน/เมาส์ และไม่ลากเมื่อกดบนปุ่ม Min/Close
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
			if input == activeInput or (not activeInput and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType.Touch)) then
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
	ToggleRow.BackgroundColor3 = Color3.fromRGB(36, 36, 46)
	ToggleRow.BorderSizePixel = 0
	ToggleRow.ZIndex = 3
	ToggleRow.Parent = MainFrame
	AddCorner(ToggleRow, 0, 6)

	local ToggleLabel = Instance.new("TextLabel")
	ToggleLabel.Size = UDim2.new(1, -54, 1, 0)
	ToggleLabel.Position = UDim2.new(0, 8, 0, 0)
	ToggleLabel.BackgroundTransparency = 1
	ToggleLabel.Visible = true
	ToggleLabel.ZIndex = 4
	ToggleLabel.Text = "Slide Boost"
	ToggleLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
	ToggleLabel.TextSize = 11
	ToggleLabel.Font = Enum.Font.Gotham
	ToggleLabel.TextXAlignment = Enum.TextXAlignment.Left
	ToggleLabel.Parent = ToggleRow

	ToggleBtn = Instance.new("TextButton")
	ToggleBtn.Size = UDim2.new(0, 42, 0, 18)
	ToggleBtn.Position = UDim2.new(1, -48, 0.5, -9)
	ToggleBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 80)
	ToggleBtn.Visible = true
	ToggleBtn.ZIndex = 4
	ToggleBtn.Text = "OFF"
	ToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	ToggleBtn.TextSize = 10
	ToggleBtn.Font = Enum.Font.GothamBold
	ToggleBtn.AutoButtonColor = true
	ToggleBtn.Parent = ToggleRow
	AddCorner(ToggleBtn, 1, 0)

	local function RefreshToggleUI()
		if not ToggleBtn then return end
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

	-- แถวที่ 2: โหมดตรวจจับ
	local ModeRow = Instance.new("Frame")
	ModeRow.Size = UDim2.new(1, -14, 0, 26)
	ModeRow.Position = UDim2.new(0, 7, 0, 62)
	ModeRow.BackgroundColor3 = Color3.fromRGB(36, 36, 46)
	ModeRow.BorderSizePixel = 0
	ModeRow.ZIndex = 3
	ModeRow.Parent = MainFrame
	AddCorner(ModeRow, 0, 6)

	local ModeLabel = Instance.new("TextLabel")
	ModeLabel.Size = UDim2.new(1, -78, 1, 0)
	ModeLabel.Position = UDim2.new(0, 8, 0, 0)
	ModeLabel.BackgroundTransparency = 1
	ModeLabel.Visible = true
	ModeLabel.ZIndex = 4
	ModeLabel.Text = "Detect Mode"
	ModeLabel.TextColor3 = Color3.fromRGB(220, 220, 225)
	ModeLabel.TextSize = 10
	ModeLabel.Font = Enum.Font.Gotham
	ModeLabel.TextXAlignment = Enum.TextXAlignment.Left
	ModeLabel.Parent = ModeRow

	ModeBtn = Instance.new("TextButton")
	ModeBtn.Size = UDim2.new(0, 70, 0, 18)
	ModeBtn.Position = UDim2.new(1, -76, 0.5, -9)
	ModeBtn.BackgroundColor3 = Color3.fromRGB(48, 58, 82)
	ModeBtn.Visible = true
	ModeBtn.ZIndex = 4
	ModeBtn.Text = Config.SlideOnly and "SLIDE ONLY" or "ALL GROUND"
	ModeBtn.TextColor3 = Color3.fromRGB(160, 210, 255)
	ModeBtn.TextSize = 9
	ModeBtn.Font = Enum.Font.GothamBold
	ModeBtn.AutoButtonColor = true
	ModeBtn.Parent = ModeRow
	AddCorner(ModeBtn, 0, 4)

	AddConnection(ModeBtn.MouseButton1Click:Connect(function()
		if IsDestroyed then return end
		Config.SlideOnly = not Config.SlideOnly
		ModeBtn.Text = Config.SlideOnly and "SLIDE ONLY" or "ALL GROUND"
	end))

	-- แถวที่ 3: ปรับแรง Boost (10 - 85)
	local ForceRow = Instance.new("Frame")
	ForceRow.Size = UDim2.new(1, -14, 0, 26)
	ForceRow.Position = UDim2.new(0, 7, 0, 92)
	ForceRow.BackgroundColor3 = Color3.fromRGB(36, 36, 46)
	ForceRow.BorderSizePixel = 0
	ForceRow.ZIndex = 3
	ForceRow.Parent = MainFrame
	AddCorner(ForceRow, 0, 6)

	local ForceLabel = Instance.new("TextLabel")
	ForceLabel.Size = UDim2.new(1, -60, 1, 0)
	ForceLabel.Position = UDim2.new(0, 8, 0, 0)
	ForceLabel.BackgroundTransparency = 1
	ForceLabel.Visible = true
	ForceLabel.ZIndex = 4
	ForceLabel.Text = "Boost (10-85)"
	ForceLabel.TextColor3 = Color3.fromRGB(220, 220, 225)
	ForceLabel.TextSize = 10
	ForceLabel.Font = Enum.Font.Gotham
	ForceLabel.TextXAlignment = Enum.TextXAlignment.Left
	ForceLabel.Parent = ForceRow

	ForceBox = Instance.new("TextBox")
	ForceBox.Size = UDim2.new(0, 48, 0, 20)
	ForceBox.Position = UDim2.new(1, -54, 0.5, -10)
	ForceBox.BackgroundColor3 = Color3.fromRGB(48, 48, 60)
	ForceBox.Visible = true
	ForceBox.ZIndex = 4
	ForceBox.Text = tostring(Config.BoostForce)
	ForceBox.TextColor3 = Color3.fromRGB(0, 255, 130)
	ForceBox.TextSize = 11
	ForceBox.Font = Enum.Font.GothamBold
	ForceBox.ClearTextOnFocus = false
	ForceBox.Parent = ForceRow
	AddCorner(ForceBox, 0, 4)

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

	-- แถวที่ 4: สถานะสด ดูว่าใช้งานได้จริงไหม
	local StatusRow = Instance.new("Frame")
	StatusRow.Size = UDim2.new(1, -14, 0, 20)
	StatusRow.Position = UDim2.new(0, 7, 0, 121)
	StatusRow.BackgroundColor3 = Color3.fromRGB(28, 28, 38)
	StatusRow.BorderSizePixel = 0
	StatusRow.ZIndex = 3
	StatusRow.Parent = MainFrame
	AddCorner(StatusRow, 0, 4)

	StatusLabel = Instance.new("TextLabel")
	StatusLabel.Size = UDim2.new(1, -12, 1, 0)
	StatusLabel.Position = UDim2.new(0, 6, 0, 0)
	StatusLabel.BackgroundTransparency = 1
	StatusLabel.Visible = true
	StatusLabel.ZIndex = 4
	StatusLabel.Text = "OFF"
	StatusLabel.TextColor3 = Color3.fromRGB(150, 150, 155)
	StatusLabel.TextSize = 10
	StatusLabel.Font = Enum.Font.GothamMedium
	StatusLabel.TextXAlignment = Enum.TextXAlignment.Left
	StatusLabel.Parent = StatusRow

	-- ซิงก์ UI กับ Config ตอนเปิดสคริปต์ครั้งแรก
	RefreshToggleUI()
	ForceBox.Text = tostring(Config.BoostForce)

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
			if ScreenGui then ScreenGui:Destroy() end
		end)
	end))
end)

-- ถ้าสร้าง UI หลักไม่ขึ้นจริง สร้างกล่อง error เล็กๆ ให้เห็นข้อความในเกม
if not BuildOk then
	local fb = Instance.new("ScreenGui")
	fb.Name = "EvadeSlideHubErr"
	fb.ResetOnSpawn = false
	fb.DisplayOrder = 1000
	fb.Parent = GuiParent
	local box = Instance.new("TextLabel")
	box.Size = UDim2.new(0, 320, 0, 90)
	box.Position = UDim2.new(0.5, -160, 0.5, -45)
	box.BackgroundColor3 = Color3.fromRGB(30, 20, 20)
	box.TextColor3 = Color3.fromRGB(255, 90, 90)
	box.TextSize = 11
	box.Font = Enum.Font.Gotham
	box.TextWrapped = true
	box.Text = "UI Build Error: " .. tostring(BuildErr)
	box.Parent = fb
end

-- ลูปอัปเดตแรงผลัก + สถานะบน UI
AddConnection(RunService.Heartbeat:Connect(function(dt)
	if IsDestroyed then return end

	local _, hum, root = GetCharParts()
	if not hum or not root or hum.Health <= 0 then
		if WasSliding or LinearVelObj or BodyVelocityObj then
			ClearMover()
		end
		if StatusLabel then
			StatusLabel.Text = "รอตัวละครเกิด..."
			StatusLabel.TextColor3 = Color3.fromRGB(255, 200, 100)
		end
		return
	end

	if not Config.SlideBoostEnabled then
		if WasSliding or LinearVelObj or BodyVelocityObj then
			ClearMover()
		end
		if StatusLabel then
			StatusLabel.Text = "OFF · กดปุ่ม ON เพื่อเปิดใช้"
			StatusLabel.TextColor3 = Color3.fromRGB(150, 150, 155)
		end
		return
	end

	local sliding = IsPlayerSliding(hum, root)
	if sliding then
		local dirUnit = ComputeDesiredDir(hum, root, dt)
		if dirUnit then
			WasSliding = true
			local speed = math.clamp(Config.BoostForce, 10, Config.MaxSlideSpeed)
			ApplyBoostVelocity(root, dirUnit, speed)
		end
	elseif WasSliding or LinearVelObj or BodyVelocityObj then
		ClearMover()
	end

	if StatusLabel then
		if sliding then
			StatusLabel.Text = "ON · กำลังสไลด์บูสต์ (" .. tostring(Config.BoostForce) .. ")"
			StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 140)
		else
			StatusLabel.Text = "ON · พร้อมใช้ (รอสไลด์/หมอบ)"
			StatusLabel.TextColor3 = Color3.fromRGB(160, 210, 255)
		end
	end
end))
