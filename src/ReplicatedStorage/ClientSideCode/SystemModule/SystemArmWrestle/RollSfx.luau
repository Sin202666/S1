--[[
	Module: RollSfx
	Description: 材质箱抽取表演音效：忽大忽小的逐步滚动声（音调渐升）、定格揭晓
	Author: 程莘
	Created: 2026-10-15
	Last Modified: 2026-10-15

	约束：
	- 纯表现，只在本机播放（抽取表演本身只有抽的人看得到），不发 Remote、不参与结算
	- 3D 播放：声源放在箱子上方的表演位置，随镜头距离/方位衰减；衰减范围取模板 RollOffMin/MaxDistance
	- 直接经 SoundInstance 零渐入播放：SoundModule:PlaySoundLocal 固定 0.1s 渐入，会把短促滚动声的起音削软；
	  模板挂在 SoundService.EFFECT 组下，跟随设置面板音效音量
	- 逐步滚动声按进度在多份不同 PlaybackSpeed 的模板间升调，越接近定格音越高

	模板（SoundService.EFFECT 下 Sound.Name）：
	- 抽取-滚动1~3：忽大忽小每一步（同一音源、音高递增）
	- 抽取-定格：揭晓抽中材质

	加载（仅 SystemArmWrestle 子模块内部使用）：
		local RollSfx = require(script.Parent.RollSfx)
		RollSfx.PlayStep(step, totalSteps, showcase.rollCFrame.Position)
		RollSfx.PlayReveal(showcase.rollCFrame.Position)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SoundInstance = Utils.SoundInstance

local RollSfx = {}

local SFX_STEPS = { "抽取-滚动1", "抽取-滚动2", "抽取-滚动3" }
local SFX_REVEAL = "抽取-定格"
local FADE_IN_SEC = 0

--[[
	本机 3D 零渐入播放一个抽取音效（非循环，播完自动归还池）
	@param name string - SoundService 下模板 Sound.Name
	@param position Vector3 - 声源世界坐标
]]
local function _play(name: string, position: Vector3)
	local sound = SoundInstance:new({ SoundName = name, Is2D = false, PlayPosition = position })
	if sound then
		sound:playSound(FADE_IN_SEC)
	end
end

--[[
	忽大忽小的一步：按进度挑音高，越接近定格越高
	@param step number - 当前第几步（1 起）
	@param total number - 总步数（≥1）
	@param position Vector3 - 声源世界坐标（表演手臂所在位置）
	@return nil
]]
function RollSfx.PlayStep(step: number, total: number, position: Vector3)
	local index = math.clamp(math.ceil(step / math.max(total, 1) * #SFX_STEPS), 1, #SFX_STEPS)
	_play(SFX_STEPS[index], position)
end

--[[
	定格揭晓音
	@param position Vector3 - 声源世界坐标（表演手臂所在位置）
	@return nil
]]
function RollSfx.PlayReveal(position: Vector3)
	_play(SFX_REVEAL, position)
end

return RollSfx
