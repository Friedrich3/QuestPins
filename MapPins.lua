-- MapPins: draws QuestPins markers on Blizzard's world map through a map data provider.
-- Uses an unsecured pin pool registered with the map (the same approach as HereBeDragons-Pins)
-- so the addon never taints the world map, the quest log or the objective tracker.
local addonName, ns = ...

local MapPins = {}
ns.MapPins = MapPins

local TEMPLATE = "QuestPinsPinTemplate"
local ICON_PATH = "Interface\\AddOns\\" .. addonName .. "\\Icons\\"
local BASE_SIZE = 16

local ICONS = {
    available          = { atlas = "QuestNormal", file = "Interface\\GossipFrame\\AvailableQuestIcon" },
    repeatable         = { atlas = "QuestDaily", file = "Interface\\GossipFrame\\DailyQuestIcon" },
    trivial            = { atlas = "QuestNormal", file = "Interface\\GossipFrame\\AvailableQuestIcon", desaturate = true, alpha = 0.75 },
    complete           = { atlas = "QuestTurnin", file = "Interface\\GossipFrame\\ActiveQuestIcon" },
    repeatableComplete = { atlas = "QuestRepeatableTurnin", file = "Interface\\GossipFrame\\DailyActiveQuestIcon" },
    incomplete         = { atlas = "QuestTurnin", file = "Interface\\GossipFrame\\ActiveQuestIcon", desaturate = true, alpha = 0.75 },
    slay               = { file = ICON_PATH .. "slay_mono", color = { 1.00, 0.42, 0.42 }, size = 0.85 },
    loot               = { file = ICON_PATH .. "loot_mono", color = { 1.00, 0.84, 0.30 }, size = 0.85 },
    object             = { file = ICON_PATH .. "object_mono", color = { 0.45, 0.80, 1.00 }, size = 0.85 },
    event              = { file = ICON_PATH .. "node", color = { 0.80, 0.55, 1.00 }, size = 0.85 },
}
MapPins.ICONS = ICONS

local FRAME_LEVEL = {
    objective = "PIN_FRAME_LEVEL_DIG_SITE",
    giver = "PIN_FRAME_LEVEL_AREA_POI",
    turnin = "PIN_FRAME_LEVEL_GOSSIP",
}

local atlasAvailable = {}
local function HasAtlas(atlas)
    if atlasAvailable[atlas] == nil then
        atlasAvailable[atlas] = (C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas)) and true or false
    end
    return atlasAvailable[atlas]
end

---------------------------------------------------------------------------------------------------
-- Pin
---------------------------------------------------------------------------------------------------
local PinMixin = CreateFromMixins(MapCanvasPinMixin)

function PinMixin:OnLoad()
    self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
    self:SetScalingLimits(1, 1.0, 1.2)
end

function PinMixin:OnAcquired(x, y, data)
    self.data = data
    self:UseFrameLevelType(FRAME_LEVEL[data.kind] or "PIN_FRAME_LEVEL_AREA_POI")
    local icon = ICONS[data.icon] or ICONS.available
    local size = BASE_SIZE * (icon.size or 1) * data.scale
    self:SetSize(size, size)

    local texture = self.texture
    if icon.atlas and HasAtlas(icon.atlas) then
        texture:SetAtlas(icon.atlas)
    else
        texture:SetTexture(icon.file)
        texture:SetTexCoord(0, 1, 0, 1)
    end
    texture:SetDesaturated(icon.desaturate and true or false)
    if icon.color then
        texture:SetVertexColor(icon.color[1], icon.color[2], icon.color[3])
    else
        texture:SetVertexColor(1, 1, 1)
    end
    texture:SetAlpha(icon.alpha or 1)
    self:SetPosition(x, y)
end

function PinMixin:OnReleased()
    self.data = nil
end

function PinMixin:OnMouseEnter()
    MapPins:ShowTooltip(self)
end

function PinMixin:OnMouseLeave()
    GameTooltip:Hide()
end

-- Pins never take clicks (they fall through to the map); avoid the protected passthrough call.
PinMixin.SetPassThroughButtons = function() end

local function CreatePin()
    local pin = CreateFrame("Frame", nil, WorldMapFrame:GetCanvas())
    Mixin(pin, PinMixin)
    pin:SetSize(BASE_SIZE, BASE_SIZE)
    pin.texture = pin:CreateTexture(nil, "ARTWORK")
    pin.texture:SetAllPoints()
    pin:SetMouseClickEnabled(false)
    pin:SetMouseMotionEnabled(true)
    return pin
end

local function ResetPin(_, pin)
    pin:Hide()
    pin:ClearAllPoints()
    if pin.OnReleased then pin:OnReleased() end
    pin.pinTemplate = nil
    pin.owningMap = nil
