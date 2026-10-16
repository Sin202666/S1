--[[
	Module: HiddenPlayers
	Description: 扳手腕对局期间本地隐藏其他玩家角色（身体 / 饰品 / 贴图 / 角色身上特效），对局交还后恢复
	Author: 程莘
	Created: 2026-10-15
	Last Modified: 2026-10-15

	范围：
	- 除本地玩家外所有玩家的 Character：BasePart / Decal 用 LocalTransparencyModifier = 1；
	  ParticleEmitter / Trail / Beam 关 Enabled
	- 对局中新加入的玩家、重生的角色、后加载的饰品一并隐藏
	- 头顶名字由服务端 PlayerManager 统一关掉；头顶 BillboardGui 由 SceneBillboards 处理，本模块不碰

	约束：
	- 纯本地显示：不改 CFrame / 碰撞 / 服务端可见状态；对手是配置 NPC，不在玩家列表里，不受影响
	- 只恢复本模块改过的实例：特效只恢复「本模块关掉的、原本开启的」那些
	- Hide / Show 成对调用（SystemArmWrestle 对局开始 / Release）；重复 Hide 忽略，未 Hide 时 Show 忽略

	加载（仅 SystemArmWrestle 内部使用）：
		local HiddenPlayers = require(script.HiddenPlayers)
		HiddenPlayers.Hide()   -- 对局开始
		HiddenPlayers.Show()   -- 对局交还控制
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local LocalPlayer = Utils.LocalPlayer

local HiddenPlayers = {}

local _active = false
local _parts: { [Instance]: number } = {}
local _effects: { Instance } = {}
local _conns: { RBXScriptConnection } = {}

--[[
	隐藏单个角色节点并记录原值，供 Show 恢复
	@param inst Instance - 角色下的候选实例；非可隐藏类型或已处理过时忽略
]]
local function _hideOne(inst: Instance)
	local obj = inst :: any
	if inst:IsA("BasePart") or inst:IsA("Decal") then
		if _parts[inst] == nil then
			_parts[inst] = obj.LocalTransparencyModifier
			obj.LocalTransparencyModifier = 1
		end
	elseif inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam") then
		if obj.Enabled then
			obj.Enabled = false
			table.insert(_effects, inst)
		end
	end
end

--[[
	隐藏角色现有节点，并监听之后挂上的饰品 / 特效
	@param character Model - 其他玩家的角色
]]
local function _hideCharacter(character: Model)
	for _, desc in ipairs(character:GetDescendants()) do
		_hideOne(desc)
	end
	table.insert(_conns, character.DescendantAdded:Connect(_hideOne))
end

--[[
	跟踪一个其他玩家：当前角色立即隐藏，之后重生的角色也隐藏
	@param player Player - 玩家；本地玩家忽略
]]
local function _trackPlayer(player: Player)
	if player == LocalPlayer then
		return
	end
	if player.Character then
		_hideCharacter(player.Character)
	end
	table.insert(_conns, player.CharacterAdded:Connect(_hideCharacter))
end

--[[
	对局开始：本地隐藏全部其他玩家角色（重复调用忽略）
]]
function HiddenPlayers.Hide()
	if _active then
		return
	end
	_active = true
	for _, player in ipairs(Players:GetPlayers()) do
		_trackPlayer(player)
	end
	table.insert(_conns, Players.PlayerAdded:Connect(_trackPlayer))
end

--[[
	对局交还控制：恢复本模块隐藏且仍在场景中的节点，停止监听（未 Hide 时忽略）
]]
function HiddenPlayers.Show()
	if not _active then
		return
	end
	_active = false
	for _, conn in ipairs(_conns) do
		conn:Disconnect()
	end
	table.clear(_conns)
	for inst, origin in pairs(_parts) do
		if inst.Parent then
			(inst :: any).LocalTransparencyModifier = origin
		end
	end
	table.clear(_parts)
	for _, inst in ipairs(_effects) do
		if inst.Parent then
			(inst :: any).Enabled = true
		end
	end
	table.clear(_effects)
end

return HiddenPlayers
