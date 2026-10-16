--[[
	Module: DumbbellPanel
	Description: ArmWrestleHUD 哑铃弹窗（ScreenGui.ArmWrestleDumbbells）：哑铃卡片列表、购买解锁与装备切换请求
	Author: 程莘
	Created: 2026-10-14
	Last Modified: 2026-10-15

	静态 UI（Studio 维护，节点名为代码契约）：
	- ArmWrestleDumbbells：Title / CloseButton / Grid(UIListLayout 纵向列表，DumbbellTemp)
	- DumbbellTemp（横向行）：左 Preview(白底 ImageLabel) / 中 ItemName + Rarity + Mult(Icon=strength) / 右 Button.Label
	  行底色与稀有度文本按哑铃 Rarity 由 Cards.ApplyRarity 改模板 Fill（UIGradient），外框与文字描边一律黑色；Bricks 积木图由 UIMgr.BindBrickTiles 跟随上色

	规则：
	- 拥有表读 PlayerData ArmWrestle.Dumbbells，当前装备读 Attribute Dumbbell，均为服务端镜像只读
	- 购买 / 装备只发 BuyDumbbell / EquipDumbbell 请求，扣金币、发放、换 Tool 全在服务端 SystemArmWrestle
	- 卡片图标读配置条目 Icon（Cards.SetIcon）

	与相关模块：
	- Panels：负责弹窗外框绑定、开关路由与互斥，Bind 时把面板 Frame 传入；OnOpened / RenderDumbbells 转到 Render
	- Cards：卡片克隆、按钮、图标与清理

	加载：
		local DumbbellPanel = require(script.Parent.DumbbellPanel)
		DumbbellPanel.Bind(panelFrame)
		DumbbellPanel.Render()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local LocalPlayer = Utils.LocalPlayer
local ArmWrestleConfig = Utils.ArmWrestleConfig
local ArmWrestleStyle = Utils.ArmWrestleStyle
local TipsModule = Utils.TipsModule
local SystemUISfx = Utils.SystemUISfx

local Common = require(script.Parent.Common)
local Cards = require(script.Parent.Cards)

local Style = ArmWrestleStyle
local C = Style.Colors
local Format = ArmWrestleConfig.Format

local DumbbellPanel = {}

-- PlayerData 拥有表的复制可能晚于 Attribute，操作后补一次重绘
local DATA_SYNC_DELAY = 0.3
-- 行底色须为白：稀有度色由模板 Fill 渐变相乘得到，底色非白会压暗
local ROW_COLOR = Color3.new(1, 1, 1)

local _panel: Frame?
local _grid: ScrollingFrame?
local _template: Frame?

--[[
	发送购买或装备请求并提示结果
	@param dumbbell table - 哑铃配置条目 { Id, ZhName }
	@param has boolean - 是否已拥有（true 走装备，false 走购买）
]]
local function _request(dumbbell: { [string]: any }, has: boolean)
	if has then
		local ok, err = Common.Invoke("EquipDumbbell", dumbbell.Id)
		if not ok then
			Common.ShowErrorTip(err)
		end
	else
		local ok, err = Common.Invoke("BuyDumbbell", dumbbell.Id)
		if ok then
			TipsModule.NormalTips(LocalPlayer, "获得哑铃", { { dumbbell.ZhName } })
			SystemUISfx.PlaySuccess()
		else
			Common.ShowErrorTip(err)
		end
	end
	task.delay(DATA_SYNC_DELAY, DumbbellPanel.Render)
end

--[[
	渲染一张哑铃卡片
	@param grid ScrollingFrame - 网格
	@param template Frame - DumbbellTemp
	@param order number - 排序
	@param dumbbell table - 哑铃配置条目
	@param has boolean - 是否已拥有
	@param equipped boolean - 是否当前装备
	@param cash number - 当前金币（决定未拥有时按钮底色）
]]
local function _renderCard(grid: ScrollingFrame, template: Frame, order: number, dumbbell: { [string]: any }, has: boolean, equipped: boolean, cash: number)
	local card = Cards.Clone(template, grid, order, ROW_COLOR)
	Cards.ApplyRarity(card, dumbbell.Xyd)
	Cards.SetIcon(card, dumbbell.Icon)
	Common.SetText(Cards.Label(card, "Mult"), "倍率数值", { tostring(dumbbell.Mult) })
	Common.SetText(Cards.Label(card, "ItemName"), dumbbell.ZhName)
	local btn, lbl
	if has then
		btn, lbl = Cards.Button(card, if equipped then C.Equipped else C.Equip)
		Common.SetText(lbl, if equipped then "已装备" else "装备")
	else
		btn, lbl = Cards.Button(card, if cash >= dumbbell.Price then C.Green else C.Disabled)
		Common.SetText(lbl, "现金价格", { Format(dumbbell.Price) })
	end
	btn.MouseButton1Click:Connect(function()
		if not equipped then
			_request(dumbbell, has)
		end
	end)
end

--[[
	重绘哑铃列表（面板未绑定或不可见时跳过）
]]
function DumbbellPanel.Render()
	local panel, grid, template = _panel, _grid, _template
	if not panel or not grid or not template or not panel.Visible then
		return
	end
	Cards.Clear(grid)
	local data = Common.Data()
	local owned = if type(data.Dumbbells) == "table" then data.Dumbbells else { ["1"] = true }
	local current = Common.Attr("Dumbbell", 1)
	local cash = Common.Coin()
	for i, dumbbell in ipairs(ArmWrestleConfig.GetDumbbells()) do
		_renderCard(grid, template, i, dumbbell, owned[tostring(dumbbell.Id)] == true, current == dumbbell.Id, cash)
	end
end

--[[
	绑定哑铃弹窗节点（Panels.Bind 内调用一次）
	@param panel Frame - ScreenGui.ArmWrestleDumbbells（外框与关闭按钮已由 Panels 绑定）
]]
function DumbbellPanel.Bind(panel: Frame)
	_panel = panel
	Common.SetText(Common.Get(panel, "Title") :: TextLabel, "哑铃")
	local grid = Common.Get(panel, "Grid") :: ScrollingFrame
	_grid = grid
	_template = Common.Get(grid, "DumbbellTemp") :: Frame
end

return DumbbellPanel
