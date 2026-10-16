--[[
	Module: WorldBoard
	Description: 把 SystemRank 力量榜缓存刷到 Workspace.World.Common.Leaderboard
	Author: 程莘
	Created: 2026-10-14
	Last Modified: 2026-10-14

	只读 SystemRank / 在线档案，不直连 OrderedDataStore。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local ArmWrestleConfig = Utils.ArmWrestleConfig
local RankConfig = Utils.RankConfig
local SystemRank = Utils.SystemRank
local TranslationHelper = Utils.TranslationHelper

local Profile = require(script.Parent.Profile)

local WorldBoard = {}

--[[
	刷新世界力量榜 SurfaceGui
	@param world Instance - Workspace.World
]]
function WorldBoard.Refresh(world: Instance)
	local common = world:FindFirstChild("Common")
	local leaderboard = common and common:FindFirstChild("Leaderboard")
	local board = leaderboard and leaderboard:FindFirstChild("Board")
	local display = board and board:FindFirstChild("Display")
	if not display then
		return
	end
	local rows = {}
	local okCache = false
	if SystemRank and SystemRank.GetCacheEntries then
		local entries = SystemRank.GetCacheEntries(RankConfig.RANK_STRENGTH_NAME)
		if type(entries) == "table" and #entries > 0 then
			okCache = true
			for _, entry in ipairs(entries) do
				local userId = entry.userId
				local name
				if type(userId) == "number" and userId > 0 then
					local ok, resolved = pcall(function()
						return Players:GetNameFromUserIdAsync(userId)
					end)
					name = if ok then resolved else tostring(userId)
				end
				table.insert(rows, { Name = name or "-", Value = entry.score or 0 })
			end
		end
	end
	if not okCache then
		for _, plr in ipairs(Players:GetPlayers()) do
			local data = Profile.Get(plr)
			if data then
				table.insert(rows, { Name = plr.Name, Value = math.floor(data.Strength or 0) })
			end
		end
		table.sort(rows, function(a, b)
			return a.Value > b.Value
		end)
	end
	for index = 1, 10 do
		local row = display:FindFirstChild("Row" .. index)
		if row then
			local nameLabel = row:FindFirstChild("Name")
			local valueLabel = row:FindFirstChild("Value")
			local entry = rows[index]
			if nameLabel and nameLabel:IsA("TextLabel") then
				if entry then
					TranslationHelper.SetRawText(nameLabel, "@" .. entry.Name)
				else
					TranslationHelper.SetRawText(nameLabel, "-")
				end
			end
			if valueLabel and valueLabel:IsA("TextLabel") then
				if entry then
					TranslationHelper.SetText(valueLabel, "力量数值", { ArmWrestleConfig.Format(entry.Value) })
				else
					TranslationHelper.SetRawText(valueLabel, "")
				end
			end
		end
	end
end

return WorldBoard
