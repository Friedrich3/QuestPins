-- Zones: turns QuestieDB spawn locations (AreaId + 0-100 coordinates) into world-map
-- positions (UiMapID + 0-1 coordinates). Spawns inside dungeons are moved to the entrance.
local _, ns = ...

local Zones = {}
ns.Zones = Zones

local areaIdToUiMapId = {}
local dungeons = {}
local alternativeToDungeon = {}

local function Decode(value, label)
    if type(value) == "table" then return value end
    if type(value) ~= "string" then return {} end
    local chunk, err = loadstring(value, "QuestieDB." .. label)
    if not chunk then error(label .. ": " .. tostring(err)) end
    local decoded = chunk()
    return type(decoded) == "table" and decoded or {}
end

function Zones:Initialize()
    local zoneData = LibQuestieDB.Support.Get("ZoneDB")
    assert(type(zoneData) == "table" and type(zoneData.private) == "table", "ZoneDB support data missing")
    local private = zoneData.private

    -- Same merge order as Questie: base map, then the provider's overrides.
    areaIdToUiMapId = Decode(private.areaIdToUiMapId, "areaIdToUiMapId")
    for areaId, uiMapId in pairs(Decode(private.areaIdToUiMapIdOverride, "areaIdToUiMapIdOverride")) do
        areaIdToUiMapId[areaId] = uiMapId
    end

    dungeons = type(private.dungeons) == "table" and private.dungeons or {}
    for areaId, entry in pairs(dungeons) do
        if type(entry[2]) == "table" then
            for _, alternativeId in ipairs(entry[2]) do
                alternativeToDungeon[alternativeId] = areaId
            end
        end
    end
end

local function DungeonEntrances(areaId)
    local entry = dungeons[areaId] or dungeons[alternativeToDungeon[areaId] or -1]
    return entry and entry[4]
end

---Calls `callback(uiMapId, x, y)` (x/y normalized 0-1) for every world-map position of a spawn.
---@param areaId number
---@param x number 0-100, or -1 for "somewhere inside this instance"
---@param y number
---@param callback fun(uiMapId: number, x: number, y: number)
function Zones:Resolve(areaId, x, y, callback)
    local entrances = DungeonEntrances(areaId)
    if entrances then
        for _, entrance in ipairs(entrances) do
            local uiMapId = areaIdToUiMapId[entrance[1]]
            if uiMapId and uiMapId > 0 then
                callback(uiMapId, entrance[2] / 100, entrance[3] / 100)
            end
        end
        return
    end
    if not x or x < 0 or y < 0 then return end
    local uiMapId = areaIdToUiMapId[areaId]
    if uiMapId and uiMapId > 0 then
        callback(uiMapId, x / 100, y / 100)
    end
end

---Resolves a whole QuestieDB spawn list ({[areaId] = {{x, y, phase?}, ...}}).
function Zones:ResolveSpawns(spawns, callback)
    if type(spawns) ~= "table" then return end
    for areaId, points in pairs(spawns) do
        if type(points) == "table" then
            local entrances = DungeonEntrances(areaId)
            if entrances then
                -- One marker per entrance, however many spawns are inside.
                self:Resolve(areaId, -1, -1, callback)
            else
                for _, point in ipairs(points) do
                    self:Resolve(areaId, point[1], point[2], callback)
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Display geometry: which data maps are drawn on the open map, and where.
---------------------------------------------------------------------------------------------------
local MAP_TYPE_CONTINENT = Enum and Enum.UIMapType and Enum.UIMapType.Continent or 2
local MAP_TYPE_ZONE = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
local MAP_TYPE_DUNGEON = Enum and Enum.UIMapType and Enum.UIMapType.Dungeon or 4
local MAP_TYPE_MICRO = Enum and Enum.UIMapType and Enum.UIMapType.Micro or 5
local MAP_TYPE_ORPHAN = Enum and Enum.UIMapType and Enum.UIMapType.Orphan or 6

local layoutCache = {}

---Returns the open map's type and a list of {uiMapId, left, top, width, height}: the map itself
---(identity transform) plus every zone/city drawn inside it, with its rectangle on the open map.
function Zones:GetLayout(displayMapId)
    local cached = layoutCache[displayMapId]
    if cached then return cached.mapType, cached.sources end

    local info = C_Map.GetMapInfo(displayMapId)
    local mapType = info and info.mapType
    local sources = {}
    if mapType == MAP_TYPE_CONTINENT or mapType == MAP_TYPE_ZONE or mapType == MAP_TYPE_MICRO
        or mapType == MAP_TYPE_DUNGEON or mapType == MAP_TYPE_ORPHAN then
        sources[1] = { displayMapId, 0, 0, 1, 1 }
        if mapType == MAP_TYPE_CONTINENT or mapType == MAP_TYPE_ZONE then
            local children = C_Map.GetMapChildrenInfo(displayMapId, nil, true) or {}
            for _, child in ipairs(children) do
                if child.mapType == MAP_TYPE_ZONE or child.mapType == MAP_TYPE_MICRO then
                    local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(child.mapID, displayMapId)
                    if minX and maxX and maxX > minX and maxY > minY and (maxX - minX) < 1.5 then
                        sources[#sources + 1] = { child.mapID, minX, minY, maxX - minX, maxY - minY }
                    end
                end
            end
        end
    end
    layoutCache[displayMapId] = { mapType = mapType, sources = sources }
    return mapType, sources
end

Zones.MAP_TYPE_CONTINENT = MAP_TYPE_CONTINENT
