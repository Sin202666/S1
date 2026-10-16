--[[
	Module: ArmSkin
	Description: 扳手腕手臂外壳：隐藏角色原双臂，复制其网格做成我们控制的左右手模型，统一上手臂颜色/材质/光效
	Author: 程莘
	Created: 2026-10-15
	Last Modified: 2026-10-16

	功能：
	- Apply：在角色下建 ArmSkinLeft / ArmSkinRight 两个 Model，按原手臂分段（R15 上臂/前臂/手，R6 整臂）复制部件，
	  用 Weld 焊到对应原部件上跟随动画弯曲；原手臂设 Transparency = 1，经典 Shirt 的袖子贴图随原手臂一起隐藏，躯干上衣保留
	- R6 原手臂的圆润边来自 CharacterMesh / 包体网格，对透明原件不可见；外壳为独立 Part，须自带 SpecialMesh
	  （优先 HumanoidDescription 左右臂包体 Id，否则 rbxasset://fonts/*arm.mesh）；R15 MeshPart 自带 MeshId，只清子物体
	- 外壳部件 Massless、不碰撞、不参与射线/触碰，不影响角色物理与命中判定；不写角色 CFrame / 速度
	- 幂等：重复调用复用已有外壳只重新上色；原手臂部件被替换（外观加载）后对应外壳段自动重建；原部件尺寸变化时外壳同步
	- 光效分 4 档：手臂档（ARM_AURA）与材质稀有度档（稀有 1 / 史诗 2 / 传说 3 / 神话+ 4）取高者，颜色跟随取胜的一方
	  （材质色发灰时改用稀有度色）
	  1 档：整臂环绕光点；2 档：光点加密；3 档：再加整臂火焰 + 半透明 ForceField 能量壳；4 档：全部加强；不挂灯光
	  粒子贴图为白底软光（art/vfx/aura，由 Color 染色）：光点是四芒星，火焰沿飞出方向；LightInfluence = 0 保证暗处也亮；全部特效实例名为 ArmAura，重刷时整体替换
	- IsArmPartName：判断名字是否为原手臂部件，供调用方监听部件替换

	与相关模块：
	- 服务端 SystemArmWrestle.Look.Apply：按档案 Arm / Mat 调用，外壳随角色复制给所有客户端
	- 客户端 SystemArmWrestle.StandFx：展台克隆角色后调用，换成限量手臂颜色
	- 分层衣服（夹克等）的袖子仍会盖住外壳，由 Look 负责移除；本模块不删衣服

	约束：
	- 不写存档、不绑 Remote、不做结算；只改外观
	- 原手臂透明度由本模块独占写入；VisibleMgr 淡入淡出会以首次记录的透明度（1）恢复，Apply 须早于任何淡出

	加载：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local ArmSkin = Utils.ArmSkin
		ArmSkin.Apply(character, data.Arm, data.Mat)
		ArmSkin.Apply(standClone, ArmWrestleConfig.LIMITED_ARM_ID, player:GetAttribute("Mat"))
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ArmWrestleConfig = Utils.ArmWrestleConfig

local ArmSkin = {}

local SKIN_PREFIX = "ArmSkin"
local WELD_NAME = "ArmSkinWeld"
local AURA_NAME = "ArmAura"
-- 白 RGB + 透明边，Color 染色后仍是软光；源文件 art/vfx/aura/aura-spark.png、aura-flame.png
local SPARK_TEXTURE = "rbxassetid://82402156329894"
local FLAME_TEXTURE = "rbxassetid://128744522232813"
local WHITE = Color3.new(1, 1, 1)
-- 手臂 Id → 光效档位；Color 覆盖发灰 / 过暗的手臂色（钢铁之臂偏灰、审判之臂近黑，粒子发光看不出）
local ARM_AURA: { [number]: { Tier: number, Color: Color3? } } = {
	[4] = { Tier = 1, Color = Color3.fromRGB(170, 210, 255) },
	[5] = { Tier = 1 },
	[6] = { Tier = 2 },
	[7] = { Tier = 2 },
	[8] = { Tier = 2 },
	[9] = { Tier = 3 },
	[10] = { Tier = 3 },
	[11] = { Tier = 4 },
	[12] = { Tier = 4, Color = Color3.fromRGB(220, 40, 70) },
}
-- 稀有度 Rank 减去该值即材质光效档（Rare=3 → 1 档）
local RARITY_TIER_OFFSET = 2
local MAX_TIER = 4
-- 材质色饱和度低于此值（岩石 / 金属等灰色）时改用稀有度色；不做混色，互补色混合会发灰
local MIN_AURA_SATURATION = 0.35
-- 能量外壳相对外壳段的放大倍数
local SHELL_SCALE = 1.1
-- 每档参数：Spark* 每部件光点；Flame* 每部件火焰（Rate 0 不生成）；Shell 能量外壳透明度（nil 不生成）
local TIER_STYLE: { [number]: { [string]: number } } = {
	[1] = { SparkRate = 4, SparkSize = 0.3, FlameRate = 0, FlameSize = 0 },
	[2] = { SparkRate = 8, SparkSize = 0.35, FlameRate = 0, FlameSize = 0 },
	[3] = { SparkRate = 12, SparkSize = 0.4, FlameRate = 12, FlameSize = 1.05, Shell = 0.65 },
	[4] = { SparkRate = 18, SparkSize = 0.5, FlameRate = 22, FlameSize = 1.45, Shell = 0.5 },
}
local HIDDEN = 1
local VISIBLE = 0
-- 每侧按 R15 / R6 部件名列出；角色上只会存在其中一套
local SIDES = {
	Left = { "LeftUpperArm", "LeftLowerArm", "LeftHand", "Left Arm" },
	Right = { "RightUpperArm", "RightLowerArm", "RightHand", "Right Arm" },
}
local ARM_PART_NAMES: { [string]: boolean } = {}
for _, names in pairs(SIDES) do
	for _, name in ipairs(names) do
		ARM_PART_NAMES[name] = true
	end
end
-- R6 整臂：无包体 Id 时用引擎经典肢体外形（圆润边）；R15 分段不走这里
local CLASSIC_ARM_MESH: { [string]: string } = {
	["Left Arm"] = "rbxasset://fonts/leftarm.mesh",
	["Right Arm"] = "rbxasset://fonts/rightarm.mesh",
}
local DESC_ARM_FIELD: { [string]: string } = {
	["Left Arm"] = "LeftArm",
	["Right Arm"] = "RightArm",
}

--[[
	取或建某侧外壳 Model
	@param char Model - 角色或其克隆体
	@param side string - "Left" | "Right"
	@return Model - 角色下名为 ArmSkin<side> 的 Model
]]
local function _getSkinModel(char: Model, side: string): Model
	local name = SKIN_PREFIX .. side
	local existing = char:FindFirstChild(name)
	if existing and existing:IsA("Model") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = char
	return model
end

--[[
	判断外壳段是否仍焊在当前原部件上
	@param skinPart Instance? - 外壳 Model 下同名子物体
	@param src BasePart - 当前原手臂部件
	@return boolean - 是 BasePart 且 Weld.Part0 指向 src 时为 true
]]
local function _isSkinValid(skinPart: Instance?, src: BasePart): boolean
	if not skinPart or not skinPart:IsA("BasePart") then
		return false
	end
	local weld = skinPart:FindFirstChild(WELD_NAME)
	return weld ~= nil and weld:IsA("Weld") and weld.Part0 == src
end

--[[
	解析 R6 整臂外壳应使用的网格 Id（包体优先，否则经典圆润肢体外形）
	@param char Model - 角色或其克隆体
	@param partName string - "Left Arm" | "Right Arm"
	@return string? - SpecialMesh.MeshId；非 R6 整臂名为 nil
]]
local function _resolveR6ArmMeshId(char: Model, partName: string): string?
	local classic = CLASSIC_ARM_MESH[partName]
	if not classic then
		return nil
	end
	local field = DESC_ARM_FIELD[partName]
	local hum = char:FindFirstChildOfClass("Humanoid")
	if field and hum then
		local ok, desc = pcall(function()
			return hum:GetAppliedDescription()
		end)
		if ok and desc then
			local assetId = (desc :: any)[field]
			if type(assetId) == "number" and assetId > 0 then
				return "rbxassetid://" .. assetId
			end
		end
	end
	return classic
end

--[[
	保证外壳段带有可见网格：保留源上的 DataModelMesh；R6 整臂无网格时补经典/包体 SpecialMesh
	@param part BasePart - 外壳段
	@param char Model - 角色或其克隆体
	@param partName string - 与原手臂同名
	@param src BasePart? - 原手臂；有则从其复制已有网格
	@return nil
]]
local function _ensureLimbMesh(part: BasePart, char: Model, partName: string, src: BasePart?)
	if part:FindFirstChildWhichIsA("DataModelMesh") then
		return
	end
	if src then
		for _, child in ipairs(src:GetChildren()) do
			if child:IsA("DataModelMesh") then
				child:Clone().Parent = part
			end
		end
		if part:FindFirstChildWhichIsA("DataModelMesh") then
			return
		end
	end
	-- MeshPart 几何在属性上，不依赖子网格；普通 Part（R6）需 SpecialMesh 才有圆润边
	if part:IsA("MeshPart") then
		return
	end
	local meshId = _resolveR6ArmMeshId(char, partName)
	if not meshId then
		return
	end
	local mesh = Instance.new("SpecialMesh")
	mesh.Name = "ArmSkinMesh"
	mesh.MeshType = Enum.MeshType.FileMesh
	mesh.MeshId = meshId
	mesh.Parent = part
end

--[[
	复制原手臂部件为外壳段并焊到原部件上；原部件尺寸变化时同步外壳尺寸
	@param src BasePart - 原手臂部件
	@param parent Model - 外壳 Model（父级为角色）
	@return BasePart - 新外壳段
]]
local function _buildSkinPart(src: BasePart, parent: Model): BasePart
	local archivable = src.Archivable
	src.Archivable = true
	local part = src:Clone() :: BasePart
	src.Archivable = archivable
	part:ClearAllChildren()
	part.Name = src.Name
	part.Transparency = VISIBLE
	part.Anchored = false
	part.Massless = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	if part:IsA("MeshPart") then
		part.TextureID = ""
	end
	local char = parent.Parent
	if char and char:IsA("Model") then
		_ensureLimbMesh(part, char, src.Name, src)
	end
	part.CFrame = src.CFrame
	local weld = Instance.new("Weld")
	weld.Name = WELD_NAME
	weld.Part0 = src
	weld.Part1 = part
	weld.C0 = CFrame.identity
	weld.C1 = CFrame.identity
	weld.Parent = part
	part.Parent = parent
	src:GetPropertyChangedSignal("Size"):Connect(function()
		if part.Parent then
			part.Size = src.Size
		end
	end)
	return part
end

--[[
	同步一侧外壳：缺失或失效的段重建，原部件已不存在的段移除，原手臂隐藏
	@param char Model - 角色或其克隆体
	@param side string - "Left" | "Right"
	@return { BasePart } - 该侧当前全部外壳段
]]
local function _syncSide(char: Model, side: string): { BasePart }
	local model = _getSkinModel(char, side)
	local parts: { BasePart } = {}
	local alive: { [string]: boolean } = {}
	for _, name in ipairs(SIDES[side]) do
		local src = char:FindFirstChild(name)
		if not src or not src:IsA("BasePart") then
			continue
		end
		alive[name] = true
		local skinPart = model:FindFirstChild(name)
		if not _isSkinValid(skinPart, src) then
			if skinPart then
				skinPart:Destroy()
			end
			skinPart = _buildSkinPart(src, model)
		else
			_ensureLimbMesh(skinPart :: BasePart, char, name, src)
		end
		src.Transparency = HIDDEN
		local legacyAura = src:FindFirstChild(AURA_NAME)
		if legacyAura then
			legacyAura:Destroy()
		end
		table.insert(parts, skinPart :: BasePart)
	end
	for _, child in ipairs(model:GetChildren()) do
		if not alive[child.Name] then
			child:Destroy()
		end
	end
	return parts
end

--[[
	计算光效档位与颜色：手臂档与材质稀有度档取高者，平手时用材质色
	@param armId number - 已校验的手臂 Id
	@param armColor Color3 - 手臂配置色
	@param mat table? - 材质配置（GetMaterial 结果）；nil 表示无材质
	@return number - 档位 0..MAX_TIER（0 无光效）
	@return Color3 - 光效主色
]]
local function _resolveAura(armId: number, armColor: Color3, mat: { [string]: any }?): (number, Color3)
	local armAura = ARM_AURA[armId]
	local armTier = if armAura then armAura.Tier else 0
	local rarity = mat and ArmWrestleConfig.GetRarity(mat.Xyd)
	local matTier = if rarity then math.clamp(rarity.Rank - RARITY_TIER_OFFSET, 0, MAX_TIER) else 0
	if mat and rarity and matTier > 0 and matTier >= armTier then
		local matColor = mat.Color :: Color3
		local _, saturation = matColor:ToHSV()
		return matTier, if saturation < MIN_AURA_SATURATION then rarity.Color else matColor
	end
	return armTier, if armAura and armAura.Color then armAura.Color else armColor
end

--[[
	在外壳段上挂环绕整段的闪烁光点
	@param part BasePart - 外壳段；粒子在部件体积内生成，靠高初速 + 阻尼冲出表面停在手臂周围
	@param style table - TIER_STYLE 某档
	@param color Color3 - 光效主色
	@return nil
]]
local function _addSpark(part: BasePart, style: { [string]: number }, color: Color3)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = AURA_NAME
	emitter.Texture = SPARK_TEXTURE
	emitter.Color = ColorSequence.new(color:Lerp(WHITE, 0.15), color)
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, style.SparkSize),
		NumberSequenceKeypoint.new(0.3, style.SparkSize * 1.2),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(0.7, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.6, 1.1)
	emitter.Rate = style.SparkRate
	emitter.Speed = NumberRange.new(3, 5)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, 0.8, 0)
	emitter.Drag = 5
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-90, 90)
	emitter.Parent = part
