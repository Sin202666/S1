--[[
	Module: TipsAnchor
	Description: 让通用提示区 TipsGui.NewTipsFrame 的顶边始终贴在 ScreenGui_Full.Top 底边下方
	Author: 程莘
	Created: 2026-10-15
	Last Modified: 2026-10-16

	功能：
	- 监听 Top 的 AbsolutePosition / AbsoluteSize（EdgeSlide 滑出滑回、UIScale 适配都会触发）、TipsGui 尺寸与根 UIScale，实时改写 NewTipsFrame.Position 的 Y
	- TipsGui（DisplayOrder 高于弹窗、IgnoreGuiInset）与 ScreenGui_Full 不在同一层：两者 AbsolutePosition 处于同一坐标系，按差值换算并除以 TipsGui 根 UIScale
	- Top 滑出屏幕（弹窗打开）时提示区夹在视口顶边，不跟着出屏
	- 本模块是 NewTipsFrame.Position 的唯一写入方；TipsRenderer 只往容器里挂提示条，不动容器位置

	静态 UI（Studio 维护，节点名为代码契约）：
	- StarterGui.TipsGui（ResetOnSpawn=false，含根 UIScale）/ NewTipsFrame（AnchorPoint Y=0）
	- StarterGui.ScreenGui_Full.Top

	加载：
		local TipsAnchor = require(script.TipsAnchor)
		TipsAnchor.Bind()  -- ArmWrestleHUD._bindHud 内调用一次（依赖 Common.Bind 已完成）
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local LocalPlayer = Utils.LocalPlayer

local Common = require(script.Parent.Common)

local TipsAnchor = {}

local TIPS_GUI_NAME = "TipsGui"
local TIPS_FRAME_NAME = "NewTipsFrame"
local TOP_GROUP_NAME = "Top"
-- 提示区与顶栏之间的留白（屏幕像素）
local GAP = 6

local _top: GuiObject?
local _tipsGui: ScreenGui?
local _tipsFrame: Frame?
local _rootScale: UIScale?

--[[
	按 Top 当前底边重算 NewTipsFrame 的 Y 偏移（X 保持 Studio 原值）
	@return nil - 节点未绑定时静默 return
]]
local function _sync()
	local top, tipsGui, frame = _top, _tipsGui, _tipsFrame
	if not top or not tipsGui or not frame then
		return
	end
	-- Top 在 IgnoreGuiInset 的 ScreenGui_Full 上，视口顶边即为 0（与 TipsGui 同坐标系）
	local targetY = math.max(top.AbsolutePosition.Y + top.AbsoluteSize.Y + GAP, 0)
	local scale = if _rootScale and _rootScale.Scale > 0 then _rootScale.Scale else 1
	local pos = frame.Position
	frame.Position = UDim2.new(pos.X.Scale, pos.X.Offset, 0, (targetY - tipsGui.AbsolutePosition.Y) / scale)
end

--[[
	绑定提示区跟随顶栏（ArmWrestleHUD._bindHud 调一次）
	@return Frame - TipsGui.NewTipsFrame
]]
function TipsAnchor.Bind(): Frame
	local tipsGui = Common.Get(LocalPlayer:WaitForChild("PlayerGui"), TIPS_GUI_NAME) :: ScreenGui
	local frame = Common.Get(tipsGui, TIPS_FRAME_NAME) :: Frame
	local top = (Common.top or Common.hud.top or Common.Get(Common.screenGuiFull :: ScreenGui, TOP_GROUP_NAME)) :: GuiObject
	_tipsGui = tipsGui
	_tipsFrame = frame
	_top = top
	_rootScale = tipsGui:FindFirstChildOfClass("UIScale")

	top:GetPropertyChangedSignal("AbsolutePosition"):Connect(_sync)
	top:GetPropertyChangedSignal("AbsoluteSize"):Connect(_sync)
	tipsGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(_sync)
	if _rootScale then
		_rootScale:GetPropertyChangedSignal("Scale"):Connect(_sync)
	end
	_sync()
	return frame
end

return TipsAnchor
