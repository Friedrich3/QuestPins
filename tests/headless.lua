-- Headless end-to-end test: loads the real QuestieDB provider as a Forever client (Source mode,
-- through QuestieDB's own emulator), mocks the WoW map/quest-log APIs, loads QuestPins and draws.
--
--   cd <QuestieDB checkout> && lua5.1 <QuestPins>/tests/headless.lua <QuestPins dir> [scenario]
--
-- Not shipped in the addon zip.
local addonDir = assert(arg[1], "usage: headless.lua <QuestPins dir> [scenario]")
local scenario = arg[2] or "orc"

local savedLibStub = rawget(_G, "LibStub")
_G.LibStub = nil
local client = dofile("emulator/client.lua")
_G.LibStub = savedLibStub
local emulator = dofile("emulator/metadata.lua")

local personas = {
    orc   = { faction = "Horde", raceId = 2, raceName = "Orc", raceFile = "Orc", classFile = "WARRIOR", className = "Warrior", classId = 1, level = 1 },
    human = { faction = "Alliance", raceId = 1, raceName = "Human", raceFile = "Human", classFile = "MAGE", className = "Mage", classId = 8, level = 1 },
}
local persona = assert(personas[scenario:match("^%a+")], "unknown scenario")
local opts = { expansion = "Forever", gameType = "forever" }
for k, v in pairs(persona) do opts[k] = v end
client.install(opts)
emulator.install("QuestieDB", emulator.parse("QuestieDB.toc"))
local t0 = os.clock()
emulator.loadAddon("QuestieDB.toc", "QuestieDB")
print(("QuestieDB loaded in %.2fs, mode=%s, contract=%s"):format(os.clock() - t0, tostring(LibQuestieDB.readMode), tostring(LibQuestieDB.contractVersion)))

---------------------------------------------------------------------------------------------------
-- WoW API mocks used by QuestPins
---------------------------------------------------------------------------------------------------
local level = persona.level
UnitLevel = function() return level end
UnitFactionGroup = function() return persona.faction end
UnitRace = function() return persona.raceName, persona.raceFile, persona.raceId end
UnitClass = function() return persona.className, persona.classFile, persona.classId end
debugprofilestop = function() return os.clock() * 1000 end
Enum = Enum or {}
Enum.UIMapType = { Cosmic = 0, World = 1, Continent = 2, Zone = 3, Dungeon = 4, Micro = 5, Orphan = 6 }

local messages = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) messages[#messages + 1] = msg; print("  [chat] " .. msg) end }

local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }

local frames = {}
local function NewRegion()
    local region = {}
    setmetatable(region, { __index = function(t, k)
        if not k:match("^%u") then return nil end -- lowercase keys are plain fields
        return function(self, ...)
            if k == "SetScript" then
                local script, fn = ...
                self.scripts = self.scripts or {}
                self.scripts[script] = fn
            elseif k == "IsShown" then return true
            elseif k == "CreateTexture" then return NewRegion()
            elseif k == "SetAtlas" then self.atlas = ...
            elseif k == "SetTexture" then self.file = ...
            elseif k == "IsMouseMotionEnabled" then return self.motion
            elseif k == "SetMouseMotionEnabled" then self.motion = ...
            elseif k == "SetSize" then self.w, self.h = ...
            end
        end
    end })
    return region
