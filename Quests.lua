-- Quests: which quests to mark and where, read from QuestieDB.
--   * givers:     a one-time index of every quest start location usable by this character
--   * available:  per-quest eligibility, re-evaluated when the character's state changes
--   * active:     turn-in locations and objective areas for quests in the log
local _, ns = ...

local Quests = { stats = nil }
ns.Quests = Quests

local Player, Zones
local QuestDB, NpcDB, ObjectDB, ItemDB

local giversByMap = {}   -- [uiMapId] = { location, ... }; location = { uiMapId, x, y, kind, id, quests = {} }
local starterCache = {}  -- ["n123"/"o456"] = { location, ... } | false
local staticCache = {}   -- [questId] = packed static fields
local availableCache, availableGeneration = {}, -1

Quests.turninsByMap = {}    -- [uiMapId] = { { x, y, kind, id, questId, complete }, ... }
Quests.objectiveGroups = {} -- { { questId, index, icon, text, points = { [uiMapId] = { {x, y, source}, ... } } }, ... }

---------------------------------------------------------------------------------------------------
-- Locations of NPCs and objects
---------------------------------------------------------------------------------------------------
local DEDUPE = 0.004 -- spawns closer than this (normalized) share one marker

local function AddUniquePoint(list, uiMapId, x, y)
    for _, existing in ipairs(list) do
        if existing[1] == uiMapId and math.abs(existing[2] - x) < DEDUPE and math.abs(existing[3] - y) < DEDUPE then
            return
        end
    end
    list[#list + 1] = { uiMapId, x, y }
end

local function SpawnsOf(kind, id)
    if kind == "n" then return NpcDB.spawns(id) end
    return ObjectDB.spawns(id)
end

---Shared location records for a quest giver/ender, or false when it can't be shown.
local function StarterLocations(kind, id)
    local key = kind .. id
    local cached = starterCache[key]
    if cached ~= nil then return cached end

    local result = false
    if kind == "n" and not Player:IsFriendly(NpcDB.friendlyToFaction(id)) then
        starterCache[key] = false
        return false
    end
    local points = {}
    Zones:ResolveSpawns(SpawnsOf(kind, id), function(uiMapId, x, y)
        AddUniquePoint(points, uiMapId, x, y)
    end)
    if points[1] then
        result = {}
        for _, point in ipairs(points) do
            result[#result + 1] = { uiMapId = point[1], x = point[2], y = point[3], kind = kind, id = id, quests = {} }
        end
    end
    starterCache[key] = result
    return result
end
Quests.StarterLocations = StarterLocations

---------------------------------------------------------------------------------------------------
-- Giver index (built once per login, in a background job)
---------------------------------------------------------------------------------------------------
function Quests:BuildIndex()
    Player, Zones = ns.Player, ns.Zones
    QuestDB, NpcDB, ObjectDB, ItemDB = LibQuestieDB.Quest, LibQuestieDB.Npc, LibQuestieDB.Object, LibQuestieDB.Item

    -- In Source mode the first read of a type compiles its whole payload: give each its own frame.
    for _, entity in ipairs({ NpcDB, QuestDB, ItemDB, ObjectDB }) do
        entity.GetAllIds()
        coroutine.yield()
    end

    local blacklist = ns.Blacklist or {}
    local questCount, locationCount = 0, 0
    for _, questId in ipairs(QuestDB.GetAllIds()) do
        if not blacklist[questId]
            and Player:HasRace(QuestDB.requiredRaces(questId))
            and Player:HasClass(QuestDB.requiredClasses(questId)) then
            local startedBy = QuestDB.startedBy(questId)
            local indexed = false
            for slot, kind in ipairs({ "n", "o" }) do
                local starters = startedBy and startedBy[slot]
                if starters then
                    for _, starterId in ipairs(starters) do
                        local locations = StarterLocations(kind, starterId)
                        if locations then
                            for _, location in ipairs(locations) do
                                if not location.quests[1] then
                                    local list = giversByMap[location.uiMapId]
                                    if not list then
                                        list = {}
                                        giversByMap[location.uiMapId] = list
                                    end
                                    list[#list + 1] = location
                                    locationCount = locationCount + 1
                                end
                                location.quests[#location.quests + 1] = questId
                            end
                            indexed = true
                        end
                    end
                end
            end
            if indexed then questCount = questCount + 1 end
        end
        ns.MaybeYield()
    end
    self.stats = { quests = questCount, locations = locationCount }
end

function Quests:GetGivers(uiMapId)
    return giversByMap[uiMapId]
end

---------------------------------------------------------------------------------------------------
-- Availability (mirrors the rules of Questie's QuestieDB.IsDoable that apply to Era content)
---------------------------------------------------------------------------------------------------
local STATIC_FIELDS = {
    "questLevel", "requiredLevel", "requiredMaxLevel", "preQuestSingle", "preQuestGroup",
    "exclusiveTo", "nextQuestInChain", "parentQuest", "breadcrumbForQuestId", "breadcrumbs",
    "disabledByQuest", "availableUntilCompleted", "availableStartingWith", "requiredSkill",
    "requiredMinRep", "requiredMaxRep", "requiredSpell", "specialFlags",
}
local F = {}
for index, name in ipairs(STATIC_FIELDS) do F[name] = index end

local function Static(questId)
    local fields = staticCache[questId]
    if not fields then
        fields = QuestDB.GetAll(questId, STATIC_FIELDS) or { n = 0 }
        staticCache[questId] = fields
    end
    return fields
end

local function Done(questId) return Player.completed[questId] or Player.questLog[questId] ~= nil end

local function PreQuestGroupFulfilled(group)
    for _, preId in ipairs(group) do
        if preId < 0 then
            if not Player.completed[-preId] then return false end
        elseif not Player.completed[preId] then
            -- An exclusive alternative of the prerequisite also counts.
            local alternatives = QuestDB.exclusiveTo(preId)
            local any = false
            for _, altId in ipairs(alternatives or {}) do
                if Player.completed[altId] then any = true break end
            end
            if not any then return false end
        end
    end
    return true
end

local function PreQuestSingleFulfilled(single)
    for _, preId in ipairs(single) do
        if Player.completed[preId] then return true end
    end
    return false
end

local function Nonzero(value) return value and value ~= 0 and value or nil end

---@return string? status "available" | "trivial" | nil when the quest should not be shown
local function Evaluate(questId)
    if Done(questId) then return nil end
    local s = Static(questId)
    local level = Player.level

    local requiredLevel = s[F.requiredLevel] or 0
    if requiredLevel > level then return nil end
    local maxLevel = Nonzero(s[F.requiredMaxLevel])
    if maxLevel and level > maxLevel then return nil end

    local single = s[F.preQuestSingle]
    if single and single[1] then
        if not PreQuestSingleFulfilled(single) then return nil end
    else
        local group = s[F.preQuestGroup]
        if group and group[1] and not PreQuestGroupFulfilled(group) then return nil end
    end

    for _, otherId in ipairs(s[F.exclusiveTo] or {}) do
        if Done(otherId) then return nil end
    end

    local nextInChain = Nonzero(s[F.nextQuestInChain])
    if nextInChain and Done(nextInChain) then return nil end

    local parent = Nonzero(s[F.parentQuest])
    if parent and not Player.questLog[parent] then return nil end

    local breadcrumbFor = Nonzero(s[F.breadcrumbForQuestId])
    if breadcrumbFor and Done(breadcrumbFor) then return nil end
    for _, breadcrumbId in ipairs(s[F.breadcrumbs] or {}) do
        if Player.questLog[breadcrumbId] then return nil end
    end

    local disabledBy = Nonzero(s[F.disabledByQuest])
    if disabledBy and Player.questLog[disabledBy] then return nil end

    local until_ = Nonzero(s[F.availableUntilCompleted])
    if until_ and Player.completed[until_] then return nil end

    local startingWith = Nonzero(s[F.availableStartingWith])
    if startingWith and not Done(startingWith) then return nil end

    local skill = s[F.requiredSkill]
    if skill and skill[1] and skill[1] ~= 0 then
        local rank = Player:GetSkillRank(skill[1])
        if not rank or rank < (skill[2] or 0) then return nil end
    end

    local minRep = s[F.requiredMinRep]
    if minRep and minRep[1] and minRep[1] ~= 0 then
        local standing = Player:GetReputation(minRep[1])
        if not standing or standing < (minRep[2] or 0) then return nil end
    end
    local maxRep = s[F.requiredMaxRep]
    if maxRep and maxRep[1] and maxRep[1] ~= 0 then
        local standing = Player:GetReputation(maxRep[1])
        if standing and standing >= (maxRep[2] or 0) then return nil end
    end

    local spell = Nonzero(s[F.requiredSpell])
    if spell then
        local known = Player:KnowsSpell(math.abs(spell))
        if (spell > 0) ~= known then return nil end
    end

    local questLevel = s[F.questLevel] or 0
    if questLevel > 0 and Player:IsTrivial(questLevel) then return "trivial" end
    return "available"
end

function Quests:GetAvailability(questId)
    if availableGeneration ~= ns.generation then
        wipe(availableCache)
        availableGeneration = ns.generation
    end
    local status = availableCache[questId]
    if status == nil then
        status = Evaluate(questId) or false
        availableCache[questId] = status
    end
    return status or nil
end

function Quests:IsRepeatable(questId)
    local flags = Static(questId)[F.specialFlags] or 0
    return flags % 2 == 1
end

function Quests:GetQuestLevel(questId)
    local entry = Player.questLog[questId]
    if entry and entry.level and entry.level > 0 then return entry.level end
    return Static(questId)[F.questLevel] or 0
end

function Quests:GetQuestName(questId)
    local entry = Player.questLog[questId]
    local name = (entry and entry.title) or C_QuestLog.GetTitleForQuestID(questId)
    if name and name ~= "" then return name, true end
    return QuestDB.name(questId) or ("Quest #" .. questId), false
end

function Quests:GetEntityName(kind, id)
    if kind == "n" then return NpcDB.name(id) end
    if kind == "o" then return ObjectDB.name(id) end
    if kind == "i" then return ItemDB.name(id) end
end

---------------------------------------------------------------------------------------------------
-- Quests in the log: turn-ins and objectives
---------------------------------------------------------------------------------------------------
local ICON_SLAY, ICON_LOOT, ICON_OBJECT, ICON_EVENT = "slay", "loot", "object", "event"
Quests.ICON_SLAY, Quests.ICON_LOOT, Quests.ICON_OBJECT, Quests.ICON_EVENT = ICON_SLAY, ICON_LOOT, ICON_OBJECT, ICON_EVENT

---Database objectives in the same order as the quest log's objectives (Questie's ordering rules).
local function OrderedObjectives(questId)
    local raw = QuestDB.objectives(questId) or {}
    local hints = LibQuestieDB.ObjectiveFirst or {}
    local list = {}
    local function add(entry, first)
        if first then table.insert(list, 1, entry) else list[#list + 1] = entry end
    end
    for _, creature in ipairs(raw[1] or {}) do
        add({ type = "monster", id = creature[1], text = creature[2] })
    end
    for _, object in ipairs(raw[2] or {}) do
        add({ type = "object", id = object[1], text = object[2] }, hints.objectObjectiveFirst and hints.objectObjectiveFirst[questId])
    end
    for _, item in ipairs(raw[3] or {}) do
        add({ type = "item", id = item[1], text = item[2] }, hints.itemObjectiveFirst and hints.itemObjectiveFirst[questId])
    end
    if raw[4] then add({ type = "reputation" }) end
    for _, credit in ipairs(raw[5] or {}) do
        add({ type = "killcredit", ids = credit[1], rootId = credit[2], text = credit[3] },
            hints.killCreditObjectiveFirst and hints.killCreditObjectiveFirst[questId])
    end
    for _, spell in ipairs(raw[6] or {}) do
        add({ type = "spell", id = spell[1], text = spell[2] }, hints.spellObjectiveFirst and hints.spellObjectiveFirst[questId])
    end
    local trigger = QuestDB.triggerEnd(questId)
    if trigger then
        add({ type = "event", text = trigger[1], spawns = trigger[2] }, hints.eventObjectiveFirst and hints.eventObjectiveFirst[questId])
    end
    return list
end

local function NewGroup(questId, index, icon, text)
    return { questId = questId, index = index, icon = icon, text = text, points = {}, count = 0 }
end

local function AddSpawns(group, spawns, sourceName)
    Zones:ResolveSpawns(spawns, function(uiMapId, x, y)
        local list = group.points[uiMapId]
        if not list then
            list = {}
            group.points[uiMapId] = list
        end
        list[#list + 1] = { x, y, sourceName }
        group.count = group.count + 1
    end)
end

local MAX_DROP_SOURCES = 40 -- items dropped by very many creatures would only paint the whole map

local function BuildObjective(questId, index, objective, logObjective)
    local logText = logObjective and logObjective.text
    if objective.type == "monster" then
        local group = NewGroup(questId, index, ICON_SLAY, logText or objective.text or NpcDB.name(objective.id))
        AddSpawns(group, NpcDB.spawns(objective.id), NpcDB.name(objective.id))
        return group
    elseif objective.type == "killcredit" then
        local group = NewGroup(questId, index, ICON_SLAY, logText or objective.text or NpcDB.name(objective.rootId))
        for _, npcId in ipairs(objective.ids or {}) do
            AddSpawns(group, NpcDB.spawns(npcId), NpcDB.name(npcId))
        end
        return group
    elseif objective.type == "object" then
        local group = NewGroup(questId, index, ICON_OBJECT, logText or objective.text or ObjectDB.name(objective.id))
        AddSpawns(group, ObjectDB.spawns(objective.id), ObjectDB.name(objective.id))
        return group
    elseif objective.type == "item" then
        local group = NewGroup(questId, index, ICON_LOOT, logText or objective.text or ItemDB.name(objective.id))
        local npcs = ItemDB.npcDrops(objective.id) or {}
        local objects = ItemDB.objectDrops(objective.id) or {}
        if #npcs + #objects <= MAX_DROP_SOURCES then
            for _, npcId in ipairs(npcs) do
                AddSpawns(group, NpcDB.spawns(npcId), NpcDB.name(npcId))
            end
            for _, objectId in ipairs(objects) do
                AddSpawns(group, ObjectDB.spawns(objectId), ObjectDB.name(objectId))
            end
        end
        return group
    elseif objective.type == "event" then
        local group = NewGroup(questId, index, ICON_EVENT, logText or objective.text)
        AddSpawns(group, objective.spawns, nil)
        return group
    end
end

local function AddTurnins(turninsByMap, questId, complete)
    local finishedBy = QuestDB.finishedBy(questId)
    for slot, kind in ipairs({ "n", "o" }) do
        for _, enderId in ipairs(finishedBy and finishedBy[slot] or {}) do
            for _, location in ipairs(StarterLocations(kind, enderId) or {}) do
                local list = turninsByMap[location.uiMapId]
                if not list then
                    list = {}
                    turninsByMap[location.uiMapId] = list
                end
                list[#list + 1] = { x = location.x, y = location.y, kind = kind, id = enderId, questId = questId, complete = complete }
            end
        end
    end
end

---Rebuilds turn-ins and objective areas for the current quest log. Runs inside a background job;
---the new tables replace the old ones only when complete, so the map never shows a partial state.
function Quests:RebuildActive()
    local turninsByMap, objectiveGroups = {}, {}
    for questId, entry in pairs(Player.questLog) do
        if QuestDB.Exists(questId) then
            AddTurnins(turninsByMap, questId, entry.complete)
            if not entry.complete then
                for index, objective in ipairs(OrderedObjectives(questId)) do
                    local logObjective = entry.objectives[index]
                    if not (logObjective and logObjective.finished) then
                        local group = BuildObjective(questId, index, objective, logObjective)
                        if group and group.count > 0 then
                            objectiveGroups[#objectiveGroups + 1] = group
                        end
                    end
                    ns.MaybeYield()
                end
            end
        end
    end
    self.turninsByMap, self.objectiveGroups = turninsByMap, objectiveGroups
end
