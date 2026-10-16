--[[
	Module: ArmWrestleArms
	Description: 手臂/材质弹窗（ScreenGui.ArmWrestleArms）的 UIManager 模块，渲染转发 ArmWrestleHUD
	Author: 程莘
	Created: 2026-10-14
	Last Modified: 2026-10-14

	显隐由 UIManager（SHOW_LOCAL_UI）负责；本模块只在显示后关闭其余面板并渲染，不切换 HUD 显隐。
]]

local HUD = require(script.Parent.ArmWrestleHUD)
local ArmWrestleArms = {}

function ArmWrestleArms:openUi()
	HUD.OnPanelOpened("Arms")
end

function ArmWrestleArms:updateUi()
	HUD.RenderArms()
end

return ArmWrestleArms