end

---------------------------------------------------------------------------------------------------
-- Data provider
---------------------------------------------------------------------------------------------------
local provider = CreateFromMixins(MapCanvasDataProviderMixin)

function provider:RemoveAllData()
    self:GetMap():RemoveAllPinsByTemplate(TEMPLATE)
end

function provider:RefreshAllData()
    self:RemoveAllData()
    if not ns.ready or not ns.db or not ns.db.enabled then return end
    local ok, err = pcall(MapPins.Draw, MapPins, self:GetMap())
    if not ok and not MapPins.reportedError then
        MapPins.reportedError = true -- once per session; the map keeps working without our pins
        ns.Print("|cffff4040could not draw markers:|r %s", tostring(err))
    end
end

function MapPins:Initialize()
    if self.initialized or not WorldMapFrame then return end
    local pool
    if CreateUnsecuredRegionPoolInstance then
        pool = CreateUnsecuredRegionPoolInstance(TEMPLATE, CreatePin, ResetPin)
    else
        pool = CreateFramePool("FRAME")
    end
    pool.createFunc, pool.resetFunc = CreatePin, ResetPin
    pool.creationFunc, pool.resetterFunc = CreatePin, ResetPin -- pre-11.x field names
    WorldMapFrame.pinPools[TEMPLATE] = pool
    WorldMapFrame:AddDataProvider(provider)
    self.initialized = true
end

function MapPins:Refresh()
    if self.initialized and WorldMapFrame:IsShown() then
        provider:RefreshAllData()
    end
end

---------------------------------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------------------------------
local function Place(map, sourceRect, x, y)
    return sourceRect[2] + x * sourceRect[4], sourceRect[3] + y * sourceRect[5]
end

local function InBounds(x, y) return x >= 0 and x <= 1 and y >= 0 and y <= 1 end

