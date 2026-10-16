--[[
	Module: WorldText
	Description: 扳手腕世界 3D UI 动态文案本地化：对手名字 / 推荐力量 / 胜利奖励、材质机购买价、升级垫价签、限量展台属性与库存
	Author: 程莘
	Created: 2026-10-15
	Last Modified: 2026-10-16

	功能：
	- BindWorld：扫描 World 下已流入的标签并监听 DescendantAdded，按所属模型从 ArmWrestleConfig 取数，
	  经 TranslationHelper.SetText 写带 {1} 的翻译键；切语言由 TranslationManager 统一刷新
	- 覆盖：Table_<对手Id> 下头顶 Info 名字行（配置 ZhName）/ Info.Power / Info.Reward；Machine_<关卡> 下 Info.Price；
	  Pad_*（Kind=TrainSpeed/WalkSpeed）下 Info.Price（配置价经 Format 缩写为 K/M…）；
	  LimitedStand 下 Info.Stats / Info.Stock
	- 库存读 LimitedStand 的 Left 属性（服务端 Economy 唯一写入），属性变化时重刷

	约束：
	- 纯表现：数值只读配置与服务端属性，不参与任何结算
	- 场景里这些标签的原始 Text 只是编辑期占位，运行时以配置为准
	- 升级垫 Change（档位效果）仍用场景原文（数值小，无需缩写）；关卡门文案由 GateFx 处理（面板克隆在 PlayerGui）
	- StreamingEnabled：标签流出再流入是新实例，DescendantAdded 时重写

	加载（仅 SystemArmWrestle 内部使用）：
		local WorldText = require(script.WorldText)
		WorldText.BindWorld(world)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ArmWrestleConfig = Utils.ArmWrestleConfig
local TranslationHelper = Utils.TranslationHelper

local WorldText = {}

local TABLE_PATTERN = "^Table_(.+)$"
local MACHINE_PATTERN = "^Machine_(%d+)$"
local STAND_PATTERN = "^LimitedStand$"
-- 头顶 Info 里这三行不是名字。名字行带标签「本地化」，TranslationManager 用 Instance.Name 当键；
-- 场景名是编辑期占位（如「晨跑少年」），不改名就会显示「未本地化-晨跑少年」
local OPPONENT_INFO_SKIP = {
	Power = true,
	Reward = true,
	Status = true,
}
local LEFT_ATTR = "Left"
local ATTR_KIND = "Kind"
local ATTR_TIER = "Tier"
local KIND_TRAIN = "TrainSpeed"
local KIND_WALK = "WalkSpeed"
local LIMITED_ARM_ID = ArmWrestleConfig.LIMITED_ARM_ID

local _world: Instance? = nil
local _watchedStands: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local _handlers: { [string]: (TextLabel) -> () } = {}

--[[
	向上查找名字匹配模式的最近祖先（止于 World 根）
	@param label Instance - 起点标签
	@param pattern string - Lua 模式，可带一个捕获
	@return Instance? - 命中的祖先；未命中为 nil
	@return string? - 模式第一个捕获；未命中为 nil
]]
local function _findAncestor(label: Instance, pattern: string): (Instance?, string?)
	local node = label.Parent
	while node and node ~= _world do
		local capture = string.match(node.Name, pattern)
		if capture then
			return node, capture
		end
		node = node.Parent
	end
	return nil, nil
end

--[[
	向上查找带 Kind=TrainSpeed/WalkSpeed 的升级垫 Model
	@param label Instance - 起点标签
	@return Instance? - 垫子模型；未命中为 nil
]]
local function _findPad(label: Instance): Instance?
	local node = label.Parent
	while node and node ~= _world do
		if node:IsA("Model") then
			local kind = node:GetAttribute(ATTR_KIND)
			if kind == KIND_TRAIN or kind == KIND_WALK then
				return node
			end
		end
		node = node.Parent
	end
	return nil
end

--[[
	Table_ 头顶 Billboard 里、除力量/奖励/状态外的那一行是对手名字
	@param label TextLabel - Head.Info 下的名字标签
	@return boolean - 是名字行时为 true
]]
local function _isOpponentNameLabel(label: TextLabel): boolean
	if OPPONENT_INFO_SKIP[label.Name] then
		return false
	end
	local parent = label.Parent
	if not parent or parent.Name ~= "Info" or not parent:IsA("BillboardGui") then
		return false
	end
	return _findAncestor(label, TABLE_PATTERN) ~= nil
end

--[[
	对手头顶名字。静态标签「本地化」会在本函数之前或之后用 Instance.Name 再刷一次，
	所以必须先把实例名改成配置 ZhName，再按该键 SetText
	@param label TextLabel - Head.Info 下的名字标签
]]
local function _applyOpponentName(label: TextLabel)
	local _, id = _findAncestor(label, TABLE_PATTERN)
	local opponent = if id then ArmWrestleConfig.GetOpponent(id) else nil
	local zhName = opponent and opponent.ZhName
	if type(zhName) ~= "string" or zhName == "" then
		return
	end
	label.Name = zhName
	TranslationHelper.SetText(label, zhName)
end

--[[
	对手头顶推荐力量 / 胜利奖励（Table_<对手Id> 对应 ArmWrestleConfig 对手 Id）
	@param label TextLabel - Info.Power 或 Info.Reward
]]
local function _applyOpponent(label: TextLabel)
	local _, id = _findAncestor(label, TABLE_PATTERN)
	local opponent = if id then ArmWrestleConfig.GetOpponent(id) else nil
	if not opponent then
		return
	end
	if label.Name == "Power" then
		TranslationHelper.SetText(label, "推荐力量值", { ArmWrestleConfig.Format(opponent.Power) })
	else
		TranslationHelper.SetText(label, "胜利奖励", { ArmWrestleConfig.Format(opponent.Reward) })
	end
end

--[[
	材质机价签（Machine_<关卡下标>；展示池内最低材质购买价；抽取免费）
	@param label TextLabel - Info.Price
]]
local function _applyMachinePrice(label: TextLabel)
	local _, index = _findAncestor(label, MACHINE_PATTERN)
	local level = if index then ArmWrestleConfig.GetLevel(tonumber(index) :: number) else nil
	local machine = level and level.Machine
	if type(machine) ~= "table" then
		return
	end
	local best: number? = nil
	for _, id in ipairs(machine.Pool or {}) do
		local mat = ArmWrestleConfig.GetMaterial(id)
		local price = mat and mat.Price
		if type(price) == "number" and price > 0 and (not best or price < best) then
			best = price
		end
	end
	if not best then
		return
	end
	TranslationHelper.SetText(label, "现金价格", { ArmWrestleConfig.Format(best) })
end

--[[
	升级垫现金价签（Pad Kind/Tier → TrainSpeed / WalkSpeed 配置 Price，经 Format 缩写）
	@param label TextLabel - Info.Price
]]
local function _applyPadPrice(label: TextLabel)
	local pad = _findPad(label)
	if not pad then
		return
	end
	local kind = pad:GetAttribute(ATTR_KIND)
	local tier = pad:GetAttribute(ATTR_TIER)
	if type(tier) ~= "number" then
		return
	end
	local list = if kind == KIND_TRAIN then ArmWrestleConfig.GetTrainSpeed() else ArmWrestleConfig.GetWalkSpeed()
	local row = list[tier]
	local price = row and row.Price
	if type(price) ~= "number" then
		return
	end
	TranslationHelper.SetText(label, "现金价格", { ArmWrestleConfig.Format(price) })
end

--[[
	价签分派：扭蛋机优先，否则升级垫
	@param label TextLabel - Info.Price
]]
local function _applyPrice(label: TextLabel)
	if _findAncestor(label, MACHINE_PATTERN) then
		_applyMachinePrice(label)
		return
	end
	_applyPadPrice(label)
end

--[[
	限量展台属性行（倍率取限量手臂配置）
	@param label TextLabel - Info.Stats
]]
local function _applyStandStats(label: TextLabel)
	if not _findAncestor(label, STAND_PATTERN) then
		return
	end
	local arm = ArmWrestleConfig.GetArm(LIMITED_ARM_ID)
	if not arm then
		return
	end
	TranslationHelper.SetText(label, "限量展台属性", { ArmWrestleConfig.Format(arm.Mult) })
end

--[[
	按展台 Left 属性写库存文案；属性尚未下发时保持原文，等属性变化再刷
	@param stand Instance - LimitedStand
	@param label TextLabel - Info.Stock
]]
local function _writeStock(stand: Instance, label: TextLabel)
	local left = stand:GetAttribute(LEFT_ATTR)
	if type(left) ~= "number" then
		return
	end
	if left <= 0 then
		TranslationHelper.SetText(label, "已售罄")
		return
	end
	local arm = ArmWrestleConfig.GetArm(LIMITED_ARM_ID)
	local limit = if arm and type(arm.Limited) == "number" then arm.Limited else left
	TranslationHelper.SetText(label, "限量剩余", { left, limit })
end

--[[
	展台 Left 属性只监听一次；回调时重新取当前 Stock 标签（流入后可能已换实例）
	@param stand Instance - LimitedStand
]]
local function _watchStand(stand: Instance)
	if _watchedStands[stand] then
		return
	end
	_watchedStands[stand] = true
	stand:GetAttributeChangedSignal(LEFT_ATTR):Connect(function()
		local holder = stand:FindFirstChild("Holder")
		local info = holder and holder:FindFirstChild("Info")
		local stock = info and info:FindFirstChild("Stock")
		if stock and stock:IsA("TextLabel") then
			_writeStock(stand, stock)
		end
	end)
end

--[[
	限量库存行
	@param label TextLabel - Info.Stock
]]
local function _applyStandStock(label: TextLabel)
	local stand = _findAncestor(label, STAND_PATTERN)
	if not stand then
		return
	end
	_watchStand(stand)
	_writeStock(stand, label)
end

_handlers.Power = _applyOpponent
_handlers.Reward = _applyOpponent
_handlers.Price = _applyPrice
_handlers.Stats = _applyStandStats
_handlers.Stock = _applyStandStock

--[[
	节点是受管标签时按名字分派；对手名字行的实例名是编辑期占位，单独识别
	@param desc Instance - World 后代
]]
local function _tryApply(desc: Instance)
	if not desc:IsA("TextLabel") then
		return
	end
	local handler = _handlers[desc.Name]
	if handler then
		handler(desc)
		return
	end
	if _isOpponentNameLabel(desc) then
		_applyOpponentName(desc)
	end
end

--[[
	绑定世界：先处理已流入的标签，再监听后续流入
	@param world Instance - Workspace.World
]]
function WorldText.BindWorld(world: Instance)
	if _world then
		return
	end
	_world = world
	for _, desc in ipairs(world:GetDescendants()) do
		_tryApply(desc)
	end
	world.DescendantAdded:Connect(_tryApply)
end

return WorldText
