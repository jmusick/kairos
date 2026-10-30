-- Reads Kairos data outside the game.
--
--   lua tools/kairos-dump.lua probes   <SavedVariables\Kairos.lua> [n]   probe matrix, last n runs
--   lua tools/kairos-dump.lua fights   <SavedVariables\Kairos.lua> [n]   timelines of the last n fights
--   lua tools/kairos-dump.lua summary  <SavedVariables\Kairos.lua>       one line per fight
--   lua tools/kairos-dump.lua events   <SavedVariables\Kairos.lua>       every recorder entry, raw GetTime()
--   lua tools/kairos-dump.lua combatlog <WoWCombatLog.txt> <SavedVariables\Kairos.lua> [player]
--       the player's casts and tracked aura stack changes from a combat log
--   lua tools/kairos-dump.lua salvo <WoWCombatLog.txt> <player> [from HH:MM:SS [to HH:MM:SS]] [verbose]
--       replays the log through Kairos/Salvo.lua and scores the estimate against true stacks
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
    if k == "salvo" then
        return ("salvo  %s (%s-%s) %s"):format(tostring(entry.v), tostring(entry.lo), tostring(entry.hi),
            tostring(entry.why))
    end
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

-- Replays a combat log through Kairos/Salvo.lua and scores the estimate against the
-- log's true Arcane Salvo stacks at every cast (each cast is a decision point).
-- The Barrage glow is synthesized from the log: lit while true Salvo is 25 or Arcane Soul
-- is up, which the 12.1.5 trace confirmed (13 of 13 glow changes). True stacks are fed
-- only at the start and after gaps (standing in for the out-of-combat reads in game).
function commands.salvo(logPath, player, ...)
    -- Optional: start and end times (HH:MM:SS, log-local) to score one session, and "verbose".
    local from, to, verbose
    for _, option in ipairs({ ... }) do
        if option == "verbose" then
            verbose = true
        else
            local h, m, s = option:match("^(%d+):(%d+):(%d+)$")
            if not h then fail("Unknown option " .. option .. ": expected HH:MM:SS or verbose") end
            local t = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
            if from then to = t else from = t end
        end
    end
    local ns = {}
    function ns:NewModule(name)
        local module = {}
        self[name] = module
        return module
    end
    assert(loadfile(root .. "/Kairos/Signal.lua"))("Kairos", ns)
    assert(loadfile(root .. "/Kairos/Salvo.lua"))("Kairos", ns)
    local Salvo = ns.Salvo
    player = player or fail("Pass the player name (the start of the combat log name)")

    local SALVO, SOUL, MISSILE_TICK, GAP = "1242974", "451038", "7268", 6
    local truth, soul, lit, truthKnown = 0, false, false, false
    local lastEvent, lastTick, channelStart = nil, nil, nil
    local decisions, anchors = {}, 0

    local function clock(stamp)
        local h, m, s = stamp:match(" (%d+):(%d+):([%d.]+)")
        return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
    end
    local function setGlow(t)
        local on = truth >= 25 or soul
        if on ~= lit then
            lit = on
            Salvo:OnGlow(Salvo.BARRAGE, on, t)
        end
    end

    local file = io.open(logPath, "r") or fail("Can't open " .. logPath)
    for line in file:lines() do
        local stamp, payload = line:match("^(%S+ %S+)%s%s(.*)$")
        local fields = payload and splitCSV(payload)
        local mine = fields and fields[3] and fields[3]:sub(1, #player) == player
        if mine and ((from and clock(stamp) < from) or (to and clock(stamp) > to)) then mine = false end
        if mine then
            local t, event, spellID = clock(stamp), fields[1], fields[10]
            if truthKnown and lastEvent and t - lastEvent >= GAP then
                Salvo:OnTruth(truth)
                anchors = anchors + 1
            end
            lastEvent = t
            if spellID == SALVO and event:find("^SPELL_AURA") then
                if event == "SPELL_AURA_APPLIED" then truth = 1
                elseif event == "SPELL_AURA_REMOVED" then truth = 0
                elseif event:find("DOSE$") then truth = tonumber(fields[14]) or truth end
                if not truthKnown then
                    truthKnown = true
                    Salvo:OnTruth(truth)
                end
                setGlow(t)
            elseif spellID == SOUL and (event == "SPELL_AURA_APPLIED" or event == "SPELL_AURA_REMOVED") then
                soul = event == "SPELL_AURA_APPLIED"
                setGlow(t)
            elseif event == "SPELL_DAMAGE" and spellID == MISSILE_TICK then
                lastTick = t
            elseif event == "SPELL_CAST_SUCCESS" then
                local id = tonumber(spellID)
                if channelStart and lastTick and lastTick > channelStart then
                    Salvo:OnChannelStop(math.min(t, lastTick + 0.05))
                end
                channelStart = (id == Salvo.MISSILES) and t or nil
                if truthKnown then
                    local value, low, high = Salvo:Estimate(t)
                    decisions[#decisions + 1] = {
                        t = t, spell = id, est = value, low = low, high = high, truth = truth,
                    }
                end
                Salvo:OnCast(id, t)
                -- The log removes Salvo a few ms after the Barrage that consumed it.
                if id == Salvo.BARRAGE and not soul then truth = 0 end
            end
        end
    end
    file:close()

    local function rate(test, filter)
        local agree, total = 0, 0
        for _, d in ipairs(decisions) do
            if not filter or filter(d) then
                total = total + 1
                if test(d) then agree = agree + 1 end
            end
        end
        return total > 0 and ("%d/%d (%.0f%%)"):format(agree, total, 100 * agree / total) or "n/a"
    end
    local err, maxErr = 0, 0
    for _, d in ipairs(decisions) do
        local e = math.abs(d.est - d.truth)
        err, maxErr = err + e, math.max(maxErr, e)
    end
    local function same(n) return function(d) return (d.est >= n) == (d.truth >= n) end end
    local nearTwelve = function(d) return d.truth >= 6 and d.truth <= 18 end
    local missilesOrBarrage = function(d) return d.spell == Salvo.MISSILES or d.spell == Salvo.BARRAGE end

    print(("Salvo replay: %d decisions (casts), %d gap re-anchors"):format(#decisions, anchors))
    print(("  mean abs error %.2f, max %d"):format(#decisions > 0 and err / #decisions or 0, maxErr))
    print("  same side of 12:          " .. rate(same(12)))
    print("    true stacks 6 to 18:    " .. rate(same(12), nearTwelve))
    print("    at Missiles or Barrage: " .. rate(same(12), missilesOrBarrage))
    print("  same side of 9 (>8):      " .. rate(same(9)))
    print("  same answer for =25:      " .. rate(same(25)))
    print("  truth inside low..high:   " .. rate(function(d) return d.truth >= d.low and d.truth <= d.high end))
    for _, d in ipairs(decisions) do
        local wrong = (d.est >= 12) ~= (d.truth >= 12) or (d.est >= 25) ~= (d.truth >= 25)
        if verbose or wrong then
            local h = math.floor(d.t / 3600)
            local m = math.floor(d.t % 3600 / 60)
            print(("  %02d:%02d:%06.3f  %-8s est %2d (%2d-%2d)  true %2d%s"):format(h, m, d.t % 60, tostring(d.spell),
                d.est, d.low, d.high, d.truth, wrong and "  <- wrong side" or ""))
        end
    end
end

local command = arg and arg[1]
if not command or not commands[command] then
    fail("Usage: lua tools/kairos-dump.lua probes|fights|summary|events|combatlog|salvo <file> [...]")
end
commands[command](select(2, (table.unpack or unpack)(arg)))
