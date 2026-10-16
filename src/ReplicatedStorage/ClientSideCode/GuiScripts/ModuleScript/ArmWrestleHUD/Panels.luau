--[[
	Module: Panels
	Description: ArmWrestleHUD 弹窗：手臂/材质（页签）、商城（委托 ShopPanel）、哑铃（委托 DumbbellPanel）、传送（委托 TeleportPanel）
	Author: 程莘
	Created: 2026-10-14
	Last Modified: 2026-10-15

	静态 UI（Studio 维护于 StarterGui.ScreenGui，节点名为代码契约）：
	- ArmWrestleArms：Title / CloseButton / TabArms / TabMats（贴弹窗外左边缘竖排）/ Grid(UIListLayout 纵向列表，ArmTemp, MatTemp)
	- ArmTemp / MatTemp 与哑铃 DumbbellTemp 同款横向行：左 Preview / 中 ItemName + Rarity + Mult / 右 Button.Label
	- 行底色与稀有度文本按条目 Rarity 由 Cards.ApplyRarity 统一上色；外框与文字描边一律黑色
	- 主界面左栏只有「手臂」一个入口；材质页经页签或 OpenArms("Mats") 打开
	- ArmWrestleShop：Title / CloseButton / Scroll(四个分区)，渲染见 ShopPanel
	- ArmWrestleDumbbells：Title / CloseButton / Grid(DumbbellTemp)，渲染见 DumbbellPanel
	- ArmWrestleTeleport：Title / CloseButton / Grid(ZoneTemp)，渲染见 TeleportPanel
	- 模板 Visible=false，渲染时克隆为 "Card"；重绘只清 "Card"，模板保留（见 Cards）
	- ArmTemp / MatTemp 下 ImageLabel "Preview"：显示条目配置的 Icon（Cards.SetIcon）
	- 首个未拥有的金币手臂卡片 Button 带 Attribute GuideTarget = "BuyArm"，供新手引导箭头定位（UIGuide 按标记查找）

	开关：
	- 一律经 Common.ShowPopup → UIManager（PopUp/PopBack 动画，UIScale 由 UISetMgr 按 PC_Scale/Mobie_Scale 适配）
	- UIManager 显示后调 GuiScripts 同名模块 openUi → ArmWrestleHUD.OnPanelOpened → OnOpened：关其余面板并渲染
	拥有/装备状态只读服务端镜像；所有按钮只发请求。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local LocalPlayer = Utils.LocalPlayer
local ArmWrestleConfig = Utils.ArmWrestleConfig
local ArmWrestleStyle = Utils.ArmWrestleStyle
local TipsModule = Utils.TipsModule
local SystemUISfx = Utils.SystemUISfx

local Common = require(script.Parent.Common)
local Cards = require(script.Parent.Cards)
local DumbbellPanel = require(script.Parent.DumbbellPanel)
local ShopPanel = require(script.Parent.ShopPanel)
local TeleportPanel = require(script.Parent.TeleportPanel)

local Style = ArmWrestleStyle
local C = Style.Colors
local Format = ArmWrestleConfig.Format

local Panels = {}

-- 面板短名 → ScreenGui 下弹窗 Frame 名（同 GuiScripts 模块名，UIManager 按此路由）
local PANEL_UI_NAMES: { [string]: string } = {
	Arms = "ArmWrestleArms",
	Shop = "ArmWrestleShop",
	Dumbbells = "ArmWrestleDumbbells",
	Teleport = "ArmWrestleTeleport",
}
-- Roblox 私有区 Robux 字形（全项目统一用字形，不用 R$ 文本或图片）
local ROBUX_GLYPH = utf8.char(0xE002)
-- PlayerData 拥有表的复制可能晚于 Attribute，操作后补一次重绘
local DATA_SYNC_DELAY = 0.3
-- 手臂/材质行底色须为白：稀有度色由模板 Fill 渐变相乘得到，底色非白会压暗
local ROW_COLOR = Color3.new(1, 1, 1)
-- 新手引导按钮箭头定位标记（与 GameConfig「引导」popupUi.target 对应）；只打在首个未拥有的金币手臂上，与服务端 CanBuyArm 取价一致
local GUIDE_TARGET_ATTR = "GuideTarget"
local GUIDE_TARGET_BUY_ARM = "BuyArm"

local _panels: { [string]: Frame } = {}
local _armsTab = "Arms"
local _armsGrid: ScrollingFrame?
local _armTemp: Frame?
local _matTemp: Frame?
local _tabArms: TextButton?
local _tabMats: TextButton?

--[[
	绑定面板外框：标题文案、关闭按钮、图标
	@param screenGui ScreenGui - PlayerGui.ScreenGui
	@param name string - 面板短名 Arms / Shop
	@return Frame - 面板
]]
local function _bindPanel(screenGui: ScreenGui, name: string): Frame
	local uiName = PANEL_UI_NAMES[name]
	local panel = Common.Get(screenGui, uiName) :: Frame
	local close = Common.Get(panel, "CloseButton") :: TextButton
	close.MouseButton1Click:Connect(function()
		Common.ShowPopup(uiName, false)
	end)
	Style.BindIcons(panel)
	_panels[name] = panel
	return panel
end

--[[
	写入 Robux 价签（字形 + 数字，数字不翻译）
	@param lbl TextLabel - 价签
	@param robux number - Robux 价格
]]
local function _setRobuxPrice(lbl: TextLabel, robux: number)
	Common.SetRaw(lbl, ROBUX_GLYPH .. " " .. tostring(robux))
end

--[[
	渲染手臂页
	@param grid ScrollingFrame - 网格
	@param template Frame - ArmTemp
]]
local function _renderArmCards(grid: ScrollingFrame, template: Frame)
	local data = Common.Data()
	local cash = Common.Coin()
	local current = Common.Attr("Arm", 1)
	local guideMarked = false
	for i, arm in ipairs(ArmWrestleConfig.GetArms()) do
		local has = data.Arms[tostring(arm.Id)] == true
		local equipped = current == arm.Id
		local card = Cards.Clone(template, grid, i, ROW_COLOR)
		Cards.ApplyRarity(card, arm.Xyd)
		Common.SetText(Cards.Label(card, "Mult"), "倍率数值", { tostring(arm.Mult) })
		Cards.SetIcon(card, arm.Icon)
		Common.SetText(Cards.Label(card, "ItemName"), arm.ZhName)
		local btn, lbl
		if has then
			btn, lbl = Cards.Button(card, if equipped then C.Equipped else C.Equip)
			Common.SetText(lbl, if equipped then "已装备" else "装备")
		elseif arm.Robux then
			btn, lbl = Cards.Button(card, C.Magenta)
			_setRobuxPrice(lbl, arm.Robux)
		else
			btn, lbl = Cards.Button(card, if cash >= arm.Price then C.Green else C.Disabled)
			Common.SetText(lbl, "现金价格", { Format(arm.Price) })
			if not guideMarked and arm.Price > 0 then
				guideMarked = true
				btn:SetAttribute(GUIDE_TARGET_ATTR, GUIDE_TARGET_BUY_ARM)
			end
		end
		btn.MouseButton1Click:Connect(function()
			if has then
				Common.Invoke("EquipArm", arm.Id)
			elseif arm.Robux then
				Common.Purchase("Product", arm.ProductKey)
			else
				local ok, err = Common.Invoke("BuyArm", arm.Id)
				if ok then
					TipsModule.NormalTips(LocalPlayer, "获得手臂", { { arm.ZhName } })
					SystemUISfx.PlaySuccess()
				else
					Common.ShowErrorTip(err)
				end
			end
			task.delay(DATA_SYNC_DELAY, Panels.RenderArms)
		end)
	end
end

--[[
	渲染材质页
	@param grid ScrollingFrame - 网格
	@param template Frame - MatTemp
]]
local function _renderMatCards(grid: ScrollingFrame, template: Frame)
	local data = Common.Data()
	local current = Common.Attr("Mat", "")
	for i, mat in ipairs(ArmWrestleConfig.GetMaterials()) do
		local has = data.Mats[mat.Id] == true
		local equipped = current == mat.Id
		local card = Cards.Clone(template, grid, i, ROW_COLOR)
		Cards.ApplyRarity(card, mat.Xyd)
		Cards.SetIcon(card, mat.Icon)
		Common.SetText(Cards.Label(card, "Mult"), "倍率数值", { tostring(mat.Mult) })
		Common.SetText(Cards.Label(card, "ItemName"), mat.ZhName)
		local btn, lbl
		local product = mat.ProductKey and ArmWrestleConfig.GetProduct(mat.ProductKey)
		if has then
			btn, lbl = Cards.Button(card, if equipped then C.Equipped else C.Equip)
			Common.SetText(lbl, if equipped then "已装备" else "装备")
		elseif product then
			btn, lbl = Cards.Button(card, C.Magenta)
			_setRobuxPrice(lbl, product.Robux)
		else
			btn, lbl = Cards.Button(card, C.Disabled)
			Common.SetText(lbl, "去抽取")
			Style.SetIcon(lbl, "lock")
		end
		btn.MouseButton1Click:Connect(function()
			if has then
				Common.Invoke("EquipMat", mat.Id)
				task.delay(DATA_SYNC_DELAY, Panels.RenderArms)
			elseif product then
				Common.Purchase("Product", mat.ProductKey)
			else
				TipsModule.NormalTips(LocalPlayer, "在材质机抽取")
			end
		end)
	end
end

--[[
	切换面板（同名再点关闭）；实际显隐由 UIManager 完成，显示后回调 OnOpened
	@param name string - Arms / Shop / Dumbbells / Teleport
]]
function Panels.Open(name: string)
	local uiName = PANEL_UI_NAMES[name]
	if not uiName then
		return
	end
	Common.ShowPopup(uiName, nil)
end

--[[
	弹窗已显示：关闭其余面板并渲染本面板
	@param name string - Arms / Shop / Dumbbells / Teleport
]]
function Panels.OnOpened(name: string)
	for key, panel in pairs(_panels) do
		if key ~= name and panel.Visible then
			Common.ShowPopup(PANEL_UI_NAMES[key], false)
		end
	end
	if name == "Arms" then
		Panels.RenderArms()
	elseif name == "Shop" then
		ShopPanel.OnOpened()
	elseif name == "Dumbbells" then
		DumbbellPanel.Render()
	elseif name == "Teleport" then
		TeleportPanel.Render()
	end
end

--[[
	关闭全部面板（对局开始时）
]]
function Panels.CloseAll()
	for key, panel in pairs(_panels) do
		if panel.Visible then
			Common.ShowPopup(PANEL_UI_NAMES[key], false)
		end
	end
end

--[[
	打开手臂面板并指定页签；面板已开且换页签时只切页不关闭
	@param tab string - Arms / Mats
]]
function Panels.OpenArms(tab: string)
	local panel = _panels.Arms
	local switching = panel ~= nil and panel.Visible and _armsTab ~= tab
	_armsTab = tab
	if switching then
		Panels.RenderArms()
		return
	end
	Panels.Open("Arms")
end

--[[
	打开/关闭商城（打开时回到顶部的通行证区）
]]
function Panels.OpenShop()
	Panels.Open("Shop")
end

--[[
	渲染手臂/材质页（面板不可见时跳过）
]]
function Panels.RenderArms()
	local grid = _armsGrid
	local panel = _panels.Arms
	if not grid or not panel or not panel.Visible then
		return
	end
	Cards.Clear(grid)
	local tabArmsBorder = _tabArms and _tabArms:FindFirstChild("Border") :: UIStroke?
	local tabMatsBorder = _tabMats and _tabMats:FindFirstChild("Border") :: UIStroke?
	if tabArmsBorder then
		tabArmsBorder.Color = if _armsTab == "Arms" then C.White else C.Black
	end
	if tabMatsBorder then
		tabMatsBorder.Color = if _armsTab == "Mats" then C.White else C.Black
	end
	if _armsTab == "Arms" then
		if _armTemp then
			_renderArmCards(grid, _armTemp)
		end
	elseif _matTemp then
		_renderMatCards(grid, _matTemp)
	end
end

--[[
	渲染商城（面板不可见时跳过）
]]
function Panels.RenderShop()
	ShopPanel.Render()
end

--[[
	渲染哑铃面板（面板不可见时跳过）
]]
function Panels.RenderDumbbells()
	DumbbellPanel.Render()
end

--[[
	绑定全部弹窗（Common.Bind 之后调用一次）
	@param screenGui ScreenGui - PlayerGui.ScreenGui
]]
function Panels.Bind(screenGui: ScreenGui)
	local arms = _bindPanel(screenGui, "Arms")
	Common.SetText(Common.Get(arms, "Title") :: TextLabel, "手臂")
	local tabArms = Common.Get(arms, "TabArms") :: TextButton
	local tabMats = Common.Get(arms, "TabMats") :: TextButton
	Common.SetText(Common.Get(tabArms, "Label") :: TextLabel, "手臂")
	Common.SetText(Common.Get(tabMats, "Label") :: TextLabel, "材质")
	_tabArms, _tabMats = tabArms, tabMats
	local armsGrid = Common.Get(arms, "Grid") :: ScrollingFrame
	_armsGrid = armsGrid
	_armTemp = Common.Get(armsGrid, "ArmTemp") :: Frame
	_matTemp = Common.Get(armsGrid, "MatTemp") :: Frame
	tabArms.MouseButton1Click:Connect(function()
		_armsTab = "Arms"
		Panels.RenderArms()
	end)
	tabMats.MouseButton1Click:Connect(function()
		_armsTab = "Mats"
		Panels.RenderArms()
	end)

	ShopPanel.Bind(_bindPanel(screenGui, "Shop"))

	DumbbellPanel.Bind(_bindPanel(screenGui, "Dumbbells"))

	TeleportPanel.Bind(_bindPanel(screenGui, "Teleport"))
end

return Panels
