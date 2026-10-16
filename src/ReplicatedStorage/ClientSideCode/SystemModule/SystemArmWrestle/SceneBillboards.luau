--[[
	Module: SceneBillboards
	Description: 扳手腕对局期间本地隐藏场景里的 BillboardGui（对手头顶牌、价签、概率牌等），对局交还后恢复
	Author: 程莘
	Created: 2026-10-15
	Last Modified: 2026-10-15

	范围：
	- Workspace 下全部 BillboardGui
	- PlayerGui 下的 BillboardGui（克隆进 PlayerGui 再 Adornee 回场景的世界牌，视觉上同属场景）
	- 对局中新流入 / 新创建的 BillboardGui 一并关掉（StreamingEnabled 下场景边走边加载）

	约束：
	- 纯本地显示：只改 Enabled；只记录并恢复「本模块关掉的、原本开启的」那些，对局中其他系统自行开关的不追踪
	- Hide / Show 成对调用（SystemArmWrestle 对局开始 / Release）；重复 Hide 忽略，未 Hide 时 Show 忽略
	- 只在对局开始时遍历一次场景，之后靠 DescendantAdded 增量处理，不轮询

	加载（仅 SystemArmWrestle 内部使用）：
		local SceneBillboards = require(script.SceneBillboards)
		SceneBillboards.Hide()   -- 对局开始
		SceneBillboards.Show()   -- 对局交还控制
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Workspace = game:GetService("Workspace")
local LocalPlayer = Utils.LocalPlayer

local SceneBillboards = {}

local _active = false
local _hidden: { BillboardGui } = {}
local _conns: { RBXScriptConnection } = {}

--[[
	关掉单个开启中的 BillboardGui 并记录，供 Show 恢复
	@param inst Instance - 候选实例；非 BillboardGui 或本就关闭时忽略
]]
local function _hideOne(inst: Instance)
	if inst:IsA("BillboardGui") and inst.Enabled then
		inst.Enabled = false
		table.insert(_hidden, inst)
	end
end

--[[
	关掉根节点下现有的 BillboardGui，并监听之后新增的
	@param root Instance - Workspace 或 PlayerGui
]]
local function _hideUnder(root: Instance)
	for _, desc in ipairs(root:GetDescendants()) do
		_hideOne(desc)
	end
	table.insert(_conns, root.DescendantAdded:Connect(_hideOne))
end

--[[
	对局开始：本地关掉场景内全部开启中的 BillboardGui（重复调用忽略）
]]
function SceneBillboards.Hide()
	if _active then
		return
	end
	_active = true
	_hideUnder(Workspace)
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		_hideUnder(playerGui)
	end
end

--[[
	对局交还控制：恢复本模块关掉且仍在场景中的 BillboardGui，停止监听新增（未 Hide 时忽略）
]]
function SceneBillboards.Show()
	if not _active then
		return
	end
	_active = false
	for _, conn in ipairs(_conns) do
		conn:Disconnect()
	end
	table.clear(_conns)
	for _, gui in ipairs(_hidden) do
		if gui.Parent then
			gui.Enabled = true
		end
	end
	table.clear(_hidden)
end

return SceneBillboards
