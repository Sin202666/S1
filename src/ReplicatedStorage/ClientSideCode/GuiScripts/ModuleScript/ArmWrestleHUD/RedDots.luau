--[[
	Module: RedDots
	Description: ArmWrestleHUD 左栏 手臂/哑铃 按钮红点（只读服务端镜像，仅展示）
	Author: 程莘
	Created: 2026-10-15
	Last Modified: 2026-10-16

	红点条件：
	- 手臂：有买得起、且倍率高于已拥有最高倍率的未拥有现金手臂
	- 哑铃：有买得起、且倍率高于已拥有最高倍率的未拥有哑铃
	- 已拥有更好或相同倍率时不提示（含未装备）；材质不提示
	- 商店无红点

	静态 UI（Studio 维护，节点名为代码契约）：
	- Left.ArmsButton / DumbbellButton 下的 Frame "Badge"（红色 ❗：子 ImageLabel Icon 贴图，默认 Visible=false）

	与相关模块：
	- ArmWrestleHUD：_bindHud 时 Bind(left)，4Hz _refresh 时 Refresh()
	- 拥有表 / 金币经 Common 读取，与 Panels / DumbbellPanel 同源

	加载：
		local RedDots = require(script.RedDots)
		RedDots.Bind(leftFrame)
		RedDots.Refresh()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ArmWrestleConfig = Utils.ArmWrestleConfig
local UIanima = Utils.UIanima

local Common = require(script.Parent.Common)

local RedDots = {}

local BADGE_NAME = "Badge"
-- 按钮名 → 红点业务键（与 _evaluators 对应）
local BUTTON_KEYS: { [string]: string } = {
	ArmsButton = "Arms",
	DumbbellButton = "Dumbbells",
}

local _badges: { [string]: GuiObject } = {}

--[[
	已拥有条目里的最高倍率
	@param rows table - 配置列表 { { Id, Mult } }
	@param owned table - 拥有表 { [tostring(Id)] = true }
	@return number - 最高倍率；没有已拥有条目时为 0
]]
local function _bestOwnedMult(rows: { { [string]: any } }, owned: { [string]: any }): number
	local best = 0
	for _, row in ipairs(rows) do
		local mult = row.Mult
		if owned[tostring(row.Id)] == true and type(mult) == "number" and mult > best then
			best = mult
		end
	end
	return best
end

--[[
	是否有买得起、且倍率高于已拥有最高倍率的未拥有现金商品（Robux 商品不计）
	已拥有更好或相同倍率时，不再为更差的可买项提示
	@param rows table - 配置列表 { { Id, Mult, Price, Robux? } }
	@param owned table - 拥有表 { [tostring(Id)] = true }
	@param cash number - 当前金币
	@return boolean - 有可购买的更高倍率项时为 true
]]
local function _hasAffordable(rows: { { [string]: any } }, owned: { [string]: any }, cash: number): boolean
	local bestOwned = _bestOwnedMult(rows, owned)
	for _, row in ipairs(rows) do
		local mult = row.Mult
		if
			not row.Robux
			and type(row.Price) == "number"
			and type(mult) == "number"
			and owned[tostring(row.Id)] ~= true
			and cash >= row.Price
			and mult > bestOwned
		then
			return true
		end
	end
	return false
end

--[[
	手臂红点：只提示买得起且倍率更高的未拥有现金手臂
	@param data table - ArmWrestle 档案镜像
	@param cash number - 当前金币
	@return boolean - 是否显示
]]
local function _evalArms(data: { [string]: any }, cash: number): boolean
	local owned = if type(data.Arms) == "table" then data.Arms else {}
	return _hasAffordable(ArmWrestleConfig.GetArms(), owned, cash)
end

--[[
	哑铃红点：只提示买得起且倍率更高的未拥有哑铃
	@param data table - ArmWrestle 档案镜像
	@param cash number - 当前金币
	@return boolean - 是否显示
]]
local function _evalDumbbells(data: { [string]: any }, cash: number): boolean
	local owned = if type(data.Dumbbells) == "table" then data.Dumbbells else { ["1"] = true }
	return _hasAffordable(ArmWrestleConfig.GetDumbbells(), owned, cash)
end

local _evaluators: { [string]: (data: { [string]: any }, cash: number) -> boolean } = {
	Arms = _evalArms,
	Dumbbells = _evalDumbbells,
}

--[[
	设置红点显隐并播放/停止提醒动画
	@param badge GuiObject - 红点节点
	@param visible boolean - 是否显示
]]
local function _setBadge(badge: GuiObject, visible: boolean)
	if badge.Visible == visible then
		return
	end
	badge.Visible = visible
	if visible then
		UIanima.RedPointAnim(badge)
	else
		UIanima.StopRedPointAnim(badge)
	end
end

--[[
	按当前镜像刷新全部红点（ArmWrestleHUD 4Hz 调用）
]]
function RedDots.Refresh()
	if next(_badges) == nil then
		return
	end
	local data = Common.Data()
	local cash = Common.Coin()
	for key, badge in pairs(_badges) do
		_setBadge(badge, _evaluators[key](data, cash))
	end
end

--[[
	绑定左栏按钮下的 Badge 节点（ArmWrestleHUD._bindHud 调用一次）
	@param left Frame - ArmWrestleHUD.Left
]]
function RedDots.Bind(left: Frame)
	for btnName, key in pairs(BUTTON_KEYS) do
		local badge = Common.Get(left, btnName, BADGE_NAME) :: GuiObject
		badge.Visible = false
		_badges[key] = badge
	end
end

return RedDots
