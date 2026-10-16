--[[
	Module: TrainFx
	Description: ArmWrestleHUD 训练加力量屏幕表现：角色周围随机弹出「力量图标 +具体数值」，缩放出现 → 停顿 → 向上飞走并消失
	Author: 程莘
	Created: 2026-10-14
	Last Modified: 2026-10-15

	功能：
	- Build()：建独立特效 ScreenGui
	- Play(amountText)：一次训练表现；弹字大小固定、角度随机，文字为 "+" .. amountText（原文数值，不走翻译键）

	约束：
	- 纯表现，数值由调用方取服务端同步的 PerClick；不写任何权威数据
	- 训练频繁，弹字走对象池；超过上限直接跳过本次表现
	- 特效 ScreenGui 不挂 UIScale，按屏幕像素定位，尺寸乘主界面像素倍率（Common.HudScale）

	加载（仅 ArmWrestleHUD 内部使用）：
		local TrainFx = require(script.TrainFx)
		TrainFx.Build()
		TrainFx.Play(Format(perClick))
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Workspace = game:GetService("Workspace")
local GuiService = game:GetService("GuiService")
local TweenService = Utils.TweenService
local LocalPlayer = Utils.LocalPlayer
local ArmWrestleStyle = Utils.ArmWrestleStyle

local Common = require(script.Parent.Common)

local Style = ArmWrestleStyle
local C = Style.Colors

local TrainFx = {}

-- 宽度留足，保证 TextScaled 字号只由高度决定，数值位数不同也一样大
local POPUP_SIZE = Vector2.new(420, 60)
local POPUP_MAX = 24
local POPUP_IN_TIME = 0.2
local POPUP_HOLD_TIME = 0.3
local POPUP_FLY_TIME = 0.55
local POPUP_FLY_SCREEN = 0.35
local POPUP_FADE_START = 0.5
local POPUP_SCALE = 1
local POPUP_TILT_DEG = 8
local SPREAD_X = 0.28
local SPREAD_UP = 0.25
local SPREAD_DOWN = 0.15
local SCREEN_MARGIN = 60

local _gui: ScreenGui?
local _freePopups: { Frame } = {}
local _popupCount = 0

--[[
	主界面在屏幕上的像素倍率（根 contain × HUD 设计倍率；未绑定时为 1）
	@return number - 缩放系数
]]
local function _scale(): number
	return Common.HudScale()
end

--[[
	取一个弹字（池空且未达上限时新建）
	@return Frame? - 弹字容器；达上限返回 nil
]]
local function _acquirePopup(): Frame?
	local popup = table.remove(_freePopups)
	if popup then
		return popup
	end
	if not _gui or _popupCount >= POPUP_MAX then
		return nil
	end
	_popupCount += 1
	local frame = Style.New("Frame", {
		Name = "TrainPopup",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		Parent = _gui,
	}, {
		Style.New("UIScale", { Name = "PopScale" }),
	}) :: Frame
	local lbl = Style.Label(frame, nil, UDim2.new(), UDim2.fromScale(1, 1), C.Gold, { Name = "Label" })
	Style.SetIcon(lbl, "strength")
	return frame
end

--[[
	弹字出生点：本地角色头部投影到屏幕后随机偏移，夹在屏幕边距内
	@return Vector2 - 特效 ScreenGui 坐标系下的像素位置
]]
local function _spawnPoint(): Vector2
	local camera = Workspace.CurrentCamera
	local vp = camera.ViewportSize
	local inset = GuiService:GetGuiInset()
	local center = Vector2.new(vp.X / 2, vp.Y / 2)
	local char = LocalPlayer.Character
	local head = char and char:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		local p, onScreen = camera:WorldToViewportPoint(head.Position)
		if onScreen then
			center = Vector2.new(p.X, p.Y)
		end
	end
	local x = center.X + (math.random() * 2 - 1) * vp.X * SPREAD_X
	local y = center.Y + (math.random() * (SPREAD_UP + SPREAD_DOWN) - SPREAD_UP) * vp.Y
	x = math.clamp(x, SCREEN_MARGIN, math.max(SCREEN_MARGIN, vp.X - SCREEN_MARGIN))
	y = math.clamp(y, inset.Y + SCREEN_MARGIN, math.max(inset.Y + SCREEN_MARGIN, vp.Y - SCREEN_MARGIN))
	return Vector2.new(x, y - inset.Y)
end

--[[
	一次训练加力量表现：缩放弹出 → 停顿 → 加速向上飞走，飞行后半段淡出 → 回池
	@param amountText string - 已格式化的单次加成（如 "1.3K"，不含 +），取服务端同步的 PerClick
]]
function TrainFx.Play(amountText: string)
	local popup = _acquirePopup()
	if not popup then
		return
	end
	local at = _spawnPoint()
	local lbl = popup:FindFirstChild("Label") :: TextLabel
	local stroke = lbl:FindFirstChild("TextStroke") :: UIStroke?
	local popScale = popup:FindFirstChild("PopScale") :: UIScale
	local s = _scale()
	Common.SetRaw(lbl, "+" .. amountText)
	lbl.TextTransparency = 0
	if stroke then
		stroke.Transparency = 0
	end
	popup.Size = UDim2.fromOffset(POPUP_SIZE.X * s, POPUP_SIZE.Y * s)
	popup.Position = UDim2.fromOffset(at.X, at.Y)
	popup.Rotation = (math.random() * 2 - 1) * POPUP_TILT_DEG
	popScale.Scale = 0
	popup.Visible = true
	TweenService:Create(popScale, TweenInfo.new(POPUP_IN_TIME, Enum.EasingStyle.Back), { Scale = POPUP_SCALE }):Play()

	local flyDelay = POPUP_IN_TIME + POPUP_HOLD_TIME
	local flyTo = at.Y - Workspace.CurrentCamera.ViewportSize.Y * POPUP_FLY_SCREEN
	TweenService:Create(
		popup,
		TweenInfo.new(POPUP_FLY_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, flyDelay),
		{ Position = UDim2.fromOffset(at.X, flyTo) }
	):Play()
	local fadeDelay = flyDelay + POPUP_FLY_TIME * POPUP_FADE_START
	local fade = TweenInfo.new(POPUP_FLY_TIME * (1 - POPUP_FADE_START), Enum.EasingStyle.Linear, Enum.EasingDirection.In, 0, false, fadeDelay)
	TweenService:Create(lbl, fade, { TextTransparency = 1 }):Play()
	if stroke then
		TweenService:Create(stroke, fade, { Transparency = 1 }):Play()
	end
	task.delay(flyDelay + POPUP_FLY_TIME, function()
		popup.Visible = false
		table.insert(_freePopups, popup)
	end)
end

--[[
	建特效 ScreenGui（HUD.Init 调一次，需在 Common.Bind 之后）
]]
function TrainFx.Build()
	if _gui then
		return
	end
	_gui = Style.New("ScreenGui", {
		Name = "ArmWrestleTrainFx",
		ResetOnSpawn = false,
		DisplayOrder = (if Common.screenGui then Common.screenGui.DisplayOrder else 0) + 1,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = LocalPlayer:WaitForChild("PlayerGui"),
	}) :: ScreenGui
end

return TrainFx
