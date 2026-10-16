--[[
	Module: SystemArmWrestle
	Description: 扳手腕客户端：手持哑铃自动训练上报、对局镜头/控制交接、移速 modifier、世界门、升级垫已购状态、动作驱动
	Author: 程莘
	Created: 2026-10-14
	Last Modified: 2026-10-16

	不写存档。WalkSpeed 只经 CharacterMoveSpeedBind.pushModifier。
	对局：TransferControlOwner + ActionArbiter Cinematic，结束必须交还；镜头从两人侧面对准相握的手，随 P 横移/推近。
	动作：子模块 Anim（训练 / 拉锯躯干 / 胜负 / 桌边对手），纯表现，只读桌子属性。
	对局姿势：子模块 BattlePose（起始姿势同临时文件夹 Table_L1_1，按 P 程序化掰手腕；接管期间 Anim.SetPoseOwner 让出该桌）；
	  判出胜负后保持到结果表现（获胜演出庆祝段 / 失败直接）才交还 Anim，期间不再补挂。
	关卡门：子模块 GateFx（门上解锁按钮 / 进度条 / 解锁变白消失特效），结算以服务端 Gate 为准；对局开始隐藏门面板，Release 时恢复。
	限量展台：子模块 StandFx（展台上站着本地玩家角色形象，双臂换成审判之臂外观），纯表现。
	世界文案：子模块 WorldText（对手名字 / 推荐力量 / 奖励、扭蛋单价、限量库存的翻译键文案），纯表现。
	材质机：子模块 MachineShowcase（奖池手臂 3D 展示 + 抽取 3D 表演），纯表现；表演经 HUD.SetRollFx 注入，结果以服务端下发为准。
	获胜演出：子模块 WinCinematic（对手被甩飞头朝下插地 + 裂纹尘土 + 镜头转向玩家庆祝），纯表现；
	  只返回镜头 CFrame，由本模块 _updateBattleCamera 唯一写镜头；庆祝时才播胜利动作并弹胜利面板，Release 时 Stop。
	场景头顶牌：子模块 SceneBillboards，对局开始本地关掉场景 BillboardGui，Release 时恢复。
	其他玩家：子模块 HiddenPlayers，对局开始本地隐藏其他玩家角色，Release 时恢复。
	对局音效：子模块 BattleSfx（开局铃 / 点按 / 砸桌 / 胜负人群反应，演出内甩飞与落地由 WinCinematic 触发），本机 2D，Release 与重生时停止。
	训练音效：子模块 TrainSfx（每次训练一声随机音源 / 音高的气泡音），本机 2D。
	升级成功音：SpeedTier / TrainTier 属性本局内增大（升级垫购买经服务端同步）时调 SystemUISfx.PlaySuccess；进服首次同步不响。
	新手引导表现（按钮箭头 / 引导线）由 SystemGuide 负责；本模块只在对局开始调 SetSuppressed(true)，Release 时恢复。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local UserInputService = Utils.UserInputService
local RunService = Utils.RunService
local Workspace = game:GetService("Workspace")
local LocalPlayer = Utils.LocalPlayer
local ReplicatedStorage = Utils.ReplicatedStorage
local ArmWrestleConfig = Utils.ArmWrestleConfig
local ArmWrestleStyle = Utils.ArmWrestleStyle
local CharacterControl = Utils.CharacterControl
local ActionArbiter = Utils.ActionArbiter
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local PlayerData = Utils.PlayerData
local TranslationHelper = Utils.TranslationHelper
local SystemGuide = Utils.SystemGuide
local SystemUISfx = Utils.SystemUISfx
local Log = Utils.Log

local Anim = require(script.Anim)
local BattlePose = require(script.BattlePose)
local GateFx = require(script.GateFx)
local StandFx = require(script.StandFx)
local WorldText = require(script.WorldText)
local MachineShowcase = require(script.MachineShowcase)
local WinCinematic = require(script.WinCinematic)
local SceneBillboards = require(script.SceneBillboards)
local HiddenPlayers = require(script.HiddenPlayers)
local BattleSfx = require(script.BattleSfx)
local TrainSfx = require(script.TrainSfx)

local SystemArmWrestle = {}

local TOOL_NAME = ArmWrestleConfig.TOOL_NAME
local WALK_MOD = ArmWrestleConfig.WALK_MODIFIER
local BATTLE_OWNER = ArmWrestleConfig.BATTLE_OWNER
local PAD_TIER_ATTR = {
	TrainSpeed = "TrainTier",
	WalkSpeed = "SpeedTier",
}
local SEAT_ATTR = ArmWrestleConfig.SEAT_ATTR
local OPP_PIVOT_ATTR = "OppPivot"
-- 镜头垂直于两人连线、放在玩家左前方：桌边牌子都在玩家右后方会挡镜头
local BATTLE_CAM_DIST = 7.2
local BATTLE_CAM_HEIGHT = 2.1
-- 桌子 Pivot 属性是桌面高度，相握的拳在其上方约 0.8
local BATTLE_CAM_HAND_HEIGHT = 0.8
local BATTLE_CAM_SWAY = 0.55
-- 随 P 横移 / 沿对局轴偏移 / 近胜负推近；开局从更远机位推进
local BATTLE_CAM_LATERAL = 2.8
local BATTLE_CAM_ALONG = 1.6
local BATTLE_CAM_PUSH = 1.8
local BATTLE_CAM_INTRO_SEC = 0.42
local BATTLE_CAM_INTRO_BACK = 5
local BATTLE_CAM_INTRO_UP = 2.2
local BATTLE_CAM_FOV = 68
local BATTLE_CAM_FOV_TIGHT = 54
local BATTLE_CAM_P_SMOOTH = 7
local BATTLE_CAM_SHAKE_DECAY = 8
local BATTLE_CAM_SHAKE_GAIN = 5
-- 交还镜头时摆到出场点背后、朝向桌子，玩家直接往前走就能回到桌边交互
local EXIT_CAM_DIST = 12
local EXIT_CAM_HEIGHT = 4
local FLAT = Vector3.new(1, 0, 1)
local UP = Vector3.yAxis

local _inited = false
local _inBattle = false
-- 已收到 End：Fighter 要到 Release 才清，期间不得再补挂对局姿势，否则会盖掉胜负动作
local _battleDecided = false
local _climbSuppressed = false
local _battleTable: Model? = nil
local _lastTrain = 0
local _gui: any = nil
local _arbiterToken: string? = nil
local _savedCameraType: Enum.CameraType? = nil
local _savedFov: number? = nil
local _camIntroT = 0
local _camSmoothP = 0.5
local _camLastP = 0.5
local _camShake = 0
local _camPos: Vector3? = nil
local _camLook: Vector3? = nil
-- 换款时服务端销毁旧哑铃发新实例，弱键避免旧 Tool 滞留到重生
local _hookedTools: { [Tool]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local _equippedTool: Tool? = nil
local _charConns: { RBXScriptConnection } = {}
local _padTouchColors: { [BasePart]: Color3 } = setmetatable({}, { __mode = "k" }) :: any
local _padInfoPositions: { [GuiObject]: UDim2 } = setmetatable({}, { __mode = "k" }) :: any
local _padPending: { [Model]: boolean } = {}
-- 各升级档位属性上次值；nil 表示尚未收到服务端镜像（首次同步不算升级）
local _lastTiers: { [string]: number } = {}

--[[
	取角色上的 CMS Bind
	@param character Model? - 角色
	@return any? - CharacterMoveSpeedBind
]]
local function _getMoveBind(character: Model?): any?
	if not character then
		return nil
	end
	local folder = character:FindFirstChild("CharacterScripts")
	local module = folder and folder:FindFirstChild("CharacterMoveSpeedBind")
	if module and module:IsA("ModuleScript") then
		return require(module)
	end
	return nil
end

--[[
	按 SpeedTier 推 CMS add modifier
	@param character Model? - 角色
]]
local function _applyWalkModifier(character: Model?)
	local bind = _getMoveBind(character)
	if not bind or not bind.pushModifier then
		return
	end
	local data = PlayerData.GetPlrDataByKey(LocalPlayer, "ArmWrestle")
	local tierIndex = if type(data) == "table" then data.SpeedTier else 1
	local list = ArmWrestleConfig.GetWalkSpeed()
	local row = list[tierIndex] or list[1]
	local target = row and row.Value or ArmWrestleConfig.GetBaseWalkSpeed()
	local add = target - ArmWrestleConfig.GetBaseWalkSpeed()
	if add == 0 then
		bind.popModifier(WALK_MOD)
		return
	end
	bind.pushModifier(WALK_MOD, { add = add })
end

--[[
	已拥有时把 Status 挪到牌子最上方，其余内容整体下移 Status 高度（Price 此时隐藏，空间足够）；未拥有还原场景原位
	@param info Instance - Holo.Info（子节点为绝对定位的 GuiObject）
	@param status TextLabel - 状态标签
	@param owned boolean - 是否已拥有
]]
local function _layoutPadInfo(info: Instance, status: TextLabel, owned: boolean)
	for _, child in ipairs(info:GetChildren()) do
		if child:IsA("GuiObject") and not _padInfoPositions[child] then
			_padInfoPositions[child] = child.Position
		end
	end
	local shift = status.Size.Y
	for _, child in ipairs(info:GetChildren()) do
		if not child:IsA("GuiObject") or child.Name == "Price" then
			continue
		end
		local origin = _padInfoPositions[child]
		if not owned then
			child.Position = origin
		elseif child == status then
			child.Position = UDim2.new(origin.X, UDim.new(0, 0))
		else
			child.Position = origin + UDim2.new(UDim.new(0, 0), shift)
		end
	end
end

--[[
	按玩家 TrainTier / SpeedTier 属性刷新单个升级垫的已购买状态（纯表现；购买结算以服务端 Economy 为准）
	@param pad Model - Zone_x.Pads 下的垫子模型（Attribute Kind / Tier）
]]
local function _applyPad(pad: Model)
	local attr = PAD_TIER_ATTR[pad:GetAttribute("Kind")]
	local tier = pad:GetAttribute("Tier")
	local owned = attr ~= nil and type(tier) == "number" and (LocalPlayer:GetAttribute(attr) or 1) >= tier
	local colors = ArmWrestleStyle.Colors
	local touch = pad:FindFirstChild("Touch")
	if touch and touch:IsA("BasePart") then
		if not _padTouchColors[touch] then
			_padTouchColors[touch] = touch.Color
		end
		touch.Color = if owned then colors.Disabled else _padTouchColors[touch]
	end
	local holo = pad:FindFirstChild("Holo")
	local info = holo and holo:FindFirstChild("Info")
	if not info then
		return
	end
	local price = info:FindFirstChild("Price")
	if price and price:IsA("TextLabel") then
		price.Visible = not owned
	end
	local status = info:FindFirstChild("Status")
	if not status or not status:IsA("TextLabel") then
		return
	end
	_layoutPadInfo(info, status, owned)
	if owned then
		TranslationHelper.SetText(status, "已拥有")
		status.TextColor3 = colors.Green
		ArmWrestleStyle.SetIcon(status, "check")
	else
		TranslationHelper.SetRawText(status, "")
		ArmWrestleStyle.SetIcon(status, nil)
	end
end

--[[
	刷新世界里当前已流入客户端的全部升级垫
]]
local function _applyPads()
	local world = Workspace:FindFirstChild(ArmWrestleConfig.WORLD_NAME)
	if not world then
		return
	end
	for _, zone in ipairs(world:GetChildren()) do
		local folder = zone:FindFirstChild("Pads")
		if not folder then
			continue
		end
		for _, pad in ipairs(folder:GetChildren()) do
			if pad:IsA("Model") then
				_applyPad(pad)
			end
		end
	end
end

--[[
	升级档位属性变化：本局内增大才播升级成功音（结算以服务端 Economy 为准，这里只做反馈）
	@param attr string - 档位属性名：SpeedTier / TrainTier
]]
local function _onTierChanged(attr: string)
	local value = LocalPlayer:GetAttribute(attr)
	local previous = _lastTiers[attr]
	_lastTiers[attr] = if type(value) == "number" then value else nil
	if previous and type(value) == "number" and value > previous then
		SystemUISfx.PlaySuccess()
	end
end

--[[
	StreamingEnabled 下垫子会流入/流出且本地改动随流出丢失，节点进入时 defer 合并重刷所属垫子
	@param world Instance - Workspace.World
]]
local function _bindPads(world: Instance)
	world.DescendantAdded:Connect(function(desc: Instance)
		local pad: Instance? = desc
		while pad and pad ~= world do
			local parent = pad.Parent
			if parent and parent.Name == "Pads" and pad:IsA("Model") then
				break
			end
			pad = parent
		end
		if not pad or pad == world or _padPending[pad :: Model] then
			return
		end
		local model = pad :: Model
		_padPending[model] = true
		task.defer(function()
			_padPending[model] = nil
			if model.Parent then
				_applyPad(model)
			end
		end)
	end)
end

--[[
	手持哑铃时按 TrainTier 冷却 ÷ 训练速度药水倍率（TrainSpeedMult Attribute）发一次训练请求（每帧调用，冷却未到直接返回；结算以服务端 Train 为准）
]]
local function _tryAutoTrain()
	local tool = _equippedTool
	if not tool or _inBattle then
		return
	end
	if tool.Parent ~= LocalPlayer.Character then
		_equippedTool = nil
		return
	end
	local data = PlayerData.GetPlrDataByKey(LocalPlayer, "ArmWrestle")
	local tiers = ArmWrestleConfig.GetTrainSpeed()
	local tier = type(data) == "table" and tiers[data.TrainTier] or tiers[1]
	local speedMult = LocalPlayer:GetAttribute("TrainSpeedMult")
	local cd = (tier and tier.Value or 1) / (if type(speedMult) == "number" and speedMult > 0 then speedMult else 1)
	local now = os.clock()
	if now - _lastTrain < cd then
		return
	end
	_lastTrain = now
	NetWork.FireServer(NetMsg.ARM_WRESTLE_TRAIN)
	Anim.PlayTrain(LocalPlayer.Character)
	TrainSfx.PlayBubble()
	if _gui and _gui.OnTrain then
		_gui.OnTrain()
	end
end

--[[
	仅指定哑铃：装备即开始自动训练，收起即停止
	@param tool Tool - 工具
]]
local function _hookTool(tool: Tool)
	if tool.Name ~= TOOL_NAME or _hookedTools[tool] then
		return
	end
	_hookedTools[tool] = true
	if tool.Parent == LocalPlayer.Character then
		_equippedTool = tool
	end
	tool.Equipped:Connect(function()
		_equippedTool = tool
	end)
	tool.Unequipped:Connect(function()
		if _equippedTool == tool then
			_equippedTool = nil
		end
	end)
end

--[[
	对局期间关闭攀爬，避免环形绳索触发 Climbing（胜后出场尤甚）
	@param character Model? - 本地角色
	@param enabled boolean - true 恢复攀爬；false 关闭
]]
local function _setClimbEnabled(character: Model?, enabled: boolean)
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	hum:SetStateEnabled(Enum.HumanoidStateType.Climbing, enabled)
	if enabled then
		_climbSuppressed = false
		if hum:GetState() == Enum.HumanoidStateType.Climbing then
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
	else
		_climbSuppressed = true
		if hum:GetState() == Enum.HumanoidStateType.Climbing then
			hum:ChangeState(Enum.HumanoidStateType.Running)
		end
	end
end

--[[
	找本地玩家正在对局的桌子（按桌子属性 Fighter）
	@return Model? - 桌子；属性尚未复制到客户端时 nil
]]
local function _findBattleTable(): Model?
	local world = Workspace:FindFirstChild(ArmWrestleConfig.WORLD_NAME)
	if not world then
		return nil
	end
	for _, zone in ipairs(world:GetChildren()) do
		local folder = zone:FindFirstChild("Tables")
		if folder then
			for _, t in ipairs(folder:GetChildren()) do
				if t:IsA("Model") and t:GetAttribute("Fighter") == LocalPlayer.UserId then
					return t
				end
			end
		end
	end
	return nil
end

--[[
	对局姿势交给 BattlePose 接管，并让 Anim 让出该桌
	@param tableModel Model - 本地玩家对局中的桌子
]]
local function _beginPose(tableModel: Model)
	BattlePose.Begin(tableModel, LocalPlayer.Character)
	Anim.SetPoseOwner(tableModel)
end

--[[
	结束 BattlePose 接管并把该桌交还 Anim
]]
local function _stopPose()
	BattlePose.Stop()
	Anim.SetPoseOwner(nil)
end

--[[
	对局开始：接管控制 + 镜头
	@param payload table - Start 载荷
]]
local function _beginBattle(payload: { [string]: any })
	WinCinematic.Stop()
	_battleDecided = false
	SceneBillboards.Hide()
	HiddenPlayers.Hide()
	GateFx.SetSuppressed(true)
	if type(SystemGuide.SetSuppressed) == "function" then
		SystemGuide.SetSuppressed(true)
	end
	BattleSfx.PlayStart()
	_inBattle = true
	if _gui and _gui.OnBattleStart then
		_gui.OnBattleStart(payload)
	end
	local character = LocalPlayer.Character
	if not character then
		return
	end
	_setClimbEnabled(character, false)
	local ctrl = CharacterControl.GetForCharacter(character)
	if ctrl then
		ctrl:TransferControlOwner(BATTLE_OWNER)
	end
	local arbiter = ActionArbiter.GetForCharacter(character)
	if arbiter then
		_arbiterToken = arbiter:Acquire({
			ownerId = BATTLE_OWNER,
			priority = ActionArbiter.Priority.Cinematic,
			blendPolicy = ActionArbiter.BlendPolicy.Override,
			cameraOwner = ActionArbiter.CameraOwner.External,
			reason = "ArmWrestle",
		})
	end
	local camera = Workspace.CurrentCamera
	_savedCameraType = camera.CameraType
	_savedFov = camera.FieldOfView
	camera.CameraType = Enum.CameraType.Scriptable
	_camIntroT = 0
	_camSmoothP = 0.5
	_camLastP = 0.5
	_camShake = 0
	_camPos = camera.CFrame.Position
	_camLook = camera.CFrame.Position + camera.CFrame.LookVector
	_battleTable = _findBattleTable()
	local okAnim, errAnim = pcall(function()
		Anim.BeginBattle(character, LocalPlayer.UserId)
	end)
	if not okAnim then
		Log.warn("SystemArmWrestle Anim.BeginBattle 失败", errAnim)
	end
	-- Fighter 可能晚到：立刻 / defer / 短延迟补挂对局姿势
	local function ensurePose()
		if not _inBattle or _battleDecided or BattlePose.IsActive() then
			return
		end
		local tableModel = _battleTable or _findBattleTable()
		_battleTable = tableModel
		if not tableModel then
			return
		end
		local ok, err = pcall(function()
			_beginPose(tableModel)
		end)
		if not ok then
			Log.warn("SystemArmWrestle BattlePose.Begin 失败", err)
		end
	end
	ensurePose()
	task.defer(ensurePose)
	task.delay(0.35, ensurePose)
end

--[[
	对局结束交还控制
]]
local function _endBattleControl()
	_inBattle = false
	_battleDecided = false
	_stopPose()
	WinCinematic.Stop()
	SceneBillboards.Show()
	HiddenPlayers.Show()
	GateFx.SetSuppressed(false)
	if type(SystemGuide.SetSuppressed) == "function" then
		SystemGuide.SetSuppressed(false)
	end
	BattleSfx.StopAll()
	Anim.StopBattle()
	local character = LocalPlayer.Character
	if character then
		_setClimbEnabled(character, true)
		local ctrl = CharacterControl.GetForCharacter(character)
		if ctrl then
			ctrl:ReleaseControlOwner(BATTLE_OWNER)
		end
		local arbiter = ActionArbiter.GetForCharacter(character)
		if arbiter then
			if _arbiterToken then
				arbiter:Release(_arbiterToken)
			end
			arbiter:ReleaseByOwner(BATTLE_OWNER)
		end
	else
		_climbSuppressed = false
	end
	_arbiterToken = nil
	local tableModel = _battleTable
	_battleTable = nil
	_camPos = nil
	_camLook = nil
	local camera = Workspace.CurrentCamera
	camera.CameraType = _savedCameraType or Enum.CameraType.Custom
	_savedCameraType = nil
	if _savedFov then
		camera.FieldOfView = _savedFov
		_savedFov = nil
	end
	-- 服务端 Release 前已把玩家送到同一出场位姿；Custom 镜头沿用当前朝向，故在此摆一次即可
	local exitCf = tableModel and ArmWrestleConfig.GetExitCFrame(tableModel)
	if exitCf then
		local look = exitCf.Position + exitCf.LookVector
		camera.CFrame = CFrame.lookAt(exitCf.Position - exitCf.LookVector * EXIT_CAM_DIST + UP * EXIT_CAM_HEIGHT, look)
	end
	if _gui and _gui.OnBattleEnd then
		_gui.OnBattleEnd()
	end
end

--[[
	胜负反应：本地角色胜负动作 + 人群反应音效 + HUD 结果弹窗（获胜演出时延到庆祝段才调用）
	@param payload table - 服务端 End 载荷 { Win: boolean, Reward: number, OppId: string }
]]
local function _showResult(payload: { [string]: any })
	-- 先还原关节再播胜负动作，最后交还该桌（对手按 P = 0 / 1 接上胜负片）
	BattlePose.Stop()
	Anim.PlayResult(payload.Win == true)
	Anim.SetPoseOwner(nil)
	BattleSfx.PlayReaction(payload.Win == true)
	if _gui and _gui.OnBattleResult then
		_gui.OnBattleResult(payload)
	end
end

--[[
	角色就绪
	@param character Model - 角色
]]
local function _onCharacter(character: Model)
	_stopPose()
	if _climbSuppressed then
		_setClimbEnabled(character, true)
	end
	WinCinematic.Stop()
	BattleSfx.StopAll()
	for _, conn in ipairs(_charConns) do
		conn:Disconnect()
	end
	table.clear(_charConns)
	table.clear(_hookedTools)
	_equippedTool = nil
	task.spawn(function()
		task.wait(0.3)
		if LocalPlayer.Character == character then
			_applyWalkModifier(character)
			local equipped = character:FindFirstChildOfClass("Tool")
			if equipped then
				_hookTool(equipped)
			end
		end
	end)
	table.insert(_charConns, character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			_hookTool(child)
		end
	end))
	local backpack = LocalPlayer:WaitForChild("Backpack")
	for _, child in ipairs(backpack:GetChildren()) do
		if child:IsA("Tool") then
			_hookTool(child)
		end
	end
	table.insert(_charConns, backpack.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			_hookTool(child)
		end
	end))
end

--[[
	对局镜头（本系统唯一镜头写口）：获胜演出优先；否则侧面比赛位随 P 横移/推近/开局推进
	@param dt number - 帧间隔（推进获胜演出与镜头平滑）
]]
local function _updateBattleCamera(dt: number)
	if not _inBattle then
		return
	end
	local camera = Workspace.CurrentCamera
	local cinematicCf = WinCinematic.Step(dt)
	if cinematicCf then
		camera.CFrame = cinematicCf
		return
	end
	local tableModel = _battleTable
	if not tableModel or tableModel:GetAttribute("Fighter") ~= LocalPlayer.UserId then
		tableModel = _findBattleTable()
		_battleTable = tableModel
	end
	-- 只要对局中、未判胜负且桌子已到，就必须挂上 BattlePose（勿依赖「刚换桌」分支）
	if tableModel and not _battleDecided and not BattlePose.IsActive() then
		local ok, err = pcall(function()
			Anim.BeginBattle(LocalPlayer.Character, LocalPlayer.UserId)
			_beginPose(tableModel)
		end)
		if not ok then
			Log.warn("SystemArmWrestle 镜头补挂臂姿失败", err)
		end
	end
	if not tableModel then
		return
	end
	local pivot = tableModel:GetAttribute("Pivot")
	if typeof(pivot) ~= "Vector3" then
		pivot = tableModel:GetPivot().Position
	end
	local fist = tableModel:FindFirstChild("Fist")
	local fistPos = if fist and fist:IsA("BasePart") then fist.Position else pivot + UP * BATTLE_CAM_HAND_HEIGHT
	local p = tableModel:GetAttribute("P")
	if typeof(p) ~= "number" then
		p = 0.5
	end
	local axis = Vector3.zAxis
	local side = -Vector3.xAxis
	local seat = tableModel:GetAttribute(SEAT_ATTR)
	local opp = tableModel:GetAttribute(OPP_PIVOT_ATTR)
	if typeof(seat) == "CFrame" and typeof(opp) == "CFrame" then
		local flat = (opp.Position - seat.Position) * FLAT
		if flat.Magnitude > 1e-3 then
			axis = flat.Unit
			side = UP:Cross(axis)
		end
	end

	local alpha = 1 - math.exp(-BATTLE_CAM_P_SMOOTH * dt)
	_camSmoothP += (p - _camSmoothP) * alpha
	local dp = math.abs(p - _camLastP)
	if dp > 0.015 then
		_camShake = math.max(_camShake, dp * BATTLE_CAM_SHAKE_GAIN)
	end
	_camLastP = p
	_camShake = math.max(_camShake - BATTLE_CAM_SHAKE_DECAY * dt, 0)
	_camIntroT += dt
	local intro = math.clamp(_camIntroT / BATTLE_CAM_INTRO_SEC, 0, 1)
	intro = intro * intro * (3 - 2 * intro)

	local bias = _camSmoothP - 0.5
	local edge = math.abs(bias) * 2
	local dist = BATTLE_CAM_DIST - edge * BATTLE_CAM_PUSH + (1 - intro) * BATTLE_CAM_INTRO_BACK
	local height = BATTLE_CAM_HEIGHT - bias * BATTLE_CAM_SWAY + (1 - intro) * BATTLE_CAM_INTRO_UP
	local focus = fistPos + side * (bias * 0.45) + UP * (0.15 * edge)
	local targetPos = focus + side * dist + axis * (bias * BATTLE_CAM_ALONG) + UP * height
	-- 进度偏向赢家一侧时镜头略绕过去，更有压迫感
	targetPos = targetPos + side * (bias * BATTLE_CAM_LATERAL * 0.35)

	local blend = 1 - math.exp(-(6 + intro * 10) * dt)
	local camPos = if _camPos then _camPos:Lerp(targetPos, blend) else targetPos
	local camLook = if _camLook then _camLook:Lerp(focus, blend) else focus
	_camPos = camPos
	_camLook = camLook

	local cf = CFrame.lookAt(camPos, camLook)
	if _camShake > 0.01 then
		local n = os.clock() * 28
		local sx = math.noise(n, 0.2) * _camShake * 0.35
		local sy = math.noise(0.5, n) * _camShake * 0.28
		local roll = math.noise(n, n * 0.3) * _camShake * 0.04
		cf = cf * CFrame.new(sx, sy, 0) * CFrame.Angles(0, 0, roll)
	end
	camera.FieldOfView = BATTLE_CAM_FOV + (BATTLE_CAM_FOV_TIGHT - BATTLE_CAM_FOV) * edge
	camera.CFrame = cf
end

--[[
	启动客户端
]]
function SystemArmWrestle.Init()
	if _inited then
		return
	end
	_inited = true

	local world = Workspace:WaitForChild(ArmWrestleConfig.WORLD_NAME, 15)
	if world then
		ArmWrestleStyle.BindIcons(world)
		ArmWrestleStyle.StyleWorld(world)
		Anim.BindWorld(world)
		_bindPads(world)
		GateFx.Init(SystemArmWrestle.Invoke)
		GateFx.BindWorld(world)
		-- TODO(程莘, 2026-10-15): 限量展台暂时下线，恢复时取消注释
		-- StandFx.BindWorld(world)
		WorldText.BindWorld(world)
		MachineShowcase.BindWorld(world)
	end

	local ok, hud = pcall(function()
		return require(ReplicatedStorage.ClientSideCode.GuiScripts.ModuleScript.ArmWrestleHUD)
	end)
	if ok and hud and hud.Init then
		_gui = hud
		hud.Init(SystemArmWrestle.Invoke)
		hud.SetRollFx(MachineShowcase.PlayRoll)
		hud.SetOfferFx(MachineShowcase.SetOfferOpen)
		hud.SetDiscardFx(MachineShowcase.DiscardShown)
	else
		Log.warn("SystemArmWrestle 加载 HUD 失败", hud)
	end

	NetWork.RegisterClientRemoteEvent(NetMsg.ARM_WRESTLE_BATTLE, function(kind: any, payload: any)
		if kind == "Start" then
			_beginBattle(type(payload) == "table" and payload or {})
		elseif kind == "End" then
			local result = if type(payload) == "table" then payload else {}
			-- 姿势保持到 _showResult：获胜演出开场仍要看到两人握手压桌，克隆体经 BattlePose.HandOffOpponent 接手输姿
			_battleDecided = true
			BattleSfx.PlayDecide()
			local played = result.Win == true
				and WinCinematic.Play(_battleTable or _findBattleTable(), LocalPlayer.Character, function()
					_showResult(result)
				end)
			if _gui and _gui.HideBattlePanel then
				_gui.HideBattlePanel()
			end
			if not played then
				_showResult(result)
			end
		elseif kind == "Release" then
			_endBattleControl()
		end
	end)
	NetWork.RegisterClientRemoteEvent(NetMsg.ARM_WRESTLE_ROLL, function(kind: any, payload: any)
		if _gui and _gui.OnRoll then
			_gui.OnRoll(kind, payload)
		end
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not _inBattle or WinCinematic.IsPlaying() then
			return
		end
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			NetWork.FireServer(NetMsg.ARM_WRESTLE_TAP)
			BattleSfx.PlayTap()
			if _gui and _gui.OnTap then
				_gui.OnTap()
			end
		end
	end)

	LocalPlayer.CharacterAdded:Connect(_onCharacter)
	if LocalPlayer.Character then
		_onCharacter(LocalPlayer.Character)
	end

	for _, attr in pairs(PAD_TIER_ATTR) do
		_onTierChanged(attr)
	end
	LocalPlayer:GetAttributeChangedSignal("SpeedTier"):Connect(function()
		_onTierChanged("SpeedTier")
		_applyWalkModifier(LocalPlayer.Character)
		_applyPads()
	end)
	LocalPlayer:GetAttributeChangedSignal("TrainTier"):Connect(function()
		_onTierChanged("TrainTier")
		_applyPads()
	end)
	_applyPads()

	RunService.RenderStepped:Connect(function(dt: number)
		_updateBattleCamera(dt)
		_tryAutoTrain()
		if _gui and _gui.Heartbeat then
			_gui.Heartbeat(dt)
		end
	end)
end

--[[
	Invoke 服务端 Action
	@param action string - 动作名
	@param ... any - 参数
	@return any
]]
function SystemArmWrestle.Invoke(action: string, ...: any): any
	return NetWork.InvokeServer(NetMsg.ARM_WRESTLE_ACTION, action, ...)
end

--[[
	是否对局中
	@return boolean
]]
function SystemArmWrestle.IsInBattle(): boolean
	return _inBattle
end

return SystemArmWrestle
