--[[
	Module: Battle
	Description: ArmWrestleHUD 对局界面：拉锯条、计时、疯狂点击、连击、暗角/闪白、开始与失败大字（胜利奖励走普通 Tips）
	Author: 程莘
	Created: 2026-10-14
	Last Modified: 2026-10-15

	只做表现：进度读桌子 Attribute "P"（服务端写），点按由客户端 SystemArmWrestle 发送。
	对局界面为静态节点（Studio 维护于 ArmWrestleHUD 下）；暗角/闪白为运行时独立 ScreenGui（不受 UIScale 影响）。
	不写镜头 / HumanoidRootPart / WalkSpeed；镜头归客户端 SystemArmWrestle。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Workspace = game:GetService("Workspace")
local TweenService = Utils.TweenService
local LocalPlayer = Utils.LocalPlayer
local ArmWrestleConfig = Utils.ArmWrestleConfig
local ArmWrestleStyle = Utils.ArmWrestleStyle
local TipsModule = Utils.TipsModule

local Common = require(script.Parent.Common)

local Style = ArmWrestleStyle
local C = Style.Colors
local Format = ArmWrestleConfig.Format

local Battle = {}

local COMBO_MIN = 4
local BAR_FOLLOW = 10
local BAR_FOLLOW_FINISH = 16

type BattleState = {
	Table: Model?,
	Active: boolean,
	Finished: boolean,
	Ends: number,
	Cur: number,
	AutoAcc: number,
}

local _state: BattleState? = nil
local _tapTimes: { number } = {}
local _frame: Frame?
local _them: TextLabel?
local _you: TextLabel?
local _barFill: Frame?
local _barMark: TextLabel?
local _timer: TextLabel?
local _tapLbl: TextLabel?
local _combo: TextLabel?
local _battleAuto: TextButton?
local _vignette: Frame?
local _vigEdges: { Frame } = {}
local _vigAlpha = 0
local _flash: Frame?

--[[
	找当前对手所在桌子（开局时调用一次）
	@param oppId string - 对手 Id
	@return Model? - 桌子
]]
local function _findTable(oppId: string): Model?
	local world = Workspace:FindFirstChild(ArmWrestleConfig.WORLD_NAME)
	if not world then
		return nil
	end
	for _, zone in ipairs(world:GetChildren()) do
		local tables = zone:FindFirstChild("Tables")
		if tables then
			for _, t in ipairs(tables:GetChildren()) do
				if t:IsA("Model") and t:GetAttribute("OpponentId") == oppId then
					return t
				end
			end
		end
	end
	return nil
end

--[[
	设置暗角透明度/颜色
	@param alpha number - 0-1
	@param color Color3? - 颜色；nil 保持
]]
local function _setVignette(alpha: number, color: Color3?)
	_vigAlpha = alpha
	for _, edge in ipairs(_vigEdges) do
		edge.BackgroundTransparency = 1 - alpha
		if color then
			edge.BackgroundColor3 = color
		end
	end
end

--[[
	全屏闪白
	@param alpha number - 起始不透明度
	@param duration number - 渐隐秒
]]
local function _doFlash(alpha: number, duration: number)
	local flash = _flash
	if not flash then
		return
	end
	flash.BackgroundTransparency = 1 - alpha
	TweenService:Create(flash, TweenInfo.new(duration), { BackgroundTransparency = 1 }):Play()
end

--[[
	对局界面开关；对局中隐藏顶栏资源、左右栏、加成条、快捷栏
	@param on boolean - 是否对局
]]
local function _setBattleHud(on: boolean)
	local hud = Common.hud
	if _frame then
		_frame.Visible = on
	end
	if _battleAuto then
		_battleAuto.Visible = on
	end
	if _vignette then
		_vignette.Visible = on
	end
	_setVignette(0)
	if _tapLbl then
		_tapLbl.Visible = false
	end
	if _combo then
		_combo.Visible = false
	end
	for _, key in ipairs({ "top", "left", "right", "boost", "backpack" }) do
		local obj = hud[key]
		if obj then
			obj.Visible = not on
		end
	end
end

--[[
	点按表现（真实点按与自动点击共用）
]]
local function _tapFeedback()
	if _barMark then
		Style.Pop(_barMark)
	end
	if _tapLbl then
		Style.Pop(_tapLbl)
	end
	table.insert(_tapTimes, os.clock())
end

--[[
	是否对局中（含结束后的结算展示）
	@return boolean
]]
function Battle.IsActive(): boolean
	return _state ~= nil
end

--[[
	开局：显示双方力量，入座即开打（无倒计时）
	@param payload table - { OppId: string, Time: number }
]]
function Battle.OnStart(payload: { [string]: any })
	local opp = ArmWrestleConfig.GetOpponent(payload.OppId)
	local duration = tonumber(payload.Time) or ArmWrestleConfig.BattleTime
	local now = os.clock()
	local state: BattleState = {
		Table = _findTable(payload.OppId),
		Active = true,
		Finished = false,
		Ends = now + duration,
		Cur = 0.5,
		AutoAcc = 0,
	}
	_state = state
	table.clear(_tapTimes)
	if opp and _them then
		Common.SetText(_them, "对局对手", { Format(opp.Power), { opp.ZhName } })
	end
	if _you then
		Common.SetText(_you, "对局自己", { Format(math.floor(Common.Attr("Strength", 0))) })
	end
	_setBattleHud(true)
	Common.ShowBig("开始！", C.Green, 0.7)
	_doFlash(0.35, 0.25)
end

--[[
	服务端判定胜负
	@param payload table - { Win: boolean, Reward: number, OppId: string }
]]
function Battle.OnResult(payload: any)
	local state = _state
	if not state or type(payload) ~= "table" then
		return
	end
	state.Active = false
	state.Finished = true
	if _tapLbl then
		_tapLbl.Visible = false
	end
	if _combo then
		_combo.Visible = false
	end
	_doFlash(0.5, 0.35)
	if payload.Win then
		TipsModule.NormalTips(LocalPlayer, "扳手腕胜利", { "$" .. Format(payload.Reward or 0) })
		Common.Confetti()
	else
		Common.ShowBig("失败…再练练吧！", C.Red, 1.8)
	end
end

--[[
	收起对局面板（拉锯条 / 双方力量 / 计时 / 自动点击 / 点击提示）；顶栏等主界面仍保持隐藏，等 OnEnd 恢复
	服务端判出胜负时调用（获胜演出 / 失败结算均不再显示拉锯条）；同时停掉 Active，否则 Update 会每帧重新显示点击提示 / 连击 / 暗角
]]
function Battle.HidePanel()
	local state = _state
	if state then
		state.Active = false
	end
	for _, obj in ipairs({ _frame, _battleAuto, _tapLbl, _combo } :: { GuiObject? }) do
		if obj then
			obj.Visible = false
		end
	end
end

--[[
	服务端交还控制后收起对局界面
]]
function Battle.OnEnd()
	_state = nil
	_setBattleHud(false)
end

--[[
	本地点按（仅开打后有表现）
]]
function Battle.OnTap()
	local state = _state
	if state and state.Active then
		_tapFeedback()
	end
end

--[[
	每帧刷新拉锯条/计时/连击/暗角
	@param dt number - 帧间隔
]]
function Battle.Update(dt: number)
	local state = _state
	if not state then
		return
	end
	local now = os.clock()
	local target = 0.5
	local tableModel = state.Table
	if tableModel and tableModel:GetAttribute("Fighter") == LocalPlayer.UserId then
		local p = tableModel:GetAttribute("P")
		if typeof(p) == "number" then
			target = p
		end
	end
	local rate = if state.Finished then BAR_FOLLOW_FINISH else BAR_FOLLOW
	state.Cur += (target - state.Cur) * math.min(dt * rate, 1)
	local p = state.Cur
	local bal = p - 0.5
	local tension = math.abs(bal) * 2
	if _barFill then
		_barFill.Size = UDim2.new(p, 0, 1, 0)
	end
	if _barMark then
		_barMark.Position = UDim2.new(1 - p, -32, 0.5, -32)
		_barMark.Rotation = math.sin(now * 30) * (4 + tension * 10)
	end
	if _timer then
		Common.SetRaw(_timer, string.format("%.1f", math.max(state.Ends - now, 0)))
	end
	if _tapLbl then
		_tapLbl.Visible = state.Active
		_tapLbl.TextColor3 = Color3.fromHSV((now * 0.8) % 1, 0.5, 1)
	end
	if state.Active and Common.Attr("AutoOn", false) and Common.HasPass("AutoClicker") then
		state.AutoAcc += dt * ArmWrestleConfig.AutoTapsPerSecond
		while state.AutoAcc >= 1 do
			state.AutoAcc -= 1
			_tapFeedback()
		end
	end
	while _tapTimes[1] and now - _tapTimes[1] > 1 do
		table.remove(_tapTimes, 1)
	end
	if _combo then
		_combo.Visible = state.Active and #_tapTimes >= COMBO_MIN
		if _combo.Visible then
			Common.SetText(_combo, "连击次数", { tostring(#_tapTimes) })
		end
	end
	local danger = math.clamp((-bal - 0.12) / 0.3, 0, 1)
	local close = math.clamp((bal - 0.2) / 0.25, 0, 1)
	if state.Active and danger > 0 then
		_setVignette(danger * (0.55 + math.sin(now * 10) * 0.25), C.Red)
	elseif state.Active and close > 0 then
		_setVignette(close * 0.45, C.Green)
	else
		_setVignette(math.max(0, _vigAlpha - dt * 3))
	end
end

--[[
	绑定对局界面（ArmWrestleHUD.Battle / BattleTap / BattleCombo / BattleAuto）并建全屏特效层，Common.Bind 之后调用一次
	@param toggleAuto function - 自动点击开关回调
	@return TextButton - 对局内自动点击按钮（供 HUD 同步文字/颜色）
]]
function Battle.Bind(toggleAuto: () -> ()): TextButton
	local gui = Common.gui :: Frame
	local frame = Common.Get(gui, "Battle") :: Frame
	_frame = frame
	_them = Common.Get(frame, "Them") :: TextLabel
	_you = Common.Get(frame, "You") :: TextLabel
	local barBg = Common.Get(frame, "BarBg")
	_barFill = Common.Get(barBg, "BarFill") :: Frame
	_barMark = Common.Get(barBg, "BarMark") :: TextLabel
	_timer = Common.Get(frame, "Timer") :: TextLabel
	_tapLbl = Common.Get(gui, "BattleTap", "Label") :: TextLabel
	Common.SetText(_tapLbl :: TextLabel, "疯狂点击！")
	_combo = Common.Get(gui, "BattleCombo", "Label") :: TextLabel
	local battleAuto = Common.Get(gui, "BattleAuto", "Button") :: TextButton
	_battleAuto = battleAuto
	battleAuto.MouseButton1Click:Connect(toggleAuto)

	-- 独立 ScreenGui：全屏特效不受主界面 UIScale 缩放
	local fxGui = Style.New("ScreenGui", {
		Name = "ArmWrestleFx",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		DisplayOrder = -1,
		Parent = LocalPlayer:WaitForChild("PlayerGui"),
	}) :: ScreenGui
	local vignette = Style.New("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = fxGui,
	}) :: Frame
	_vignette = vignette
	for _, spec in ipairs({
		{ UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.25), 90 },
		{ UDim2.fromScale(0, 0.75), UDim2.fromScale(1, 0.25), -90 },
		{ UDim2.fromScale(0, 0), UDim2.fromScale(0.18, 1), 0 },
		{ UDim2.fromScale(0.82, 0), UDim2.fromScale(0.18, 1), 180 },
	}) do
		local edge = Style.New("Frame", {
			Position = spec[1],
			Size = spec[2],
			BackgroundColor3 = C.Red,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = vignette,
		}, {
			Style.New("UIGradient", { Rotation = spec[3], Transparency = NumberSequence.new(0, 1) }),
		}) :: Frame
		table.insert(_vigEdges, edge)
	end
	_flash = Style.New("Frame", {
		BackgroundColor3 = C.White,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = fxGui,
	}) :: Frame
	return battleAuto
end

return Battle
