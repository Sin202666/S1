--[[
	Module: ArmWrestleHUD
	Description: 扳手腕主界面（布局与样式对齐原型 ClientMain）：顶栏、左右侧栏、目标行、训练加力量表现
	Author: 程莘
	Created: 2026-10-14
	Last Modified: 2026-10-16

	功能：
	- 顶部居中两枚数值框（力量/现金，挂在 ScreenGui_Full.Top），左侧 2 列方块：商店/手臂、哑铃/传送（在线奖励入口已下线；材质并入手臂弹窗页签，无独立入口）
	- 哑铃按钮的图标与手臂一致，为子 TextLabel "Icon"（Icon Attribute = dumbbell，静态图片）
	- 传送 打开传送弹窗 ArmWrestleTeleport（各关卡落点，已解锁可传送），见 TeleportPanel
	- 手臂/哑铃 角标 Badge（红色 ❗）由子模块 RedDots 按镜像数据显隐，见 RedDots；商店无红点
	- 快捷栏上方 新手引导文本（引导结束后隐藏）；小屏（ViewportDisplaySize.Small）文案放大 50%；自动点击开关仅在对局内（BattleAuto）
	- 对局中隐藏左右栏、目标行与快捷栏（ScreenGui.Main.Backpack），结束后恢复
	- 任一弹窗显示时顶栏/左右栏/底部各分组滑出屏幕四周，弹窗全关后滑回，见 EdgeSlide
	- 右侧付费栏：力量倍数（x2→x64 依次购买）+ 三档力量包，见 StrengthShop
	- 右下角加成栏：同服好友加成（点击邀请好友）、Roblox 会员加成（点击订阅会员），见 BoostBar
	- 右下角药水 Buff 栏（加成栏左侧同一排）：生效药水图标 + 倒计时，点击看详情；对局中也显示，见 PotionBuffBar
	- 进服有待领离线时长时弹出离线奖励窗，点击领取由服务端结算力量，见 OfflinePanel
	- 打开 Roblox 菜单即弹出挽留礼物窗（每账号一次现金），点击领取由服务端结算，见 MenuGift；同时屏幕上下显示离线奖励横幅，见 MenuOfflineHint
	- 子模块：Common（共享上下文）、Panels（弹窗，商城委托 ShopPanel、哑铃委托 DumbbellPanel、传送委托 TeleportPanel）、Roll（报价卡 / 扭蛋结果提示，3D 抽取表演经 SetRollFx 注入）、Battle（对局界面）、TrainFx（训练弹字）、StrengthShop（右侧付费栏）、BoostBar（右下角加成栏）、PotionBuffBar（药水 Buff 栏）、OfflinePanel（离线奖励弹窗）、MenuGift（菜单挽留弹窗）、MenuOfflineHint（菜单离线提示横幅）、RedDots（左栏红点）、EdgeSlide（弹窗显示时四周 UI 滑出屏幕）、TipsAnchor（TipsGui 提示区跟随顶栏下方）
	- 只展示与发请求；结算在服务端 SystemArmWrestle，请求经客户端 SystemArmWrestle.Invoke

	静态 UI（Studio 维护，本模块只绑定不新建，节点名为代码契约，改名须同步）：
	- ScreenGui_Full.Top：Strength/Cash.Value（IgnoreGuiInset 顶栏）
	- ScreenGui.ArmWrestleHUD：Objective(Title，快捷栏上方，仅新手引导期间显示)
	  / Left(ShopButton/ArmsButton/DumbbellButton/TeleportButton，手臂与哑铃带 Badge 红色 ❗) / Right(见 StrengthShop) / Boost(见 BoostBar) / PotionBuff(见 PotionBuffBar) / OfflineReward(见 OfflinePanel) / Battle / BattleTap / BattleCombo
	  / BattleAuto / Offer / Roll / BigText；各分组 Frame 下 UIScale 为 HUD 设计倍率
	- ArmWrestleArms / ArmWrestleShop / ArmWrestleDumbbells / ArmWrestleTeleport：弹窗，见 Panels / DumbbellPanel / TeleportPanel
	- 挽留礼物弹窗在独立的 StarterGui.MenuGiftGui（高 DisplayOrder + 压暗遮罩），见 MenuGift
	- 菜单离线提示横幅在独立的 StarterGui.MenuHintGui（Top / Bottom），见 MenuOfflineHint

	与相关模块：
	- 客户端 SystemArmWrestle：Init 时传入 Invoke，SetRollFx 注入 MachineShowcase.PlayRoll，并转发 Roll/Battle 事件、点按、训练、每帧心跳
	- ArmWrestleArms / ArmWrestleShop / ArmWrestleDumbbells / ArmWrestleTeleport：UIManager 弹窗模块，openUi 回调 OnPanelOpened

	加载：
		local HUD = require(ReplicatedStorage.ClientSideCode.GuiScripts.ModuleScript.ArmWrestleHUD)
		HUD.Init(SystemArmWrestle.Invoke)
		HUD.Heartbeat(dt)            -- RenderStepped 每帧
		HUD.OnBattleStart(payload)   -- { OppId, Time }
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local LocalPlayer = Utils.LocalPlayer
local ArmWrestleConfig = Utils.ArmWrestleConfig
local ArmWrestleStyle = Utils.ArmWrestleStyle
local TipsModule = Utils.TipsModule
local GetData = Utils.GetData
local SystemGuide = Utils.SystemGuide
local DeviceType = Utils.DeviceType
local GuiService = Utils.GuiService

local Common = require(script.Common)
local Panels = require(script.Panels)
local Roll = require(script.Roll)
local Battle = require(script.Battle)
local TrainFx = require(script.TrainFx)
local StrengthShop = require(script.StrengthShop)
local BoostBar = require(script.BoostBar)
local PotionBuffBar = require(script.PotionBuffBar)
local OfflinePanel = require(script.OfflinePanel)
local MenuGift = require(script.MenuGift)
local MenuOfflineHint = require(script.MenuOfflineHint)
local RedDots = require(script.RedDots)
local EdgeSlide = require(script.EdgeSlide)
local TipsAnchor = require(script.TipsAnchor)

local Style = ArmWrestleStyle
local C = Style.Colors
local Format = ArmWrestleConfig.Format

local ArmWrestleHUD = {}

local REFRESH_INTERVAL = 0.25
-- 小屏引导文案相对 Studio 设计倍率的放大倍数（Title 为 TextScaled，跟 Objective.UIScale）
local SMALL_SCREEN_GUIDE_TEXT_SCALE = 1.5
local _initStarted = false
local _inited = false
local _acc = 0
local _strength: TextLabel?
local _cash: TextLabel?
local _objective: TextLabel?
local _objectiveBaseScale: number? = nil
local _autoBtns: { TextButton } = {}
local _lastStrength: number? = nil

--[[
	取按钮下承载文字的子 TextLabel "Label"（TranslationHelper 不处理 TextButton）
	@param btn Instance - 按钮
	@return TextLabel - 文字
]]
local function _label(btn: Instance): TextLabel
	return Common.Get(btn, "Label") :: TextLabel
end

--[[
	同步对局内自动点击按钮的文字与颜色
]]
local function _setAutoButtons()
	local on = Common.Attr("AutoOn", false) == true
	for _, btn in ipairs(_autoBtns) do
		btn.BackgroundColor3 = if on then C.Green else C.Red
		local lbl = btn:FindFirstChild("Label")
		if lbl and lbl:IsA("TextLabel") then
			Common.SetText(lbl, if on then "自动点击：开" else "自动点击：关")
		end
	end
end

--[[
	自动点击开关；无通行证时提示并走购买
]]
local function _toggleAuto()
	if not Common.HasPass("AutoClicker") then
		TipsModule.NormalTips(LocalPlayer, "需要自动点击通行证")
		Common.Purchase("Pass", "AutoClicker")
		return
	end
	Common.Invoke("SetAuto", Common.Attr("AutoOn", false) ~= true)
end

--[[
	刷新顶栏数值
]]
local function _updatePills()
	local strength = Common.Attr("Strength", 0)
	if _strength then
		Common.SetRaw(_strength, Format(math.floor(strength)))
		if _lastStrength and strength ~= _lastStrength then
			Style.Pop(_strength)
		end
	end
	_lastStrength = strength
	if _cash then
		Common.SetRaw(_cash, Format(math.floor(Common.Coin())))
	end
end

--[[
	刷新新手引导文本：仅引导进行中且不在对局时显示（显隐只由此处写，Battle 不再切换）
	阶段由客户端 SystemGuide 解析服务端发布的 GuideName；按钮箭头 / 引导线也由 SystemGuide 负责
]]
local function _updateObjective()
	local objective = _objective
	if not objective then
		return
	end
	local stage = SystemGuide.GetStage()
	objective.Visible = stage ~= nil and not Battle.IsActive()
	if not stage then
		return
	end
	if DeviceType.IsMobile() and stage.ZhText_Mobile then
		Common.SetText(objective, stage.ZhText_Mobile)
	else
		Common.SetText(objective, stage.ZhText)
	end
end

--[[
	4Hz 刷新：目标、报价卡距离、右下角药水 Buff 倒计时、左栏红点
]]
local function _refresh()
	_updateObjective()
	Roll.Refresh()
	PotionBuffBar.Tick()
	RedDots.Refresh()
end

--[[
	小屏把快捷栏上方引导文案放大 50%；大屏恢复 Studio 上的 Objective.UIScale
	@return nil
]]
local function _applyGuideTextScale()
	local title = _objective
	if not title then
		return
	end
	local frame = title.Parent
	local uiScale = frame and frame:FindFirstChildOfClass("UIScale")
	if not uiScale then
		return
	end
	if _objectiveBaseScale == nil then
		_objectiveBaseScale = uiScale.Scale
	end
	local mul = if GuiService.ViewportDisplaySize == Enum.DisplaySize.Small then SMALL_SCREEN_GUIDE_TEXT_SCALE else 1
	uiScale.Scale = (_objectiveBaseScale :: number) * mul
end

--[[
	绑定顶栏、目标行、左右侧栏、快捷栏引用（静态节点见文件头）
]]
local function _bindHud()
	local gui = Common.gui :: Frame
	local top = Common.top :: Frame
	_strength = Common.Get(top, "Strength", "Value") :: TextLabel
	_cash = Common.Get(top, "Cash", "Value") :: TextLabel
	Common.SetRaw(_strength :: TextLabel, "0")
	Common.SetRaw(_cash :: TextLabel, "0")

	_objective = Common.Get(gui, "Objective", "Title") :: TextLabel
	_applyGuideTextScale()
	GuiService:GetPropertyChangedSignal("ViewportDisplaySize"):Connect(_applyGuideTextScale)

	local left = Common.Get(gui, "Left") :: Frame
	local shopBtn = Common.Get(left, "ShopButton") :: TextButton
	Common.SetText(_label(shopBtn), "商店")
	local armsBtn = Common.Get(left, "ArmsButton") :: TextButton
	Common.SetText(_label(armsBtn), "手臂")
	local dumbbellBtn = Common.Get(left, "DumbbellButton") :: TextButton
	Common.SetText(_label(dumbbellBtn), "哑铃")
	local teleportBtn = Common.Get(left, "TeleportButton") :: TextButton
	Common.SetText(_label(teleportBtn), "传送")

	shopBtn.MouseButton1Click:Connect(function()
		Panels.OpenShop()
	end)
	armsBtn.MouseButton1Click:Connect(function()
		Panels.OpenArms("Arms")
	end)
	dumbbellBtn.MouseButton1Click:Connect(function()
		Panels.Open("Dumbbells")
	end)
	teleportBtn.MouseButton1Click:Connect(function()
		Panels.Open("Teleport")
	end)

	Common.hud.top = top
	Common.hud.left = left
	RedDots.Bind(left)
	Common.hud.right = StrengthShop.Bind(gui)
	Common.hud.boost = BoostBar.Bind(gui)
	PotionBuffBar.Bind(gui)
	OfflinePanel.Bind(gui)
	MenuGift.Bind()
	MenuOfflineHint.Bind()
	Common.hud.backpack = Common.Get(Common.screenGui :: ScreenGui, "Main", "Backpack")
	EdgeSlide.Bind()
	TipsAnchor.Bind()
end

--[[
	绑定玩家镜像变化
]]
local function _bindAttributes()
	LocalPlayer:GetAttributeChangedSignal("Strength"):Connect(_updatePills)
	-- 金币 NumberValue 由背包镜像延迟创建，等待会阻塞 Init，故放后台线程
	task.spawn(function()
		local coinValue = GetData.WaitBagNumberValue(LocalPlayer, Common.COIN_ID)
		coinValue.Changed:Connect(function()
			_updatePills()
			if _cash then
				Style.Pop(_cash)
			end
			Panels.RenderArms()
			Panels.RenderDumbbells()
		end)
		_updatePills()
		Panels.RenderArms()
	end)
	for _, name in ipairs({ "Arm", "Mat" }) do
		LocalPlayer:GetAttributeChangedSignal(name):Connect(Panels.RenderArms)
	end
	LocalPlayer:GetAttributeChangedSignal("Dumbbell"):Connect(Panels.RenderDumbbells)
	LocalPlayer:GetAttributeChangedSignal("AutoOn"):Connect(_setAutoButtons)
end

--[[
	刷新顶栏与目标（UIManager / 旧入口兼容）
]]
function ArmWrestleHUD.RefreshHud()
	if not _inited then
		return
	end
	_updatePills()
	_refresh()
end

--[[
	重绘手臂/材质面板（可见时）
]]
function ArmWrestleHUD.RenderArms()
	Panels.RenderArms()
end

--[[
	重绘哑铃面板（可见时）
]]
function ArmWrestleHUD.RenderDumbbells()
	Panels.RenderDumbbells()
end

--[[
	重绘商店面板（可见时）
]]
function ArmWrestleHUD.RenderShop()
	Panels.RenderShop()
end

--[[
	打开/切换面板（经 UIManager 播放弹出动画）
	@param name string - Arms / Mats / Shop / Dumbbells / Teleport
]]
function ArmWrestleHUD.OpenPanel(name: string)
	if name == "Arms" or name == "Mats" then
		Panels.OpenArms(name)
	elseif name == "Shop" then
		Panels.OpenShop()
	else
		Panels.Open(name)
	end
end

--[[
	弹窗已由 UIManager 显示后的回调：关闭其余面板并渲染内容（ArmWrestleArms / Shop / Dumbbells / Teleport:openUi 调用）
	@param name string - Arms / Shop / Dumbbells / Teleport
]]
function ArmWrestleHUD.OnPanelOpened(name: string)
	Panels.OnOpened(name)
end

--[[
	服务端抽奖下发
	@param kind any - Offer / Result
	@param payload any - Offer: { Id, Level, Price, Owned }；Result: { Id, Level, Pool, Refund }
]]
function ArmWrestleHUD.OnRoll(kind: any, payload: any)
	Roll.OnRoll(kind, payload)
end

--[[
	注入 3D 抽取表演：报价卡 / 扭蛋提示在表演定格后才出现（客户端 SystemArmWrestle 传 MachineShowcase.PlayRoll）
	@param fx function - (level: number, matId: string) -> boolean，阻塞到表演定格；返回是否播放到定格
]]
function ArmWrestleHUD.SetRollFx(fx: (number, string) -> boolean)
	Roll.SetRollFx(fx)
end

--[[
	注入报价条显隐通知：报价条打开期间 3D 侧隐藏该箱子的 E 抽取 Prompt（客户端 SystemArmWrestle 传 MachineShowcase.SetOfferOpen）
	@param fx function - (level: number?) -> ()，报价条显示时传所属关卡下标、隐藏时传 nil
]]
function ArmWrestleHUD.SetOfferFx(fx: (number?) -> ())
	Roll.SetOfferFx(fx)
end

--[[
	注入「放弃报价」表现：报价条点关闭时收回该箱子上方的 3D 手臂并合盖（客户端 SystemArmWrestle 传 MachineShowcase.DiscardShown）
	@param fx function - (level: number) -> ()，参数为报价所属关卡下标
]]
function ArmWrestleHUD.SetDiscardFx(fx: (number) -> ())
	Roll.SetDiscardFx(fx)
end

--[[
	对局开始：收起面板与报价卡，切对局界面
	@param payload table - { OppId: string, Time: number }
]]
function ArmWrestleHUD.OnBattleStart(payload: { [string]: any })
	Panels.CloseAll()
	Roll.HideOffer()
	Battle.OnStart(payload)
	_updateObjective()
end

--[[
	对局胜负
	@param payload any - { Win: boolean, Reward: number, OppId: string }
]]
function ArmWrestleHUD.OnBattleResult(payload: any)
	Battle.OnResult(payload)
end

--[[
	对局分出胜负（服务端 End）：收起对局面板（拉锯条等），主界面其余部分仍等 OnBattleEnd 恢复
]]
function ArmWrestleHUD.HideBattlePanel()
	Battle.HidePanel()
end

--[[
	对局结束（服务端交还控制后）
]]
function ArmWrestleHUD.OnBattleEnd()
	Battle.OnEnd()
	_updateObjective()
end

--[[
	本地点按表现
]]
function ArmWrestleHUD.OnTap()
	Battle.OnTap()
end

--[[
	训练表现：屏幕随机弹出「力量图标 +具体数值」，缩放出现后停顿再向上飞走（数值取服务端同步的 PerClick，仅表现）
]]
function ArmWrestleHUD.OnTrain()
	if not _inited then
		return
	end
	TrainFx.Play(Format(Common.Attr("PerClick", 1)))
end

--[[
	每帧心跳：对局界面每帧更新，其余 4Hz
	@param dt number? - 帧间隔，缺省按 1/60
]]
function ArmWrestleHUD.Heartbeat(dt: number?)
	if not _inited then
		return
	end
	local step = dt or 1 / 60
	Battle.Update(step)
	_acc += step
	if _acc < REFRESH_INTERVAL then
		return
	end
	_acc = 0
	_refresh()
end

--[[
	UIManager 兼容：显示主界面
]]
function ArmWrestleHUD:openUi()
	if Common.gui then
		Common.gui.Visible = true
	end
end

--[[
	UIManager 兼容：隐藏主界面
]]
function ArmWrestleHUD:closeUi()
	if Common.gui then
		Common.gui.Visible = false
	end
end

--[[
	UIManager 兼容：刷新
]]
function ArmWrestleHUD:updateUi()
	ArmWrestleHUD.RefreshHud()
end

--[[
	绑定静态界面（客户端 SystemArmWrestle.Init 调一次）；绑定完成前 Heartbeat / OnTrain 不生效
	@param invoke function? - (action, ...) -> ok, result；传客户端 SystemArmWrestle.Invoke
]]
function ArmWrestleHUD.Init(invoke: ((string, ...any) -> ...any)?)
	if _initStarted then
		return
	end
	_initStarted = true
	if invoke then
		Common.SetInvoker(invoke)
	end
	Common.Bind()
	_bindHud()
	TrainFx.Build()
	Panels.Bind(Common.screenGui :: ScreenGui)
	Roll.Bind()
	table.insert(_autoBtns, Battle.Bind(_toggleAuto))
	_bindAttributes()
	_inited = true
	_setAutoButtons()
	_updatePills()
	_refresh()
end

return ArmWrestleHUD
