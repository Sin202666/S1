--[[
	Module: GateFx
	Description: 扳手腕关卡门客户端表现：门上解锁按钮、力量进度条、已解锁隐藏、解锁变白消失特效
	Author: 程莘
	Created: 2026-10-14
	Last Modified: 2026-10-16

	功能：
	- BindWorld：发现 Zone_N.Gate_N，把场景 Display（SurfaceGui）克隆进 PlayerGui 并 Adornee 回门，
	  原件本地禁用（Workspace 下的 SurfaceGui 收不到点击）；克隆时 Lock / Need 按关卡配置写翻译键文案，
	  并清掉 Icon（纯文字，不在文字左侧贴锁 / 力量图）
	- 下一关（Unlocked + 1）门上显示 Holder.UnlockBtn；力量够亮绿、不够置灰，点击 Invoke("UnlockLevel", index)
	  按钮与 HUD 按钮同款（白底 + Fill 渐变 + Inner 高光 + Bricks 积木图）：力量够开 Fill，不够关 Fill 并改灰底，积木图由 UIMgr.BindBrickTiles 跟随
	  点击经 AddListen.AddMouseClick：按下缩放回弹 + 点击音效
	- 克隆面板不 AlwaysOnTop（贴门面渲染，不穿墙）；MaxDistance 限制远距离显示
	- Unlocked 属性在本局内增大时，播一次解锁成功音（SystemUISfx.PlaySuccess），对新解锁的门播「变白 → 膨胀 → 渐隐 + 白色粒子」后隐藏；进服时直接隐藏不播
	- SetSuppressed：扳手腕对局期间隐藏全部门面板，期间 Strength / Unlocked 刷新也不会重新显示

	约束：
	- 纯表现：只读 Unlocked / Strength 属性，结算以服务端 Gate.OnUnlock 为准
	- 门是每个玩家本地一份表现，Color / Size / Transparency / CanCollide 只在本地改
	- StreamingEnabled：门流出再流入是新实例、本地改动丢失，DescendantAdded 时重绑 Adornee 并重刷

	加载（仅 SystemArmWrestle 内部使用）：
		local GateFx = require(script.GateFx)
		GateFx.Init(SystemArmWrestle.Invoke)
		GateFx.BindWorld(world)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TweenService = Utils.TweenService
local Debris = Utils.Debris
local LocalPlayer = Utils.LocalPlayer
local ArmWrestleConfig = Utils.ArmWrestleConfig
local ArmWrestleStyle = Utils.ArmWrestleStyle
local CameraModule = Utils.CameraModule
local EnumMgr = Utils.EnumMgr
local TranslationHelper = Utils.TranslationHelper
local AddListen = Utils.AddListen
local SystemUISfx = Utils.SystemUISfx
local Log = Utils.Log

local GateFx = {}

local ACTION_UNLOCK_LEVEL = "UnlockLevel"
local DISPLAY_NAME = "Display"
local BUTTON_NAME = "UnlockBtn"
local BUTTON_FILL_NAME = "Fill"
local WHITE = Color3.new(1, 1, 1)
local FLASH_TIME = 0.25
local SWELL_TIME = 0.3
local FADE_TIME = 0.55
local SWELL_THICKNESS = 6
local FADE_GROW = 1.06
local SPARK_COUNT = 90
-- 白底四芒星，art/vfx/aura/aura-spark.png
local SPARK_TEXTURE = "rbxassetid://82402156329894"
local SHAKE_INTENSITY = 0.6
local PANEL_MAX_DISTANCE = 300

type GateVisual = {
	Color: Color3,
	Material: Enum.Material,
	Transparency: number,
	Size: Vector3,
}

local _invoke: ((string, ...any) -> any)? = nil
local _playerGui: Instance? = nil
local _gates: { [number]: BasePart } = {}
local _guis: { [number]: SurfaceGui } = {}
local _origin: { [BasePart]: GateVisual } = setmetatable({}, { __mode = "k" }) :: any
local _playing: { [number]: boolean } = {}
local _pendingRefresh: { [number]: boolean } = {}
local _requesting = false
local _lastUnlocked = 0
local _suppressed = false

--[[
	当前已解锁关卡数
	@return number - Unlocked 属性，缺省 1
]]
local function _getUnlocked(): number
	local value = LocalPlayer:GetAttribute("Unlocked")
	return if type(value) == "number" then value else 1
end

--[[
	当前力量
	@return number - Strength 属性，缺省 0
]]
local function _getStrength(): number
	local value = LocalPlayer:GetAttribute("Strength")
	return if type(value) == "number" then value else 0
end

--[[
	门实例仍在场景中
	@param index number - 关卡下标
	@return BasePart? - 门；已流出为 nil
]]
local function _getGate(index: number): BasePart?
	local part = _gates[index]
	if part and part.Parent then
		return part
	end
	return nil
end

--[[
	记录门首次看到时的外观（流入的新实例自带场景原值）
	@param part BasePart - 门
	@return GateVisual - 原始外观
]]
local function _rememberOrigin(part: BasePart): GateVisual
	local origin = _origin[part]
	if not origin then
		origin = {
			Color = part.Color,
			Material = part.Material,
			Transparency = part.Transparency,
			Size = part.Size,
		}
		_origin[part] = origin
	end
	return origin
end

--[[
	刷新门上进度条与解锁按钮
	@param index number - 关卡下标
	@param gui SurfaceGui - PlayerGui 中的克隆面板
]]
local function _refreshPanel(index: number, gui: SurfaceGui)
	local level = ArmWrestleConfig.GetLevel(index)
	local holder = gui:FindFirstChild("Holder")
	if not level or not holder then
		return
	end
	local strength = _getStrength()
	local ready = strength >= level.Gate
	local bar = holder:FindFirstChild("Bar")
	local fill = bar and bar:FindFirstChild("Fill")
	if fill and fill:IsA("Frame") then
		local ratio = if level.Gate > 0 then math.clamp(strength / level.Gate, 0, 1) else 1
		fill.Size = UDim2.fromScale(ratio, 1)
	end
	local text = bar and bar:FindFirstChild("Text")
	if text and text:IsA("TextLabel") then
		TranslationHelper.SetRawText(
			text,
			ArmWrestleConfig.Format(math.floor(math.min(strength, level.Gate))) .. " / " .. ArmWrestleConfig.Format(level.Gate)
		)
	end
	local button = holder:FindFirstChild(BUTTON_NAME)
	if button and button:IsA("GuiButton") then
		button.Visible = index == _getUnlocked() + 1
		button.BackgroundColor3 = if ready then WHITE else ArmWrestleStyle.Colors.Disabled
		button.AutoButtonColor = ready
		local fill = button:FindFirstChild(BUTTON_FILL_NAME)
		if fill and fill:IsA("UIGradient") then
			fill.Enabled = ready
		end
	end
end

--[[
	按解锁状态设置单扇门（特效播放中跳过，由特效收尾设置）
	@param index number - 关卡下标
]]
local function _applyGate(index: number)
	if _playing[index] then
		return
	end
	local part = _getGate(index)
	local gui = _guis[index]
	local unlocked = index <= _getUnlocked()
	if part then
		local origin = _rememberOrigin(part)
		part.CanCollide = not unlocked
		part.Transparency = if unlocked then 1 else origin.Transparency
		local display = part:FindFirstChild(DISPLAY_NAME)
		if display and display:IsA("SurfaceGui") then
			display.Enabled = false
		end
	end
	if gui then
		gui.Enabled = part ~= nil and not unlocked and not _suppressed
		if gui.Enabled then
			_refreshPanel(index, gui)
		end
	end
end

--[[
	刷新全部已知门
]]
local function _applyAll()
	for index in pairs(_gates) do
		_applyGate(index)
	end
end

--[[
	门上标题和需求只留文字：清掉场景 Icon，避免 BindIcons 在文字左侧再贴图
	@param lbl TextLabel - Lock 或 Need
]]
local function _clearTextIcon(lbl: TextLabel)
	lbl:SetAttribute("Icon", nil)
	local icon = lbl:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") then
		icon:Destroy()
	end
	local pad = lbl:FindFirstChildOfClass("UIPadding")
	if pad then
		pad:Destroy()
	end
end

--[[
	点击解锁：请求服务端结算（结果经 Unlocked 属性回传触发特效）
	@param index number - 关卡下标
]]
local function _requestUnlock(index: number)
	local invoke = _invoke
	if _requesting or not invoke or index ~= _getUnlocked() + 1 then
		return
	end
	_requesting = true
	task.spawn(function()
		local ok, err = pcall(invoke, ACTION_UNLOCK_LEVEL, index)
		if not ok then
			Log.warn("GateFx 解锁请求失败", index, err)
		end
		_requesting = false
	end)
end

--[[
	为门建立 PlayerGui 面板；已有则只重绑 Adornee
	@param index number - 关卡下标
	@param part BasePart - 门
]]
local function _ensurePanel(index: number, part: BasePart)
	local gui = _guis[index]
	if gui then
		gui.Adornee = part
		return
	end
	local template = part:FindFirstChild(DISPLAY_NAME)
	if not template or not template:IsA("SurfaceGui") or not _playerGui then
		return
	end
	local clone = template:Clone()
	clone.Name = "GateDisplay_" .. index
	clone.Adornee = part
	clone.ResetOnSpawn = false
	clone.AlwaysOnTop = false
	clone.MaxDistance = PANEL_MAX_DISTANCE
	ArmWrestleStyle.StyleWorld(clone)
	local holder = clone:FindFirstChild("Holder")
	local level = ArmWrestleConfig.GetLevel(index)
	local lock = holder and holder:FindFirstChild("Lock")
	if lock and lock:IsA("TextLabel") then
		_clearTextIcon(lock)
		if level then
			TranslationHelper.SetText(lock, "关卡门标题", { index, { level.ZhName } })
		end
	end
	local need = holder and holder:FindFirstChild("Need")
	if need and need:IsA("TextLabel") then
		_clearTextIcon(need)
		if level then
			TranslationHelper.SetText(need, "关卡门解锁需求", { ArmWrestleConfig.Format(level.Gate) })
		end
	end
	local button = holder and holder:FindFirstChild(BUTTON_NAME)
	if button and button:IsA("GuiButton") then
		local label = button:FindFirstChild("Label")
		if label and label:IsA("TextLabel") then
			TranslationHelper.SetText(label, "解锁")
		end
		AddListen.AddMouseClick(button, function()
			_requestUnlock(index)
		end, button)
	else
		Log.warn("GateFx 门面板缺少解锁按钮", part:GetFullName())
	end
	clone.Parent = _playerGui
	_guis[index] = clone
end

--[[
	登记门实例（首次或流入）
	@param part BasePart - Gate_N
]]
local function _registerGate(part: BasePart)
	local index = tonumber(string.match(part.Name, "^Gate_(%d+)$"))
	if not index then
		return
	end
	_gates[index] = part
	_rememberOrigin(part)
	_ensurePanel(index, part)
	_applyGate(index)
end

--[[
	流入节点归属到门后合并为一次 defer 重刷（Display 可能晚于门本体到达）
	@param desc Instance - 新增节点
]]
local function _onDescendantAdded(desc: Instance)
	local part: Instance? = desc
	while part and not string.match(part.Name, "^Gate_%d+$") do
		part = part.Parent
	end
	if not part or not part:IsA("BasePart") then
		return
	end
	local index = tonumber(string.match(part.Name, "^Gate_(%d+)$")) :: number
	if _pendingRefresh[index] then
		return
	end
	_pendingRefresh[index] = true
	local gate = part :: BasePart
	task.defer(function()
		_pendingRefresh[index] = nil
		if gate.Parent then
			_registerGate(gate)
		end
	end)
end

--[[
	白色粒子爆发（每次解锁一次性创建，非热路径）
	@param part BasePart - 门
]]
local function _burstSparks(part: BasePart)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SPARK_TEXTURE
	emitter.Color = ColorSequence.new(WHITE)
	emitter.LightEmission = 1
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.6),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.6, 1.2)
	emitter.Speed = NumberRange.new(8, 22)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Drag = 3
	emitter.Rate = 0
	emitter.Parent = part
	emitter:Emit(SPARK_COUNT)
	Debris:AddItem(emitter, 1.5)
