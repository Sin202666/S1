--[[
	Module: ArmWrestleDumbbells
	Description: 哑铃弹窗（ScreenGui.ArmWrestleDumbbells）的 UIManager 模块，渲染转发 ArmWrestleHUD
	Author: 程莘
	Created: 2026-10-14
	Last Modified: 2026-10-14

	显隐由 UIManager（SHOW_LOCAL_UI）负责；本模块只在显示后关闭其余面板并渲染，不切换 HUD 显隐。
]]

local HUD = require(script.Parent.ArmWrestleHUD)
local ArmWrestleDumbbells = {}

function ArmWrestleDumbbells:openUi()
	HUD.OnPanelOpened("Dumbbells")
end

function ArmWrestleDumbbells:updateUi()
	HUD.RenderDumbbells()
end

return ArmWrestleDumbbells
