--[[
	Module: Battle
	Description: 扳手腕对局：桌子占用、点按令牌桶、服务端 P 结算；入座 / 出场 / 关卡传送各一次写 HRP
	Author: 程莘
	Created: 2026-10-14
	Last Modified: 2026-10-15

	入座即开打（无倒计时）。
	位姿写口：本模块在对局开始入座、结束交还控制前出场、非对局时关卡传送（TeleportZone）各独占一次写 HRP.CFrame（+ Rubberband 纠偏）；禁止每帧改 HRP。
	传送落点：第 1 关 World.Common.Spawn，第 N 关 World.Zone_N.TeleportPoint（场景摆放的隐形部件）。
	入座点读桌子属性 ArmWrestleConfig.SEAT_ATTR，出场点读 EXIT_ATTR（擂台围栏外；均为 R6 HRP CFrame，场景烘焙）；
	离场 / 死亡的静默结束不送出（角色已销毁或将重生）。
	结束后延迟交还：获胜 WIN_RELEASE_DELAY_SEC（客户端播获胜演出，奖励仍在 End 时立即结算）、失败 LOSE_RELEASE_DELAY_SEC；期间桌子保持占用。
	手臂姿态由客户端 SystemArmWrestle/Anim 按桌子属性 P 播动画，服务端不挂 IK。
	结算只看服务端 P / 时长，不信客户端 CFrame。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local Workspace = game:GetService("Workspace")
local ArmWrestleConfig = Utils.ArmWrestleConfig
local EnumMgr = Utils.EnumMgr
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local TipsModule = Utils.TipsModule
local SystemCharacterMotion = Utils.SystemCharacterMotion
local Log = Utils.Log

local Profile = require(script.Parent.Profile)

local Battle = {}

local PlayerAttr = EnumMgr.PlayerAttr
local SEAT_ATTR = ArmWrestleConfig.SEAT_ATTR
local ZONE_PREFIX = "Zone_"
local SPAWN_POINT_NAME = "Spawn"
local TELEPORT_POINT_NAME = "TeleportPoint"
-- R6 站立时 HRP 中心离脚底的高度
local ROOT_ABOVE_GROUND = 3

type BattleState = {
	Table: Model,
	Opp: { [string]: any },
	P: number,
	Start: number,
	Pending: number,
	Tokens: number,
	LastTap: number,
	AutoAcc: number,
	LastSync: number,
}

local _battles: { [Player]: BattleState } = {}
local _tableBusy: { [Instance]: Player } = {}
local _tables: { [string]: Model } = {}
local _heartbeat: RBXScriptConnection?
local _hasPass: ((Player, string) -> boolean)?
local _getPasses: ((Player) -> { [string]: boolean })?
local _afterChange: ((Player, { [string]: any }, boolean) -> ())?
local _guideEvent: ((Player, { [string]: any }, string, any?) -> ())?

--[[
	是否对局中
	@param plr Player - 玩家
	@return boolean
]]
function Battle.IsInBattle(plr: Player): boolean
	return _battles[plr] ~= nil
end

--[[
	注入依赖
	@param deps table - hasPass / getPasses / afterChange / guideEvent（胜利写档成功后带 "win" 与对手 Id 推进新手引导）
]]
function Battle.Bind(deps: {
	hasPass: (Player, string) -> boolean,
	getPasses: (Player) -> { [string]: boolean },
	afterChange: (Player, { [string]: any }, boolean) -> (),
	guideEvent: (Player, { [string]: any }, string, any?) -> (),
})
	_hasPass = deps.hasPass
	_getPasses = deps.getPasses
	_afterChange = deps.afterChange
	_guideEvent = deps.guideEvent
end

--[[
	一次性把玩家 HRP 放到指定位姿并纠偏（入座 / 出场共用，禁止每帧调用）
	@param plr Player - 玩家
	@param root BasePart - 玩家 HumanoidRootPart
	@param cf CFrame - 目标 HRP 位姿（桌子烘焙属性 SEAT_ATTR / EXIT_ATTR）
	@param reason string - 纠偏原因标签，供 SystemCharacterMotion 日志区分
	@param durationSec number? - 客户端纠偏插值时长；nil 用默认短插值，0 为瞬移（远距离传送须瞬移，否则插值途经空中）
]]
local function _placeRoot(plr: Player, root: BasePart, cf: CFrame, reason: string, durationSec: number?)
	-- 角色 PrimaryPart 为 Head，不能用 PivotTo
	root.CFrame = cf
	if SystemCharacterMotion and SystemCharacterMotion.FireRubberband then
		SystemCharacterMotion.FireRubberband(plr, cf.Position, durationSec, reason)
	end
end

--[[
	对局结束送出擂台（擂台四面挡墙，留在座位上会被关住）；离场 / 死亡 / 已开新局时跳过
	@param plr Player - 玩家
	@param tableModel Model - 刚结束对局的桌子（出场位姿见 ArmWrestleConfig.GetExitCFrame，面朝桌子）
]]
local function _exitArena(plr: Player, tableModel: Model)
	if not plr.Parent or _battles[plr] then
		return
	end
	local exitCf = ArmWrestleConfig.GetExitCFrame(tableModel)
	if not exitCf then
		Log.warn("SystemArmWrestle.Battle 桌子缺少出场点", tableModel:GetFullName())
		return
	end
	local char = plr.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp or hum.Health <= 0 then
		return
	end
	local root = hrp :: BasePart
	_placeRoot(plr, root, exitCf, "ArmWrestleExit")
end

--[[
	结束对局
	@param plr Player - 玩家
	@param win boolean - 是否获胜
	@param silent boolean? - 静默（离场/死亡）
]]
local function _endBattle(plr: Player, win: boolean, silent: boolean?)
	local state = _battles[plr]
	if not state then
		return
	end
	_battles[plr] = nil
	local tableModel = state.Table
	tableModel:SetAttribute("P", if win then 1 else 0)
	local reward = 0
	local data = Profile.Get(plr)
	if win and data and _getPasses and _afterChange then
		local _, cashMult = Profile.GetMults(plr, data, _getPasses(plr))
		reward = math.floor((state.Opp.Reward or 0) * cashMult)
		data.Wins = (data.Wins or 0) + 1
		local committed = Profile.Commit(plr, data, reward)
		if not committed then
			reward = 0
			data = Profile.Get(plr) or data
		end
		_afterChange(plr, data, false)
		if committed and _guideEvent then
			_guideEvent(plr, data, "win", state.Opp.Id)
		end
	elseif data and _afterChange then
		Profile.Save(plr, data)
		_afterChange(plr, data, false)
	end
	plr:SetAttribute(PlayerAttr.InBattle, false)
	if not silent then
		NetWork.FireClient(plr, NetMsg.ARM_WRESTLE_BATTLE, "End", {
			Win = win,
			Reward = reward,
			OppId = state.Opp.Id,
		})
	end
	local releaseDelay = if silent
		then 0
		elseif win then ArmWrestleConfig.WIN_RELEASE_DELAY_SEC
		else ArmWrestleConfig.LOSE_RELEASE_DELAY_SEC
	task.delay(releaseDelay, function()
		if not silent then
			_exitArena(plr, tableModel)
		end
		tableModel:SetAttribute("Fighter", nil)
		tableModel:SetAttribute("P", 0.5)
		_tableBusy[tableModel] = nil
		local top = tableModel:FindFirstChild("Top")
		local prompt = top and top:FindFirstChild("Prompt")
		if prompt and prompt:IsA("ProximityPrompt") then
			prompt.Enabled = true
		end
		if plr.Parent then
			NetWork.FireClient(plr, NetMsg.ARM_WRESTLE_BATTLE, "Release", {})
		end
	end)
end

--[[
	开始对局
	@param plr Player - 玩家
	@param tableModel Model - 桌子
]]
local function _startBattle(plr: Player, tableModel: Model)
	if not _getPasses or not _afterChange then
		return
	end
	local data = Profile.Get(plr)
	if not data or _battles[plr] then
		return
	end
	local oppId = tableModel:GetAttribute("OpponentId")
	local opp, levelIndex = ArmWrestleConfig.GetOpponent(oppId)
	if not opp or not levelIndex then
		return
	end
	if levelIndex > (data.Unlocked or 1) then
		TipsModule.ErrorTips(plr, "需要先解锁关卡", { tostring(levelIndex) })
		return
	end
	if _tableBusy[tableModel] then
		TipsModule.ErrorTips(plr, "桌子比赛中")
		return
	end
	local char = plr.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not char or not hum or not hrp or hum.Health <= 0 then
		return
	end
	local seatCf = tableModel:GetAttribute(SEAT_ATTR)
	if typeof(seatCf) ~= "CFrame" then
		Log.warn("SystemArmWrestle.Battle 桌子缺少入座点", tableModel:GetFullName())
		return
	end
	hum:UnequipTools()
	local root = hrp :: BasePart
	_placeRoot(plr, root, seatCf, "ArmWrestleBattle")
	_tableBusy[tableModel] = plr
	local top = tableModel:FindFirstChild("Top")
	local prompt = top and top:FindFirstChild("Prompt")
	if prompt and prompt:IsA("ProximityPrompt") then
		prompt.Enabled = false
	end
	local arm = ArmWrestleConfig.GetArm(data.Arm) or ArmWrestleConfig.GetArm(1)
	local mat = ArmWrestleConfig.GetMaterial(data.Mat)
	tableModel:SetAttribute("Fighter", plr.UserId)
	tableModel:SetAttribute("ArmColor", arm and arm.Color)
	tableModel:SetAttribute("ArmMat", mat and mat.Mat or "SmoothPlastic")
	tableModel:SetAttribute("P", 0.5)
	_battles[plr] = {
		Table = tableModel,
		Opp = opp,
		P = 0.5,
		Start = os.clock(),
		Pending = 0,
		Tokens = ArmWrestleConfig.MaxTapsPerSecond,
		LastTap = os.clock(),
		AutoAcc = 0,
		LastSync = 0,
	}
	plr:SetAttribute(PlayerAttr.InBattle, true)
	NetWork.FireClient(plr, NetMsg.ARM_WRESTLE_BATTLE, "Start", {
		OppId = opp.Id,
		Time = ArmWrestleConfig.BattleTime,
	})
end

--[[
	点按入队（令牌桶）
	@param plr Player - 玩家
]]
function Battle.OnTap(plr: Player)
	local state = _battles[plr]
	if not state then
		return
	end
	local now = os.clock()
	if now < state.Start then
		return
	end
	state.Tokens = math.min(
		ArmWrestleConfig.MaxTapsPerSecond,
		state.Tokens + (now - state.LastTap) * ArmWrestleConfig.MaxTapsPerSecond
	)
	state.LastTap = now
	if state.Tokens >= 1 then
		state.Tokens -= 1
		state.Pending += 1
	end
end

--[[
	绑定世界桌子 Prompt
	@param world Folder - Workspace.World
]]
function Battle.BindWorld(world: Instance)
	for _, zone in ipairs(world:GetChildren()) do
		local folder = zone:FindFirstChild("Tables")
		if folder then
			for _, tableModel in ipairs(folder:GetChildren()) do
				if tableModel:IsA("Model") then
					local oppId = tableModel:GetAttribute("OpponentId")
					if type(oppId) == "string" then
						_tables[oppId] = tableModel
					end
					local top = tableModel:FindFirstChild("Top")
					local prompt = top and top:FindFirstChild("Prompt")
					if prompt and prompt:IsA("ProximityPrompt") then
						prompt.MaxActivationDistance = ArmWrestleConfig.TABLE_PROMPT_DISTANCE
						prompt.Triggered:Connect(function(plr: Player)
							if plr and plr:IsA("Player") then
								_startBattle(plr, tableModel)
							end
						end)
					end
				end
			end
		end
	end
end

--[[
	心跳推进 P
	@param dt number - 帧间隔
]]
local function _step(dt: number)
	local now = os.clock()
	for plr, state in pairs(_battles) do
		local data = Profile.Get(plr)
		if not data or not plr.Parent then
			_endBattle(plr, false, true)
		elseif now >= state.Start then
			local k = math.clamp((data.Strength or 0) / math.max(state.Opp.Power, 1), 0.1, 4)
			local taps = state.Pending
			state.Pending = 0
			if _hasPass and _hasPass(plr, "AutoClicker") and plr:GetAttribute("AutoOn") then
				state.AutoAcc += dt * ArmWrestleConfig.AutoTapsPerSecond
				local autoTaps = math.floor(state.AutoAcc)
				state.AutoAcc -= autoTaps
				taps += autoTaps
			end
			local drift = ArmWrestleConfig.OpponentDrift * (1 + math.sin(now * 2.7) * 0.35)
			state.P = math.clamp(state.P + taps * ArmWrestleConfig.TapPower * k - drift * dt, 0, 1)
			if state.P >= 1 then
				_endBattle(plr, true)
			elseif state.P <= 0 or now - state.Start > ArmWrestleConfig.BattleTime then
				_endBattle(plr, false)
			elseif now - state.LastSync > 0.05 then
				state.LastSync = now
				state.Table:SetAttribute("P", state.P)
			end
		end
	end
end

--[[
	启动心跳
]]
function Battle.StartHeartbeat()
	if _heartbeat then
		return
	end
	_heartbeat = RunService.Heartbeat:Connect(_step)
end

--[[
	离场/死亡强制结束
	@param plr Player - 玩家
]]
function Battle.ForceEnd(plr: Player)
	if _battles[plr] then
		_endBattle(plr, false, true)
	end
end

--[[
	查找关卡传送落点：第 1 关用 World.Common.Spawn，其余关用 World.Zone_N.TeleportPoint（场景摆放，朝向即落地朝向）
	@param levelIndex number - 1-based 关卡下标
	@return BasePart? - 落点部件；场景缺失时为 nil
]]
local function _findTeleportPoint(levelIndex: number): BasePart?
	local world = Workspace:FindFirstChild(ArmWrestleConfig.WORLD_NAME)
	if not world then
		return nil
	end
	local point
	if levelIndex == 1 then
		local common = world:FindFirstChild("Common")
		point = common and common:FindFirstChild(SPAWN_POINT_NAME)
	else
		local zone = world:FindFirstChild(ZONE_PREFIX .. levelIndex)
		point = zone and zone:FindFirstChild(TELEPORT_POINT_NAME)
	end
	if point and point:IsA("BasePart") then
		return point
	end
	return nil
end

--[[
	传送到指定关卡落点（与入座 / 出场同一写口，一次性写 HRP 并纠偏）；解锁、冷却等业务校验由调用方 Economy 完成
	@param plr Player - 玩家
	@param levelIndex number - 1-based 关卡下标
	@return boolean - 成功为 true；对局中、角色未就绪/死亡、落点缺失为 false
]]
function Battle.TeleportZone(plr: Player, levelIndex: number): boolean
	if Battle.IsInBattle(plr) then
		return false
	end
	local point = _findTeleportPoint(levelIndex)
	if not point then
		Log.warn("SystemArmWrestle.Battle 关卡缺少传送落点", levelIndex)
		return false
	end
	local char = plr.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp or hum.Health <= 0 then
		return false
	end
	local cf = point.CFrame + Vector3.new(0, point.Size.Y / 2 + ROOT_ABOVE_GROUND, 0)
	_placeRoot(plr, hrp :: BasePart, cf, "ArmWrestleTeleport", 0)
	return true
end

return Battle
