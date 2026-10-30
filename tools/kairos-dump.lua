-- Reads Kairos data outside the game.
--
--   lua tools/kairos-dump.lua probes   <SavedVariables\Kairos.lua> [n]   probe matrix, last n runs
--   lua tools/kairos-dump.lua fights   <SavedVariables\Kairos.lua> [n]   timelines of the last n fights
--   lua tools/kairos-dump.lua summary  <SavedVariables\Kairos.lua>       one line per fight
--   lua tools/kairos-dump.lua events   <SavedVariables\Kairos.lua>       every recorder entry, raw GetTime()
--   lua tools/kairos-dump.lua combatlog <WoWCombatLog.txt> <SavedVariables\Kairos.lua> [player]
--       the player's casts and tracked aura stack changes from a combat log
--
-- SavedVariables live in _retail_\WTF\Account\<ACCOUNT>\SavedVariables\Kairos.lua and
-- are written on /reload, logout or exit. Combat logs live in _retail_\Logs.
-- Runs on Lua 5.1 or later (the LuaLS binary works as an interpreter).

local root = arg and arg[0] and arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]+$") or "."

local function fail(message)
    io.stderr:write(message, "\n")
    os.exit(1)
end

local function loadDB(path)
    local chunk, err = loadfile(path)
    if not chunk then fail("Can't read " .. tostring(path) .. ": " .. tostring(err)) end
    chunk()
    if type(KairosDB) ~= "table" then fail(path .. " has no KairosDB") end
    return KairosDB
end

-- Loads Probe.lua against a minimal namespace to reuse its decoder and report.
local function loadProbe()
    local ns = { Signal = {} }
    function ns:NewModule(name)
        local module = {}
        self[name] = module
        return module
    end
    local chunk = assert(loadfile(root .. "/Kairos/Probe.lua"))
    chunk("Kairos", ns)
    return ns.Probe
end

local function entries(db)
    local flight = db.flight or {}
    local list, out = flight.entries or {}, {}
    local count, pos = #list, flight.pos or #list
    for i = 1, count do out[i] = list[(pos + i - 1) % count + 1] end
    return out
end

--- Spell names from probe keys ("spell Arcane Blast (30451) ...") and learned aura IDs.
local function spellNames(db, Probe)
    local names = {}
    for _, run in ipairs(db.probes or {}) do
        for _, entry in ipairs(run.results or {}) do
            local key = Probe.Decode(entry)
            local name, id = key:match("^spell (.-) %((%d+)%)")
            if name and name ~= "GCD" then names[tonumber(id)] = name end
        end
    end
    for name, id in pairs((db.global or {}).auraIDs or {}) do names[id] = names[id] or name end
    return names
end

