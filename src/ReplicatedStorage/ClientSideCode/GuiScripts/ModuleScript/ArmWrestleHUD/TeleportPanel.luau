--[[
	Module: TeleportPanel
	Description: ArmWrestleHUD 传送弹窗（ScreenGui.ArmWrestleTeleport）：按关卡列出传送目的地，已解锁的可一键传送
	Author: 程莘
	Created: 2026-10-15
	Last Modified: 2026-10-16

	静态 UI（Studio 维护，节点名为代码契约）：
	- ArmWrestleTeleport：Title / CloseButton / Grid(ZoneTemp)
	- ZoneTemp（行高与手臂/哑铃一致）：SceneBg(整行长条场景底图) / SceneDim / Index / ItemName / Desc / Button.Label

	规则：
	- 每关一张卡片，顺序同 ArmWrestleConfig.GetLevels()；解锁进度读服务端同步的 Attribute Unlocked（只读）
	- 卡片三态：当前位置（本地角色所在关，仅展示）/ 已解锁（可传送）/ 未解锁（锁定并显示所需力量 Gate）
	- 点击只发 Teleport 请求；解锁校验、冷却、写角色位姿全在服务端 SystemArmWrestle（Economy 校验 → Battle.TeleportZone）
	- 传送成功关闭弹窗；失败按失败码 TipsModule 错误提示（locked / battle / wait）

	与相关模块：
	- Panels：负责弹窗外框绑定、开关路由与互斥，Bind 时把面板 Frame 传入；OnOpened 转到 Render
	- Cards：卡片克隆、按钮与文本读取、清理

	加载：
		local TeleportPanel = require(script.Parent.TeleportPanel)
		TeleportPanel.Bind(panelFrame)
		TeleportPanel.Render()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local LocalPlayer = Utils.LocalPlayer
local ArmWrestleConfig = Utils.ArmWrestleConfig
local ArmWrestleStyle = Utils.ArmWrestleStyle
local TipsModule = Utils.TipsModule

local Common = require(script.Parent.Common)
local Cards = require(script.Parent.Cards)

local Style = ArmWrestleStyle
local C = Style.Colors
local Format = ArmWrestleConfig.Format

local TeleportPanel = {}

local UI_NAME = "ArmWrestleTeleport"

local _panel: Frame?
local _grid: ScrollingFrame?
local _template: Frame?

--[[
	本地角色当前所在关卡（关卡沿 X 轴每 ZoneLength 一段排布；仅用于卡片“当前位置”展示）
	@param levelCount number - 关卡总数
	@return number? - 1-based 关卡下标；角色未就绪为 nil
]]
local function _currentLevel(levelCount: number): number?
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	local index = math.floor(root.Position.X / ArmWrestleConfig.ZoneLength) + 1
	return math.clamp(index, 1, levelCount)
end

--[[
	发送传送请求：成功关闭弹窗，失败错误提示
	@param levelIndex number - 1-based 关卡下标
]]
local function _request(levelIndex: number)
	local ok, err = Common.Invoke("Teleport", levelIndex)
	if ok then
		Common.ShowPopup(UI_NAME, false)
		return
	end
	if err == "locked" then
		TipsModule.ErrorTips(LocalPlayer, "区域未解锁")
	else
		Common.ShowErrorTip(err)
	end
	TeleportPanel.Render()
end

--[[
	渲染一张关卡卡片
	@param grid ScrollingFrame - 网格
	@param template Frame - ZoneTemp
	@param index number - 1-based 关卡下标（同时作排序）
	@param level table - 关卡配置条目 { ZhName, Gate, Icon, Ground = { Color } }
	@param unlocked boolean - 是否已解锁
	@param current boolean - 是否本地角色所在关
]]
local function _renderCard(grid: ScrollingFrame, template: Frame, index: number, level: { [string]: any }, unlocked: boolean, current: boolean)
	local card = Cards.Clone(template, grid, index, if unlocked then C.Card else C.Disabled, if current then C.White else C.Black)
	local sceneBg = card:FindFirstChild("SceneBg")
	if sceneBg and sceneBg:IsA("ImageLabel") then
		if type(level.Icon) == "string" and level.Icon ~= "" then
			sceneBg.Image = level.Icon
			sceneBg.ImageTransparency = 0
		else
			sceneBg.Image = ""
			sceneBg.BackgroundColor3 = level.Ground.Color
			sceneBg.BackgroundTransparency = 0
		end
	end
	local indexLabel = card:FindFirstChild("Index")
	if indexLabel and indexLabel:IsA("TextLabel") then
		Common.SetRaw(indexLabel, tostring(index))
	end
	Common.SetText(Cards.Label(card, "ItemName"), level.ZhName)
	local desc = Cards.Label(card, "Desc")
	local btn, lbl
	if current then
		btn, lbl = Cards.Button(card, C.Equipped)
		Common.SetText(lbl, "当前位置")
		Common.SetText(desc, "已解锁")
	elseif unlocked then
		btn, lbl = Cards.Button(card, C.Green)
		Common.SetText(lbl, "传送")
		Common.SetText(desc, "已解锁")
	else
		btn, lbl = Cards.Button(card, C.Disabled)
		Common.SetText(lbl, "未解锁")
		Style.SetIcon(lbl, "lock")
		Common.SetText(desc, "需要力量", { Format(level.Gate or 0) })
	end
	btn.MouseButton1Click:Connect(function()
		if current then
			return
		end
		if not unlocked then
			TipsModule.ErrorTips(LocalPlayer, "区域未解锁")
			return
		end
		_request(index)
	end)
end

--[[
	重绘关卡列表（面板未绑定或不可见时跳过）
]]
function TeleportPanel.Render()
	local panel, grid, template = _panel, _grid, _template
	if not panel or not grid or not template or not panel.Visible then
		return
	end
	Cards.Clear(grid)
	local levels = ArmWrestleConfig.GetLevels()
	local unlockedCount = Common.Attr("Unlocked", 1)
	local current = _currentLevel(#levels)
	for i, level in ipairs(levels) do
		_renderCard(grid, template, i, level, i <= unlockedCount, current == i)
	end
end

--[[
	绑定传送弹窗节点（Panels.Bind 内调用一次）；解锁进度变化时自动重绘
	@param panel Frame - ScreenGui.ArmWrestleTeleport（外框与关闭按钮已由 Panels 绑定）
]]
function TeleportPanel.Bind(panel: Frame)
	_panel = panel
	Common.SetText(Common.Get(panel, "Title") :: TextLabel, "传送")
	local grid = Common.Get(panel, "Grid") :: ScrollingFrame
	_grid = grid
	_template = Common.Get(grid, "ZoneTemp") :: Frame
	LocalPlayer:GetAttributeChangedSignal("Unlocked"):Connect(TeleportPanel.Render)
end

return TeleportPanel
