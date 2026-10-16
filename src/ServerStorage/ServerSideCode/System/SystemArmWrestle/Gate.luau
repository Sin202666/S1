--[[
	Module: Gate
	Description: 扳手腕关卡门解锁结算：玩家点击门上解锁，服务端校验顺序/力量后推进 Unlocked
	Author: 程莘
	Created: 2026-10-14
	Last Modified: 2026-10-16

	功能：
	- BindWorld：缓存 Workspace.World.Zone_N.Gate_N（服务端无流式，引用稳定）
	- OnUnlock：经 SystemArmWrestle 的 ARM_WRESTLE_ACTION("UnlockLevel", levelIndex) 调入
	  对局中 / 力量不足均给玩家错误提示（不校验与门的距离；门面板远处可见可点，静默拒绝会被当成按钮失灵）

	与相关模块：
	- 力量门槛读 ArmWrestleConfig 关卡 Gate；不扣力量/金币
	- Profile.AddStrength 不再自动解锁，只在跨门槛时提示
	- 写档走 deps.commit（Profile.Commit 原子提交 + 镜像同步）
	- 客户端 GateFx 只读 Unlocked Attribute 做按钮/特效，不参与结算

	加载（仅 SystemArmWrestle/init 内部使用）：
		local Gate = require(script.Gate)
		Gate.Bind({ isInBattle = Battle.IsInBattle, commit = _commit })
		Gate.BindWorld(world)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ArmWrestleConfig = Utils.ArmWrestleConfig
local TipsModule = Utils.TipsModule
local Log = Utils.Log

local Profile = require(script.Parent.Profile)

local Gate = {}

local _gates: { [number]: BasePart } = {}
local _isInBattle: ((Player) -> boolean)?
local _commit: ((Player, { [string]: any }) -> boolean)?

--[[
	注入依赖
	@param deps table - isInBattle (Player)->boolean 对局判定；commit (Player, data)->boolean 写档并同步镜像
]]
function Gate.Bind(deps: {
	isInBattle: (Player) -> boolean,
	commit: (Player, { [string]: any }) -> boolean,
})
	_isInBattle = deps.isInBattle
	_commit = deps.commit
end

--[[
	缓存世界中的关卡门
	@param world Instance - Workspace.World（子级 Zone_N 下的 Gate_N BasePart）
]]
function Gate.BindWorld(world: Instance)
	table.clear(_gates)
	for _, zone in ipairs(world:GetChildren()) do
		for _, child in ipairs(zone:GetChildren()) do
			local index = tonumber(string.match(child.Name, "^Gate_(%d+)$"))
			if index and child:IsA("BasePart") then
				_gates[index] = child
			end
		end
	end
end

--[[
	玩家请求解锁关卡（只能解锁下一关；力量达到门槛即可，不消耗）
	@param plr Player - 玩家（NetWork 已校验在线）
	@param levelIndex any - 客户端传入的目标关卡下标，须为 Unlocked + 1
	@return boolean - 是否解锁成功
	@return string? - 失败码：invalid / battle / strength / save
]]
function Gate.OnUnlock(plr: Player, levelIndex: any): (boolean, string?)
	if not _isInBattle or not _commit then
		return false, "invalid"
	end
	local data = Profile.Get(plr)
	if not data or type(levelIndex) ~= "number" or levelIndex ~= (data.Unlocked or 1) + 1 then
		return false, "invalid"
	end
	local level = ArmWrestleConfig.GetLevel(levelIndex)
	local part = _gates[levelIndex]
	if not level or not part then
		return false, "invalid"
	end
	if _isInBattle(plr) then
		TipsModule.ErrorTips(plr, "对局中无法操作")
		return false, "battle"
	end
	local strength = data.Strength or 0
	if strength < level.Gate then
		TipsModule.ErrorTips(plr, "解锁力量不足", { ArmWrestleConfig.Format(math.ceil(level.Gate - strength)) })
		return false, "strength"
	end
	data.Unlocked = levelIndex
	if not _commit(plr, data) then
		Log.warn("SystemArmWrestle.Gate 解锁写档失败", plr.UserId, levelIndex)
		return false, "save"
	end
	TipsModule.NormalTips(plr, "解锁新关卡", { { level.ZhName } })
	return true
end

return Gate
