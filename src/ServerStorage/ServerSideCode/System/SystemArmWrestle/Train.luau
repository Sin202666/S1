--[[
	Module: Train
	Description: 扳手腕训练结算；只认指定哑铃 Tool，服务端冷却（训练速度阶 ÷ 训练速度药水倍率）与加力量
	Author: 程莘
	Created: 2026-10-14
	Last Modified: 2026-10-14
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ArmWrestleConfig = Utils.ArmWrestleConfig
local TipsModule = Utils.TipsModule
local Log = Utils.Log

local Profile = require(script.Parent.Profile)
local Potion = require(script.Parent.Potion)

local Train = {}

local _lastTrain: { [Player]: number } = {}
local _hasPass: ((Player, string) -> boolean)?
local _getPasses: ((Player) -> { [string]: boolean })?
local _isInBattle: ((Player) -> boolean)?
local _afterChange: ((Player, { [string]: any }, boolean) -> ())?

--[[
	注入会话依赖
	@param deps table - hasPass / getPasses / isInBattle / afterChange
]]
function Train.Bind(deps: {
	hasPass: (Player, string) -> boolean,
	getPasses: (Player) -> { [string]: boolean },
	isInBattle: (Player) -> boolean,
	afterChange: (Player, { [string]: any }, boolean) -> (),
})
	_hasPass = deps.hasPass
	_getPasses = deps.getPasses
	_isInBattle = deps.isInBattle
	_afterChange = deps.afterChange
end

--[[
	角色是否装备指定哑铃
	@param plr Player - 玩家
	@return boolean - 已装备为 true
]]
local function _hasDumbbell(plr: Player): boolean
	local char = plr.Character
	if not char then
		return false
	end
	local tool = char:FindFirstChildOfClass("Tool")
	return tool ~= nil and tool.Name == ArmWrestleConfig.TOOL_NAME
end

--[[
	处理一次训练请求
	@param plr Player - 玩家
	@return nil
]]
function Train.OnTrain(plr: Player)
	if not _isInBattle or not _getPasses or not _afterChange then
		return
	end
	if _isInBattle(plr) then
		return
	end
	local data = Profile.Get(plr)
	if not data then
		return
	end
	if not _hasDumbbell(plr) then
		return
	end
	local tiers = ArmWrestleConfig.GetTrainSpeed()
	local tier = tiers[data.TrainTier] or tiers[1]
	local cooldown = (tier and tier.Value or 1) / Potion.GetMult(plr, "TrainSpeed")
	local now = os.clock()
	if _lastTrain[plr] and now - _lastTrain[plr] < cooldown * 0.8 then
		return
	end
	_lastTrain[plr] = now
	local passes = _getPasses(plr)
	local perClick = select(1, Profile.GetMults(plr, data, passes))
	local reached = Profile.AddStrength(plr, data, perClick, passes)
	if not Profile.Save(plr, data) then
		Log.warn("SystemArmWrestle.Train 存档失败", plr.UserId)
		return
	end
	_afterChange(plr, data, false)
	if reached then
		local level = ArmWrestleConfig.GetLevel(data.Unlocked + 1)
		if level then
			TipsModule.NormalTips(plr, "可以解锁新关卡", { { level.ZhName } })
		end
	end
end

--[[
	玩家离场清理
	@param plr Player - 玩家
]]
function Train.OnPlayerRemoving(plr: Player)
	_lastTrain[plr] = nil
end

return Train