end
CreateFrame = function()
    local frame = NewRegion()
    frames[#frames + 1] = frame
    return frame
end

-- Quest log scenario
local questLog = {}        -- ordered { questID, title, level, complete, objectives }
local completed = {}
C_QuestLog = {
    GetAllCompletedQuestIDs = function() local ids = {} for id in pairs(completed) do ids[#ids + 1] = id end return ids end,
    GetNumQuestLogEntries = function() return #questLog end,
    GetInfo = function(i) local q = questLog[i] return q and { questID = q.questID, title = q.title, level = q.level, isHeader = false } end,
    IsComplete = function(id) for _, q in ipairs(questLog) do if q.questID == id then return q.complete end end return false end,
    GetQuestObjectives = function(id) for _, q in ipairs(questLog) do if q.questID == id then return q.objectives end end return {} end,
    GetTitleForQuestID = function() return nil end,
    GetTrivialRange = function() return 5 end,
    RequestLoadQuestByID = function() end,
}
C_SkillInfo = { GetSkillLineInfoByID = function() return nil end }
C_Reputation = { GetFactionDataByID = function() return nil end }
C_SpellBook = { IsSpellKnown = function() return false end }
C_Texture = { GetAtlasInfo = function(atlas) return atlas == "QuestNormal" or atlas == "QuestTurnin" end }
GetQuestDifficultyColor = function() return { r = 1, g = 1, b = 0 } end

-- Map geometry (made-up rectangles, consistent with Kalimdor > Durotar > Orgrimmar nesting)
local mapInfo = {
    [1414] = { mapID = 1414, name = "Kalimdor", mapType = 2 },
    [1411] = { mapID = 1411, name = "Durotar", mapType = 3, parent = 1414 },
    [1454] = { mapID = 1454, name = "Orgrimmar", mapType = 3, parent = 1411 },
    [1412] = { mapID = 1412, name = "Mulgore", mapType = 3, parent = 1414 },
    [1413] = { mapID = 1413, name = "The Barrens", mapType = 3, parent = 1414 },
    [1415] = { mapID = 1415, name = "Eastern Kingdoms", mapType = 2 },
    [1429] = { mapID = 1429, name = "Elwynn Forest", mapType = 3, parent = 1415 },
    [1453] = { mapID = 1453, name = "Stormwind City", mapType = 3, parent = 1429 },
}
local rects = { -- [child][top] = {minX, maxX, minY, maxY}
    [1411] = { [1414] = { 0.58, 0.68, 0.40, 0.58 } },
    [1454] = { [1414] = { 0.59, 0.62, 0.38, 0.43 }, [1411] = { 0.10, 0.40, 0.00, 0.25 } },
    [1412] = { [1414] = { 0.38, 0.48, 0.48, 0.66 } },
    [1413] = { [1414] = { 0.46, 0.60, 0.38, 0.80 } },
    [1429] = { [1415] = { 0.40, 0.55, 0.75, 0.85 } },
    [1453] = { [1415] = { 0.41, 0.45, 0.72, 0.77 }, [1429] = { 0.05, 0.35, 0.00, 0.40 } },
}
C_Map = {
    GetMapInfo = function(id) return mapInfo[id] end,
    GetMapChildrenInfo = function(id, _, all)
        local out = {}
        for childId, info in pairs(mapInfo) do
            local p = info.parent
            while p do
                if p == id then out[#out + 1] = info break end
                if not all then break end
                p = mapInfo[p] and mapInfo[p].parent
            end
        end
        return out
    end,
    GetMapRectOnMap = function(child, top)
        local r = rects[child] and rects[child][top]
        if r then return r[1], r[2], r[3], r[4] end
    end,
}

-- Map canvas mocks
function Mixin(object, ...) for i = 1, select("#", ...) do for k, v in pairs((select(i, ...))) do object[k] = v end end return object end
function CreateFromMixins(...) return Mixin({}, ...) end
MapCanvasDataProviderMixin = { OnAdded = function(self, map) self.owningMap = map end, GetMap = function(self) return self.owningMap end }
MapCanvasPinMixin = {
    UseFrameLevelType = function(self, t) self.frameLevelType = t end,
    SetScalingLimits = function() end,
    SetPosition = function(self, x, y) self.x, self.y = x, y end,
    CheckMouseButtonPassthrough = function(self) self:SetPassThroughButtons() end,
}
function CreateUnsecuredRegionPoolInstance(template, create, reset)
    local pool = { active = {}, inactive = {} }
    function pool:Acquire()
        local obj = table.remove(self.inactive)
        local new = obj == nil
        if new then obj = self.createFunc(self) end
        self.active[obj] = true
        return obj, new
    end
    function pool:ReleaseAll()
        for obj in pairs(self.active) do self.resetFunc(self, obj) self.inactive[#self.inactive + 1] = obj end
        self.active = {}
    end
    return pool
end
local pins = {}
WorldMapFrame = {
    pinPools = {}, mapID = 1411, shown = true,
    GetCanvas = function() return {} end,
    IsShown = function(self) return self.shown end,
    GetMapID = function(self) return self.mapID end,
    AddDataProvider = function(self, provider) self.provider = provider provider:OnAdded(self) end,
    AcquirePin = function(self, template, ...)
        local pin, new = self.pinPools[template]:Acquire()
        pin.pinTemplate = template
        if new then pin:OnLoad() end
        pin:OnAcquired(...)
        pin:CheckMouseButtonPassthrough("RightButton")
        pins[#pins + 1] = pin
        return pin
    end,
    RemoveAllPinsByTemplate = function(self, template)
        if self.pinPools[template] then self.pinPools[template]:ReleaseAll() end
        pins = {}
    end,
}
local tooltipLines = {}
GameTooltip = {
    SetOwner = function(self, owner) self.owner = owner tooltipLines = {} end,
    AddLine = function(_, text) tooltipLines[#tooltipLines + 1] = text end,
    Show = function() end, Hide = function() end,
    IsShown = function() return true end, GetOwner = function(self) return self.owner end,
}
SlashCmdList = {}

---------------------------------------------------------------------------------------------------
-- Load QuestPins exactly as the TOC lists it
---------------------------------------------------------------------------------------------------
local ns = {}
for line in io.lines(addonDir .. "/QuestPins.toc") do
    if line:match("%.lua$") then
        local chunk = assert(loadfile(addonDir .. "/" .. line:gsub("\\", "/")))
        chunk("QuestPins", ns)
    end
end

local function Fire(event, ...)
    for _, frame in ipairs(frames) do
        if frame.scripts and frame.scripts.OnEvent then frame.scripts.OnEvent(frame, event, ...) end
    end
end

local function Pump()
    for _ = 1, 100000 do
        local didWork = false
        for _, frame in ipairs(frames) do
            if frame.scripts and frame.scripts.OnUpdate then frame.scripts.OnUpdate(frame, 0.016) didWork = true end
        end
        if timers[1] then
            local pending = timers
            timers = {}
            for _, fn in ipairs(pending) do fn() end
            didWork = true
        end
        if not didWork then return end
    end
    error("pump did not settle")
end

local function Summary(label)
    local counts, byIcon = 0, {}
    for _, pin in ipairs(pins) do
        counts = counts + 1
        byIcon[pin.data.icon] = (byIcon[pin.data.icon] or 0) + 1
        assert(pin.x >= 0 and pin.x <= 1 and pin.y >= 0 and pin.y <= 1, "pin out of bounds")
        assert(pin.texture.atlas or pin.texture.file, "pin without texture")
    end
    local parts = {}
    for icon, n in pairs(byIcon) do parts[#parts + 1] = icon .. "=" .. n end
    table.sort(parts)
    print(("%s: %d pins (%s)"):format(label, counts, table.concat(parts, ", ")))
    return byIcon
end

local function TooltipFor(predicate)
    for _, pin in ipairs(pins) do
        if predicate(pin.data) then
            pin:OnMouseEnter()
            return table.concat(tooltipLines, " | ")
        end
    end
end

local function ShowMap(mapId)
    WorldMapFrame.mapID = mapId
    WorldMapFrame.provider:RefreshAllData()
end

---------------------------------------------------------------------------------------------------
-- Scenario
---------------------------------------------------------------------------------------------------
QuestPinsDB = nil
Fire("ADDON_LOADED", "QuestPins")
t0 = os.clock()
Fire("PLAYER_LOGIN")
Pump()
assert(ns.ready, "index not ready")
print(("index: %d quests, %d giver locations, built in %.2fs"):format(ns.Quests.stats.quests, ns.Quests.stats.locations, os.clock() - t0))
assert(SlashCmdList.QUESTPINS, "slash command missing")

local failures = 0
local function Check(cond, msg)
    print((cond and "  ok   " or "  FAIL ") .. msg)
    if not cond then failures = failures + 1 end
end


Check(QuestPinsDB.showTurnIn == false, "turn-in '?' markers off by default")
Check(QuestPinsDB.showObjectives == false, "objective areas off by default")

if persona.faction == "Horde" then
    -- Fresh level 1 orc in Durotar (Valley of Trials).
    ShowMap(1411)
    local icons = Summary("Durotar lvl1")
    Check((icons.available or 0) > 0, "available quest givers drawn in Durotar")
    local tip = TooltipFor(function(d) return d.kind == "giver" end)
    print("  tooltip: " .. tostring(tip))
    Check(tip and tip:find("%[%d+%]") ~= nil, "giver tooltip lists a quest with level")
    local tipAll = {}
    for _, pin in ipairs(pins) do pin:OnMouseEnter() tipAll[#tipAll + 1] = table.concat(tooltipLines, " | ") end
    local all = table.concat(tipAll, "\n")
    Check(all:find("Your Place In The World", 1, true) ~= nil, "'Your Place In The World' (4641) offered at level 1")
    local function GiverOffers(questId)
        for _, pin in ipairs(pins) do
            if pin.data.kind == "giver" then
                for _, q in ipairs(pin.data.quests) do if q.questId == questId then return true end end
            end
        end
        return false
    end
    Check(GiverOffers(788), "'Cutting Teeth' (788, no prerequisite) offered")
    Check(not GiverOffers(789), "'Sting of the Scorpid' (789) hidden until 788 is turned in")
    Check(not GiverOffers(792), "'Vile Familiars' (792, requires level 2) hidden at level 1")
    Check(not GiverOffers(8532), "AQ War Effort quests hidden")
    Check(not GiverOffers(9263), "inactive invasion quests hidden")

    -- Complete 4641 and take 788 Cutting Teeth (kill Mottled Boars).
    completed[4641] = true
    Fire("QUEST_TURNED_IN", 4641)
    questLog = {
        { questID = 788, title = "Cutting Teeth", level = 2, complete = false,
          objectives = { { text = "Mottled Boar slain: 3/10", type = "monster", finished = false, numFulfilled = 3, numRequired = 10 } } },
    }
    Fire("QUEST_ACCEPTED", 788)
    Pump()
    ShowMap(1411)
    icons = Summary("Durotar after accepting 788 (defaults)")
    Check(not GiverOffers(4641), "completed quest 4641 no longer offered")
    Check((icons.slay or 0) == 0, "no objective areas with default settings")
    SlashCmdList.QUESTPINS("objectives")
    SlashCmdList.QUESTPINS("turnin")
    Pump()
    ShowMap(1411)
    icons = Summary("Durotar after accepting 788 (objectives + turnin on)")
    Check((icons.slay or 0) > 0, "kill objective areas for Mottled Boar drawn")
    tip = TooltipFor(function(d) return d.kind == "objective" end)
    print("  tooltip: " .. tostring(tip))
    Check(tip and tip:find("Cutting Teeth", 1, true) and tip:find("Mottled Boar", 1, true), "objective tooltip shows quest and target")
    Check((icons.complete or 0) == 0, "no turn-in '?' while 788 is incomplete (incomplete turn-ins off)")
    tipAll = {}
    for _, pin in ipairs(pins) do pin:OnMouseEnter() tipAll[#tipAll + 1] = table.concat(tooltipLines, " | ") end
    all = table.concat(tipAll, "\n")
    Check(not GiverOffers(788), "788 not offered again while it is in the log")
    Check(not GiverOffers(789), "789 still hidden while 788 is only in the log")

    -- Finish objective -> turn-in appears, objective pins vanish.
    questLog[1].complete = true
    questLog[1].objectives[1].finished = true
    questLog[1].objectives[1].numFulfilled = 10
    questLog[1].objectives[1].text = "Mottled Boar slain: 10/10"
    Fire("QUEST_LOG_UPDATE")
    Pump()
    ShowMap(1411)
    icons = Summary("Durotar with 788 complete")
    Check((icons.complete or 0) > 0, "turn-in '?' shown for completed quest")
    Check((icons.slay or 0) == 0, "objective markers removed once complete")
    tip = TooltipFor(function(d) return d.kind == "turnin" end)
    print("  tooltip: " .. tostring(tip))

    -- Turn in 788: its follow-up 789 becomes available.
    completed[788] = true
    questLog = {}
    Fire("QUEST_TURNED_IN", 788)
    Fire("QUEST_REMOVED", 788)
    Pump()
    ShowMap(1411)
    icons = Summary("Durotar after turning in 788")
    Check(GiverOffers(789), "'Sting of the Scorpid' (789) offered after 788 is turned in")
    Check((icons.complete or 0) == 0, "turn-in marker gone after turn-in")

    -- Completed without QUEST_TURNED_IN (e.g. flagged by the server): resynced on the next rebuild.
    completed[789] = true
    Fire("QUEST_REMOVED", 9999)
    Pump()
    ShowMap(1411)
    Summary("Durotar after 789 silently completed")
    Check(not GiverOffers(789), "quest completed without a turn-in event is hidden after resync")

    -- Continent view: givers shown smaller, objectives hidden by default.
    ShowMap(1414)
    icons = Summary("Kalimdor continent")
    Check((icons.available or 0) > 0, "givers visible on continent map")

    -- Slash command toggles.
    SlashCmdList.QUESTPINS("available")
    Pump()
    ShowMap(1411)
    icons = Summary("Durotar with available toggled off")
    Check((icons.available or 0) == 0, "/qpins available hides givers")
    SlashCmdList.QUESTPINS("available")
    SlashCmdList.QUESTPINS("trivial")
    Pump()

    -- Level 20 with nothing done: Durotar quests become trivial (grey) only when enabled.
    level = 20
    Fire("PLAYER_LEVEL_UP", 20)
    Pump()
    ShowMap(1411)
    icons = Summary("Durotar lvl20, trivial on")
    Check((icons.trivial or 0) > 0, "low-level quests shown grey when trivial is on")
    SlashCmdList.QUESTPINS("trivial")
    Pump()
    ShowMap(1411)
    icons = Summary("Durotar lvl20, trivial off")
    Check((icons.trivial or 0) == 0, "low-level quests hidden by default")

    -- Alliance-only content must never show for a Horde character.
    ShowMap(1429)
    icons = Summary("Elwynn Forest as orc")
    Check((icons.available or 0) == 0, "no Alliance quest givers for a Horde character")
else
    ShowMap(1429)
    local icons = Summary("Elwynn lvl1 human")
    Check((icons.available or 0) > 0, "available quest givers drawn in Elwynn Forest")
    local tip = TooltipFor(function(d) return d.kind == "giver" end)
    print("  tooltip: " .. tostring(tip))
    for _, pin in ipairs(pins) do
        if pin.data.icon == "repeatable" then
            pin:OnMouseEnter()
            print("  repeatable giver: " .. table.concat(tooltipLines, " | "))
        end
    end
    -- A quest done before login is never offered.
    local function OffersHuman(questId)
        for _, pin in ipairs(pins) do
            if pin.data.kind == "giver" then
                for _, q in ipairs(pin.data.quests) do if q.questId == questId then return true end end
            end
        end
        return false
    end
    Check(OffersHuman(783), "'A Threat Within' (783) offered at level 1")
    completed[783] = true
    Fire("QUEST_TURNED_IN", 783)
    Pump()
    ShowMap(1429)
    Summary("Elwynn after completing 783")
    Check(not OffersHuman(783), "completed quest 783 no longer offered")
    ShowMap(1411)
    icons = Summary("Durotar as human")
    Check((icons.available or 0) == 0, "no Horde quest givers for an Alliance character")
end

-- Remaining code paths must run without errors.
local okPaths, errPaths = pcall(function()
    for _, cmd in ipairs({ "", "scale 1.5", "scale 9", "objectives", "objectives", "continentobjectives", "incomplete", "repeatable", "toggle", "toggle", "debug", "debug", "bogus", "reset" }) do
        SlashCmdList.QUESTPINS(cmd)
    end
    Fire("UPDATE_FACTION")
    Fire("SKILL_LINES_CHANGED")
    Fire("LEARNED_SPELL_IN_TAB")
    Pump()
    ShowMap(1414)
    TooltipFor(function(d) return d.kind == "giver" end)
    Fire("QUEST_DATA_LOAD_RESULT", pins[1] and pins[1].data.quests and pins[1].data.quests[1].questId or 1, true)
    ShowMap(9999) -- unknown map: must draw nothing, not error
end)
Check(okPaths, "slash commands, misc events and unknown maps run cleanly " .. tostring(errPaths or ""))
Check(QuestPinsDB.iconScale == 1.0 and QuestPinsDB.enabled == true, "reset restores defaults")

print(failures == 0 and "ALL CHECKS PASSED" or (failures .. " CHECK(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