local function DrawGivers(map, sources, scale)
    local db, Quests = ns.db, ns.Quests
    for _, source in ipairs(sources) do
        for _, location in ipairs(Quests:GetGivers(source[1]) or {}) do
            local quests, normal, repeatable = nil, false, false
            for _, questId in ipairs(location.quests) do
                local status = Quests:GetAvailability(questId)
                if status == "available" or (status == "trivial" and db.showTrivial) then
                    local isRepeatable = Quests:IsRepeatable(questId)
                    if db.showRepeatable or not isRepeatable then
                        quests = quests or {}
                        quests[#quests + 1] = { questId = questId, status = status }
                        if status == "available" then
                            if isRepeatable then repeatable = true else normal = true end
                        end
                    end
                end
            end
            if quests then
                local x, y = Place(map, source, location.x, location.y)
                if InBounds(x, y) then
                    local icon = normal and "available" or repeatable and "repeatable" or "trivial"
                    map:AcquirePin(TEMPLATE, x, y, {
                        kind = "giver", icon = icon, scale = scale,
                        entity = location.kind, entityId = location.id, quests = quests,
                    })
                end
            end
        end
    end
end

local function DrawTurnins(map, sources, scale)
    local db, Quests = ns.db, ns.Quests
    local merged = {}
    for _, source in ipairs(sources) do
        for _, turnin in ipairs(Quests.turninsByMap[source[1]] or {}) do
            if (turnin.complete and db.showTurnIn) or (not turnin.complete and db.showIncompleteTurnIn) then
                local x, y = Place(map, source, turnin.x, turnin.y)
                if InBounds(x, y) then
                    local key = ("%s%d:%.3f:%.3f"):format(turnin.kind, turnin.id, x, y)
                    local pinData = merged[key]
                    if not pinData then
                        pinData = { kind = "turnin", scale = scale, x = x, y = y, entity = turnin.kind, entityId = turnin.id, quests = {} }
                        merged[key] = pinData
                    end
                    pinData.quests[#pinData.quests + 1] = { questId = turnin.questId, complete = turnin.complete }
                end
            end
        end
    end
    for _, pinData in pairs(merged) do
        local anyComplete, allRepeatable = false, true
        for _, quest in ipairs(pinData.quests) do
            if quest.complete then anyComplete = true end
            if not Quests:IsRepeatable(quest.questId) then allRepeatable = false end
        end
        pinData.icon = not anyComplete and "incomplete" or allRepeatable and "repeatableComplete" or "complete"
        map:AcquirePin(TEMPLATE, pinData.x, pinData.y, pinData)
    end
end

-- Greedy clustering in display space: nearby spawns of one objective become one marker.
local function Cluster(points, radius)
    local clusters = {}
    for _, point in ipairs(points) do
        local x, y = point[1], point[2]
        local target
        for _, cluster in ipairs(clusters) do
            if math.abs(cluster.x - x) < radius and math.abs(cluster.y - y) < radius then
                target = cluster
                break
            end
        end
        if target then
            local n = target.n + 1
            target.x = target.x + (x - target.x) / n
            target.y = target.y + (y - target.y) / n
            target.n = n
        else
            target = { x = x, y = y, n = 1, sources = {} }
            clusters[#clusters + 1] = target
        end
        if point[3] then target.sources[point[3]] = true end
    end
    return clusters
end

local function DrawObjectives(map, sources, scale, radius)
    for _, group in ipairs(ns.Quests.objectiveGroups) do
        local points = {}
        for _, source in ipairs(sources) do
            for _, point in ipairs(group.points[source[1]] or {}) do
                local x, y = Place(map, source, point[1], point[2])
                if InBounds(x, y) then
                    points[#points + 1] = { x, y, point[3] }
                end
            end
        end
        if points[1] then
            for _, cluster in ipairs(Cluster(points, radius)) do
                map:AcquirePin(TEMPLATE, cluster.x, cluster.y, {
                    kind = "objective", icon = group.icon, scale = scale * 0.9,
                    group = group, sources = cluster.sources,
                })
            end
        end
    end
end

function MapPins:Draw(map)
    local displayMapId = map:GetMapID()
    if not displayMapId then return end
    local mapType, sources = ns.Zones:GetLayout(displayMapId)
    if not sources[1] then return end

    local db = ns.db
    local isContinent = mapType == ns.Zones.MAP_TYPE_CONTINENT
    local scale = db.iconScale * (isContinent and 0.8 or 1)

    if db.showObjectives and (not isContinent or db.continentObjectives) then
        DrawObjectives(map, sources, scale, isContinent and 0.012 or 0.03)
    end
    if not isContinent or db.continentAvailable then
        if db.showAvailable then DrawGivers(map, sources, scale) end
        if db.showTurnIn or db.showIncompleteTurnIn then DrawTurnins(map, sources, scale) end
    end
end

---------------------------------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------------------------------
local function LevelColor(level)
    if GetQuestDifficultyColor and level and level > 0 then
        local color = GetQuestDifficultyColor(level)
        if color then return color.r, color.g, color.b end
    end
    return 1, 0.82, 0
end

local tooltipPin, waitingFor = nil, {}

local function QuestLine(questId, suffix)
    local Quests = ns.Quests
    local name, fromClient = Quests:GetQuestName(questId)
    if not fromClient and C_QuestLog.RequestLoadQuestByID then
        waitingFor[questId] = true
        C_QuestLog.RequestLoadQuestByID(questId)
    end
    local level = Quests:GetQuestLevel(questId)
    local r, g, b = LevelColor(level)
    local text = level > 0 and ("[%d] %s"):format(level, name) or name
    GameTooltip:AddLine(text .. (suffix or ""), r, g, b)
end

local function SortedSources(set, limit)
    local list = {}
    for name in pairs(set) do list[#list + 1] = name end
    table.sort(list)
    if #list > limit then
        local extra = #list - limit
        for i = #list, limit + 1, -1 do list[i] = nil end
        list[#list + 1] = ("+%d"):format(extra)
    end
    return table.concat(list, ", ")
end

function MapPins:ShowTooltip(pin)
    local data = pin.data
    if not data then return end
    tooltipPin = pin
    wipe(waitingFor)
    GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
    local Quests = ns.Quests

    if data.kind == "giver" or data.kind == "turnin" then
        local entityName = Quests:GetEntityName(data.entity, data.entityId)
        if entityName then GameTooltip:AddLine(entityName, 1, 1, 1) end
        for _, quest in ipairs(data.quests) do
            local suffix
            if data.kind == "turnin" then
                suffix = quest.complete and "" or " |cff999999(in progress)|r"
            elseif Quests:IsRepeatable(quest.questId) then
                suffix = " |cff66bbff(repeatable)|r"
            end
            QuestLine(quest.questId, suffix)
        end
    elseif data.kind == "objective" then
        local group = data.group
        QuestLine(group.questId)
        if group.text and group.text ~= "" then
            GameTooltip:AddLine(group.text, 1, 1, 1, true)
        end
        if next(data.sources) then
            GameTooltip:AddLine(SortedSources(data.sources, 3), 0.65, 0.65, 0.65, true)
        end
    end
    GameTooltip:Show()
end

function MapPins:OnQuestDataLoaded(questId, success)
    if success and waitingFor[questId] and tooltipPin and tooltipPin.data
        and GameTooltip:IsShown() and GameTooltip:GetOwner() == tooltipPin then
        self:ShowTooltip(tooltipPin)
    end
end
