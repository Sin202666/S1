--[[
	Module: BattleSfx
	Description: 扳手腕对局音效：开局铃、点按拳击声、砸桌、胜负人群反应、获胜演出的甩飞 / 落地撞击
	Author: 程莘
	Created: 2026-10-15
	Last Modified: 2026-10-15

	约束：
	- 纯表现，只在本机 2D 播放（只有自己听到），不发 Remote、不参与结算
	- 统一经 SoundModule:PlaySoundLocal 播放；模板挂在 SoundService.EFFECT 组下，跟随设置面板音效音量
	- 点按音限频 TAP_MIN_INTERVAL，并在多份不同 PlaybackSpeed 的模板间随机，连点不糊成一片；自动点击不出声
	- Release / 角色重生时 StopAll，避免对局外残留欢呼等长音

	模板（SoundService.EFFECT 下 Sound.Name）：
	- 扳手腕-开局铃 / 扳手腕-握拳：开局
	- 扳手腕-点击1~3：点按（同一音源、音高不同）
	- 扳手腕-砸桌：分出胜负瞬间手背砸桌
	- 扳手腕-欢呼 / 扳手腕-惋惜：胜 / 负人群反应（获胜演出时延到庆祝段）
	- 扳手腕-甩飞 / 扳手腕-落地撞击 / 扳手腕-碎石：获胜演出

	加载（仅 SystemArmWrestle 及其子模块内部使用）：
		local BattleSfx = require(script.BattleSfx)          -- SystemArmWrestle
		local BattleSfx = require(script.Parent.BattleSfx)   -- 子模块
		BattleSfx.PlayStart()
		BattleSfx.PlayTap()
		BattleSfx.PlayDecide()
		BattleSfx.PlayReaction(true)
		BattleSfx.StopAll()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SoundModule = Utils.SoundModule

local BattleSfx = {}

local SFX_BELL = "扳手腕-开局铃"
local SFX_GRIP = "扳手腕-握拳"
local SFX_TAPS = { "扳手腕-点击1", "扳手腕-点击2", "扳手腕-点击3" }
local SFX_DECIDE = "扳手腕-砸桌"
local SFX_CHEER = "扳手腕-欢呼"
local SFX_AWW = "扳手腕-惋惜"
local SFX_LAUNCH = "扳手腕-甩飞"
local SFX_IMPACT = "扳手腕-落地撞击"
local SFX_RUBBLE = "扳手腕-碎石"
local ALL_SFX = {
	SFX_BELL,
	SFX_GRIP,
	SFX_TAPS[1],
	SFX_TAPS[2],
	SFX_TAPS[3],
	SFX_DECIDE,
	SFX_CHEER,
	SFX_AWW,
	SFX_LAUNCH,
	SFX_IMPACT,
	SFX_RUBBLE,
}
local TAP_MIN_INTERVAL = 0.07
local STOP_FADE_SEC = 0.25

local _lastTap = 0

--[[
	本机 2D 播放一个对局音效
	@param name string - SoundService 下模板 Sound.Name
]]
local function _play(name: string)
	SoundModule:PlaySoundLocal({ SoundName = name, Is2D = true })
end

--[[
	开局：拳击铃 + 双方握拳
	@return nil
]]
function BattleSfx.PlayStart()
	_play(SFX_BELL)
	_play(SFX_GRIP)
end

--[[
	玩家真实点按：限频 TAP_MIN_INTERVAL 秒，随机挑一个音高的拳击声
	@return nil
]]
function BattleSfx.PlayTap()
	local now = os.clock()
	if now - _lastTap < TAP_MIN_INTERVAL then
		return
	end
	_lastTap = now
	_play(SFX_TAPS[math.random(#SFX_TAPS)])
end

--[[
	分出胜负瞬间（收到服务端 End）：手背砸桌
	@return nil
]]
function BattleSfx.PlayDecide()
	_play(SFX_DECIDE)
end

--[[
	胜负人群反应（与胜负动作 / 结果弹窗同时）
	@param win boolean - true 欢呼，false 惋惜
	@return nil
]]
function BattleSfx.PlayReaction(win: boolean)
	_play(if win then SFX_CHEER else SFX_AWW)
end

--[[
	获胜演出：对手被甩飞出去
	@return nil
]]
function BattleSfx.PlayLaunch()
	_play(SFX_LAUNCH)
end

--[[
	获胜演出：对手头朝下砸进地里（撞击 + 碎石）
	@return nil
]]
function BattleSfx.PlayImpact()
	_play(SFX_IMPACT)
	_play(SFX_RUBBLE)
end

--[[
	渐出停止全部对局音效（Release / 角色重生时调用）
	@return nil
]]
function BattleSfx.StopAll()
	for _, name in ipairs(ALL_SFX) do
		SoundModule:StopSoundLocal({ SoundName = name, FadeTime = STOP_FADE_SEC })
	end
end

return BattleSfx