end

--[[
	在外壳段上挂整段向上飘的火焰
	@param part BasePart - 外壳段
	@param style table - TIER_STYLE 某档；FlameRate > 0 时才调用
	@param color Color3 - 光效主色
	@return nil
]]
local function _addFlame(part: BasePart, style: { [string]: number }, color: Color3)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = AURA_NAME
	emitter.Texture = FLAME_TEXTURE
	emitter.Color = ColorSequence.new(color:Lerp(WHITE, 0.1), color)
	emitter.LightEmission = 0.8
	emitter.LightInfluence = 0
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, style.FlameSize),
		NumberSequenceKeypoint.new(1, style.FlameSize * 0.25),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.15, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.4, 0.7)
	emitter.Rate = style.FlameRate
	emitter.Speed = NumberRange.new(2.5, 3.5)
	emitter.Drag = 6
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, 4, 0)
	-- 贴图尖端朝上，沿飞出方向立起来，避免整圈乱转变成光斑
	emitter.Orientation = Enum.ParticleOrientation.VelocityParallel
	emitter.Rotation = NumberRange.new(-12, 12)
	emitter.RotSpeed = NumberRange.new(-20, 20)
	emitter.ZOffset = 0.3
	emitter.Parent = part
end

--[[
	给外壳段套一层略大的半透明 ForceField 能量壳（复制同一网格，R15 也贴合手臂形状），焊在外壳段上
	@param part BasePart - 外壳段；须在挂粒子之前调用，否则复制体会带上它们
	@param style table - TIER_STYLE 某档；Shell 非 nil 时才调用
	@param color Color3 - 光效主色
	@return nil
]]
local function _addShell(part: BasePart, style: { [string]: number }, color: Color3)
	local shell = part:Clone()
	-- 保留肢体外形网格，只清 Weld / 粒子等；否则能量壳又变回尖角方块
	for _, child in ipairs(shell:GetChildren()) do
		if not child:IsA("DataModelMesh") then
			child:Destroy()
		end
	end
	shell.Name = AURA_NAME
	shell.Size = part.Size * SHELL_SCALE
	local mesh = shell:FindFirstChildWhichIsA("DataModelMesh")
	if mesh and mesh:IsA("SpecialMesh") then
		mesh.Scale = mesh.Scale * SHELL_SCALE
	end
	shell.Material = Enum.Material.ForceField
	shell.Color = color
	shell.Transparency = style.Shell
	shell.CastShadow = false
	shell.CFrame = part.CFrame
	local weld = Instance.new("Weld")
	weld.Part0 = part
	weld.Part1 = shell
	weld.Parent = shell
	shell.Parent = part
