-- // Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")
local Debris = game:GetService("Debris")

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()

-- // Config
local Config = {
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

	InfiniteJump = false,

	AutoFlee = false,
	FleeDistance = 28,
	FleeTeleportRange = 85,
	FleeCooldown = 0.7,

	SkyAFK = false,
	SkyHeight = 420,
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

local BotParts = {}
local ScanAccum = 0
local LastFleeTime = 0
local SkyPos = nil
local InfJumpCd = 0

local ScreenGui = nil
local MainFrame = nil
local ToggleBtn = nil
local ModeBtn = nil
local ForceBox = nil
local FleeBox = nil
local StatusLabel = nil
local FloatBtn = nil

-- // ป้ายวินิจฉัย: สร้างก่อนใครเสมอใน PlayerGui ถ้าเมนูใหญ่ไม่ขึ้น ป้ายนี้จะบอกว่ารันไปถึงไหน
local DiagGui = nil
local DiagLabel = nil
do
	local okPg, pg = pcall(function() return LocalPlayer:WaitForChild("PlayerGui") end)
	if okPg and pg then
		local okG, g = pcall(function()
			local sg = Instance.new("ScreenGui")
			sg.Name = "EvadeDiag"
			sg.ResetOnSpawn = false
			sg.DisplayOrder = 1002
			sg.Enabled = true
			return sg
		end)
		if okG and g then
			DiagGui = g
			local okL, lbl = pcall(function()
				local t = Instance.new("TextLabel")
				t.Size = UDim2.new(0, 300, 0, 56)
				t.Position = UDim2.new(0.5, -150, 0.05, 0)
				t.BackgroundColor3 = Color3.fromRGB(24, 24, 32)
				t.BackgroundTransparency = 0.15
				t.TextColor3 = Color3.fromRGB(130, 255, 170)
				t.TextSize = 11
				t.Font = Enum.Font.Gotham
				t.TextWrapped = true
				t.Text = "Evade Hub: กำลังโหลด..."
				t.Parent = g
				return t
			end)
			if okL and lbl then
				DiagLabel = lbl
			end
			pcall(function() g.Parent = pg end)
		end
	end
end

local function Diag(msg)
	if DiagLabel and DiagLabel.Parent then
		DiagLabel.Text = tostring(msg)
	end
end

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

pcall(function()
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
end)

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

-- Infinite Jump: hum.Jump ใช้ได้แค่ตอนแตะพื้น กลางอากาศต้องยิงแรงดัน Y เอง
local function AirJump(root, hum)
	if not root or not hum then return end
	local power = tonumber(hum.JumpPower) or 50
	if power < 30 then
		power = 50
	end
	pcall(function()
		local imp = Instance.new("BodyVelocity")
		imp.Name = "InfJumpImpulse"
		imp.MaxForce = Vector3.new(0, 80000, 0)
		imp.P = 20000
		imp.Velocity = Vector3.new(root.AssemblyLinearVelocity.X, power, root.AssemblyLinearVelocity.Z)
		imp.Parent = root
		Debris:AddItem(imp, 0.18)
	end)
end

-- Infinite Jump: แตะกระโดดกลางอากาศยิงแรงดันขึ้น; แตะพื้นยังคงกระโดดปกติ
pcall(function()
	AddConnection(UserInputService.JumpRequest:Connect(function()
		if IsDestroyed or not Config.InfiniteJump then return end
		local _, hum, root = GetCharParts()
		if not hum or not root or hum.Health <= 0 then return end
		InfJumpCd = 0
		if hum.FloorMaterial == Enum.Material.Air or hum:GetState() == Enum.HumanoidStateType.Freefall then
			AirJump(root, hum)
		else
			pcall(function() hum.Jump = true end)
		end
	end))
end)

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
		pcall(function() att:Destroy() end)
	end
	if BodyVelocityObj then
		local obj = BodyVelocityObj
		BodyVelocityObj = nil
		pcall(function() obj:Destroy() end)
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

-- // บอท
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

-- // ฟ้า
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
		pcall(function() root.Anchored = false end)
	end
end

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
	pcall(HookCharacter, LocalPlayer.Character)
end
pcall(function()
	AddConnection(LocalPlayer.CharacterAdded:Connect(HookCharacter))
end)

-- // เลือกที่ GUI: CoreGui ก่อน ถ้าไม่ได้ค่อย PlayerGui (ไม่ใช้ gethui ที่อาจเป็นกล่องลึกมองไม่เห็น)
local GuiParent = nil
do
	local okPg, pg = pcall(function() return LocalPlayer:WaitForChild("PlayerGui") end)
	local okCore = pcall(function()
		local test = Instance.new("ScreenGui")
		test.Parent = CoreGui
		test:Destroy()
	end)
	if okCore then
		GuiParent = CoreGui
	end
	if not GuiParent and okPg and pg then
		GuiParent = pg
	end
	if not GuiParent and okPg and pg then
		GuiParent = pg
	end
end

if GuiParent then
	pcall(function()
		local old = GuiParent:FindFirstChild("EvadeSlideHub")
		if old then old:Destroy() end
	end)
end

local BuildOk, BuildErr = pcall(function()
	ScreenGui = Instance.new("ScreenGui")
	ScreenGui.Name = "EvadeSlideHub"
	ScreenGui.ResetOnSpawn = false
	ScreenGui.IgnoreGuiInset = true
	ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	ScreenGui.DisplayOrder = 999
	ScreenGui.Enabled = true
	pcall(function() ScreenGui.Parent = GuiParent end)
	if not ScreenGui.Parent then
		local okPg, pg = pcall(function() return LocalPlayer:WaitForChild("PlayerGui") end)
		if okPg and pg then ScreenGui.Parent = pg end
	end

	MainFrame = Instance.new("Frame")
	MainFrame.Name = "MainFrame"
	MainFrame.Size = UDim2.new(0, 214, 0, 276)
	MainFrame.Position = UDim2.new(0.5, -107, 0.28, 0)
	MainFrame.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
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
	MinBtn.Visible = true
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
	CloseBtn.Visible = true
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
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y
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

	local _, BoostBtn = CreateToggleRow(32, "Slide Boost", "SlideBoostEnabled", Color3.fromRGB(0, 190, 95))
	ToggleBtn = BoostBtn

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
	ModeBtn.ZIndex = 4
	ModeBtn.Text = Config.SlideOnly and "SLIDE ONLY" or "ALL GROUND"
	ModeBtn.TextColor3 = Color3.fromRGB(160, 210, 255)
	ModeBtn.TextSize = 9
	ModeBtn.Font = Enum.Font.GothamBold
	ModeBtn.Parent = ModeRow
	AddCorner(ModeBtn, 0, 4)

	AddConnection(ModeBtn.MouseButton1Click:Connect(function()
		if IsDestroyed then return end
		Config.SlideOnly = not Config.SlideOnly
		ModeBtn.Text = Config.SlideOnly and "SLIDE ONLY" or "ALL GROUND"
	end))

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
	ForceLabel.ZIndex = 4
	ForceLabel.Text = "Boost Speed (10-85)"
	ForceLabel.TextColor3 = Color3.fromRGB(220, 220, 225)
	ForceLabel.TextSize = 10
	ForceLabel.Font = Enum.Font.Gotham
	ForceLabel.TextXAlignment = Enum.TextXAlignment.Left
	ForceLabel.Parent = ForceRow

	ForceBox = Instance.new("TextBox")
	ForceBox.Size = UDim2.new(0, 48, 0, 20)
	ForceBox.Position = UDim2.new(1, -54, 0.5, -10)
	ForceBox.BackgroundColor3 = Color3.fromRGB(48, 48, 60)
	ForceBox.ZIndex = 4
	ForceBox.Text = tostring(Config.BoostForce)
	ForceBox.TextColor3 = Color3.fromRGB(0, 255, 130)
	ForceBox.TextSize = 11
	ForceBox.Font = Enum.Font.GothamBold
	ForceBox.ClearTextOnFocus = false
	ForceBox.Parent = ForceRow
	AddCorner(ForceBox, 0, 4)

	AddConnection(ForceBox.FocusLost:Connect(function()
		if IsDestroyed then return end
		local num = tonumber(ForceBox.Text)
		if num and num == num then
			Config.BoostForce = math.clamp(math.floor(num + 0.5), 10, Config.MaxSlideSpeed)
		end
		ForceBox.Text = tostring(Config.BoostForce)
	end))

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
	StatusLabel.ZIndex = 4
	StatusLabel.Text = "OFF"
	StatusLabel.TextColor3 = Color3.fromRGB(150, 150, 155)
	StatusLabel.TextSize = 10
	StatusLabel.Font = Enum.Font.Gotham
	StatusLabel.TextXAlignment = Enum.TextXAlignment.Left
	StatusLabel.Parent = StatusRow

	CreateToggleRow(146, "Infinite Jump", "InfiniteJump", Color3.fromRGB(90, 170, 255))

	local FleeRow = Instance.new("Frame")
	FleeRow.Size = UDim2.new(1, -14, 0, 26)
	FleeRow.Position = UDim2.new(0, 7, 0, 176)
	FleeRow.BackgroundColor3 = Color3.fromRGB(36, 36, 46)
	FleeRow.BorderSizePixel = 0
	FleeRow.ZIndex = 3
	FleeRow.Parent = MainFrame
	AddCorner(FleeRow, 0, 6)

	local FleeLabel = Instance.new("TextLabel")
	FleeLabel.Size = UDim2.new(1, -150, 1, 0)
	FleeLabel.Position = UDim2.new(0, 8, 0, 0)
	FleeLabel.BackgroundTransparency = 1
	FleeLabel.ZIndex = 4
	FleeLabel.Text = "Auto Flee Bot"
	FleeLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
	FleeLabel.TextSize = 11
	FleeLabel.Font = Enum.Font.Gotham
	FleeLabel.TextXAlignment = Enum.TextXAlignment.Left
	FleeLabel.Parent = FleeRow

	FleeBox = Instance.new("TextBox")
	FleeBox.Size = UDim2.new(0, 42, 0, 20)
	FleeBox.Position = UDim2.new(1, -98, 0.5, -10)
	FleeBox.BackgroundColor3 = Color3.fromRGB(48, 48, 60)
	FleeBox.ZIndex = 4
	FleeBox.Text = tostring(Config.FleeDistance)
	FleeBox.TextColor3 = Color3.fromRGB(255, 200, 120)
	FleeBox.TextSize = 10
	FleeBox.Font = Enum.Font.GothamBold
	FleeBox.ClearTextOnFocus = false
	FleeBox.Parent = FleeRow
	AddCorner(FleeBox, 0, 4)

	local FleeToggleBtn = Instance.new("TextButton")
	FleeToggleBtn.Size = UDim2.new(0, 42, 0, 18)
	FleeToggleBtn.Position = UDim2.new(1, -48, 0.5, -9)
	FleeToggleBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 80)
	FleeToggleBtn.ZIndex = 4
	FleeToggleBtn.Text = "OFF"
	FleeToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	FleeToggleBtn.TextSize = 10
	FleeToggleBtn.Font = Enum.Font.GothamBold
	FleeToggleBtn.AutoButtonColor = true
	FleeToggleBtn.Parent = FleeRow
	AddCorner(FleeToggleBtn, 1, 0)

	local function RefreshFleeToggle()
		FleeToggleBtn.BackgroundColor3 = Config.AutoFlee and Color3.fromRGB(255, 150, 60) or Color3.fromRGB(70, 70, 80)
		FleeToggleBtn.Text = Config.AutoFlee and "ON" or "OFF"
	end

	AddConnection(FleeToggleBtn.MouseButton1Click:Connect(function()
		if IsDestroyed then return end
		Config.AutoFlee = not Config.AutoFlee
		RefreshFleeToggle()
		if not Config.AutoFlee then
			LastFleeTime = 0
		end
	end))
	RefreshFleeToggle()

	AddConnection(FleeBox.FocusLost:Connect(function()
		if IsDestroyed then return end
		local num = tonumber(FleeBox.Text)
		if num and num == num then
			Config.FleeDistance = math.clamp(math.floor(num + 0.5), 10, 300)
		end
		FleeBox.Text = tostring(Config.FleeDistance)
	end))

	CreateToggleRow(206, "Sky AFK Farm", "SkyAFK", Color3.fromRGB(170, 120, 255))

	local FleeNowRow = Instance.new("Frame")
	FleeNowRow.Size = UDim2.new(1, -14, 0, 24)
	FleeNowRow.Position = UDim2.new(0, 7, 0, 236)
	FleeNowRow.BackgroundColor3 = Color3.fromRGB(70, 34, 34)
	FleeNowRow.BorderSizePixel = 0
	FleeNowRow.ZIndex = 3
	FleeNowRow.Parent = MainFrame
	AddCorner(FleeNowRow, 0, 6)

	local FleeNowBtn = Instance.new("TextButton")
	FleeNowBtn.Size = UDim2.new(1, -8, 1, -4)
	FleeNowBtn.Position = UDim2.new(0, 4, 0, 2)
	FleeNowBtn.BackgroundColor3 = Color3.fromRGB(160, 55, 55)
	FleeNowBtn.ZIndex = 4
	FleeNowBtn.Text = "FLEE NOW · วาปหนีบอททันที"
	FleeNowBtn.TextColor3 = Color3.fromRGB(255, 235, 235)
	FleeNowBtn.TextSize = 10
	FleeNowBtn.Font = Enum.Font.GothamBold
	FleeNowBtn.AutoButtonColor = true
	FleeNowBtn.Parent = FleeNowRow

	AddConnection(FleeNowBtn.MouseButton1Click:Connect(function()
		if IsDestroyed then return end
		local _, _, root = GetCharParts()
		if not root then return end
		local bp = GetNearestBot(root)
		if bp then
			DoFlee(root, bp)
		else
			pcall(function() root.CFrame = root.CFrame + Vector3.new(0, 25, 0) end)
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
		Config.SkyAFK = false
		SlideKeyHeld = false
		ReleaseSky(nil)
		ClearMover()

		for _, conn in ipairs(Connections) do
			pcall(function() conn:Disconnect() end)
		end
		table.clear(Connections)
		ClearCharConns()

		pcall(function() if ScreenGui then ScreenGui:Destroy() end end)
	end))

	-- สร้างเมนูสำเร็จแล้ว ปิดป้ายวินิจฉัย
	pcall(function()
		if DiagGui then DiagGui:Destroy() end
		DiagGui = nil
		DiagLabel = nil
	end)
	Diag = function() end
end)

