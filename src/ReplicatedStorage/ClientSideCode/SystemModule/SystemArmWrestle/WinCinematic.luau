--[[
	Module: WinCinematic
	Description: 扳手腕获胜演出：对手顺着掰赢方向旋转飞出、头朝下插进地里（裂纹 / 碎石 / 尘土 / 冲击波），镜头最后转到玩家庆祝
	Author: 程莘
	Created: 2026-10-15
	Last Modified: 2026-10-16

	时间轴（秒，自 Play 起；落地后顿帧 HITSTOP_SEC，期间时间轴暂停、只震屏）：
	- 0 ~ FLY_START：镜头从握手机位推近相握的手，拳头处迸火花；克隆体经 BattlePose.HandOffOpponent 接手原对手当前输姿，
	  无缝衔接（未在接管中时退回 Anim 拉锯片掰输端）；起飞时交还，切到甩飞动作
	- FLY_START ~ IMPACT：对手克隆体顺着掰赢方向（玩家左手侧，AW_Battle 赢的一端拳头往玩家左边压）横飞，
	  高度只降不升（先平后陡，像被平抛）、同时侧翻约 1.5 圈（FLIP_ANGLE）；
	  镜头硬切到对手一侧的固定全景（起飞点与落点同时入画），缓慢推近
	- IMPACT：头朝下插进落点地面，震屏 + 顿帧，裂纹 / 碎石 / 尘土 / 冲击波；全景再停 CAM_WIDE_HOLD_SEC 看清落点
	- 之后 ~ CELEBRATE：转到贴地仰拍露在地面上抽搐的双腿
	- CELEBRATE ~ WIN_CINEMATIC_SEC：镜头甩到玩家正面缓推，回调 onCelebrate（玩家庆祝动作 + 胜利弹窗）；之后定格到服务端 Release

	约束：
	- 纯表现，只在获胜者本地播放；奖励以服务端 End 载荷为准，演出不参与结算
	- 原对手模型只用 LocalTransparencyModifier 隐藏，从不写其 CFrame；飞出去的是本地克隆体
	- 不写玩家 HRP（玩家仍在服务端入座点）；碎石为锚定件由本模块逐帧摆放、不参与物理，不会推动角色
	- 不写 CurrentCamera：Step 只返回本帧镜头 CFrame（含震屏），由 SystemArmWrestle 对局镜头唯一写口落地
	- 服务端 Battle 获胜后延迟 WIN_RELEASE_DELAY_SEC 才出场并发 Release，须大于 WIN_CINEMATIC_SEC
	- Release / 新对局 / 角色重生时 Stop：销毁克隆体与特效、恢复原对手显示
	- 起飞 / 落地音效经 BattleSfx 在对应帧触发（不受顿帧影响）；欢呼由 onCelebrate 侧播放

	加载（仅 SystemArmWrestle 内部使用）：
		local WinCinematic = require(script.WinCinematic)
		-- 收到获胜 End：
		local played = WinCinematic.Play(tableModel, LocalPlayer.Character, function()
			Anim.PlayResult(true)
		end)
		-- RenderStepped（唯一镜头写口）：
		local cf = WinCinematic.Step(dt)
		if cf then
			camera.CFrame = cf
		end
		-- Release：
		WinCinematic.Stop()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TweenService = Utils.TweenService
local Workspace = game:GetService("Workspace")
local ArmWrestleConfig = Utils.ArmWrestleConfig
local Log = Utils.Log

local Anim = require(script.Parent.Anim)
local BattlePose = require(script.Parent.BattlePose)
local BattleSfx = require(script.Parent.BattleSfx)

local WinCinematic = {}

local SEAT_ATTR = ArmWrestleConfig.SEAT_ATTR
local OPP_PIVOT_ATTR = "OppPivot"
local OPPONENT_MODEL_NAME = ArmWrestleConfig.OPPONENT_MODEL_NAME
local ANIM_FLAIL = ArmWrestleConfig.ANIM_LOSE
local TOTAL_SEC = ArmWrestleConfig.WIN_CINEMATIC_SEC
local FX_FOLDER_NAME = "ArmWrestleWinFx"
local FLAT = Vector3.new(1, 0, 1)
local UP = Vector3.yAxis

-- 开场定格只留一点蓄力感，过长会被感知为卡顿
local FLY_START = 0.12
local IMPACT = 0.62
local CELEBRATE = 2.3
local HITSTOP_SEC = 0.09
-- 落点沿掰赢方向离对手的水平距离（略远于桌边，仍落在台面内侧）；该方向有碰撞件时往回收 WALL_MARGIN
local LAND_DIST = 6.5
local WALL_MARGIN = 1.5
-- 落点再沿对手背后（背对玩家）平移，不改变侧向摔出距离
local LAND_BACK = 2
-- 侧翻总角度：1.5 圈落地正好头朝下，再多转一点让双腿顺着飞行方向斜插
local FLIP_ANGLE = math.pi * 3 + math.rad(12)
-- 下落曲线指数：越大前段越平、后段越陡
local FALL_POWER = 2
-- 头朝下时 HRP 中心低于地面的深度：头和上半截躯干埋进地里，腰和双腿露出
local BURY_DEPTH = 0.4
-- 桌子 Pivot 属性是桌面高度，相握的拳在其上方约 0.8
local HAND_HEIGHT = 0.8

local CAM_BATTLE_DIST = 8
local CAM_BATTLE_HEIGHT = 2.25
local CAM_PUSH_DIST = 4.2
local CAM_PUSH_HEIGHT = 1
-- 横飞全景 / 落地特写机位：在对手一侧朝玩家方向回看（从玩家一侧拍会被玩家身体挡满画面），玩家与桌子作背景；
-- 角度为偏离「对手背后」朝掰赢方向转的角度；被挡墙挡住时由 _clampCamera 拉回。
-- 全景注视点取起飞点→落点 CAM_WIDE_BIAS 处，机位固定不跟拍，飞得快也不会甩出画面。
-- 全景取负角（起飞点斜后方高位）：掰赢方向一侧离挡墙太近，机位会被拉到 5 格内，框不住起飞点与落点
local CAM_WIDE_ANGLE = math.rad(-60)
local CAM_WIDE_DIST_FROM = 8
local CAM_WIDE_DIST_TO = 7.5
local CAM_WIDE_HEIGHT = 4
local CAM_WIDE_LOOK_HEIGHT = 1.5
local CAM_WIDE_BIAS = 0.5
local CAM_WIDE_HOLD_SEC = 0.35
local CAM_LAND_ANGLE = math.rad(35)
local CAM_WALL_PAD = 0.6
local CAM_LAND_DIST_FROM = 6.5
local CAM_LAND_DIST_TO = 5
local CAM_LAND_HEIGHT = 0.4
local CAM_LAND_LOOK_HEIGHT = 1.8
local CAM_CHEER_DIST_FROM = 6
local CAM_CHEER_DIST_TO = 4.5
local CAM_CHEER_SIDE = 3
local CAM_CHEER_HEIGHT = 1.8
local CAM_CHEER_LOOK_HEIGHT = 0.8
-- 镜头指数平滑速率：越大跟得越紧；math.huge 为硬切
local SMOOTH_PUSH = 12
local SMOOTH_CUT = math.huge
local SMOOTH_LAND = 6
local SMOOTH_CHEER = 5
local SHAKE_AMP = 1.1
local SHAKE_DECAY = 6
local SHAKE_FREQ = 22
local SHAKE_ROLL = 0.05

local CRATER_SIZE = 3.6
local CRACK_COUNT = 9
local CRACK_INNER = 1.2
local CRACK_LEN_MIN = 2.2
local CRACK_LEN_MAX = 4.4
local CRACK_GROW_SEC = 0.12
local CRACK_COLOR = Color3.fromRGB(28, 24, 22)
local ROCK_COUNT = 12
local ROCK_GRAVITY = 60
local ROCK_BOUNCE = 0.3
local ROCK_REST_SPEED = 2
local SHOCKWAVE_SIZE = 14
local SHOCKWAVE_SEC = 0.35
local DUST_COLOR = Color3.fromRGB(205, 190, 165)
local DUST_RING_COUNT = 26
local DUST_COLUMN_COUNT = 10
local SPARK_COUNT = 25
-- 白底软尘 / 四芒星，art/vfx/aura/aura-smoke.png、aura-spark.png，由 Color 染色
local SMOKE_TEXTURE = "rbxassetid://127208793645214"
local SPARK_TEXTURE = "rbxassetid://82402156329894"
local LEG_TWITCH_ANGLE = math.rad(18)
local LEG_TWITCH_FREQ = 9
local LEG_TWITCH_DECAY = 1.2

type Rock = {
	Part: BasePart,
	Pos: Vector3,
	Vel: Vector3,
	Rot: CFrame,
	Spin: Vector3,
	Half: number,
	Resting: boolean,
}

type Session = {
	Character: Model?,
	Seat: CFrame,
	Folder: Folder,
	Clone: Model,
	Root: BasePart,
	Hidden: { Instance },
	Hips: { [Motor6D]: CFrame },
	Rocks: { Rock },
	StartCf: CFrame,
	EndCf: CFrame,
	Ground: Vector3,
	FloorHit: RaycastResult?,
	RayParams: RaycastParams,
	Axis: Vector3,
	Side: Vector3,
	Facing: Vector3,
	Slam: Vector3,
	Focus: Vector3,
	Clock: number,
	Real: number,
	Hitstop: number,
	Flailing: boolean,
	Impacted: boolean,
	Celebrated: boolean,
	OnCelebrate: (() -> ())?,
	CamPos: Vector3,
	CamLook: Vector3,
}

local _session: Session? = nil

--[[
	缓入缓出
	@param t number - 0~1 进度
	@return number - 平滑后进度
]]
local function _smooth(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

--[[
	缓出（先快后慢）
	@param t number - 0~1 进度
	@return number - 平滑后进度
]]
local function _easeOut(t: number): number
	t = math.clamp(t, 0, 1)
	return 1 - (1 - t) * (1 - t)
end

--[[
	创建本地特效件（锚定、无碰撞、不参与射线 / 触碰）
	@param parent Instance - 父级（演出文件夹）
	@param size Vector3 - 尺寸
	@param cf CFrame - 位姿
	@param color Color3 - 颜色
	@param material Enum.Material - 材质
	@return Part - 新零件
]]
local function _newPart(parent: Instance, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material
	part.Parent = parent
	return part
end

--[[
	在指定点放一个不可见锚点并挂上粒子发射器（Enabled=false，由调用方 Emit）
	@param parent Instance - 父级（演出文件夹）
	@param position Vector3 - 世界坐标
	@param props table - ParticleEmitter 属性表（Texture / Color / Size / Speed 等）
	@return ParticleEmitter - 发射器
]]
local function _newEmitter(parent: Instance, position: Vector3, props: { [string]: any }): ParticleEmitter
	local anchor = _newPart(parent, Vector3.one, CFrame.new(position), Color3.new(1, 1, 1), Enum.Material.SmoothPlastic)
	anchor.Transparency = 1
	local emitter = Instance.new("ParticleEmitter")
	emitter.Enabled = false
	for key, value in pairs(props) do
		(emitter :: any)[key] = value
	end
	emitter.Parent = anchor
	return emitter
end

--[[
	求落点：从对手沿掰赢方向 LAND_DIST，有碰撞件时往回收，再沿对手背后 LAND_BACK；然后向下找地面
	@param start Vector3 - 对手 HRP 位置
	@param dir Vector3 - 掰赢方向（水平单位向量，玩家左手侧）
	@param back Vector3 - 对手背后的水平单位向量（背对玩家）
	@param params RaycastParams - 排除玩家角色 / 桌子 / 演出文件夹、只认可碰撞件
	@return Vector3 - 地面点
	@return RaycastResult? - 地面命中结果；没打到地面为 nil（按 R6 站立高度估算地面）
]]
local function _findLanding(start: Vector3, dir: Vector3, back: Vector3, params: RaycastParams): (Vector3, RaycastResult?)
	local dist = LAND_DIST
	local wall = Workspace:Raycast(start, dir * (LAND_DIST + WALL_MARGIN), params)
	if wall then
		dist = math.max(wall.Distance - WALL_MARGIN, 0)
	end
	local above = start + dir * dist + back * LAND_BACK + UP * 4
	local floor = Workspace:Raycast(above, -UP * 20, params)
	if floor then
		return floor.Position, floor
	end
	return Vector3.new(above.X, start.Y - 3, above.Z), nil
end

--[[
	本地克隆对手：去掉碰撞 / 射线 / 脚本 / 交互，供演出随意摆放
	@param original Model - 桌边对手（服务端复制下来的原模型，只读）
	@param parent Instance - 演出文件夹
	@return Model? - 克隆体；克隆失败为 nil
]]
local function _cloneOpponent(original: Model, parent: Instance): Model?
	local archivable = original.Archivable
	original.Archivable = true
	local ok, clone = pcall(original.Clone, original)
	original.Archivable = archivable
	if not ok or not clone then
		Log.warn("SystemArmWrestle.WinCinematic 克隆对手失败", clone)
		return nil
	end
	for _, desc in ipairs(clone:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.CanCollide = false
			desc.CanQuery = false
			desc.CanTouch = false
			desc.LocalTransparencyModifier = 0
		elseif desc:IsA("BaseScript") or desc:IsA("ProximityPrompt") or desc:IsA("BillboardGui") then
			desc:Destroy()
		end
	end
	local hum = clone:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	clone.Parent = parent
	return clone
end

--[[
	隐藏原对手（仅本地显示层，不改其 CFrame / Transparency）；头顶推荐力量牌一并本地关掉，否则会悬在空位上
	@param original Model - 桌边对手
	@return { Instance } - 被隐藏的零件 / 贴花 / 原本开启的 BillboardGui，Stop 时恢复
]]
local function _hideOriginal(original: Model): { Instance }
	local hidden = {}
	for _, desc in ipairs(original:GetDescendants()) do
		if desc:IsA("BasePart") or desc:IsA("Decal") then
			(desc :: any).LocalTransparencyModifier = 1
			table.insert(hidden, desc)
		elseif desc:IsA("BillboardGui") and desc.Enabled then
			desc.Enabled = false
			table.insert(hidden, desc)
		end
	end
	return hidden
end

--[[
	拳头处迸一圈火花（演出开场）
	@param s Session - 当前演出
]]
local function _burstSparks(s: Session)
	local emitter = _newEmitter(s.Folder, s.Focus, {
		Texture = SPARK_TEXTURE,
		Color = ColorSequence.new(Color3.fromRGB(255, 240, 170), Color3.fromRGB(255, 170, 60)),
		LightEmission = 1,
		Size = NumberSequence.new(0.5, 0),
		Lifetime = NumberRange.new(0.3, 0.6),
		Speed = NumberRange.new(8, 14),
		SpreadAngle = Vector2.new(180, 180),
		Drag = 3,
	})
	emitter:Emit(SPARK_COUNT)
end

--[[
	落点裂纹：深色凹坑 + 放射状两折裂缝，快速生长
	@param s Session - 当前演出
]]
local function _spawnCracks(s: Session)
	local ground = s.Ground
	local crater = _newPart(
		s.Folder,
		Vector3.new(0.06, CRATER_SIZE, CRATER_SIZE),
		CFrame.new(ground + UP * 0.03) * CFrame.Angles(0, 0, math.rad(90)),
		CRACK_COLOR,
		Enum.Material.Slate
	)
	crater.Shape = Enum.PartType.Cylinder
	for i = 1, CRACK_COUNT do
		local yaw = (i / CRACK_COUNT) * math.pi * 2 + (math.random() - 0.5) * 0.5
		local length = CRACK_LEN_MIN + math.random() * (CRACK_LEN_MAX - CRACK_LEN_MIN)
		local from = ground + Vector3.new(math.cos(yaw), 0, math.sin(yaw)) * CRACK_INNER
		local lift = UP * (0.02 + i * 0.002)
		local delay = 0
		for segment = 1, 2 do
			local segYaw = if segment == 1 then yaw else yaw + (math.random() - 0.5) * 1
			local segLen = length * (if segment == 1 then 0.55 else 0.45)
			local width = if segment == 1 then 0.24 else 0.14
			local dir = Vector3.new(math.cos(segYaw), 0, math.sin(segYaw))
			local to = from + dir * segLen
			local part = _newPart(
				s.Folder,
				Vector3.new(width, 0.04, 0.05),
				CFrame.lookAt(from + lift, from + lift + dir),
				CRACK_COLOR,
				Enum.Material.Slate
			)
			local mid = (from + to) / 2 + lift
			TweenService:Create(
				part,
				TweenInfo.new(CRACK_GROW_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, delay),
				{ Size = Vector3.new(width, 0.04, segLen), CFrame = CFrame.lookAt(mid, mid + dir) }
			):Play()
			from = to
			delay += CRACK_GROW_SEC * 0.7
		end
	end
end

--[[
	落点碎石：颜色 / 材质取地面，由 _stepRocks 逐帧做简易抛体
	@param s Session - 当前演出
]]
local function _spawnRocks(s: Session)
	local hit = s.FloorHit
	local hitPart = hit and hit.Instance
	local color = if hitPart and hitPart:IsA("BasePart") then hitPart.Color:Lerp(CRACK_COLOR, 0.25) else CRACK_COLOR
	local material = if hit then hit.Material else Enum.Material.Slate
	for _ = 1, ROCK_COUNT do
		local size = 0.35 + math.random() * 0.45
		local yaw = math.random() * math.pi * 2
		local dir = Vector3.new(math.cos(yaw), 0, math.sin(yaw))
		local pos = s.Ground + dir * 0.5 + UP * size
		local rot = CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
		local part = _newPart(s.Folder, Vector3.one * size, CFrame.new(pos) * rot, color, material)
		table.insert(s.Rocks, {
			Part = part,
			Pos = pos,
			Vel = dir * (8 + math.random() * 10) + UP * (14 + math.random() * 12),
			Rot = rot,
			Spin = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 20,
			Half = size / 2,
			Resting = false,
		})
	end
end

--[[
	落点尘土：贴地四散的尘环 + 向上翻涌的尘柱 + 扩散冲击波圈
	@param s Session - 当前演出
]]
local function _spawnDust(s: Session)
	local base = {
		Texture = SMOKE_TEXTURE,
		Color = ColorSequence.new(DUST_COLOR),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.45),
			NumberSequenceKeypoint.new(0.7, 0.78),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-40, 40),
		Acceleration = UP * 1.5,
	}
	local ring = table.clone(base)
	ring.Size = NumberSequence.new(1.2, 3.4)
	ring.Lifetime = NumberRange.new(1.2, 2.2)
	ring.Speed = NumberRange.new(16, 24)
	ring.SpreadAngle = Vector2.new(85, 85)
	ring.Drag = 5
	_newEmitter(s.Folder, s.Ground + UP * 0.3, ring):Emit(DUST_RING_COUNT)
	local column = table.clone(base)
	column.Size = NumberSequence.new(1.4, 2.6)
	column.Lifetime = NumberRange.new(1, 1.8)
	column.Speed = NumberRange.new(6, 10)
	column.SpreadAngle = Vector2.new(20, 20)
	column.Drag = 2
	_newEmitter(s.Folder, s.Ground + UP * 0.3, column):Emit(DUST_COLUMN_COUNT)

	local wave = _newPart(
		s.Folder,
		Vector3.new(0.08, 1, 1),
		CFrame.new(s.Ground + UP * 0.1) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.new(1, 1, 1),
		Enum.Material.Neon
	)
	wave.Shape = Enum.PartType.Cylinder
	wave.Transparency = 0.3
	TweenService:Create(
		wave,
		TweenInfo.new(SHOCKWAVE_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.08, SHOCKWAVE_SIZE, SHOCKWAVE_SIZE), Transparency = 1 }
	):Play()
end

--[[
	落地：定姿、停掉挣扎动作、记录双腿关节、放全部冲击特效
	@param s Session - 当前演出
]]
local function _impact(s: Session)
	s.Impacted = true
	s.Hitstop = HITSTOP_SEC
	s.Root.CFrame = s.EndCf
	local hum = s.Clone:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if animator then
		for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
			track:Stop(0.1)
		end
	end
	local torso = s.Clone:FindFirstChild("Torso")
	if torso then
		for _, name in ipairs({ "Right Hip", "Left Hip" }) do
			local motor = torso:FindFirstChild(name)
			if motor and motor:IsA("Motor6D") then
				s.Hips[motor] = motor.C0
			end
		end
	end
	_spawnCracks(s)
	_spawnRocks(s)
	_spawnDust(s)
	BattleSfx.PlayImpact()
end

--[[
	双腿抽搐（R6 髋关节绕 C0 的 Z 轴摆动），左右反相、逐渐衰减
	@param s Session - 当前演出
	@param t number - 时间轴秒数
]]
local function _twitchLegs(s: Session, t: number)
	local since = t - IMPACT
	local amp = LEG_TWITCH_ANGLE * math.exp(-LEG_TWITCH_DECAY * since)
	for motor, c0 in pairs(s.Hips) do
		local sign = if motor.Name == "Left Hip" then -1 else 1
		motor.C0 = c0 * CFrame.Angles(0, 0, sign * amp * math.sin(since * LEG_TWITCH_FREQ))
	end
end

--[[
	按时间轴摆放对手克隆体：桌边待定 → 抛物线后空翻 → 落地插地
	@param s Session - 当前演出
	@param t number - 时间轴秒数
]]
local function _stepOpponent(s: Session, t: number)
	if t < FLY_START then
		s.Root.CFrame = s.StartCf
		return
	end
	if t < IMPACT then
		if not s.Flailing then
			s.Flailing = true
			BattlePose.HandOffOpponent(nil)
			Anim.PlayOnModel(s.Clone, ANIM_FLAIL, true)
			BattleSfx.PlayLaunch()
		end
		local u = (t - FLY_START) / (IMPACT - FLY_START)
		local from = s.StartCf.Position
		local to = s.EndCf.Position
		local flat = from:Lerp(to, u)
		local pos = Vector3.new(flat.X, from.Y + (to.Y - from.Y) * u ^ FALL_POWER, flat.Z)
		s.Root.CFrame = CFrame.new(pos) * CFrame.fromAxisAngle(UP:Cross(s.Slam), FLIP_ANGLE * u) * s.StartCf.Rotation
		return
	end
	if not s.Impacted then
		_impact(s)
	end
	_twitchLegs(s, t)
end

--[[
	碎石简易抛体：重力 + 落地弹一次后静止
	@param s Session - 当前演出
	@param dt number - 帧间隔
]]
local function _stepRocks(s: Session, dt: number)
	local floorY = s.Ground.Y
	for _, rock in ipairs(s.Rocks) do
		if rock.Resting then
			continue
		end
		rock.Vel -= UP * ROCK_GRAVITY * dt
		rock.Pos += rock.Vel * dt
		rock.Rot = CFrame.Angles(rock.Spin.X * dt, rock.Spin.Y * dt, rock.Spin.Z * dt) * rock.Rot
		if rock.Pos.Y < floorY + rock.Half and rock.Vel.Y < 0 then
			rock.Pos = Vector3.new(rock.Pos.X, floorY + rock.Half, rock.Pos.Z)
			rock.Vel = Vector3.new(rock.Vel.X * 0.5, -rock.Vel.Y * ROCK_BOUNCE, rock.Vel.Z * 0.5)
			rock.Spin *= 0.5
			if rock.Vel.Y < ROCK_REST_SPEED then
				rock.Resting = true
			end
		end
		rock.Part.CFrame = CFrame.new(rock.Pos) * rock.Rot
	end
end

--[[
	玩家当前站位（读角色 HRP，不写）；角色缺失时用桌子入座点
	@param s Session - 当前演出
	@return Vector3 - 玩家 HRP 位置
]]
local function _getPlayerRoot(s: Session): Vector3
	local hrp = s.Character and s.Character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp.Position
	end
	return s.Seat.Position
end

--[[
	机位与注视点之间被挡墙等碰撞件隔开时，把机位拉回到挡点前
	@param s Session - 当前演出（复用其射线参数）
	@param look Vector3 - 注视点
	@param pos Vector3 - 期望机位
	@return Vector3 - 修正后机位；未被挡时原样返回
]]
local function _clampCamera(s: Session, look: Vector3, pos: Vector3): Vector3
	local offset = pos - look
	local hit = Workspace:Raycast(look, offset, s.RayParams)
	if not hit then
		return pos
	end
	return hit.Position - offset.Unit * CAM_WALL_PAD
end

--[[
	对手一侧朝玩家回看的水平机位方向
	@param s Session - 当前演出
	@param angle number - 从「对手背后」朝掰赢方向转的弧度（0 = 对手正后方，π/2 = 掰赢方向正侧）
	@return Vector3 - 水平单位向量（落点 / 飞行中点 + 它 × 距离 = 机位）
]]
local function _slamView(s: Session, angle: number): Vector3
	return s.Facing * math.cos(angle) + s.Slam * math.sin(angle)
end

--[[
	本段镜头目标机位与注视点、平滑速率
	@param s Session - 当前演出
	@param t number - 时间轴秒数
	@return Vector3 - 目标机位
	@return Vector3 - 目标注视点
	@return number - 指数平滑速率
]]
local function _getCameraTarget(s: Session, t: number): (Vector3, Vector3, number)
	if t < FLY_START then
		local k = _easeOut(t / FLY_START)
		local dist = CAM_BATTLE_DIST + (CAM_PUSH_DIST - CAM_BATTLE_DIST) * k
		local height = CAM_BATTLE_HEIGHT + (CAM_PUSH_HEIGHT - CAM_BATTLE_HEIGHT) * k
		return s.Focus + s.Side * dist + UP * height, s.Focus, SMOOTH_PUSH
	end
	local wideEnd = IMPACT + CAM_WIDE_HOLD_SEC
	if t < wideEnd then
		local k = _smooth((t - FLY_START) / (wideEnd - FLY_START))
		local flat = s.StartCf.Position:Lerp(s.Ground, CAM_WIDE_BIAS)
		local look = Vector3.new(flat.X, s.Ground.Y + CAM_WIDE_LOOK_HEIGHT, flat.Z)
		local dist = CAM_WIDE_DIST_FROM + (CAM_WIDE_DIST_TO - CAM_WIDE_DIST_FROM) * k
		local pos = look + _slamView(s, CAM_WIDE_ANGLE) * dist + UP * CAM_WIDE_HEIGHT
		return _clampCamera(s, look, pos), look, SMOOTH_CUT
	end
	if t < CELEBRATE then
		local k = _smooth((t - wideEnd) / (CELEBRATE - wideEnd))
		local orbit = _slamView(s, CAM_LAND_ANGLE)
		local dist = CAM_LAND_DIST_FROM + (CAM_LAND_DIST_TO - CAM_LAND_DIST_FROM) * k
		local look = s.Ground + UP * CAM_LAND_LOOK_HEIGHT
		return _clampCamera(s, look, s.Ground + orbit * dist + UP * CAM_LAND_HEIGHT), look, SMOOTH_LAND
	end
	local k = _smooth((t - CELEBRATE) / math.max(TOTAL_SEC - CELEBRATE, 0.01))
	local root = _getPlayerRoot(s)
	local dist = CAM_CHEER_DIST_FROM + (CAM_CHEER_DIST_TO - CAM_CHEER_DIST_FROM) * k
	local look = root + UP * CAM_CHEER_LOOK_HEIGHT
	local pos = root + s.Axis * dist + s.Side * CAM_CHEER_SIDE + UP * CAM_CHEER_HEIGHT
	return _clampCamera(s, look, pos), look, SMOOTH_CHEER
end

--[[
	平滑跟随 + 落地后衰减震屏
	@param s Session - 当前演出
	@param t number - 时间轴秒数
	@param dt number - 帧间隔
	@return CFrame - 本帧镜头
]]
local function _stepCamera(s: Session, t: number, dt: number): CFrame
	local targetPos, targetLook, rate = _getCameraTarget(s, t)
	local alpha = 1 - math.exp(-rate * dt)
	s.CamPos = s.CamPos:Lerp(targetPos, alpha)
	s.CamLook = s.CamLook:Lerp(targetLook, alpha)
	local cf = CFrame.lookAt(s.CamPos, s.CamLook)
	if not s.Impacted then
		return cf
	end
	local since = math.max(t - IMPACT, 0) + (HITSTOP_SEC - math.max(s.Hitstop, 0))
	local amp = SHAKE_AMP * math.exp(-SHAKE_DECAY * since)
	if amp < 0.01 then
		return cf
	end
	local n = s.Real * SHAKE_FREQ
	local x = math.noise(n, 0.3) * amp
	local y = math.noise(0.7, n) * amp
	local roll = math.noise(n, n * 0.5 + 1.1) * amp * SHAKE_ROLL
	return cf * CFrame.new(x * 0.5, y * 0.5, 0) * CFrame.Angles(0, 0, roll)
end

--[[
	开始获胜演出（先 Stop 上一段）；桌子缺入座 / 对手位姿或对手模型时不播
	@param tableModel Model? - 本地玩家刚获胜的桌子（读 SEAT_ATTR / OppPivot / Pivot 属性与 Opponent 子模型）
	@param character Model? - 本地玩家角色（只读 HRP 位置做庆祝机位，并从落点射线中排除）
	@param onCelebrate (() -> ())? - 镜头转向玩家时回调一次（播庆祝动作、弹胜利面板）；Stop 早于该时刻则不回调
	@return boolean - 成功开播为 true；调用方为 false 时应直接走普通胜利表现
]]
function WinCinematic.Play(tableModel: Model?, character: Model?, onCelebrate: (() -> ())?): boolean
	WinCinematic.Stop()
	if not tableModel then
		return false
	end
	local seat = tableModel:GetAttribute(SEAT_ATTR)
	local oppCf = tableModel:GetAttribute(OPP_PIVOT_ATTR)
	local original = tableModel:FindFirstChild(OPPONENT_MODEL_NAME)
	if typeof(seat) ~= "CFrame" or typeof(oppCf) ~= "CFrame" or not original or not original:IsA("Model") then
		return false
	end
	local axis = (oppCf.Position - seat.Position) * FLAT
	if axis.Magnitude < 1e-3 then
		return false
	end
	axis = axis.Unit
	local side = UP:Cross(axis)
	local facing = seat.LookVector * FLAT
	facing = if facing.Magnitude > 1e-3 then facing.Unit else axis
	-- 玩家右手掰赢时拳头压向玩家左手侧；对手面朝玩家，背后与 facing 同向
	local slam = UP:Cross(facing)
	local back = -oppCf.LookVector * FLAT
	back = if back.Magnitude > 1e-3 then back.Unit else facing
	local pivot = tableModel:GetAttribute("Pivot")
	if typeof(pivot) ~= "Vector3" then
		pivot = tableModel:GetPivot().Position
	end

	local folder = Instance.new("Folder")
	folder.Name = FX_FOLDER_NAME
	folder.Parent = Workspace
	local clone = _cloneOpponent(original, folder)
	local root = clone and clone:FindFirstChild("HumanoidRootPart")
	if not clone or not root or not root:IsA("BasePart") then
		folder:Destroy()
		return false
	end
	root.Anchored = true
	root.CFrame = oppCf
	if not BattlePose.HandOffOpponent(clone) then
		Anim.HoldBattleOnModel(clone, 0)
	end
	Anim.PreloadOnModel(clone, ANIM_FLAIL)

	local exclude: { Instance } = { folder, tableModel }
	if character then
		table.insert(exclude, character)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.RespectCanCollide = true
	local ground, floorHit = _findLanding(oppCf.Position, slam, back, params)
	local endRot = CFrame.fromAxisAngle(UP:Cross(slam), FLIP_ANGLE) * oppCf.Rotation
	local focus = pivot + UP * HAND_HEIGHT

	local s: Session = {
		Character = character,
		Seat = seat,
		Folder = folder,
		Clone = clone,
		Root = root,
		Hidden = _hideOriginal(original),
		Hips = {},
		Rocks = {},
		StartCf = oppCf,
		EndCf = CFrame.new(ground - UP * BURY_DEPTH) * endRot,
		Ground = ground,
		FloorHit = floorHit,
		RayParams = params,
		Axis = axis,
		Side = side,
		Facing = facing,
		Slam = slam,
		Focus = focus,
		Clock = 0,
		Real = 0,
		Hitstop = 0,
		Flailing = false,
		Impacted = false,
		Celebrated = false,
		OnCelebrate = onCelebrate,
		CamPos = Workspace.CurrentCamera.CFrame.Position,
		CamLook = focus,
	}
	_session = s
	_burstSparks(s)
	return true
end

--[[
	推进一帧演出并给出镜头（由 SystemArmWrestle 对局镜头写口每帧调用并落地）
	@param dt number - 帧间隔（RenderStepped）
	@return CFrame? - 本帧镜头；未在演出中为 nil（调用方走普通对局镜头）
]]
function WinCinematic.Step(dt: number): CFrame?
	local s = _session
	if not s then
		return nil
	end
	s.Real += dt
	local advancing = s.Hitstop <= 0
	if advancing then
		s.Clock += dt
	else
		s.Hitstop -= dt
	end
	local t = s.Clock
	_stepOpponent(s, t)
	if advancing then
		_stepRocks(s, dt)
	end
	if not s.Celebrated and t >= CELEBRATE then
		s.Celebrated = true
		if s.OnCelebrate then
			task.spawn(s.OnCelebrate)
		end
	end
	return _stepCamera(s, t, dt)
end

--[[
	结束演出：销毁克隆体与全部特效、恢复原对手显示；未在演出中忽略
]]
function WinCinematic.Stop()
	local s = _session
	if not s then
		return
	end
	_session = nil
	for _, inst in ipairs(s.Hidden) do
		if not inst.Parent then
			continue
		end
		if inst:IsA("BillboardGui") then
			inst.Enabled = true
		else
			(inst :: any).LocalTransparencyModifier = 0
		end
	end
	s.Folder:Destroy()
end

--[[
	是否正在播放获胜演出
	@return boolean - 演出中（Play 成功后到 Stop 之前）为 true
]]
function WinCinematic.IsPlaying(): boolean
	return _session ~= nil
end

return WinCinematic
