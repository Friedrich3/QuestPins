-- Player: the character facts that decide which quests are shown.
-- Read-only use of the quest log: nothing here tracks, watches or modifies quests.
local _, ns = ...

local Player = {
    completed = {},   -- [questId] = true
    questLog = {},    -- [questId] = { complete = bool, objectives = QuestObjectiveInfo[] }
    level = 1,
}
ns.Player = Player

local floor = math.floor

function Player:Initialize()
    self.level = UnitLevel("player")
    local _, _, raceId = UnitRace("player")
    local _, classFile = UnitClass("player")
    local enum = LibQuestieDB.Enum
    self.raceMask = enum.raceMaskById and enum.raceMaskById[raceId]
    self.classMask = enum.classKeys and enum.classKeys[classFile]
    local faction = UnitFactionGroup("player")
    self.factionLetter = faction == "Alliance" and "A" or faction == "Horde" and "H" or nil

    wipe(self.completed)
    if C_QuestLog.GetAllCompletedQuestIDs then
        for _, questId in ipairs(C_QuestLog.GetAllCompletedQuestIDs() or {}) do
            self.completed[questId] = true
        end
    elseif GetQuestsCompleted then
        for questId in pairs(GetQuestsCompleted() or {}) do
            self.completed[questId] = true
        end
    end
    self:InvalidateCaches()
end

function Player:SetCompleted(questId)
    if questId then self.completed[questId] = true end
end

function Player:IsCompleted(questId)
    return self.completed[questId] == true
end

function Player:InLog(questId)
    return self.questLog[questId] ~= nil
end

-- Masks can exceed 32 bits (Skyborne races), so test bits arithmetically, never with bit.band.
local function HasBit(mask, bitValue)
    return floor(mask / bitValue) % 2 == 1
end

function Player:HasRace(requiredRaces)
    if not requiredRaces or requiredRaces == 0 or not self.raceMask then return true end
    return HasBit(requiredRaces, self.raceMask)
end

function Player:HasClass(requiredClasses)
    if not requiredClasses or requiredClasses == 0 or not self.classMask then return true end
    return HasBit(requiredClasses, self.classMask)
end

function Player:IsFriendly(friendlyToFaction)
    if not friendlyToFaction or friendlyToFaction == "" or not self.factionLetter then return true end
    return friendlyToFaction:find(self.factionLetter, 1, true) ~= nil
end

---------------------------------------------------------------------------------------------------
-- Level, professions, reputation, spells
---------------------------------------------------------------------------------------------------
local greenRange

function Player:InvalidateCaches()
    greenRange = nil
    self.skillCache = {}
    self.repCache = {}
end

function Player:IsTrivial(questLevel)
    if not questLevel or questLevel <= 0 then return false end
    if not greenRange then
        if C_QuestLog.GetTrivialRange then
            greenRange = C_QuestLog.GetTrivialRange()
        elseif GetQuestGreenRange then
            greenRange = GetQuestGreenRange()
        end
        greenRange = greenRange or 8
    end
    return self.level - questLevel > greenRange
end

---@return number? rank Skill rank, or nil when the character does not have the skill.
function Player:GetSkillRank(skillId)
    local cached = self.skillCache[skillId]
    if cached ~= nil then return cached or nil end
    local rank
    if C_SkillInfo and C_SkillInfo.GetSkillLineInfoByID then
        local info = C_SkillInfo.GetSkillLineInfoByID(skillId)
        rank = info and not info.isHeader and info.rank or nil
    end
    self.skillCache[skillId] = rank or false
    return rank
end

---@return number? standing Earned reputation, or nil when the faction is unknown to the character.
function Player:GetReputation(factionId)
    local cached = self.repCache[factionId]
    if cached ~= nil then return cached or nil end
    local standing
    if C_Reputation and C_Reputation.GetFactionDataByID then
        local data = C_Reputation.GetFactionDataByID(factionId)
        standing = data and data.currentStanding
    elseif GetFactionInfoByID then
        standing = select(6, GetFactionInfoByID(factionId))
    end
    self.repCache[factionId] = standing or false
    return standing
end

function Player:KnowsSpell(spellId)
    if C_SpellBook and C_SpellBook.IsSpellKnown then
        return C_SpellBook.IsSpellKnown(spellId) or (IsPlayerSpell and IsPlayerSpell(spellId)) or false
    end
    return (IsSpellKnown and IsSpellKnown(spellId)) or (IsPlayerSpell and IsPlayerSpell(spellId)) or false
end

---------------------------------------------------------------------------------------------------
-- Quest log snapshot
---------------------------------------------------------------------------------------------------
local lastSignature = ""

local function BuildSignature()
    local parts = {}
    for index = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(index)
        if info and not info.isHeader and info.questID and info.questID > 0 then
            parts[#parts + 1] = info.questID
            parts[#parts + 1] = C_QuestLog.IsComplete(info.questID) and "c" or "i"
            for _, objective in ipairs(C_QuestLog.GetQuestObjectives(info.questID) or {}) do
                parts[#parts + 1] = (objective.finished and "f" or "") .. tostring(objective.numFulfilled)
            end
        end
    end
    return table.concat(parts, ",")
end

function Player:QuestLogChanged()
    return BuildSignature() ~= lastSignature
end

function Player:ReadQuestLog()
    local log = {}
    for index = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(index)
        if info and not info.isHeader and info.questID and info.questID > 0 then
            local questId = info.questID
            log[questId] = {
                complete = C_QuestLog.IsComplete(questId) and true or false,
                objectives = C_QuestLog.GetQuestObjectives(questId) or {},
                title = info.title,
                level = info.level,
            }
        end
    end
    self.questLog = log
    lastSignature = BuildSignature()
end
