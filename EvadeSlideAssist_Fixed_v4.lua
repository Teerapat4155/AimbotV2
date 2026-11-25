-- // Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()

-- // Config
local Config = {
	-- เดิม: Slide Boost
	SlideBoostEnabled = false,
	SlideOnly = true,
	BoostForce = 45,
	MaxSlideSpeed = 85,
	HipDropThreshold = 0.12,
	SlideSpeedThreshold = 20,
	GraceWindow = 0.25,
	SteerBlend = 0.45,
	SlideKeys = {
		Enum.KeyCode.C,
		Enum.KeyCode.LeftControl,
		Enum.KeyCode.LeftShift,
	},

	-- [ใหม่] Infinite Jump
	InfiniteJump = false,

	-- [ใหม่] วาปหนีบอทอัตโนมัติ
	AutoFlee = false,
	FleeDistance = 28,        -- ระยะ (studs ≈ เมตร) ที่บอทเข้ามาแล้วจะวาฬหนี
	FleeTeleportRange = 85,   -- ระยะที่วาฬหนีออกไปไกลแค่ไหน
	FleeCooldown = 0.7,       -- กันวาฬถี่เกินไป (วินาที)

	-- [ใหม่] วาฬขึ้นฟ้า AFK ฟาร์ม
	SkyAFK = false,
	SkyHeight = 420,          -- ความสูงเหนือตำแหน่งปัจจุบัน (studs)
}

Config.BoostForce = math.clamp(math.floor(Config.BoostForce + 0.5), 10, Config.MaxSlideSpeed)
Config.FleeDistance = math.clamp(math.floor(Config.FleeDistance + 0.5), 10, 300)

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

-- [ใหม่] ตัวแปลบอท / วาฬหนี / ฟ้า
local BotParts = {}
local ScanAccum = 0
local LastFleeTime = 0
local SkyPos = nil

-- UI references
local ScreenGui = nil
local MainFrame = nil
local ToggleBtn = nil
local ModeBtn = nil
local ForceBox = nil
local FleeBox = nil
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

-- UICorner.CornerRadius เป็นชนิด UDim ห้ามใช้ UDim2; ห่อ pcall กัน error จุดเดียวดับทั้ง UI
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

-- [ใหม่] Infinite Jump: แตะกระโดดกลางอากาศได้เรื่อยๆ
AddConnection(UserInputService.JumpRequest:Connect(function()
	if IsDestroyed or not Config.InfiniteJump then return end
	local _, hum, root = GetCharParts()
	if hum and root and hum.Health > 0 and hum.FloorMaterial == Enum.Material.Air then
		pcall(function()
			hum.Jump = true
		end)
	end
end))

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

	return SmoothedDir
end

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

-- // [ใหม่] ระบบบอท: เก็บตำแหน่งส่วนของบอททุกตัวในแมพ
local function RefreshBots()
	BotParts = {}
	for _, obj in ipairs(workspace:GetDescendants()) do
		if obj:IsA("Model") and not Players:GetPlayerFromCharacter(obj) then
			local part = obj.PrimaryPart
			if not part then
				part = obj:FindFirstChild("Head") or obj:FindFirstChild("HumanoidRootPart")
			end
			if not part then
				part = obj:FindFirstChildWhichIsA("BasePart")
			end
			if part and part:IsA("BasePart") and part.Transparency < 1 then
				table.insert(BotParts, part)
			end
		end
	end
end

local function GetNearestBot(root)
	local bestPart, bestDist
	for _, part in ipairs(BotParts) do
		if part and part.Parent and part:IsDescendantOf(workspace) then
			local okPos, pos = pcall(function() return part.Position end)
			if okPos then
				local d = (pos - root.Position).Magnitude
				if not bestDist or d < bestDist then
					bestDist = d
					bestPart = part
				end
			end
		end
	end
	return bestPart, bestDist
end

-- วาปหนี: ย้ายผู้เล่นออกไปทิศตรงข้ามกับบอท
local function DoFlee(root, botPart)
	if not root or not botPart then return end
	pcall(function()
		local away = root.Position - botPart.Position
		away = Vector3.new(away.X, 0, away.Z)
		if away.Magnitude < 1e-3 then
			away = root.CFrame.LookVector * -1
		end
		away = away.Unit
		local target = root.Position + away * Config.FleeTeleportRange
		target = Vector3.new(target.X, root.Position.Y, target.Z)
		root.CFrame = CFrame.new(target)
	end)
	LastFleeTime = os.clock()
end

-- // [ใหม่] โหมดฟาร์มบนฟ้า
local function ApplySky(root)
	if not root then return end
	pcall(function()
		if not SkyPos then
			SkyPos = root.Position + Vector3.new(0, Config.SkyHeight, 0)
		end
		root.Anchored = true
		root.CFrame = CFrame.new(SkyPos)
	end)
end

local function ReleaseSky(root)
	SkyPos = nil
	if root then
		pcall(function()
			root.Anchored = false
		end)
	end
end

-- อัปเดตค่า HipHeight ปกติเมื่อ Spawn
local function HookCharacter(char)
	ClearMover()
	ClearCharConns()
	ReleaseSky(nil)
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