end

--[[
	清掉旧光效并按档位重挂
	@param parts { BasePart } - 外壳段
	@param tier number - 档位 0..MAX_TIER
	@param color Color3 - 光效主色
	@return nil
]]
local function _applyAura(parts: { BasePart }, tier: number, color: Color3)
	local style = TIER_STYLE[tier]
	for _, part in ipairs(parts) do
		for _, child in ipairs(part:GetChildren()) do
			if child.Name == AURA_NAME then
				child:Destroy()
			end
		end
		if not style then
			continue
		end
		if style.Shell then
			_addShell(part, style, color)
		end
		_addSpark(part, style, color)
		if style.FlameRate > 0 then
			_addFlame(part, style, color)
		end
	end
end

--[[
	给外壳段上色 / 材质，并按档位挂光效
	@param parts { BasePart } - 外壳段
	@param armId number - 手臂 Id
	@param matId string? - 材质 Id；nil 或未知时用 SmoothPlastic
	@return nil
]]
local function _paint(parts: { BasePart }, armId: number, matId: string?)
	local arm = ArmWrestleConfig.GetArm(armId)
	if not arm then
		armId = 1
		arm = ArmWrestleConfig.GetArm(armId)
	end
	if not arm then
		return
	end
	local mat = if matId then ArmWrestleConfig.GetMaterial(matId) else nil
	local material = if mat then (Enum.Material[mat.Mat] or Enum.Material.SmoothPlastic) else Enum.Material.SmoothPlastic
	for _, part in ipairs(parts) do
		part.Color = arm.Color
		part.Material = material
	end
	local tier, color = _resolveAura(armId, arm.Color, mat)
	_applyAura(parts, tier, color)
end

--[[
	隐藏原双臂并建 / 更新左右手外壳，按手臂与材质上色
	@param char Model - 角色或其克隆体（展台模特）；须含原手臂部件
	@param armId number - 手臂 Id（ArmWrestleConfig.GetArm）；无效时按 1
	@param matId string? - 材质 Id（ArmWrestleConfig.GetMaterial）；nil 表示无材质（SmoothPlastic）
	@return nil
]]
function ArmSkin.Apply(char: Model, armId: number, matId: string?)
	if not char then
		return
	end
	local parts: { BasePart } = {}
	for side in pairs(SIDES) do
		for _, part in ipairs(_syncSide(char, side)) do
			table.insert(parts, part)
		end
	end
	_paint(parts, armId, matId)
end

--[[
	判断部件名是否为原手臂部件（R15 / R6）
	@param name string - 部件名
	@return boolean - 是原手臂部件名时为 true
]]
function ArmSkin.IsArmPartName(name: string): boolean
	return ARM_PART_NAMES[name] == true
end

return ArmSkin
