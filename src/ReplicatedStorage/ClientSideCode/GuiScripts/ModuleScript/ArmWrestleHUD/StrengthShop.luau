--[[
	Module: StrengthShop
	Description: 扳手腕主界面右侧付费栏：力量倍数档（x2→x64 依次购买）与三档力量包
	Author: 程莘
	Created: 2026-10-14
	Last Modified: 2026-10-14

	功能：
	- 顶部大按钮只展示「下一档」力量倍数（读服务端同步的 StrengthTier Attribute），买满最高档后整块隐藏
	- 下方力量包按钮价签 = PerClick × Amount（与服务端 Economy.GrantProduct 同公式，仅展示），用 FormatFixed 显示 1.00T / 10.0B
	- 点击一律经 Common.Purchase：商品 Id 为 0 走 Studio DevGrant，否则弹官方购买；发货与档位校验全在服务端

	静态 UI（Studio 维护于 StarterGui.ScreenGui.ArmWrestleHUD，本模块只绑定不新建，节点名为代码契约）：
	- Right(UIScale)
	  - Tier / PriceBar / Limited（「仅限」）、Price（Robux 价，文本前缀 \u{E002} 字形，不挂图片）
	  - Tier / TierButton / Label（「x{1} 力量」）
	  - Pack1..Pack3：顺序对应 ArmWrestleConfig.StrengthPackOrder；子节点 Price（同上）、Amount（「+ 1.00T」）

	与相关模块：
	- ArmWrestleHUD.init：Bind 后把 Right 写入 Common.hud.right，对局中由 Battle 隐藏
	- 服务端 SystemArmWrestle.Economy.GrantProduct：StrengthTier / Strength 发货；真实收据经 SystemBuyRoblox

	加载：
		local StrengthShop = require(script.StrengthShop)
		Common.hud.right = StrengthShop.Bind(Common.gui)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local LocalPlayer = Utils.LocalPlayer
local ArmWrestleConfig = Utils.ArmWrestleConfig
local ArmWrestleStyle = Utils.ArmWrestleStyle

local Common = require(script.Parent.Common)

local Style = ArmWrestleStyle
local FormatFixed = ArmWrestleConfig.FormatFixed

local StrengthShop = {}

local PACK_PREFIX = "Pack"
local PRODUCT_KIND = "Product"
-- Roblox 私有区 Robux 字形（全项目统一用字形，不用 R$ 文本或图片）
local ROBUX_GLYPH = utf8.char(0xE002)

local _tierFrame: Frame?
local _tierPrice: TextLabel?
local _tierLabel: TextLabel?
local _tierBtn: TextButton?
local _packs: { { key: string, price: TextLabel, amount: TextLabel } } = {}
local _lastTier: number? = nil

--[[
	当前可购买的下一档力量倍数
	@return string? - 商品键；已满级为 nil
	@return table? - 商品配置 { Robux, Tier, Mult }
]]
local function _nextTierProduct(): (string?, { [string]: any }?)
	return ArmWrestleConfig.GetStrengthTierProduct(Common.Attr("StrengthTier", 0) + 1)
end

--[[
	刷新顶部力量倍数按钮；档位变化时回弹提示
]]
local function _renderTier()
	local frame = _tierFrame
	if not frame or not _tierPrice or not _tierLabel then
		return
	end
	local tier = Common.Attr("StrengthTier", 0)
	local _, product = _nextTierProduct()
	frame.Visible = product ~= nil
	if not product then
		return
	end
	Common.SetRaw(_tierPrice, ROBUX_GLYPH .. " " .. tostring(product.Robux))
	Common.SetText(_tierLabel, "力量倍数标签", { tostring(product.Mult) })
	if _lastTier and tier ~= _lastTier and _tierBtn then
		Style.Pop(_tierBtn)
	end
	_lastTier = tier
end

--[[
	刷新力量包价签（随每次训练力量变化）
]]
local function _renderPacks()
	local perClick = Common.Attr("PerClick", 1)
	for _, pack in ipairs(_packs) do
		local product = ArmWrestleConfig.GetProduct(pack.key)
		if product then
			Common.SetRaw(pack.price, ROBUX_GLYPH .. " " .. tostring(product.Robux))
			Common.SetRaw(pack.amount, "+ " .. FormatFixed(perClick * (product.Amount or 0)))
		end
	end
end

--[[
	购买下一档力量倍数（客户端只决定弹哪个商品，档位以服务端为准）
]]
local function _buyNextTier()
	local key = _nextTierProduct()
	if key then
		Common.Purchase(PRODUCT_KIND, key)
	end
end

--[[
	重绘整栏
]]
function StrengthShop.Render()
	_renderTier()
	_renderPacks()
end

--[[
	绑定右侧付费栏静态节点与镜像监听（ArmWrestleHUD.Init 调一次）
	@param gui Frame - ArmWrestleHUD 容器（Common.gui）
	@return Frame - Right 分组，供对局中隐藏
]]
function StrengthShop.Bind(gui: Frame): Frame
	local right = Common.Get(gui, "Right") :: Frame
	local tier = Common.Get(right, "Tier") :: Frame
	_tierFrame = tier
	Common.SetText(Common.Get(tier, "PriceBar", "Limited") :: TextLabel, "仅限")
	_tierPrice = Common.Get(tier, "PriceBar", "Price") :: TextLabel
	local tierBtn = Common.Get(tier, "TierButton") :: TextButton
	_tierBtn = tierBtn
	_tierLabel = Common.Get(tierBtn, "Label") :: TextLabel
	tierBtn.MouseButton1Click:Connect(_buyNextTier)

	for i, key in ipairs(ArmWrestleConfig.StrengthPackOrder) do
		local btn = Common.Get(right, PACK_PREFIX .. i) :: TextButton
		table.insert(_packs, {
			key = key,
			price = Common.Get(btn, "Price") :: TextLabel,
			amount = Common.Get(btn, "Amount") :: TextLabel,
		})
		btn.MouseButton1Click:Connect(function()
			Common.Purchase(PRODUCT_KIND, key)
		end)
	end

	LocalPlayer:GetAttributeChangedSignal("StrengthTier"):Connect(_renderTier)
	LocalPlayer:GetAttributeChangedSignal("PerClick"):Connect(_renderPacks)
	StrengthShop.Render()
	return right
end

return StrengthShop
