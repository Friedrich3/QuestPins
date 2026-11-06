-- QuestPins: Questie-style quest markers on the world map only.
-- Core: settings, background job runner, event wiring and slash commands.
local addonName, ns = ...

ns.name = addonName
ns.ready = false          -- true once the quest-giver index has been built
ns.generation = 0         -- bumped whenever player state changes; invalidates availability caches

local REQUIRED_CONTRACT = 4

local defaults = {
    enabled = true,
    showAvailable = true,      -- yellow "!" at quest givers
    showTurnIn = true,         -- yellow "?" at quest enders of completed quests
    showIncompleteTurnIn = false, -- grey "?" at quest enders of quests still in progress
    showObjectives = true,     -- objective areas of quests in the log
    showTrivial = false,       -- grey "!" for low-level quests
    showRepeatable = true,     -- blue "!" for repeatable quests
    continentAvailable = true, -- quest givers / turn-ins on continent maps
    continentObjectives = false, -- objectives on continent maps (can get crowded)
    iconScale = 1.0,
}
ns.defaults = defaults

local function Print(fmt, ...)
    local msg = select("#", ...) > 0 and fmt:format(...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffQuestPins|r: " .. msg)
end
ns.Print = Print

function ns.Debug(fmt, ...)
    if QuestPinsDB and QuestPinsDB.debug then Print("|cff999999" .. fmt .. "|r", ...) end
end

---------------------------------------------------------------------------------------------------
-- Background jobs: coroutines resumed on OnUpdate within a small time budget per frame, so the
-- initial database scan never stalls the client (or trips the script time limit).
---------------------------------------------------------------------------------------------------
local jobs = {}
local jobFrame = CreateFrame("Frame")
local FRAME_BUDGET_MS = 6

local function RunJobs()
    local start = debugprofilestop()
    while jobs[1] do
        local job = jobs[1]
        local ok, err = coroutine.resume(job.co)
        if not ok then
            table.remove(jobs, 1)
            Print("|cffff4040error in %s:|r %s", job.name, tostring(err))
            if job.onError then job.onError(err) end
        elseif coroutine.status(job.co) == "dead" then
            table.remove(jobs, 1)
            if job.onDone then job.onDone() end
        end
        if debugprofilestop() - start > FRAME_BUDGET_MS then break end
    end
    if not jobs[1] then jobFrame:SetScript("OnUpdate", nil) end
end

function ns.RunJob(name, func, onDone, onError)
    jobs[#jobs + 1] = { name = name, co = coroutine.create(func), onDone = onDone, onError = onError }
    jobFrame:SetScript("OnUpdate", RunJobs)
end

-- Yield only when this frame's budget is spent; cheap to call in tight loops.
local yieldClock = 0
function ns.MaybeYield()
    if debugprofilestop() - yieldClock > FRAME_BUDGET_MS then
        coroutine.yield()
        yieldClock = debugprofilestop()
    end
end

---------------------------------------------------------------------------------------------------
-- Change propagation: state changes are coalesced and the open map is redrawn once.
---------------------------------------------------------------------------------------------------
local refreshPending = false
local activeDirty = false
local activeRunning = false

-- Rebuilds turn-ins/objectives for the quest log in the background, then redraws the map.
local function RebuildActive()
    if activeRunning then
        activeDirty = true -- run again once the current pass finishes
        return
    end
    activeDirty = false
    activeRunning = true
    ns.Player:ReadQuestLog()
    ns.generation = ns.generation + 1
    ns.RunJob("objectives", function()
        ns.Quests:RebuildActive()
    end, function()
        activeRunning = false
        if activeDirty then RebuildActive() else ns.MapPins:Refresh() end
    end, function()
        activeRunning = false
    end)
end
ns.RebuildActive = RebuildActive

function ns.MarkDirty(rebuildActive)
    ns.generation = ns.generation + 1
    if rebuildActive then activeDirty = true end
    if refreshPending then return end
    refreshPending = true
    C_Timer.After(0.25, function()
        refreshPending = false
        if not ns.ready then return end
        if activeDirty then
            RebuildActive()
        else
            ns.MapPins:Refresh()
        end
    end)
end

local logCheckPending = false
local function CheckQuestLog()
    if logCheckPending then return end
    logCheckPending = true
    C_Timer.After(0.5, function()
        logCheckPending = false
        if ns.ready and ns.Player:QuestLogChanged() then ns.MarkDirty(true) end
    end)
end

---------------------------------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------------------------------
local function CheckProvider()
    if type(LibQuestieDB) ~= "table" or type(LibQuestieDB.Quest) ~= "table" then
        Print("|cffff4040QuestieDB is not loaded.|r Install/enable the QuestieDB addon (it ships with Questie for Forever).")
        return false
    end
    local ok, message = LibQuestieDB.RequireContract(REQUIRED_CONTRACT)
    if not ok then
        Print("|cffff4040QuestieDB version not supported:|r %s", tostring(message))
        return false
    end
    return true
end

local function Start()
    if not CheckProvider() then return false end
    local ok, err = pcall(ns.Zones.Initialize, ns.Zones)
    if not ok then
        Print("|cffff4040could not read zone data from QuestieDB:|r %s", tostring(err))
        return false
    end
    ns.Player:Initialize()
    ns.MapPins:Initialize()

    ns.RunJob("index", function()
        ns.Quests:BuildIndex()
    end, function()
        ns.ready = true
        ns.Debug("index ready")
        RebuildActive()
    end)
    return true
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= addonName then return end
        QuestPinsDB = QuestPinsDB or {}
        for key, value in pairs(defaults) do
            if QuestPinsDB[key] == nil then QuestPinsDB[key] = value end
        end
        ns.db = QuestPinsDB
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        if not Start() then return end
        self:RegisterEvent("QUEST_ACCEPTED")
        self:RegisterEvent("QUEST_REMOVED")
        self:RegisterEvent("QUEST_TURNED_IN")
        self:RegisterEvent("QUEST_LOG_UPDATE")
        self:RegisterEvent("PLAYER_LEVEL_UP")
        self:RegisterEvent("SKILL_LINES_CHANGED")
        self:RegisterEvent("UPDATE_FACTION")
        self:RegisterEvent("LEARNED_SPELL_IN_TAB")
        self:RegisterEvent("QUEST_DATA_LOAD_RESULT")
    elseif event == "QUEST_TURNED_IN" then
        ns.Player:SetCompleted((...))
        ns.MarkDirty(true)
    elseif event == "QUEST_ACCEPTED" or event == "QUEST_REMOVED" then
        ns.MarkDirty(true)
    elseif event == "QUEST_LOG_UPDATE" then
        -- Fires very often; checked at most twice a second, redraws only on real progress.
        CheckQuestLog()
    elseif event == "PLAYER_LEVEL_UP" then
        ns.Player.level = (...) or UnitLevel("player")
        ns.Player:InvalidateCaches()
        ns.MarkDirty(false)
    elseif event == "QUEST_DATA_LOAD_RESULT" then
        ns.MapPins:OnQuestDataLoaded(...)
    else
        ns.Player:InvalidateCaches()
        ns.MarkDirty(false)
    end
end)

---------------------------------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------------------------------
local toggles = {
    available = { "showAvailable", "available quests" },
    turnin = { "showTurnIn", "turn-ins of completed quests" },
    incomplete = { "showIncompleteTurnIn", "turn-ins of unfinished quests" },
    objectives = { "showObjectives", "objectives" },
    trivial = { "showTrivial", "low-level quests" },
    repeatable = { "showRepeatable", "repeatable quests" },
    continent = { "continentAvailable", "quest givers on continent maps" },
    continentobjectives = { "continentObjectives", "objectives on continent maps" },
}

local function OnOff(value) return value and "|cff40ff40on|r" or "|cffff4040off|r" end

local function PrintStatus()
    Print("map markers %s, icon scale %.2f", OnOff(ns.db.enabled), ns.db.iconScale)
    for _, key in ipairs({ "available", "turnin", "incomplete", "objectives", "trivial", "repeatable", "continent", "continentobjectives" }) do
        local toggle = toggles[key]
        Print("  /qpins %s - %s (%s)", key, toggle[2], OnOff(ns.db[toggle[1]]))
    end
    Print("  /qpins scale <0.5-2> | /qpins toggle | /qpins reset")
end

SLASH_QUESTPINS1 = "/qpins"
SLASH_QUESTPINS2 = "/questpins"
SlashCmdList.QUESTPINS = function(input)
    local command, argument = (input or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
    if command == "" or command == "help" then
        PrintStatus()
        return
    end
    if command == "toggle" or command == "on" or command == "off" then
        if command == "toggle" then ns.db.enabled = not ns.db.enabled else ns.db.enabled = command == "on" end
        Print("map markers %s", OnOff(ns.db.enabled))
    elseif toggles[command] then
        local key = toggles[command][1]
        ns.db[key] = not ns.db[key]
        Print("%s %s", toggles[command][2], OnOff(ns.db[key]))
    elseif command == "scale" then
        local scale = tonumber(argument)
        if not scale or scale < 0.5 or scale > 2 then
            Print("usage: /qpins scale <0.5-2>")
            return
        end
        ns.db.iconScale = scale
        Print("icon scale %.2f", scale)
    elseif command == "reset" then
        for key, value in pairs(defaults) do ns.db[key] = value end
        Print("settings reset")
    elseif command == "debug" then
        ns.db.debug = not ns.db.debug
        Print("debug %s", OnOff(ns.db.debug))
        if ns.db.debug and ns.Quests.stats then
            Print("indexed %d quests with %d giver locations; QuestieDB %s mode", ns.Quests.stats.quests,
                ns.Quests.stats.locations, tostring(LibQuestieDB and LibQuestieDB.readMode))
        end
        return
    else
        Print("unknown command '%s'", command)
        PrintStatus()
        return
    end
    ns.MarkDirty(false)
end
