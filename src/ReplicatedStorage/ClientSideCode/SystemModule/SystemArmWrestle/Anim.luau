--[[
	Module: Anim
	Description: 扳手腕客户端动作：训练举哑铃、对局拉锯（本地玩家 + 桌边 R6 对手）、胜负反应
	Author: 程莘
	Created: 2026-10-14
	Last Modified: 2026-10-16

	功能：
	- PlayTrain：本地角色播 ANIM_TRAIN（只键 Torso / Right Arm，不压腿部 locomotion）
	- BeginBattle / PlayResult / StopBattle：本地角色对局动作；拉锯片 TimePosition 跟随桌子属性 P
	- SetPoseOwner：本地对局由 BattlePose 程序化接管姿势时，让出该桌（不给本地玩家与该桌对手播拉锯 / 待机 / 胜负片），交还后补刷
	- BindWorld：桌边 Opponent（锚定 R6）按桌子属性 Fighter / P 本地播拉锯，进度取 1 - P；无 Fighter 时循环 ANIM_IDLE
	- HoldBattleOnModel / PreloadOnModel / PlayOnModel：获胜演出的对手克隆体当帧定格在掰输姿势并预加载起飞动作，起飞时切到该动作（其余轨道淡出）
	- PlayResult(true) 的胜利动作只播一次（获胜演出的庆祝段），StopBattle 时若仍在播则淡出
	- BeginBattle 时若 Fighter 尚未复制到客户端，属性到达后会自动认领桌子并开始 scrub（避免玩家僵站无动作）

	约束：
	- 纯表现：只读桌子属性，不写 HRP / CFrame / 存档 / 结算（服务端 Battle 独占入座与 P）
	- 拉锯片长固定 BATTLE_LENGTH 秒，t=0 本方输、t=1 本方赢；对手与玩家共用同一片
	- Studio 内优先用 ArmWrestleConfig.ANIM_SOURCE_PATH 下的 KeyframeSequence 注册临时动画，
	  改完源动画不必先发布即可预览；缺源或线上走 AnimationModule/Animation.luau 登记的 ID
	  （源动画改动须重新发布覆盖登记 ID，线上才生效）

	加载（仅 SystemArmWrestle 内部使用）：
		local Anim = require(script.Anim)
		Anim.BindWorld(world)
		Anim.PlayTrain(LocalPlayer.Character)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local ReplicatedStorage = Utils.ReplicatedStorage
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local AnimationModule = Utils.AnimationModule
local ArmWrestleConfig = Utils.ArmWrestleConfig
local Log = Utils.Log

local Anim = {}

local ANIM_TRAIN = ArmWrestleConfig.ANIM_TRAIN
local ANIM_BATTLE = ArmWrestleConfig.ANIM_BATTLE
local ANIM_WIN = ArmWrestleConfig.ANIM_WIN
local ANIM_LOSE = ArmWrestleConfig.ANIM_LOSE
local ANIM_IDLE = ArmWrestleConfig.ANIM_IDLE
local OPPONENT_MODEL_NAME = ArmWrestleConfig.OPPONENT_MODEL_NAME
local PRIORITY = Enum.AnimationPriority.Action
local FADE_TIME = 0.15
local TRAIN_FADE_TIME = 0.05
local BATTLE_LENGTH = 1
-- 非循环轨道 TimePosition 落在片尾会被当作播完而停轨
local END_EPSILON = 0.001

local _animIds: { [string]: number | false } = {}
local _previewAnims: { [string]: Animation | false } = {}
-- Instance 作弱键会被提前回收导致重复 LoadAnimation，故强引用 + Destroying 清理
local _previewTracks: { [Animator]: { [string]: AnimationTrack } } = {}
local _tables: { Model } = {}
local _battleTable: Model? = nil
local _battleAnimator: Animator? = nil
local _battleUserId: number? = nil
local _resultShown = false
-- BattlePose 接管中的桌子：本地玩家与该桌对手的关节只由 BattlePose 写
local _poseTable: Model? = nil

--[[
	取模型 Humanoid 下的 Animator
	@param model Model? - 角色或对手模型
	@return Animator? - 动画器；模型未就绪时 nil
]]
local function _getAnimator(model: Model?): Animator?
	local hum = model and model:FindFirstChildOfClass("Humanoid")
	return hum and hum:FindFirstChildOfClass("Animator") or nil
end

--[[
	查动画登记 ID（每名只查一次，未登记只告警一次）
	@param name string - Animation.luau 逻辑名
	@return number? - rbx 动画 ID；未登记 nil
]]
local function _resolveId(name: string): number?
	local cached = _animIds[name]
	if cached == nil then
		cached = AnimationModule.GetAnimID(name) or false
		_animIds[name] = cached
	end
	return if cached then cached else nil
end

--[[
	Studio 预览：把源 KeyframeSequence 注册为临时动画（线上不可用）
	@param name string - 逻辑名，同时是源文件夹下 KeyframeSequence 名
	@return Animation? - 临时动画；非 Studio 或缺源时 nil
]]
local function _getPreviewAnimation(name: string): Animation?
	local cached = _previewAnims[name]
	if cached ~= nil then
		return if cached then cached else nil
	end
	_previewAnims[name] = false
	if not RunService:IsStudio() then
		return nil
	end
	local node: Instance? = ReplicatedStorage
	for _, childName in ipairs(ArmWrestleConfig.ANIM_SOURCE_PATH) do
		node = node and node:FindFirstChild(childName)
	end
	local sequence = node and node:FindFirstChild(name)
	if not sequence or not sequence:IsA("KeyframeSequence") then
		if not _resolveId(name) then
			Log.warn("SystemArmWrestle.Anim 缺少动画源", name)
		end
		return nil
	end
	local ok, tempId = pcall(function()
		return KeyframeSequenceProvider:RegisterKeyframeSequence(sequence)
	end)
	if not ok then
		Log.warn("SystemArmWrestle.Anim 注册预览动画失败", name, tempId)
		return nil
	end
	local animation = Instance.new("Animation")
	animation.Name = name
	animation.AnimationId = tempId
	_previewAnims[name] = animation
	return animation
end

--[[
	取（并缓存）轨道：Studio 有源动画时走预览，否则走 AnimationModule 登记 ID
	@param animator Animator - 动画器
	@param name string - 逻辑名
	@return AnimationTrack? - 轨道；不可用时 nil
]]
local function _getTrack(animator: Animator, name: string): AnimationTrack?
	local animation = _getPreviewAnimation(name)
	if not animation then
		if _resolveId(name) then
			return AnimationModule.LoadAnimationTrack(animator, name, 1, nil, nil, PRIORITY, FADE_TIME)
		end
		return nil
	end
	local tracks = _previewTracks[animator]
	if not tracks then
		tracks = {}
		_previewTracks[animator] = tracks
		animator.Destroying:Once(function()
			_previewTracks[animator] = nil
		end)
	end
	local track = tracks[name]
	if not track then
		track = animator:LoadAnimation(animation)
		track.Priority = PRIORITY
		tracks[name] = track
	end
	return track
end

--[[
	从头播放一次
	@param animator Animator - 动画器
	@param name string - 逻辑名
	@param fadeTime number - 淡入秒数
	@param looped boolean? - 是否循环；nil 保持动画资源自身设置
]]
local function _playFromStart(animator: Animator, name: string, fadeTime: number, looped: boolean?)
	local track = _getTrack(animator, name)
	if not track then
		return
	end
	if track.IsPlaying then
		track:Stop(0)
	end
	if looped ~= nil then
		track.Looped = looped
	end
	track:Play(fadeTime)
	track:AdjustSpeed(1)
end

--[[
	停止轨道（未加载过则忽略）
	@param animator Animator - 动画器
	@param name string - 逻辑名
]]
local function _stopTrack(animator: Animator, name: string)
	local track = _getTrack(animator, name)
	if track and track.IsPlaying then
		track:Stop(FADE_TIME)
	end
end

--[[
	拉锯片定格到指定进度
	@param animator Animator - 动画器
	@param progress number - 本方进度 0（输）~ 1（赢）
	@param fadeTime number? - 轨道未播放时的淡入秒数，缺省 FADE_TIME
]]
local function _scrubBattle(animator: Animator, progress: number, fadeTime: number?)
	local track = _getTrack(animator, ANIM_BATTLE)
	if not track then
		return
	end
	if not track.IsPlaying then
		track:Play(fadeTime or FADE_TIME)
	end
	track:AdjustSpeed(0)
	track.TimePosition = math.clamp(progress, 0, 1) * (BATTLE_LENGTH - END_EPSILON)
end

--[[
	对手无人挑战时循环待机；起始帧随机，避免全场对手动作同步
	@param animator Animator - 对手动画器
]]
local function _playIdle(animator: Animator)
	local track = _getTrack(animator, ANIM_IDLE)
	if not track or track.IsPlaying then
		return
	end
	track.Looped = true
	track:Play(FADE_TIME)
	track:AdjustSpeed(1)
	if track.Length > 0 then
		track.TimePosition = math.random() * track.Length
	end
end

--[[
	读桌子当前进度
	@param tableModel Model - 桌子
	@return number - 玩家方进度 P，缺省 0.5
]]
local function _getProgress(tableModel: Model): number
	local p = tableModel:GetAttribute("P")
	return if type(p) == "number" then p else 0.5
end

--[[
	按桌子属性刷新对手与本地玩家姿态
	@param tableModel Model - 桌子
]]
local function _syncTable(tableModel: Model)
	if tableModel == _poseTable then
		return
	end
	local p = _getProgress(tableModel)
	local fighter = tableModel:GetAttribute("Fighter")
	local oppAnimator = _getAnimator(tableModel:FindFirstChild(OPPONENT_MODEL_NAME) :: Model?)
	if oppAnimator and fighter == nil then
		_stopTrack(oppAnimator, ANIM_BATTLE)
		_stopTrack(oppAnimator, ANIM_WIN)
		_stopTrack(oppAnimator, ANIM_LOSE)
		_playIdle(oppAnimator)
	elseif oppAnimator then
		_stopTrack(oppAnimator, ANIM_IDLE)
		local result = if p >= 1 then ANIM_LOSE elseif p <= 0 then ANIM_WIN else nil
		if result then
			_stopTrack(oppAnimator, ANIM_BATTLE)
			local track = _getTrack(oppAnimator, result)
			if track and not track.IsPlaying then
				_playFromStart(oppAnimator, result, FADE_TIME)
			end
		else
			_stopTrack(oppAnimator, ANIM_WIN)
			_stopTrack(oppAnimator, ANIM_LOSE)
			_scrubBattle(oppAnimator, 1 - p)
		end
	end
	-- 对局中：Fighter 晚到时认领桌子；已认领则 scrub 本地玩家拉锯
	if _battleAnimator and not _resultShown and _battleUserId ~= nil then
		if tableModel:GetAttribute("Fighter") == _battleUserId then
			_battleTable = tableModel
			_scrubBattle(_battleAnimator, p)
		elseif tableModel == _battleTable then
			_scrubBattle(_battleAnimator, p)
		end
	end
end

--[[
	找本地玩家正在使用的桌子
	@param userId number - 玩家 UserId
	@return Model? - 桌子；未入座 nil
]]
local function _findFighterTable(userId: number): Model?
	for _, tableModel in ipairs(_tables) do
		if tableModel:GetAttribute("Fighter") == userId then
			return tableModel
		end
	end
	return nil
end

--[[
	绑定单张桌子；对手模型 / Animator 复制晚到时补刷
	@param tableModel Instance - 桌子候选（非带 OpponentId 的 Model 或已绑定则忽略）
]]
local function _bindTable(tableModel: Instance)
	if not tableModel:IsA("Model") or not tableModel:GetAttribute("OpponentId") or table.find(_tables, tableModel) then
		return
	end
	table.insert(_tables, tableModel)
	local function onChanged()
		_syncTable(tableModel)
	end
	tableModel:GetAttributeChangedSignal("P"):Connect(onChanged)
	tableModel:GetAttributeChangedSignal("Fighter"):Connect(onChanged)
	tableModel.DescendantAdded:Connect(function(desc: Instance)
		if desc:IsA("Animator") then
			onChanged()
		end
	end)
	onChanged()
end

--[[
	绑定区域下的 Tables 文件夹（含晚到的桌子）
	@param folder Instance - Zone_*/Tables
]]
local function _bindTablesFolder(folder: Instance)
	for _, child in ipairs(folder:GetChildren()) do
		_bindTable(child)
	end
	folder.ChildAdded:Connect(_bindTable)
end

--[[
	绑定单个区域（Tables 文件夹可能晚于区域复制到客户端）
	@param zone Instance - World/Zone_*
]]
local function _bindZone(zone: Instance)
	local folder = zone:FindFirstChild("Tables")
	if folder then
		_bindTablesFolder(folder)
		return
	end
	local conn: RBXScriptConnection
	conn = zone.ChildAdded:Connect(function(child: Instance)
		if child.Name == "Tables" then
			conn:Disconnect()
			_bindTablesFolder(child)
		end
	end)
end

--[[
	绑定世界内所有扳手腕桌子（属性 / 复制事件驱动，不轮询）
	@param world Instance - Workspace 下 ArmWrestleConfig.WORLD_NAME 文件夹，子级 Zone_*/Tables/Table_*
]]
function Anim.BindWorld(world: Instance)
	for _, zone in ipairs(world:GetChildren()) do
		_bindZone(zone)
	end
	world.ChildAdded:Connect(_bindZone)
end

--[[
	训练举哑铃动作（调用方已过本地冷却；服务端仍独立校验结算）
	@param character Model? - 本地玩家角色；nil 或无 Animator 时忽略
]]
function Anim.PlayTrain(character: Model?)
	local animator = _getAnimator(character)
	if animator then
		_playFromStart(animator, ANIM_TRAIN, TRAIN_FADE_TIME)
	end
end

--[[
	对局开始：本地角色进入拉锯姿态，之后随桌子属性 P 自动定格
	@param character Model? - 本地玩家角色
	@param userId number - 本地玩家 UserId，用于按桌子属性 Fighter 找桌
]]
function Anim.BeginBattle(character: Model?, userId: number)
	_battleAnimator = _getAnimator(character)
	_battleUserId = userId
	_battleTable = _findFighterTable(userId)
	_resultShown = false
	if _battleAnimator then
		_stopTrack(_battleAnimator, ANIM_TRAIN)
	end
	if _battleTable then
		_syncTable(_battleTable)
	else
		-- Fighter / 桌子列表可能晚一帧；对已绑定桌补刷一次以触发认领
		for _, tableModel in ipairs(_tables) do
			_syncTable(tableModel)
			if _battleTable then
				break
			end
		end
	end
end

--[[
	本地对局姿势交给 BattlePose 接管 / 交还：接管时停掉本地玩家拉锯片与该桌对手的全部对局动作，
	期间该桌属性变化不再触发本模块写动作；交还（传 nil 或换桌）时按当前属性补刷原桌
	@param tableModel Model? - BattlePose 正在接管的桌子；nil 表示交还
]]
function Anim.SetPoseOwner(tableModel: Model?)
	local prev = _poseTable
	if prev == tableModel then
		return
	end
	_poseTable = tableModel
	if tableModel then
		local oppAnimator = _getAnimator(tableModel:FindFirstChild(OPPONENT_MODEL_NAME) :: Model?)
		if oppAnimator then
			for _, name in ipairs({ ANIM_BATTLE, ANIM_WIN, ANIM_LOSE, ANIM_IDLE }) do
				_stopTrack(oppAnimator, name)
			end
		end
		if _battleAnimator then
			_stopTrack(_battleAnimator, ANIM_BATTLE)
		end
	end
	if prev and prev.Parent then
		_syncTable(prev)
	end
end

--[[
	把本地模型定格在拉锯片指定进度（获胜演出克隆对手后立刻接上原对手的掰输姿势，克隆体本身不带播放中的轨道）
	@param model Model? - 带 Humanoid/Animator 的模型；nil 或无 Animator 时忽略
	@param progress number - 该模型一方的进度 0（输）~ 1（赢）
]]
function Anim.HoldBattleOnModel(model: Model?, progress: number)
	local animator = _getAnimator(model)
	if animator then
		-- 新克隆的 Animator 从绑定姿势淡入会闪一下，替换原对手时必须当帧到位
		_scrubBattle(animator, progress, 0)
	end
end

--[[
	提前在本地模型上加载动作轨道（不播放），避免真正播放那一帧才加载导致动作晚到
	@param model Model? - 带 Humanoid/Animator 的模型；nil 或无 Animator 时忽略
	@param name string - Animation.luau 逻辑名（如 ArmWrestleConfig.ANIM_LOSE）
]]
function Anim.PreloadOnModel(model: Model?, name: string)
	local animator = _getAnimator(model)
	if animator then
		_getTrack(animator, name)
	end
end

--[[
	在本地模型上从头播一段动作（如获胜演出里被甩飞的对手克隆体）；模型上其余播放中的轨道同时淡出，避免同优先级混合
	@param model Model? - 带 Humanoid/Animator 的模型；nil 或无 Animator 时忽略
	@param name string - Animation.luau 逻辑名（如 ArmWrestleConfig.ANIM_LOSE）
	@param looped boolean? - 是否循环；nil 保持动画资源自身设置
]]
function Anim.PlayOnModel(model: Model?, name: string, looped: boolean?)
	local animator = _getAnimator(model)
	if not animator then
		return
	end
	local target = _getTrack(animator, name)
	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		if track ~= target then
			track:Stop(FADE_TIME)
		end
	end
	_playFromStart(animator, name, FADE_TIME, looped)
end

--[[
	对局结果反应（结果以服务端 End 载荷为准）；获胜动作强制只播一次，不随动画资源的循环设置
	@param win boolean - 本地玩家是否获胜
]]
function Anim.PlayResult(win: boolean)
	local animator = _battleAnimator
	if not animator then
		return
	end
	_resultShown = true
	_stopTrack(animator, ANIM_BATTLE)
	_playFromStart(animator, if win then ANIM_WIN else ANIM_LOSE, FADE_TIME, if win then false else nil)
end

--[[
	对局交还控制：停掉本地角色全部对局动作
]]
function Anim.StopBattle()
	local animator = _battleAnimator
	_battleAnimator = nil
	_battleTable = nil
	_battleUserId = nil
	_resultShown = false
	if not animator or not animator.Parent then
		return
	end
	for _, name in ipairs({ ANIM_BATTLE, ANIM_WIN, ANIM_LOSE }) do
		_stopTrack(animator, name)
	end
end

return Anim