end

--[[
	播放一扇门的解锁特效：变白发光 → 加厚膨胀 → 渐隐 + 白色粒子，结束后保持隐藏
	@param index number - 关卡下标
]]
local function _playUnlock(index: number)
	local part = _getGate(index)
	if not part or _playing[index] then
		_applyGate(index)
		return
	end
	_playing[index] = true
	local origin = _rememberOrigin(part)
	local gui = _guis[index]
	if gui then
		gui.Enabled = false
	end
	part.CanCollide = false
	part.Material = Enum.Material.Neon
	local flash = TweenService:Create(
		part,
		TweenInfo.new(FLASH_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Color = WHITE, Transparency = 0 }
	)
	local swell = TweenService:Create(
		part,
		TweenInfo.new(SWELL_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = Vector3.new(SWELL_THICKNESS, origin.Size.Y, origin.Size.Z) }
	)
	local fade = TweenService:Create(
		part,
		TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Transparency = 1, Size = Vector3.new(SWELL_THICKNESS, origin.Size.Y * FADE_GROW, origin.Size.Z * FADE_GROW) }
	)
	flash.Completed:Once(function()
		swell:Play()
	end)
	swell.Completed:Once(function()
		_burstSparks(part)
		CameraModule.CameraShakeOnce(EnumMgr.CameraShakeType.MagicHit, SHAKE_INTENSITY)
		fade:Play()
	end)
	fade.Completed:Once(function()
		part.Size = origin.Size
		part.Material = origin.Material
		part.Color = origin.Color
		_playing[index] = nil
		_applyGate(index)
	end)
	flash:Play()
