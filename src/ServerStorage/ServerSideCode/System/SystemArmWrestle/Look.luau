--[[
	Module: Look
	Description: 扳手腕手臂外观（原双臂隐藏，换 ArmSkin 外壳上颜色/材质/特效）与哑铃 Tool 发放/换款，不写 WalkSpeed / CFrame
	Author: 程莘
	Created: 2026-10-14
	Last Modified: 2026-10-15
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ArmWrestleConfig = Utils.ArmWrestleConfig
local ArmSkin = Utils.ArmSkin
local Log = Utils.Log

local Look = {}

local DUMBBELL_ATTR = "DumbbellId"
-- 会盖住手臂的分层衣服类型；裤/鞋等不遮手臂的保留
local ARM_COVER_ACCESSORY = {
	[Enum.AccessoryType.Shirt] = true,
	[Enum.AccessoryType.TShirt] = true,
	[Enum.AccessoryType.Jacket] = true,
	[Enum.AccessoryType.Sweater] = true,
	[Enum.AccessoryType.DressSkirt] = true,
}

-- 角色 → 最近一次 Apply 的档案；弱键避免持有已销毁角色
local _watched: { [Model]: { [string]: any } } = setmetatable({}, { __mode = "k" }) :: any

--[[
	判断角色子物体是否为会盖住手臂外壳的分层衣服（经典 Shirt 印在已隐藏的原手臂上，不算）
	@param inst Instance - 角色直接子物体
	@return boolean - 遮手臂的分层衣服 Accessory 为 true
]]
local function _isArmCover(inst: Instance): boolean
	return inst:IsA("Accessory") and ARM_COVER_ACCESSORY[inst.AccessoryType] == true
end

--[[
	移除盖住手臂外壳的分层衣服
	@param char Model - 角色
	@return nil
]]
local function _stripArmCover(char: Model)
	for _, child in ipairs(char:GetChildren()) do
		if _isArmCover(child) then
			child:Destroy()
		end
	end
end

--[[
	角色外观（分层衣服 / 身体部件）在 CharacterAdded 后异步加载，原手臂部件被替换或加了衣服时重新套用手臂外观；每个角色只连一次
	@param plr Player - 玩家
	@param char Model - 角色
	@param data table - ArmWrestle 档案
	@return nil
]]
local function _watchCharacter(plr: Player, char: Model, data: { [string]: any })
	local isNew = _watched[char] == nil
	_watched[char] = data
	if not isNew then
		return
	end
	char.ChildAdded:Connect(function(child)
		local isArmPart = child:IsA("BasePart") and ArmSkin.IsArmPartName(child.Name)
		if not (isArmPart or _isArmCover(child)) then
			return
		end
		task.defer(function()
			local latest = _watched[char]
			if latest and plr.Character == char then
				Look.Apply(plr, latest)
			end
		end)
	end)
end

--[[
	按装备手臂/材质改角色外观：隐藏原双臂换成 ArmSkin 外壳，并移除会盖住外壳的分层衣服
	@param plr Player - 玩家
	@param data table - ArmWrestle 档案；读 Arm(number) / Mat(string?)
	@return nil
]]
function Look.Apply(plr: Player, data: { [string]: any })
	local char = plr.Character
	if not char or type(data) ~= "table" then
		return
	end
	_watchCharacter(plr, char, data)
	_stripArmCover(char)
	ArmSkin.Apply(char, data.Arm, data.Mat)
end

--[[
	确保玩家持有当前装备款式的哑铃 Tool（唯一发放处）：克隆 ArmWrestleConfig.FindToolTemplate() 并按款式改色，放进 Backpack
	已有同款直接返回；款式不同则销毁旧 Tool 换新，旧 Tool 正在手持时新 Tool 代为装备（保持手持状态）
	Tool 名固定为 TOOL_NAME，训练校验与客户端挂钩只认名字；款式写在 Attribute DumbbellId
	@param plr Player - 玩家
	@param dumbbellId number - 当前装备哑铃 Id；无效时按 1
	@return Tool? - 已有或新克隆的 Tool；无 Backpack 或模板缺失时为 nil
]]
function Look.EnsureDumbbell(plr: Player, dumbbellId: number): Tool?
	local id = if ArmWrestleConfig.GetDumbbell(dumbbellId) then dumbbellId else 1
	local name = ArmWrestleConfig.TOOL_NAME
	local backpack = plr:FindFirstChildOfClass("Backpack")
	local character = plr.Character
	local held = character and character:FindFirstChild(name)
	local existing = if held and held:IsA("Tool") then held else backpack and backpack:FindFirstChild(name)
	local wasHeld = existing ~= nil and existing == held
	if existing and existing:IsA("Tool") then
		if existing:GetAttribute(DUMBBELL_ATTR) == id then
			return existing
		end
		existing:Destroy()
	end
	if not backpack then
		return nil
	end
	local template = ArmWrestleConfig.FindToolTemplate()
	if not template then
		Log.warn("SystemArmWrestle.Look 缺少哑铃模板", table.concat(ArmWrestleConfig.TOOL_ASSET_PATH, "."), name)
		return nil
	end
	local tool = template:Clone()
	ArmWrestleConfig.ApplyDumbbellLook(tool, id)
	tool:SetAttribute(DUMBBELL_ATTR, id)
	tool.Parent = backpack
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	if wasHeld and hum and hum.Health > 0 then
		hum:EquipTool(tool)
	end
	return tool
end

return Look