-- // UI Parent: gethui() -> CoreGui -> PlayerGui
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
	MainFrame.Size = UDim2.new(0, 214, 0, 276)
	MainFrame.Position = UDim2.new(0.5, -107, 0.28, 0)
	MainFrame.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
	MainFrame.BackgroundTransparency = 0
	MainFrame.BorderSizePixel = 0
	MainFrame.Active = true
	MainFrame.Visible = true
	MainFrame.ZIndex = 2
	MainFrame.Parent = ScreenGui
	AddCorner(MainFrame, 0, 8)

	local TopBar = Instance.new("Frame")
	TopBar.Size = UDim2.new(1, 0, 0, 26)
	TopBar.BackgroundColor3 = Color3.fromRGB(38, 38, 52)
	TopBar.BorderSizePixel = 0
	TopBar.Active = true
	TopBar.ZIndex = 3
	TopBar.Parent = MainFrame
	AddCorner(TopBar, 0, 8)

	local Title = Instance.new("TextLabel")
	Title.Size = UDim2.new(1, -58, 1, 0)
	Title.Position = UDim2.new(0, 8, 0, 0)
	Title.BackgroundTransparency = 1
	Title.ZIndex = 4
	Title.Text = "Evade Hub"
	Title.TextColor3 = Color3.fromRGB(245, 245, 245)
	Title.TextSize = 12
	Title.Font = Enum.Font.GothamBold
	Title.TextXAlignment = Enum.TextXAlignment.Left
	Title.Parent = TopBar

	local MinBtn = Instance.new("TextButton")
	MinBtn.Size = UDim2.new(0, 22, 0, 20)
	MinBtn.Position = UDim2.new(1, -48, 0.5, -10)
	MinBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 88)
	MinBtn.ZIndex = 4
	MinBtn.Text = "-"
	MinBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	MinBtn.TextSize = 14
	MinBtn.Font = Enum.Font.GothamBold
	MinBtn.Parent = TopBar
	AddCorner(MinBtn, 0, 4)

	local CloseBtn = Instance.new("TextButton")
	CloseBtn.Size = UDim2.new(0, 22, 0, 20)
	CloseBtn.Position = UDim2.new(1, -24, 0.5, -10)
	CloseBtn.BackgroundColor3 = Color3.fromRGB(190, 60, 60)
	CloseBtn.ZIndex = 4
	CloseBtn.Text = "X"
	CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	CloseBtn.TextSize = 11
	CloseBtn.Font = Enum.Font.GothamBold
	CloseBtn.Parent = TopBar
	AddCorner(CloseBtn, 0, 4)

	FloatBtn = Instance.new("TextButton")
	FloatBtn.Size = UDim2.new(0, 44, 0, 44)
	FloatBtn.Position = UDim2.new(0.06, 0, 0.3, 0)
	FloatBtn.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
	FloatBtn.Text = "⚡"
	FloatBtn.TextColor3 = Color3.fromRGB(255, 230, 120)
	FloatBtn.TextSize = 20
	FloatBtn.Active = true
	FloatBtn.Visible = false
	FloatBtn.ZIndex = 5
	FloatBtn.Parent = ScreenGui
	AddCorner(FloatBtn, 1, 0)

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

	-- ช่วยสร้างแถวปุ่ม ON/OFF ทั่วไป
	local function CreateToggleRow(y, labelText, cfgKey, accentColor)
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -14, 0, 26)
		row.Position = UDim2.new(0, 7, 0, y)
		row.BackgroundColor3 = Color3.fromRGB(36, 36, 46)
		row.BorderSizePixel = 0
		row.ZIndex = 3
		row.Parent = MainFrame
		AddCorner(row, 0, 6)

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, -54, 1, 0)
		label.Position = UDim2.new(0, 8, 0, 0)
		label.BackgroundTransparency = 1
		label.ZIndex = 4
		label.Text = labelText
		label.TextColor3 = Color3.fromRGB(235, 235, 235)
		label.TextSize = 11
		label.Font = Enum.Font.Gotham
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = row

		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(0, 42, 0, 18)
		btn.Position = UDim2.new(1, -48, 0.5, -9)
		btn.BackgroundColor3 = Color3.fromRGB(70, 70, 80)
		btn.ZIndex = 4
		btn.Text = "OFF"
		btn.TextColor3 = Color3.fromRGB(255, 255, 255)
		btn.TextSize = 10
		btn.Font = Enum.Font.GothamBold
		btn.AutoButtonColor = true
		btn.Parent = row
		AddCorner(btn, 1, 0)

		local refresh = function()
			btn.BackgroundColor3 = Config[cfgKey] and (accentColor or Color3.fromRGB(0, 190, 95)) or Color3.fromRGB(70, 70, 80)
			btn.Text = Config[cfgKey] and "ON" or "OFF"
		end

		AddConnection(btn.MouseButton1Click:Connect(function()
			if IsDestroyed then return end
			Config[cfgKey] = not Config[cfgKey]
			refresh()
			if cfgKey == "SkyAFK" then
				local _, _, root = GetCharParts()
				if Config.SkyAFK then
					SkyPos = nil
				else
					ReleaseSky(root)
				end
			end
			if cfgKey == "AutoFlee" and not Config.AutoFlee then
				LastFleeTime = 0
			end
		end))

		refresh()
		return row, btn
	end

	-- แถว 1: Slide Boost
	local _, BoostBtn = CreateToggleRow(32, "Slide Boost", "SlideBoostEnabled", Color3.fromRGB(0, 190, 95))
	ToggleBtn = BoostBtn

	-- แถว 2: โหมดตรวจจับ
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
	Mo
