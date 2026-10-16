--[[
	Module: BattlePose
	Description: 扳手腕对局姿势：以临时文件夹 Table_L1_1 两人摆位为起始姿势，按桌子进度 P 程序化做掰手腕动作
	Author: 程莘
	Created: 2026-10-16
	Last Modified: 2026-10-16

	功能：
	- Begin / Stop：接管本地玩家与该桌对手的 R6 六个关节（RootJoint / Neck / 左右肩 / 左右髋），PreSimulation 每帧写 Transform
	- 起始姿势（P = 0.5）与参考桌一致：肩关节 C1 用参考值（桌边对手模型已内置，玩家角色按臂长缩放套用），其余关节 Transform 归零
	- 右臂：两人右肩连线作公共转轴，两条右臂绕它转同一角度（始终并排贴合、肩不脱节）；
	  掰赢方把相握的手压向玩家左手侧（与 WinCinematic 甩飞方向一致），P 到 0 / 1 时输家手背贴近桌面
	- 躯干：绕各自右肩、沿同一转轴随进度侧倾；头只跟一半；双腿保持竖直、随髋平移
	- 较劲抖动：僵持中与进度变化快时叠加小幅噪声
	- 左手：手尖钉在入座位姿下的参考扶点（世界坐标，Begin 时算定），躯干倾斜时由肩关节补偿，整局不动
	- HandOffOpponent：获胜演出把对手换成本地克隆体继续定格输姿，起飞前传 nil 交还给动画
	- 显示进度对服务端属性 P 做指数平滑，只读不写

	参考：
	- Workspace["临时文件夹"].Table_L1_1（「玩家的位置」+ Opponent 已摆位姿）

	约束：
	- 纯本地表现；只读桌子属性 P / R6Seat / OppPivot，不写 HRP / 存档 / 结算
	- 接管期间本模块是两人上述关节的唯一写入方：调用方须同时 Anim.SetPoseOwner(tableModel) 让 Anim 停播该桌拉锯片，Stop 后再交还
	- 仅支持 R6；缺关节的一方不接管

	加载（仅 SystemArmWrestle 内部）：
		local BattlePose = require(script.BattlePose)
		BattlePose.Begin(tableModel, LocalPlayer.Character)
		Anim.SetPoseOwner(tableModel)
		-- 获胜演出：克隆体接手输姿，起飞时交还
		BattlePose.HandOffOpponent(clone)
		BattlePose.HandOffOpponent(nil)
		-- 结算 / 交还
		BattlePose.Stop()
		Anim.SetPoseOwner(nil)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local ArmWrestleConfig = Utils.ArmWrestleConfig

local BattlePose = {}

local SEAT_ATTR = ArmWrestleConfig.SEAT_ATTR
local OPP_PIVOT_ATTR = "OppPivot"
local OPPONENT_MODEL_NAME = ArmWrestleConfig.OPPONENT_MODEL_NAME
local HIP_NAMES = { "Right Hip", "Left Hip" }
local UP = Vector3.yAxis
local FLAT = Vector3.new(1, 0, 1)

-- 参考桌「玩家的位置」肩关节 C1（标准 R6 臂长 2）；玩家角色按自身臂长缩放平移分量
local REF_ARM_LENGTH = 2
local REF_RIGHT_C1 = CFrame.new(
	-0.5,
	0.9753023386,
	-0.5883182287,
	0,
	0,
	1,
	-0.8007820249,
	-0.5989558697,
	0,
	0.5989558697,
	-0.8007820249,
	0
)
local REF_LEFT_C1 = CFrame.new(
	0.5,
	0.703137517,
	-0.0869471729,
	0,
	0,
	-1,
	0.9707094431,
	0.2402565777,
	0,
	0.2402565777,
	-0.9707094431,
	0
)
-- P 到 0 / 1 时右臂绕肩连线转过的角度：并排的输家手臂此时贴到桌面
local MAX_ARM_DEG = 80
local MAX_LEAN_DEG = 6
-- 头随躯干侧倾的比例，其余部分回正保持看向握手处
local HEAD_FOLLOW = 0.5
local P_SMOOTH = 10
-- 抖动强度：僵持基础值 + 每秒进度变化 × 增益，封顶后再平滑
local SHAKE_BASE = 1
local SHAKE_SPEED_GAIN = 1.5
local SHAKE_MAX = 2.5
local SHAKE_SMOOTH = 6
local SHAKE_ARM_DEG = 1.5
local SHAKE_LEAN_DEG = 0.8
local SHAKE_FREQ = 7
-- 服务端判出胜负时 P 精确为 0 / 1，此后不再算僵持
local STRUGGLE_EPSILON = 0.001

type Rig = {
	Model: Model,
	Root: BasePart,
	RootJoint: Motor6D,
	RightShoulder: Motor6D,
	LeftShoulder: Motor6D,
	Neck: Motor6D?,
	Hips: { Motor6D },
	Saved: { [Motor6D]: { C0: CFrame, C1: CFrame } },
	LeftTip: Vector3,
	LeftRest: Vector3,
}

type Session = {
	Table: Model,
	Character: Model?,
	Player: Rig?,
	Opponent: Rig?,
	OpponentHandedOff: boolean,
	P: number,
	Shake: number,
	Clock: number,
}

-- 本地角色的 Animator 每帧动画步进都会重置 Transform（即使没有在播轨道），必须在其后的 PreSimulation 写入
local _stepConn: RBXScriptConnection? = nil
local _session: Session? = nil

--[[
	取 Motor6D 子节点
	@param parent Instance - 关节父零件
	@param name string - 关节名
	@return Motor6D? - 关节；不存在或类型不符时 nil
]]
local function _findMotor(parent: Instance, name: string): Motor6D?
	local motor = parent:FindFirstChild(name)
	return if motor and motor:IsA("Motor6D") then motor else nil
end

--[[
	只缩放 CFrame 平移分量（体型缩放后的关节偏移）
	@param cf CFrame - 原 CFrame
	@param scale number - 缩放倍数
	@return CFrame - 平移缩放、旋转不变
]]
local function _scaleTranslation(cf: CFrame, scale: number): CFrame
	return CFrame.new(cf.Position * scale) * cf.Rotation
end

--[[
	绕世界点旋转
	@param cf CFrame - 被旋转的世界 CFrame
	@param point Vector3 - 旋转中心
	@param rot CFrame - 纯旋转
	@return CFrame - 旋转后的世界 CFrame
]]
local function _rotateAbout(cf: CFrame, point: Vector3, rot: CFrame): CFrame
	return CFrame.new(point) * rot * CFrame.new(-point) * cf
end

--[[
	由 Part0 / 期望 Part1 世界位姿反解关节 Transform（Part1 = Part0 * C0 * Transform * C1⁻¹）
	@param motor Motor6D - 关节
	@param part0Cf CFrame - Part0 世界位姿
	@param part1Cf CFrame - Part1 期望世界位姿
	@return CFrame - Transform
]]
local function _jointTransform(motor: Motor6D, part0Cf: CFrame, part1Cf: CFrame): CFrame
	return motor.C0:Inverse() * part0Cf:Inverse() * part1Cf * motor.C1
end

--[[
	建立一方 R6 接管状态：记原始 C0/C1，按需套参考 C1，算定左手扶点
	@param model Model? - 本地角色 / 桌边对手 / 获胜演出克隆体
	@param useRefC1 boolean - true 时肩关节 C1 改为参考值（玩家角色）；对手模型已内置参考 C1 传 false
	@param baseCf any - 入座 HRP 位姿（桌子属性 R6Seat / OppPivot）；非 CFrame 时用当前 HRP
	@return Rig? - 接管状态；缺零件或关节时 nil
]]
local function _buildRig(model: Model?, useRefC1: boolean, baseCf: any): Rig?
	if not model or not model.Parent then
		return nil
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	local torso = model:FindFirstChild("Torso")
	local leftArm = model:FindFirstChild("Left Arm")
	if not root or not root:IsA("BasePart") or not torso or not torso:IsA("BasePart") then
		return nil
	end
	if not leftArm or not leftArm:IsA("BasePart") then
		return nil
	end
	local rootJoint = _findMotor(root, "RootJoint")
	local rightShoulder = _findMotor(torso, "Right Shoulder")
	local leftShoulder = _findMotor(torso, "Left Shoulder")
	if not rootJoint or not rightShoulder or not leftShoulder then
		return nil
	end
	local neck = _findMotor(torso, "Neck")
	local hips: { Motor6D } = {}
	for _, name in ipairs(HIP_NAMES) do
		local hip = _findMotor(torso, name)
		if hip then
			table.insert(hips, hip)
		end
	end

	local saved: { [Motor6D]: { C0: CFrame, C1: CFrame } } = {}
	local motors: { Motor6D } = { rootJoint, rightShoulder, leftShoulder }
	if neck then
		table.insert(motors, neck)
	end
	for _, hip in ipairs(hips) do
		table.insert(motors, hip)
	end
	for _, motor in ipairs(motors) do
		saved[motor] = { C0 = motor.C0, C1 = motor.C1 }
	end

	if useRefC1 then
		local scale = leftArm.Size.Y / REF_ARM_LENGTH
		rightShoulder.C1 = _scaleTranslation(REF_RIGHT_C1, scale)
		leftShoulder.C1 = _scaleTranslation(REF_LEFT_C1, scale)
	end

	local leftTip = Vector3.new(0, -leftArm.Size.Y * 0.5, 0)
	local base = if typeof(baseCf) == "CFrame" then baseCf else root.CFrame
	local torsoBase = base * rootJoint.C0 * rootJoint.C1:Inverse()
	local leftRest = (torsoBase * leftShoulder.C0 * leftShoulder.C1:Inverse()):PointToWorldSpace(leftTip)

	return {
		Model = model,
		Root = root,
		RootJoint = rootJoint,
		RightShoulder = rightShoulder,
		LeftShoulder = leftShoulder,
		Neck = neck,
		Hips = hips,
		Saved = saved,
		LeftTip = leftTip,
		LeftRest = leftRest,
	}
end

--[[
	接管状态是否仍有效（角色重生 / 克隆体销毁后失效）
	@param rig Rig - 接管状态
	@return boolean - 关键零件与关节仍在场景中为 true
]]
local function _isRigAlive(rig: Rig): boolean
	return rig.Model.Parent ~= nil
		and rig.Root.Parent ~= nil
		and rig.RootJoint.Parent ~= nil
		and rig.RightShoulder.Parent ~= nil
		and rig.LeftShoulder.Parent ~= nil
end

--[[
	还原接管过的关节 C0/C1 并清 Transform
	@param rig Rig? - 接管状态
]]
local function _restoreRig(rig: Rig?)
	if not rig then
		return
	end
	for motor, orig in pairs(rig.Saved) do
		if motor.Parent then
			motor.C0 = orig.C0
			motor.C1 = orig.C1
			motor.Transform = CFrame.identity
		end
	end
end

--[[
	未倾斜时的躯干世界位姿（HRP + RootJoint 静态偏移）
	@param rig Rig - 接管状态
	@return CFrame - 躯干世界位姿
]]
local function _getTorsoRef(rig: Rig): CFrame
	local rootJoint = rig.RootJoint
	return rig.Root.CFrame * rootJoint.C0 * rootJoint.C1:Inverse()
end

--[[
	左手扶桌：在参考臂姿上做最小转动让手尖落回扶点，残差用平移补齐（手尖绝对不动）
	@param rig Rig - 接管状态
	@param torso CFrame - 本帧躯干世界位姿（已含侧倾）
]]
local function _applyLeft(rig: Rig, torso: CFrame)
	local shoulder = rig.LeftShoulder
	local armRef = torso * shoulder.C0 * shoulder.C1:Inverse()
	local pivot = (torso * shoulder.C0).Position
	local from = armRef:PointToWorldSpace(rig.LeftTip) - pivot
	local to = rig.LeftRest - pivot
	local arm = armRef
	if from.Magnitude > 1e-3 and to.Magnitude > 1e-3 then
		local a = from.Unit
		local b = to.Unit
		local cross = a:Cross(b)
		if cross.Magnitude > 1e-5 then
			local angle = math.acos(math.clamp(a:Dot(b), -1, 1))
			arm = _rotateAbout(armRef, pivot, CFrame.fromAxisAngle(cross.Unit, angle))
		end
	end
	arm += rig.LeftRest - arm:PointToWorldSpace(rig.LeftTip)
	shoulder.Transform = _jointTransform(shoulder, torso, arm)
end

--[[
	一方整身姿势：躯干绕右肩侧倾 → 右臂绕公共轴转 → 腿竖直 → 头半跟随 → 左手扶桌
	@param rig Rig - 接管状态
	@param torsoRef CFrame - 未倾斜躯干世界位姿
	@param axis Vector3 - 公共转轴（单位向量，正角度把上方压向玩家左手侧）
	@param armAngle number - 右臂转角（弧度）
	@param lean number - 躯干侧倾角（弧度）
]]
local function _applyRig(rig: Rig, torsoRef: CFrame, axis: Vector3, armAngle: number, lean: number)
	local rightShoulder = rig.RightShoulder
	local pivot = (torsoRef * rightShoulder.C0).Position
	local torso = _rotateAbout(torsoRef, pivot, CFrame.fromAxisAngle(axis, lean))
	rig.RootJoint.Transform = _jointTransform(rig.RootJoint, rig.Root.CFrame, torso)

	local armRef = torsoRef * rightShoulder.C0 * rightShoulder.C1:Inverse()
	local arm = _rotateAbout(armRef, pivot, CFrame.fromAxisAngle(axis, armAngle))
	rightShoulder.Transform = _jointTransform(rightShoulder, torso, arm)

	for _, hip in ipairs(rig.Hips) do
		local legRef = torsoRef * hip.C0 * hip.C1:Inverse()
		local shift = (torso * hip.C0).Position - (torsoRef * hip.C0).Position
		hip.Transform = _jointTransform(hip, torso, legRef + shift)
	end

	local neck = rig.Neck
	if neck then
		local headRef = torsoRef * neck.C0 * neck.C1:Inverse()
		local from = (torsoRef * neck.C0).Position
		local to = (torso * neck.C0).Position
		local head = _rotateAbout(headRef, from, CFrame.fromAxisAngle(axis, lean * HEAD_FOLLOW)) + (to - from)
		neck.Transform = _jointTransform(neck, torso, head)
	end

	_applyLeft(rig, torso)
end

--[[
	玩家左手侧水平方向（掰赢时相握的手压过去的方向）
	@param tableModel Model - 桌子
	@return Vector3 - 水平单位向量
]]
local function _getSlam(tableModel: Model): Vector3
	local seat = tableModel:GetAttribute(SEAT_ATTR)
	local facing = if typeof(seat) == "CFrame" then seat.LookVector * FLAT else Vector3.zero
	if facing.Magnitude < 1e-3 then
		local opp = tableModel:GetAttribute(OPP_PIVOT_ATTR)
		if typeof(seat) == "CFrame" and typeof(opp) == "CFrame" then
			facing = (opp.Position - seat.Position) * FLAT
		end
	end
	if facing.Magnitude < 1e-3 then
		facing = -Vector3.zAxis
	end
	return UP:Cross(facing.Unit)
end

--[[
	公共转轴：两人右肩连线（只有一方时退化为水平对局轴），并定向为正角度压向玩家左手侧
	@param tableModel Model - 桌子
	@param playerShoulder Vector3? - 玩家右肩世界点
	@param oppShoulder Vector3? - 对手右肩世界点
	@return Vector3 - 单位转轴
]]
local function _getAxis(tableModel: Model, playerShoulder: Vector3?, oppShoulder: Vector3?): Vector3
	local slam = _getSlam(tableModel)
	local axis = slam:Cross(UP)
	if playerShoulder and oppShoulder then
		local line = oppShoulder - playerShoulder
		if line.Magnitude > 1e-3 then
			axis = line.Unit
		end
	end
	if axis:Cross(UP):Dot(slam) < 0 then
		axis = -axis
	end
	return axis
end

--[[
	补建失效 / 晚到的接管状态（角色重生、对手复制晚到）
	@param s Session - 会话
]]
local function _resolveRigs(s: Session)
	local player = s.Player
	if not player or not _isRigAlive(player) then
		s.Player = _buildRig(s.Character, true, s.Table:GetAttribute(SEAT_ATTR))
	end
	local opponent = s.Opponent
	if opponent and not _isRigAlive(opponent) then
		s.Opponent = nil
	end
	if not s.Opponent and not s.OpponentHandedOff then
		local model = s.Table:FindFirstChild(OPPONENT_MODEL_NAME)
		s.Opponent = _buildRig(
			if model and model:IsA("Model") then model else nil,
			false,
			s.Table:GetAttribute(OPP_PIVOT_ATTR)
		)
	end
end

--[[
	一帧：平滑进度 → 抖动强度 → 双方姿势
	@param s Session - 会话
	@param dt number - 帧间隔
]]
local function _step(s: Session, dt: number)
	local tableModel = s.Table
	if not tableModel.Parent then
		BattlePose.Stop()
		return
	end
	_resolveRigs(s)

	local target = tableModel:GetAttribute("P")
	if typeof(target) ~= "number" then
		target = 0.5
	end
	local prev = s.P
	s.P += (target - s.P) * (1 - math.exp(-P_SMOOTH * dt))
	local speed = math.abs(s.P - prev) / math.max(dt, 1e-3)
	local struggling = target > STRUGGLE_EPSILON and target < 1 - STRUGGLE_EPSILON
	local shakeTarget = math.min((if struggling then SHAKE_BASE else 0) + speed * SHAKE_SPEED_GAIN, SHAKE_MAX)
	s.Shake += (shakeTarget - s.Shake) * (1 - math.exp(-SHAKE_SMOOTH * dt))
	s.Clock += dt

	local player = s.Player
	local opponent = s.Opponent
	local playerTorso = if player then _getTorsoRef(player) else nil
	local oppTorso = if opponent then _getTorsoRef(opponent) else nil
	local playerShoulder = if player and playerTorso then (playerTorso * player.RightShoulder.C0).Position else nil
	local oppShoulder = if opponent and oppTorso then (oppTorso * opponent.RightShoulder.C0).Position else nil
	local axis = _getAxis(tableModel, playerShoulder, oppShoulder)

	local drive = (s.P - 0.5) * 2
	local n = s.Clock * SHAKE_FREQ
	local armAngle = math.rad(drive * MAX_ARM_DEG + math.noise(n, 0.37) * s.Shake * SHAKE_ARM_DEG)
	local lean = math.rad(drive * MAX_LEAN_DEG + math.noise(0.71, n) * s.Shake * SHAKE_LEAN_DEG)
	if player and playerTorso then
		_applyRig(player, playerTorso, axis, armAngle, lean)
	end
	if opponent and oppTorso then
		_applyRig(opponent, oppTorso, axis, armAngle, lean)
	end
end

--[[
	对局开始：接管本地玩家与该桌对手姿势（先 Stop 上一局）
	@param tableModel Model? - 桌子；nil 时只 Stop
	@param character Model? - 本地玩家角色；晚到 / 重生时每帧补建
]]
function BattlePose.Begin(tableModel: Model?, character: Model?)
	BattlePose.Stop()
	if not tableModel then
		return
	end
	local p = tableModel:GetAttribute("P")
	local s: Session = {
		Table = tableModel,
		Character = character,
		Player = nil,
		Opponent = nil,
		OpponentHandedOff = false,
		P = if typeof(p) == "number" then p else 0.5,
		Shake = 0,
		Clock = 0,
	}
	_session = s
	_resolveRigs(s)
	_stepConn = RunService.PreSimulation:Connect(function(dt: number)
		if _session == s then
			_step(s, dt)
		end
	end)
end

--[[
	获胜演出换对手：还原当前对手关节，改为接管给定模型（定格当前输姿）；nil 表示不再接管任何对手
	@param model Model? - 获胜演出克隆体（HRP 须已摆到 OppPivot）；nil 时交还给动画（克隆体起飞前调用）
	@return boolean - 已接管给定模型为 true；未在对局中 / 传 nil / 模型缺 R6 关节为 false
]]
function BattlePose.HandOffOpponent(model: Model?): boolean
	local s = _session
	if not s then
		return false
	end
	_restoreRig(s.Opponent)
	s.Opponent = nil
	s.OpponentHandedOff = true
	if model then
		s.Opponent = _buildRig(model, false, s.Table:GetAttribute(OPP_PIVOT_ATTR))
	end
	return s.Opponent ~= nil
end

--[[
	结束接管：断开每帧写入并还原双方关节
]]
function BattlePose.Stop()
	if _stepConn then
		_stepConn:Disconnect()
		_stepConn = nil
	end
	local s = _session
	if not s then
		return
	end
	_session = nil
	_restoreRig(s.Player)
	_restoreRig(s.Opponent)
end

--[[
	是否正在接管对局姿势
	@return boolean - true 表示接管中
]]
function BattlePose.IsActive(): boolean
	return _session ~= nil
end

return BattlePose