end

--[[
	Unlocked 变化：本局内增大才播特效与解锁成功音；首次收到服务端镜像（_lastUnlocked 为 0）只刷新
]]
local function _onUnlockedChanged()
	local unlocked = _getUnlocked()
	local previous = _lastUnlocked
	_lastUnlocked = if LocalPlayer:GetAttribute("Unlocked") ~= nil then unlocked else 0
	if previous > 0 and unlocked > previous then
		SystemUISfx.PlaySuccess()
		for index = previous + 1, unlocked do
			_playUnlock(index)
		end
	end
	_applyAll()
end

--[[
	注入服务端 Action 调用并监听属性（SystemArmWrestle.Init 调一次）
	@param invoke (string, ...any) -> any - SystemArmWrestle.Invoke
]]
function GateFx.Init(invoke: (string, ...any) -> any)
	_invoke = invoke
	_playerGui = LocalPlayer:WaitForChild("PlayerGui")
	_lastUnlocked = if LocalPlayer:GetAttribute("Unlocked") ~= nil then _getUnlocked() else 0
	LocalPlayer:GetAttributeChangedSignal("Unlocked"):Connect(_onUnlockedChanged)
	LocalPlayer:GetAttributeChangedSignal("Strength"):Connect(_applyAll)
end

--[[
	绑定世界中的关卡门（含 StreamingEnabled 流入）
	@param world Instance - Workspace.World
]]
function GateFx.BindWorld(world: Instance)
	for _, desc in ipairs(world:GetDescendants()) do
		if desc:IsA("BasePart") and string.match(desc.Name, "^Gate_%d+$") then
			_registerGate(desc)
		end
	end
	world.DescendantAdded:Connect(_onDescendantAdded)
end

--[[
	对局期间隐藏全部门面板，结束后按解锁状态恢复（重复设置相同值忽略）
	@param suppressed boolean - true 隐藏（对局开始）；false 恢复（对局交还控制）
]]
function GateFx.SetSuppressed(suppressed: boolean)
	if _suppressed == suppressed then
		return
	end
	_suppressed = suppressed
	_applyAll()
end

return GateFx
