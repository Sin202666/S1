--[[
	Module: Roll
	Description: ArmWrestleHUD 材质报价（Offer）按钮条与扭蛋结果（Result）的界面部分；3D 抽取表演由注入的 RollFx 播放
	Author: 程莘
	Created: 2026-10-14
	Last Modified: 2026-10-15

	抽取结果由服务端决定并下发；表演只是表现。
	流程：收到 Offer / Result（载荷带 Level）→ RollFx(Level, Id) 在该关材质箱上方播放 3D 表演并阻塞到定格
	→ Offer 弹出报价条（价格 / 购买 / 换一个 / 关闭），Result 经 TipsModule 提示（新材质按稀有度渐变 / 重复返还）。「换一个」拿到新报价后重播表演。
	材质名称 / 稀有度 / 力量倍率由 3D 定格手臂头顶牌子展示，2D 只保留价格与按钮。
	报价未处理（未购买 / 未关闭）时：离开材质箱自动隐藏，再靠近自动显示（服务端报价在购买或离线前一直有效）。
	报价条显示期间按 E =「换一个」；显隐经注入的 OfferFx 通知 3D 侧（MachineShowcase.SetOfferOpen 隐藏该箱子的 E 抽取 Prompt）。
	购买成功或点关闭：经注入的 DiscardFx（MachineShowcase.DiscardShown）收回 3D 手臂并合盖。
	RollFx 由客户端 SystemArmWrestle 经 ArmWrestleHUD.SetRollFx 注入（MachineShowcase.PlayRoll）；未注入时直接出结果。
	静态节点（Studio 维护）：ArmWrestleHUD.Offer(Price/BuyButton/NextButton/CloseButton)。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Workspace = game:GetService("Workspace")
local LocalPlayer = Utils.LocalPlayer
local UserInputService = Utils.UserInputService
local ArmWrestleConfig = Utils.ArmWrestleConfig
local ArmWrestleStyle = Utils.ArmWrestleStyle
local TipsModule = Utils.TipsModule
local SystemUISfx = Utils.SystemUISfx

local Common = require(script.Parent.Common)

local Style = ArmWrestleStyle
local C = Style.Colors
local Format = ArmWrestleConfig.Format

local Roll = {}

local CONFETTI_RANK = 3
local OFFER_RANGE = ArmWrestleConfig.NEAR_MACHINE_STUDS
local NEXT_KEY = Enum.KeyCode.E
local KEY_HINT_SIZE = 26

local _offerFrame: Frame?
local _offerPrice: TextLabel?
local _offerToken = 0
local _offerSpinning = false
-- 当前未处理报价所在关卡；nil 表示没有待处理报价（已购买 / 已关闭 / 换签失败）
local _offerLevel: number? = nil
local _offerControls: { GuiObject } = {}
local _rollFx: ((number, string) -> boolean)? = nil
local _offerFx: ((number?) -> ())? = nil
local _discardFx: ((number) -> ())? = nil

--[[
	找某关材质箱的 Main（未流入时为 nil）
	@param level number - 关卡下标
	@return BasePart? - 箱体
]]
local function _machineMain(level: number): BasePart?
	local world = Workspace:FindFirstChild(ArmWrestleConfig.WORLD_NAME)
	if not world then
		return nil
	end
	local name = "Machine_" .. level
	for _, zone in ipairs(world:GetChildren()) do
		local machine = zone:FindFirstChild(name)
		local main = machine and machine:FindFirstChild("Main")
		if main and main:IsA("BasePart") then
			return main
		end
	end
	return nil
end

--[[
	本地玩家是否在某关材质箱交互范围内
	@param level number - 关卡下标
	@return boolean - 在 OFFER_RANGE 内为 true；角色或箱子未加载为 false
]]
local function _isNearMachine(level: number): boolean
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local main = _machineMain(level)
	return root ~= nil and main ~= nil and (root.Position - main.Position).Magnitude <= OFFER_RANGE
end

--[[
	播放 3D 抽取表演并阻塞到定格；未注入 RollFx 或载荷缺 Level 时直接返回
	@param payload table - 服务端载荷 { Id: string, Level: number? }
]]
local function _playFx(payload: { [string]: any })
	local fx = _rollFx
	if fx and type(payload.Level) == "number" then
		fx(payload.Level, payload.Id)
	end
end

--[[
	报价条价格与按钮（购买 / 换一个 / 关闭）显隐；显示时逐个回弹
	@param visible boolean - true 显示，false 隐藏
]]
local function _setOfferControls(visible: boolean)
	for _, obj in ipairs(_offerControls) do
		obj.Visible = visible
		if visible then
			Style.Pop(obj)
		end
	end
end

--[[
	设置报价条显隐（唯一写入点），并通知 3D 侧当前打开报价条的箱子
	@param visible boolean - true 显示，false 隐藏
]]
local function _setOfferVisible(visible: boolean)
	local frame = _offerFrame
	if not frame then
		return
	end
	frame.Visible = visible
	local fx = _offerFx
	if fx then
		fx(if visible then _offerLevel else nil)
	end
end

--[[
	结束当前报价（购买成功 / 关闭 / 换签失败）：隐藏报价条且靠近不再自动弹出
]]
local function _endOffer()
	_offerLevel = nil
	_setOfferVisible(false)
end

--[[
	结束当前报价并收回该箱子上方的 3D 手臂、合盖（购买成功 / 点关闭共用）
]]
local function _discardOffer()
	local level = _offerLevel
	_endOffer()
	local fx = _discardFx
	if fx and level then
		fx(level)
	end
end

--[[
	报价落定：显示价格，按钮回弹，高稀有度未拥有撒彩纸
	@param offer table - { Id: string, Price: number?, Owned: boolean? }
	@param mat table - offer.Id 对应材质配置
]]
local function _revealOffer(offer: { [string]: any }, mat: { [string]: any })
	if offer.Owned then
		Common.SetText(_offerPrice :: TextLabel, "已拥有")
	else
		Common.SetText(_offerPrice :: TextLabel, "现金价格", { Format(offer.Price or mat.Price or 0) })
	end
	_setOfferControls(true)
	local rarity = ArmWrestleConfig.GetRarity(mat.Xyd)
	if not offer.Owned and rarity and rarity.Rank >= CONFETTI_RANK then
		Common.Confetti()
	end
end

--[[
	报价流程：收起报价条 → 3D 表演定格 → 弹出报价条（人已走远则等靠近再由 Refresh 显示）；新报价到来时旧流程作废
	@param offer table - { Id: string, Level: number?, Price: number?, Owned: boolean? }
]]
local function _playOffer(offer: { [string]: any })
	local frame = _offerFrame
	local mat = type(offer.Id) == "string" and ArmWrestleConfig.GetMaterial(offer.Id)
	if not frame or not mat then
		_offerSpinning = false
		return
	end
	_offerToken += 1
	local token = _offerToken
	_offerSpinning = true
	_offerLevel = if type(offer.Level) == "number" then offer.Level else nil
	_setOfferVisible(false)
	_playFx(offer)
	if token ~= _offerToken then
		return
	end
	_revealOffer(offer, mat)
	_setOfferVisible(_offerLevel == nil or _isNearMachine(_offerLevel))
	_offerSpinning = false
end

--[[
	「换一个」：向服务端换签并重播表演；冷却中提示，其他失败结束报价（按钮与 E 键共用）
]]
local function _onNext()
	if _offerSpinning then
		return
	end
	-- 先占位，防止 Invoke 往返期间连点导致服务端连续换签
	_offerSpinning = true
	local ok, offer = Common.Invoke("OfferNext")
	if ok and type(offer) == "table" then
		_playOffer(offer)
	else
		_offerSpinning = false
		if offer == "wait" then
			Common.ShowErrorTip(offer)
		else
			_endOffer()
		end
	end
end

--[[
	「获得新材质」提示：按材质稀有度 Rank 作为 xyd 渲染文字渐变（超出稀有度渐变档位时由渲染侧夹取）
	@param mat table - ArmWrestleConfig.GetMaterial 返回的材质条目（用 ZhName / Rarity）
	@param rarity table? - ArmWrestleConfig.GetRarity 返回的稀有度条目（用 Rank）；nil 时按 1 档
]]
local function _tipNewMaterial(mat: { [string]: any }, rarity: { [string]: any }?)
	TipsModule.RainbowTips(LocalPlayer, "获得新材质", { { mat.ZhName } }, nil, if rarity then rarity.Rank else 1)
end

--[[
	扭蛋结果：3D 表演定格后提示（重复返还 / 获得新材质），高稀有度撒彩纸
	@param result table - { Id: string, Level: number?, Refund: number? }
]]
local function _playRoll(result: { [string]: any })
	if type(result.Id) ~= "string" then
		return
	end
	_playFx(result)
	local mat = ArmWrestleConfig.GetMaterial(result.Id)
	local rarity = mat and ArmWrestleConfig.GetRarity(mat.Xyd)
	if (result.Refund or 0) > 0 then
		TipsModule.NormalTips(LocalPlayer, "重复材质返还", { Format(result.Refund) })
	elseif mat then
		_tipNewMaterial(mat, rarity)
		if rarity and rarity.Rank >= CONFETTI_RANK then
			Common.Confetti()
		end
	end
end

--[[
	注入 3D 抽取表演（客户端 SystemArmWrestle 传 MachineShowcase.PlayRoll）
	@param fx function - (level: number, matId: string) -> boolean，阻塞到表演定格
]]
function Roll.SetRollFx(fx: (number, string) -> boolean)
	_rollFx = fx
end

--[[
	注入报价条显隐通知（客户端 SystemArmWrestle 传 MachineShowcase.SetOfferOpen）
	@param fx function - (level: number?) -> ()，报价条显示时传所属关卡、隐藏时传 nil
]]
function Roll.SetOfferFx(fx: (number?) -> ())
	_offerFx = fx
end

--[[
	注入「放弃报价」表现（客户端 SystemArmWrestle 传 MachineShowcase.DiscardShown）
	@param fx function - (level: number) -> ()，购买成功或点关闭时以报价所属关卡调用，收回 3D 手臂并合盖
]]
function Roll.SetDiscardFx(fx: (number) -> ())
	_discardFx = fx
end

--[[
	服务端抽奖下发
	@param kind string - Offer / Result
	@param payload table - Offer: { Id, Level, Price, Owned }；Result: { Id, Level, Pool, Refund }
]]
function Roll.OnRoll(kind: any, payload: any)
	if type(payload) ~= "table" then
		return
	end
	if kind == "Offer" then
		task.spawn(_playOffer, payload)
	elseif kind == "Result" then
		task.spawn(_playRoll, payload)
	end
end

--[[
	临时隐藏报价条（如对局开始）；报价仍待处理，回到材质箱附近会再显示
]]
function Roll.HideOffer()
	_setOfferVisible(false)
end

--[[
	按距离显隐待处理的报价条（4Hz）：离开材质箱隐藏，回到附近显示；表演中不处理
]]
function Roll.Refresh()
	local frame = _offerFrame
	local level = _offerLevel
	if not frame or not level or _offerSpinning then
		return
	end
	local near = _isNearMachine(level)
	if near == frame.Visible then
		return
	end
	_setOfferVisible(near)
	if near then
		_setOfferControls(true)
	end
end

--[[
	绑定报价条（ArmWrestleHUD.Offer），Common.Bind 之后调用一次
]]
function Roll.Bind()
	local gui = Common.gui :: Frame
	local frame = Common.Get(gui, "Offer") :: Frame
	_offerFrame = frame
	_offerPrice = Common.Get(frame, "Price") :: TextLabel

	local buy = Common.Get(frame, "BuyButton") :: TextButton
	Common.SetText(Common.Get(buy, "Label") :: TextLabel, "购买")
	buy.MouseButton1Click:Connect(function()
		if _offerSpinning then
			return
		end
		local ok, res = Common.Invoke("OfferBuy")
		if ok then
			local mat = ArmWrestleConfig.GetMaterial(res)
			SystemUISfx.PlaySuccess()
			Common.Confetti()
			if mat then
				_tipNewMaterial(mat, ArmWrestleConfig.GetRarity(mat.Xyd))
			end
			_discardOffer()
		else
			Common.ShowErrorTip(res)
		end
	end)
	local nextBtn = Common.Get(frame, "NextButton") :: TextButton
	Common.SetText(Common.Get(nextBtn, "Label") :: TextLabel, "换一个")
	local keyHint = Style.Label(
		nextBtn,
		nil,
		UDim2.new(1, -KEY_HINT_SIZE + 6, 0, -8),
		UDim2.fromOffset(KEY_HINT_SIZE, KEY_HINT_SIZE),
		C.Gold,
		{ Name = "KeyHint", ZIndex = nextBtn.ZIndex + 2 }
	)
	Common.SetRaw(keyHint, "E")
	nextBtn.MouseButton1Click:Connect(_onNext)
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not processed and input.KeyCode == NEXT_KEY and frame.Visible then
			_onNext()
		end
	end)
	local close = Common.Get(frame, "CloseButton") :: TextButton
	Common.SetRaw(Common.Get(close, "Label") :: TextLabel, "X")
	close.MouseButton1Click:Connect(_discardOffer)
	_offerControls = { _offerPrice :: TextLabel, buy, nextBtn, close }
end

return Roll