if not BuildOk then
	Diag("UI Error: " .. tostring(BuildErr))
end

-- // Heartbeat ครอบ pcall กัน error เฟรมเดียวดับทั้งลูป
AddConnection(RunService.Heartbeat:Connect(function(dt)
	if IsDestroyed then return end
	local ok, err = pcall(function()
		local _, hum, root = GetCharParts()
		if not hum or not root or hum.Health <= 0 then
			if WasSliding or LinearVelObj or BodyVelocityObj then
				ClearMover()
			end
			if StatusLabel then
				StatusLabel.Text = "รอตัวละครเกิด..."
			end
			return
		end

		ScanAccum = ScanAccum + dt
		if ScanAccum >= 0.4 then
			ScanAccum = 0
			RefreshBots()
		end
		local botPart, nearestDist = GetNearestBot(root)

		-- กดค้าง Space กลางอากาศ (เดสก์ท็อป) จะดันขึ้นเป็นจังหวะ
		InfJumpCd = InfJumpCd - dt
		if Config.InfiniteJump and InfJumpCd <= 0
			and UserInputService:IsKeyDown(Enum.KeyCode.Space)
			and hum.FloorMaterial == Enum.Material.Air then
			AirJump(root, hum)
			InfJumpCd = 0.22
		end

		if Config.SkyAFK then
			ApplySky(root)
			if StatusLabel then
				StatusLabel.Text = "SKY AFK · " .. (botPart and string.format("Bot %.1fm", nearestDist) or "Bot -")
				StatusLabel.TextColor3 = Color3.fromRGB(190, 150, 255)
			end
			return
		end

		if Config.AutoFlee and botPart and nearestDist and nearestDist <= Config.FleeDistance
			and os.clock() - LastFleeTime > Config.FleeCooldown then
			DoFlee(root, botPart)
		end

		if not Config.SlideBoostEnabled then
			if WasSliding or LinearVelObj or BodyVelocityObj then
				ClearMover()
			end
			if StatusLabel then
				StatusLabel.Text = "OFF · " .. (botPart and string.format("Bot %.1fm", nearestDist) or "Bot -")
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
			local botTxt = botPart and string.format("Bot %.1fm", nearestDist) or "Bot -"
			if sliding then
				StatusLabel.Text = "ON · บูสต์สไลด์ | " .. botTxt
				StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 140)
			else
				StatusLabel.Text = "ON · พร้อม | " .. botTxt
				StatusLabel.TextColor3 = Color3.fromRGB(160, 210, 255)
			end
		end
	end)
	if not ok and DiagLabel and DiagLabel.Parent then
		Diag("Heartbeat Error: " .. tostring(err))
	end
end))

Diag("Evade Hub โหลดแล้ว — หากไม่เห็นเมนูใหญ่ ส่งข้อความในป้ายนี้กลับมา")
