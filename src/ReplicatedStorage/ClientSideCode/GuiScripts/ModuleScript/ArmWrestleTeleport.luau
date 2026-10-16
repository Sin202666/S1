--[[
	Module: ArmWrestleTeleport
	Description: 传送弹窗（ScreenGui.ArmWrestleTeleport）的 UIManager 模块，渲染转发 ArmWrestleHUD
	Author: 程莘
	Created: 2026-10-15
	Last Modified: 2026-10-15

	显隐由 UIManager（SHOW_LOCAL_UI）负责；本模块只在显示后关闭其余面板并渲染，不切换 HUD 显隐。
]]

local HUD = require(script.Parent.ArmWrestleHUD)
local ArmWrestleTeleport = {}

function ArmWrestleTeleport:openUi()
	HUD.OnPanelOpened("Teleport")
end

return ArmWrestleTeleport