local function fights(db)
    local list, current = {}, nil
    for _, entry in ipairs(entries(db)) do
        if entry.k == "fight" and entry.phase == "start" then
            current = { start = entry, events = {} }
            list[#list + 1] = current
        elseif entry.k == "fight" and entry.phase == "after" then
            -- Readable auras just after the fight (older data put them on the end marker).
            local last = list[#list]
            if last and not last.after then last.after = entry end
        elseif current then
            if entry.k == "fight" and entry.phase == "end" then
                current.finish = entry
                current = nil
            else
                current.events[#current.events + 1] = entry
            end
        end
    end
    return list
end

local function auraList(auras)
    local parts = {}
    for name, stacks in pairs(auras or {}) do
        if stacks and stacks > 0 then parts[#parts + 1] = ("%s %d"):format(name, stacks) end
    end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, ", ") or "none"
end

local function spellLabel(names, id)
    if not id then return "?" end
    return names[id] and ("%s (%d)"):format(names[id], id) or tostring(id)
end

local function describe(entry, names)
    local k = entry.k
    if k == "cast" then return "cast   " .. spellLabel(names, entry.spell) end
    if k == "ac" then return "charges " .. tostring(entry.n) end
    if k == "glow" then return ("glow   %s %s"):format(spellLabel(names, entry.spell), entry.on and "on" or "off") end
    if k == "pick" then
        return ("pick   %s %s%s"):format(entry.src or "?", spellLabel(names, entry.spell),
            entry.why and (" (" .. entry.why .. ")") or "")
    end
    if k == "aura" then
        if entry.op == "add" then
            return "aura   added " .. (entry.spell and spellLabel(names, entry.spell) or "(secret)")
        end
        if entry.op then return ("aura   %s %s"):format(entry.name or "?", entry.op) end
        return ("aura   %s = %s"):format(entry.name or "?", tostring(entry.n))
    end
    return k
end

local commands = {}

function commands.probes(path, count)
    local Probe = loadProbe()
    print(Probe.Report(loadDB(path).probes or {}, tonumber(count) or 8))
end

function commands.fights(path, count)
    local db = loadDB(path)
    local names = spellNames(db, loadProbe())
    local list = fights(db)
    count = tonumber(count) or 3
    for i = math.max(1, #list - count + 1), #list do
        local fight = list[i]
        local t0 = fight.start.t
        print(("## Fight %d: %s, %.1f s"):format(i, os.date("%Y-%m-%d %H:%M:%S", fight.start.at or 0),
            fight.finish and fight.finish.length or -1))
        print("before: " .. auraList(fight.start.auras) .. ", charges " .. tostring(fight.start.ac))
        for _, entry in ipairs(fight.events) do
            print(("%+7.2f  %s"):format((entry.t or t0) - t0, describe(entry, names)))
        end
        if fight.finish then
            local after = fight.after or fight.finish
            if after.auras then
                print("after:  " .. auraList(after.auras) .. ", charges " .. tostring(after.ac))
            else
                print("after:  (combat restarted before auras were readable)")
            end
            print(("aura events: %s, secret parts: %s, added: %s"):format(tostring(fight.finish.auraEvents),
                tostring(fight.finish.secret), tostring(fight.finish.added)))
        else
            print("(no end marker: still in combat when saved)")
        end
        print("")
    end
end

--- Every recorder entry with its raw GetTime(), including events between fights.
function commands.events(path)
    local db = loadDB(path)
    local names = spellNames(db, loadProbe())
    for _, entry in ipairs(entries(db)) do
        local text = describe(entry, names)
        if entry.k == "fight" then
            text = ("fight  %s %s"):format(entry.phase, entry.at and os.date("%H:%M:%S", entry.at) or "")
        elseif entry.k == "session" then
            text = ("session %s spec %s build %s"):format(tostring(entry.char), tostring(entry.spec),
                tostring(entry.build))
        end
        print(("%.3f  %s"):format(entry.t or 0, text))
    end
end

function commands.summary(path)
    local db = loadDB(path)
    print("| # | Start | Length | Casts | Salvo before | Salvo after | Salvo updates | Aura events | Secret parts |")
    print("|---|---|---|---|---|---|---|---|---|")
    for i, fight in ipairs(fights(db)) do
        local casts, salvoUpdates = 0, 0
        for _, entry in ipairs(fight.events) do
            if entry.k == "cast" then casts = casts + 1 end
            if entry.k == "aura" and entry.name == "Arcane Salvo" and entry.op == "upd" then
                salvoUpdates = salvoUpdates + 1
            end
        end
        local finish = fight.finish or {}
        local after = (fight.after or finish).auras or {}
        print(("| %d | %s | %.1f | %d | %s | %s | %d | %s | %s |"):format(i,
            os.date("%H:%M:%S", fight.start.at or 0), finish.length or -1, casts,
            tostring((fight.start.auras or {})["Arcane Salvo"]), tostring(after["Arcane Salvo"]),
            salvoUpdates, tostring(finish.auraEvents), tostring(finish.secret)))
    end
end

-- Splits a combat log event's CSV payload, keeping quoted commas.
local function splitCSV(text)
    local fields, pos = {}, 1
    while pos <= #text + 1 do
        if text:sub(pos, pos) == '"' then
            local close = text:find('"', pos + 1, true) or #text
            fields[#fields + 1] = text:sub(pos + 1, close - 1)
            pos = close + 2
        else
            local comma = text:find(",", pos, true) or (#text + 1)
            fields[#fields + 1] = text:sub(pos, comma - 1)
            pos = comma + 1
        end
    end
    return fields
end

local AURA_EVENTS = {
    SPELL_AURA_APPLIED = "applied", SPELL_AURA_REMOVED = "removed", SPELL_AURA_REFRESH = "refresh",
    SPELL_AURA_APPLIED_DOSE = "dose+", SPELL_AURA_REMOVED_DOSE = "dose-",
}

function commands.combatlog(logPath, svPath, player)
    local db = loadDB(svPath)
    local names = spellNames(db, loadProbe())
    local tracked = {}
    for name, id in pairs((db.global or {}).auraIDs or {}) do tracked[id] = name end
    if not player then
        for charKey in pairs(db.profiles or {}) do player = charKey:match("^[^-]+") end
    end
    if not player then fail("Pass the player name: no profile in SavedVariables") end

    local file = io.open(logPath, "r")
    if not file then fail("Can't open " .. logPath) end
    for line in file:lines() do
        local stamp, payload = line:match("^(%S+ %S+)%s%s(.*)$")
        if payload then
            local fields = splitCSV(payload)
            local event, srcName, spellID = fields[1], fields[3], tonumber(fields[10])
            local mine = srcName and srcName:sub(1, #player) == player
            if event == "SPELL_CAST_SUCCESS" and mine then
                print(stamp .. "  cast   " .. spellLabel(names, spellID))
            elseif AURA_EVENTS[event] and spellID and tracked[spellID] and mine then
                local amount = (event:find("DOSE") and fields[14]) and (" " .. fields[14]) or ""
                print(stamp .. "  aura   " .. tracked[spellID] .. " " .. AURA_EVENTS[event] .. amount)
            elseif event == "ENCOUNTER_START" or event == "ENCOUNTER_END" or event == "COMBAT_LOG_VERSION" then
                print(stamp .. "  " .. event)
            end
        end
    end
    file:close()
end

local command = arg and arg[1]
if not command or not commands[command] then
    fail("Usage: lua tools/kairos-dump.lua probes|fights|summary|events|combatlog <file> [...]")
end
commands[command](select(2, (table.unpack or unpack)(arg)))
