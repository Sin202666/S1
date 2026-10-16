--[[
	Module: StandFx
	Description: 扳手腕限量展台客户端表现：展台上站着本地玩家的角色形象，双臂换成审判之臂外观
	Author: 程莘
	Created: 2026-10-14
	Last Modified: 2026-10-15

	功能：
	- BindWorld：找到 World.Common.LimitedStand.Display，本地隐藏场景原模型（LocalTransparencyModifier + 关碰撞），
	  克隆本地玩家角色（去脚本/工具/头顶 GUI，全部锚定，放大 SHOW_SCALE），脚踩台面站在 Display 正下方并缓慢自转
	- 双臂外观与服务端 SystemArmWrestle.Look.Apply 同走 ArmSkin.Apply：颜色取限量手臂（LIMITED_ARM_ID），
	  材质取本地玩家当前装备材质（Mat 属性；手臂配置本身无材质）；克隆体自带的外壳会被复用并重新上色
	- 角色重生 / 外观加载完成 / Mat 属性变化时重建

	约束：
	- 纯表现：只读角色外观、Mat 属性与 ArmWrestleConfig，不涉及购买结算
	- 展示模型挂在 Workspace 下而非展台内：展台部件会随 StreamingEnabled 流出，挂内部会被一并移除
	- StreamingEnabled：Display 部件流入时是新实例，DescendantAdded 时重新隐藏

	加载（仅 SystemArmWrestle 内部使用）：
		local StandFx = require(script.StandFx)
		StandFx.BindWorld(world)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local LocalPlayer = Utils.LocalPlayer
local ArmWrestleConfig = Utils.ArmWrestleConfig
local ArmSkin = Utils.ArmSkin
local Workspace = game:GetService("Workspace")

local StandFx = {}

local COMMON_NAME = "Common"
local STAND_NAME = "LimitedStand"
local DISPLAY_NAME = "Display"
local HOLDER_NAME = "Holder"
local SHOW_NAME = "LimitedStandShow"
local AURA_NAME = "ArmAura"
local MAT_ATTR = "Mat"
local LIMITED_ARM_ID = ArmWrestleConfig.LIMITED_ARM_ID
-- 放大后含头饰约 7 格高，头顶低于 Holder.Info 牌子下沿，不遮价格
local SHOW_SCALE = 1.3
local FLOOR_RAY_LENGTH = 30
local SPIN_SPEED = math.rad(30)

local _display: Model? = nil
local _show: Model? = nil
local _showBase: CFrame = CFrame.identity
local _spin = 0
local _spinConn: RBXScriptConnection? = nil
local _rebuildQueued = false

--[[
	本地隐藏 Display 下的单个部件（不改 Transparency，避免与场景原值混淆）
	@param inst Instance - Display 的后代；非 BasePart 忽略
]]
local function _hidePart(inst: Instance)
	if not inst:IsA("BasePart") then
		return
	end
	inst.LocalTransparencyModifier = 1
	inst.CanCollide = false
	inst.CanQuery = false
	inst.CanTouch = false
end

--[[
	克隆本地角色外观：去掉脚本 / 工具 / 头顶 GUI 等运行时附属，部件全部锚定且不参与物理
	@param character Model - LocalPlayer.Character
	@return Model? - 克隆体（未挂父级）；角色缺 Humanoid 时为 nil
]]
local function _cloneAvatar(character: Model): Model?
	local archivable = character.Archivable
	character.Archivable = true
	local clone = character:Clone()
	character.Archivable = archivable
	if not clone then
		return nil
	end
	for _, desc in ipairs(clone:GetDescendants()) do
		if
			desc:IsA("LuaSourceContainer")
			or desc:IsA("Tool")
			or desc:IsA("ForceField")
			or desc:IsA("LayerCollector")
			or desc:IsA("Sound")
			or desc.Name == AURA_NAME
		then
			desc:Destroy()
		end
	end
	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		clone:Destroy()
		return nil
	end
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	for _, desc in ipairs(clone:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.Anchored = true
			desc.CanCollide = false
			desc.CanQuery = false
			desc.CanTouch = false
		end
	end
	clone.Name = SHOW_NAME
	return clone
end

--[[
	把双臂外壳换成限量手臂颜色 + 当前装备材质（与服务端 Look.Apply 同走 ArmSkin.Apply）
	@param avatar Model - _cloneAvatar 的结果
]]
local function _applyArmLook(avatar: Model)
	ArmSkin.Apply(avatar, LIMITED_ARM_ID, LocalPlayer:GetAttribute(MAT_ATTR))
end

--[[
	展台台面上的站立基准：从 Display 的 Pivot 向下打射线，忽略 Holder（隐形交互块）与 Display
	@param display Model - LimitedStand.Display
	@return CFrame - 台面落点（无旋转）；未命中时退回 Display 的 Pivot
]]
local function _getFloor(display: Model): CFrame
	local origin = display:GetPivot().Position
	local exclude: { Instance } = { display }
	local holder = display.Parent and display.Parent:FindFirstChild(HOLDER_NAME)
	if holder then
		table.insert(exclude, holder)
	end
	if LocalPlayer.Character then
		table.insert(exclude, LocalPlayer.Character)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	local hit = Workspace:Raycast(origin, Vector3.new(0, -FLOOR_RAY_LENGTH, 0), params)
	return CFrame.new(if hit then hit.Position else origin)
end

--[[
	按当前角色外观与装备材质重建展示角色：放大后脚底贴台面
]]
local function _rebuildShow()
	if _show then
		_show:Destroy()
		_show = nil
	end
	local display = _display
	local character = LocalPlayer.Character
	if not display or not display.Parent or not character then
		return
	end
	local avatar = _cloneAvatar(character)
	if not avatar then
		return
	end
	_applyArmLook(avatar)
	avatar:ScaleTo(avatar:GetScale() * SHOW_SCALE)
	avatar:PivotTo(CFrame.identity)
	local boxCFrame, boxSize = avatar:GetBoundingBox()
	-- Pivot 相对脚底的高度，旋转时保持脚踩台面
	local footOffset = -(boxCFrame.Position.Y - boxSize.Y / 2)
	_showBase = _getFloor(display) * CFrame.new(0, footOffset, 0)
	avatar:PivotTo(_showBase * CFrame.Angles(0, _spin, 0))
	avatar.Parent = Workspace
	_show = avatar
end

--[[
	合并同帧多次触发（重生、外观加载、换材质可能接连到达）为一次重建
]]
local function _queueRebuild()
	if _rebuildQueued then
		return
	end
	_rebuildQueued = true
	task.defer(function()
		_rebuildQueued = false
		_rebuildShow()
	end)
end

--[[
	每帧自转展示角色
	@param dt number - 帧间隔
]]
local function _onHeartbeat(dt: number)
	local show = _show
	if not show then
		return
	end
	_spin = (_spin + SPIN_SPEED * dt) % (math.pi * 2)
	show:PivotTo(_showBase * CFrame.Angles(0, _spin, 0))
end

--[[
	登记展台 Display：隐藏原模型、监听流入部件、建展示角色
	@param display Model - LimitedStand.Display
]]
local function _registerDisplay(display: Model)
	if _display == display then
		return
	end
	_display = display
	for _, desc in ipairs(display:GetDescendants()) do
		_hidePart(desc)
	end
	display.DescendantAdded:Connect(_hidePart)
	display.Destroying:Once(function()
		if _display ~= display then
			return
		end
		_display = nil
		if _show then
			_show:Destroy()
			_show = nil
		end
	end)
	_queueRebuild()
	if not _spinConn then
		_spinConn = RunService.Heartbeat:Connect(_onHeartbeat)
	end
end

--[[
	新增节点若是 LimitedStand.Display 则登记（Display 可能晚于 World 到达）
	@param desc Instance - World 的新增后代
]]
local function _onDescendantAdded(desc: Instance)
	if desc.Name ~= DISPLAY_NAME or not desc:IsA("Model") then
		return
	end
	local stand = desc.Parent
	if stand and stand.Name == STAND_NAME then
		_registerDisplay(desc)
	end
end

--[[
	绑定世界中的限量展台（含 StreamingEnabled 流入），并监听角色外观与装备材质变化（SystemArmWrestle.Init 调一次）
	@param world Instance - Workspace.World
]]
function StandFx.BindWorld(world: Instance)
	local common = world:FindFirstChild(COMMON_NAME)
	local stand = common and common:FindFirstChild(STAND_NAME)
	local display = stand and stand:FindFirstChild(DISPLAY_NAME)
	if display and display:IsA("Model") then
		_registerDisplay(display)
	end
	world.DescendantAdded:Connect(_onDescendantAdded)
	LocalPlayer.CharacterAdded:Connect(_queueRebuild)
	LocalPlayer.CharacterAppearanceLoaded:Connect(_queueRebuild)
	LocalPlayer:GetAttributeChangedSignal(MAT_ATTR):Connect(_queueRebuild)
end

return StandFx
