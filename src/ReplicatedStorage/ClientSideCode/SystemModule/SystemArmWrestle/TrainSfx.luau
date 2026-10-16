--[[
	Module: TrainSfx
	Description: 手持哑铃训练音效：每次训练一声泡泡音
	Author: 程莘
	Created: 2026-10-15
	Last Modified: 2026-10-15

	约束：
	- 纯表现，只在本机 2D 播放（训练弹字也只有自己看得到），不发 Remote、不参与结算
	- 直接经 SoundInstance 零渐入播放：SoundModule:PlaySoundLocal 固定 0.1s 渐入，会把短促泡泡音的起音削软；
	  模板挂在 SoundService.EFFECT 组下，跟随设置面板音效音量

	模板（SoundService.EFFECT 下 Sound.Name）：
	- 训练-气泡：卡通泡泡音

	加载（仅 SystemArmWrestle 子模块内部使用）：
		local TrainSfx = require(script.TrainSfx)
		TrainSfx.PlayBubble()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SoundInstance = Utils.SoundInstance

local TrainSfx = {}

local SFX_BUBBLE = "训练-气泡"
local FADE_IN_SEC = 0

--[[
	播一声训练泡泡音
	@return nil
]]
function TrainSfx.PlayBubble()
	local sound = SoundInstance:new({ SoundName = SFX_BUBBLE, Is2D = true })
	if sound then
		sound:playSound(FADE_IN_SEC)
	end
end

return TrainSfx
