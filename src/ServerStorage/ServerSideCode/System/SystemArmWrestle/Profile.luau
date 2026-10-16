--[[
	Module: Profile
	Description: 扳手腕存档读写、力量/金币结算与客户端镜像（新手引导推进在 SystemGuide）
	Author: 程莘
	Created: 2026-10-14
	Last Modified: 2026-10-15

	只经 PlayerData.ChangePlrData（内部 SystemSave.ChangeStat）。不直连 DataStore。
	货币即背包金币（itemdataConf id=1，EnumMgr.ItemID.Coin），唯一写口为 SystemBag；
	ArmWrestle.Cash 存档字段已废弃：业务不再读改，整树写回时原样带过（老存档余额不迁移）。
	扣/加金币与档案写回须走 Profile.Commit，同一 SystemSave.Mutate 内原子提交。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local PlayerData = Utils.PlayerData
local ArmWrestleConfig = Utils.ArmWrestleConfig
local EnumMgr = Utils.EnumMgr
local RankConfig = Utils.RankConfig
local SystemRecord = Utils.SystemRecord
local SystemSave = Utils.SystemSave
local SystemBag = Utils.SystemBag
local Log = Utils.Log

local Potion = require(script.Parent.Potion)
local Boost = require(script.Parent.Boost)

local Profile = {}

local STAT_ROOT = "ArmWrestle"
local COIN_ID = EnumMgr.ItemID.Coin
local PlayerAttr = EnumMgr.PlayerAttr
local RECORD_STRENGTH = RankConfig.GetRecordField(RankConfig.RANK_STRENGTH_NAME) :: string

--[[
	是否在线有效玩家
	@param plr any - 待校验
	@return boolean - 有效为 true
]]
local function _isPlayer(plr: any): boolean
	return typeof(plr) == "Instance" and plr:IsA("Player") and plr.Parent ~= nil
end

--[[
	集合表转逗号串（客户端只读镜像，Attribute 不能存表）
	@param set table - { [key] = true }
	@return string - 排序后逗号分隔；空集为 ""
]]
local function _joinKeys(set: { [string]: boolean }): string
	local keys = {}
	for key, on in pairs(set) do
		if on then
			table.insert(keys, tostring(key))
		end
	end
	table.sort(keys)
	return table.concat(keys, ",")
end

--[[
	读取并补全 ArmWrestle 子树（深拷贝）
	@param plr Player - 玩家
	@return table? - 可变副本；会话未加载完为 nil
]]
function Profile.Get(plr: Player): { [string]: any }?
	if not _isPlayer(plr) then
		return nil
	end
	-- SaveMetaData 已含 ArmWrestle，加载时会补全；读不到即会话未就绪，不能用默认档案顶替
	local data = PlayerData.GetPlrDataByKey(plr, STAT_ROOT)
	if type(data) ~= "table" then
		return nil
	end
	local defaults = ArmWrestleConfig.GetDefaultProfile()
	for key, value in pairs(defaults) do
		if data[key] == nil then
			data[key] = value
		end
	end
	if type(data.Arms) ~= "table" then
		data.Arms = { ["1"] = true }
	end
	if type(data.Mats) ~= "table" then
		data.Mats = {}
	end
	if type(data.Dumbbells) ~= "table" then
		data.Dumbbells = { ["1"] = true }
	end
	if type(data.PotionLeft) ~= "table" then
		data.PotionLeft = {}
	end
	if not data.Dumbbells[tostring(data.Dumbbell)] then
		data.Dumbbell = 1
	end
	return data
end

--[[
	整树写回存档
	@param plr Player - 玩家
	@param data table - 完整 ArmWrestle 表
	@return boolean - 是否成功
]]
function Profile.Save(plr: Player, data: { [string]: any }): boolean
	if not _isPlayer(plr) or type(data) ~= "table" then
		return false
	end
	local ok, err = PlayerData.ChangePlrData(plr, STAT_ROOT, data)
	if not ok then
		Log.warn("SystemArmWrestle.Profile.Save 失败", plr.UserId, err)
		return false
	end
	return true
end

--[[
	每次训练的基础力量（不含药水等会话临时加成）：手臂 × 材质 × 哑铃 × 力量倍数档，2 倍力量通行证再 ×2
	@param data table - 档案（读 Arm / Mat / Dumbbell / StrengthTier）
	@param ownedPasses table - 会话通行证 { [key] = true }
	@return number - 基础每次训练力量
]]
function Profile.GetBaseStrength(data: { [string]: any }, ownedPasses: { [string]: boolean }): number
	local arm = ArmWrestleConfig.GetArm(data.Arm) or ArmWrestleConfig.GetArm(1)
	local mat = ArmWrestleConfig.GetMaterial(data.Mat)
	local dumbbell = ArmWrestleConfig.GetDumbbell(data.Dumbbell)
	local strength = (arm and arm.Mult or 1) * (mat and mat.Mult or 1) * (dumbbell and dumbbell.Mult or 1)
	strength *= ArmWrestleConfig.GetStrengthTierMult(data.StrengthTier)
	if ownedPasses.DoubleStrength then
		strength *= 2
	end
	return strength
end

--[[
	力量/现金/装备倍率（每次训练力量 = GetBaseStrength × 力量药水；
	现金倍率 = 2 倍金钱通行证 × 金币药水 × 好友/会员加成 Boost.GetCashMult）
	@param plr Player - 玩家（读其会话药水与好友/会员加成）
	@param data table - 档案（读 Arm / Mat / Dumbbell / StrengthTier）
	@param ownedPasses table - 会话通行证
	@return number - 每次训练力量
	@return number - 现金倍率
]]
function Profile.GetMults(plr: Player, data: { [string]: any }, ownedPasses: { [string]: boolean }): (number, number)
	local strength = Profile.GetBaseStrength(data, ownedPasses)
	strength *= Potion.GetMult(plr, "Strength")
	local cash = if ownedPasses.DoubleCash then 2 else 1
	cash *= Potion.GetMult(plr, "Cash")
	cash *= Boost.GetCashMult(plr)
	return strength, cash
end

--[[
	已解锁关最高对手奖励
	@param data table - 档案
	@return number - 奖励
]]
function Profile.BestReward(data: { [string]: any }): number
	local levels = ArmWrestleConfig.GetLevels()
	local unlocked = math.clamp(data.Unlocked or 1, 1, #levels)
	local level = levels[unlocked]
	local opponents = level and level.Opponents
	if not opponents or #opponents == 0 then
		return 0
	end
	return opponents[#opponents].Reward or 0
end

--[[
	同步 Attribute / 排行分（不写 WalkSpeed）；OwnedPasses、FriendBoost / PremiumBoost（整数百分比）与药水镜像（Potion.SyncAttributes）仅供界面展示
	@param plr Player - 玩家
	@param data table - 档案
	@param ownedPasses table - 通行证 { [key] = true }
]]
function Profile.Sync(plr: Player, data: { [string]: any }, ownedPasses: { [string]: boolean })
	if not _isPlayer(plr) then
		return
	end
	local perClick, cashMult = Profile.GetMults(plr, data, ownedPasses)
	plr:SetAttribute("Strength", data.Strength)
	plr:SetAttribute("Wins", data.Wins)
	plr:SetAttribute("Unlocked", data.Unlocked)
	plr:SetAttribute("TrainTier", data.TrainTier)
	plr:SetAttribute("SpeedTier", data.SpeedTier)
	plr:SetAttribute("Arm", data.Arm)
	plr:SetAttribute("Mat", data.Mat)
	plr:SetAttribute("Dumbbell", data.Dumbbell)
	plr:SetAttribute("StrengthTier", data.StrengthTier or 0)
	plr:SetAttribute("PerClick", perClick)
	plr:SetAttribute("CashMult", cashMult)
	plr:SetAttribute("FriendBoost", Boost.GetFriendPercent(plr))
	plr:SetAttribute("PremiumBoost", Boost.GetPremiumPercent(plr))
	plr:SetAttribute(PlayerAttr.InBattle, plr:GetAttribute(PlayerAttr.InBattle) == true)
	plr:SetAttribute("OwnedPasses", _joinKeys(ownedPasses))
	Potion.SyncAttributes(plr, data)
	if RECORD_STRENGTH then
		SystemRecord.RecordCover(plr, RECORD_STRENGTH, math.floor(data.Strength or 0))
	end
end

--[[
	加力量；关卡不在此自动解锁，须玩家点击门上解锁按钮（Gate.OnUnlock，不要求靠近）
	@param plr Player - 玩家
	@param data table - 档案（原地）
	@param amount number - 增量
	@param ownedPasses table - 通行证
	@return boolean - 本次是否刚跨过下一关力量门槛（用于提示去门前解锁）
]]
function Profile.AddStrength(plr: Player, data: { [string]: any }, amount: number, ownedPasses: { [string]: boolean }): boolean
	if type(amount) ~= "number" or amount <= 0 then
		return false
	end
	local before = data.Strength or 0
	data.Strength = before + amount
	local nextLevel = ArmWrestleConfig.GetLevel((data.Unlocked or 1) + 1)
	local reached = nextLevel ~= nil and before < nextLevel.Gate and data.Strength >= nextLevel.Gate
	return reached
end

--[[
	当前背包金币数量
	@param plr Player - 玩家
	@return number - 金币数；会话未就绪为 0
]]
function Profile.GetCoin(plr: Player): number
	if not _isPlayer(plr) then
		return 0
	end
	return SystemBag.GetItemCountByID(plr, COIN_ID)
end

--[[
	金币变动与档案写回原子提交（同一 SystemSave.Mutate；任一步失败整笔不生效）
	@param plr Player - 玩家
	@param data table - 完整 ArmWrestle 表
	@param coinDelta number? - 金币增减；正数 floor 后入包，负数 ceil 后扣除；nil/0 仅写档
	@return boolean - 是否成功
	@return string? - 失败码（INSUFFICIENT_COUNT 余额不足 / INVALID_PLAYER 等）
]]
function Profile.Commit(plr: Player, data: { [string]: any }, coinDelta: number?): (boolean, string?)
	if not _isPlayer(plr) or type(data) ~= "table" then
		return false, "INVALID_PLAYER"
	end
	local delta = if type(coinDelta) == "number" and coinDelta == coinDelta then coinDelta else 0
	local ok, err = SystemSave.Mutate(plr, function()
		if delta > 0 then
			local gain = math.floor(delta)
			if gain > 0 then
				local added, addErr = SystemBag.AddItems(plr, { COIN_ID }, { gain })
				if not added then
					return false, addErr
				end
			end
		elseif delta < 0 then
			local removed, removeErr = SystemBag.RemoveItem(plr, { COIN_ID }, { math.ceil(-delta) })
			if not removed then
				return false, removeErr
			end
		end
		return PlayerData.ChangePlrData(plr, STAT_ROOT, data)
	end)
	if not ok then
		Log.warn("SystemArmWrestle.Profile.Commit 失败", plr.UserId, delta, err)
		return false, err
	end
	return true
end

return Profile
