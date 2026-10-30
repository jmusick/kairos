-- Reads Kairos data outside the game.
--
--   lua tools/kairos-dump.lua probes   <SavedVariables\Kairos.lua> [n]   probe matrix, last n runs
--   lua tools/kairos-dump.lua fights   <SavedVariables\Kairos.lua> [n]   timelines of the last n fights
--   lua tools/kairos-dump.lua summary  <SavedVariables\Kairos.lua>       one line per fight
--   lua tools/kairos-dump.lua events   <SavedVariables\Kairos.lua>       every recorder entry, raw GetTime()
--   lua tools/kairos-dump.lua combatlog <WoWCombatLog.txt> <SavedVariables\Kairos.lua> [player]
--       the player's casts and tracked aura stack changes from a combat log
--   lua tools/kairos-dump.lua salvo <WoWCombatLog.txt> <player> [from HH:MM:SS [to HH:MM:SS]] [verbose]
--       replays the log through Kairos/Specs/MageArcane/Salvo.lua and scores the estimate against true stacks
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
    local chunk = assert(loadfile(root .. "/Kairos/Data/Probe.lua"))
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
    if k == "cp" then return ("cumpow %s %s"):format(tostring(entry.n), tostring(entry.why)) end
    if k == "watch" then return ("watch  %s %s"):format(spellLabel(names, entry.spell), tostring(entry.sig)) end
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

-- Combat log replay for Arcane ------------------------------------------------------

local function clock(stamp)
    local h, m, s = stamp:match(" (%d+):(%d+):([%d.]+)")
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
end

local function clockText(t)
    return ("%02d:%02d:%06.3f"):format(math.floor(t / 3600), math.floor(t % 3600 / 60), t % 60)
end

--- Optional trailing arguments: a start and an end time (HH:MM:SS, log-local) that limit
--- what gets scored, and "verbose".
local function parseOptions(...)
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
    return from, to, verbose
end

--- Loads addon files against a minimal namespace (no WoW API needed at file scope).
local function loadAddonFiles(paths)
    local ns = {}
    function ns:NewModule(name)
        local module = {}
        self[name] = module
        return module
    end
    function ns:NewSpec(specID, spec)
        self.Specs = self.Specs or {}
        self.Specs[specID] = spec
        return spec
    end
    for _, path in ipairs(paths) do
        assert(loadfile(root .. "/Kairos/" .. path))("Kairos", ns)
    end
    return ns
end

local A = {
    SALVO = 1242974, CLEARCASTING = 263725, CUMULATIVE = 1296930, SOUL = 451038,
    SURGE_BUFF = 365362, BOLT_PROC = 1295942, SPHERE = 448604, MISSILE_TICK = 7268,
    TOUCH_CD = 45, SURGE_CD = 90, ORB_CHARGES = 2, ORB_RECHARGE = 20, SURGE_BUFF_LENGTH = 17.4,
    GCD = 1.2, ENEMY_WINDOW = 3, GAP = 6,
}

--- Replays every event of the player in a combat log, keeping the true Arcane state and
--- running the Salvo and Cumulative Power estimators alongside. Returns one record per
--- cast on the GCD, taken just before the cast: the true state, the estimates, and the cast.
---
--- The estimators see only what they would in game: casts, Missiles channels (ended at the
--- last missile tick), the Barrage glow (synthesized: lit while true Salvo is 25 or Arcane
--- Soul is up, as the 12.1.5 trace confirmed), and the true stacks after 6 s gaps
--- (standing in for the out-of-combat reads).
local function replayArcane(logPath, player)
    local ns = loadAddonFiles({ "Core/Signal.lua", "Specs/MageArcane/Salvo.lua",
        "Specs/MageArcane/CumulativePower.lua", "Specs/MageArcane/APL.lua" })
    local Salvo, Power, APL = ns.ArcaneSalvo, ns.ArcaneCumulativePower, ns.ArcaneAPL
    local S = APL.SPELLS
    local onGcd = {
        [S.MISSILES] = true, [S.BLAST] = true, [S.BARRAGE] = true, [S.ORB] = true, [S.PULSE] = true,
        [S.BOLT] = true, [S.SURGE] = true, [12051] = true, [1449] = true,
    }

    local stacks = { [A.SALVO] = 0, [A.CLEARCASTING] = 0, [A.CUMULATIVE] = 0 }
    local up = {}
    local surgeAt, charges, prevGcd = nil, 0, nil
    local lastCast, enemies, records = {}, {}, {}
    local orb = { n = A.ORB_CHARGES, since = nil }
    local seen = { casts = {}, auras = {} }
    local lit, truthKnown, lastEvent, lastTick, channelStart, anchors = false, false, nil, nil, nil, 0
    local started, successes = {}, {}

    local function advanceOrb(t)
        while orb.since and orb.n < A.ORB_CHARGES and t >= orb.since + A.ORB_RECHARGE do
            orb.n = orb.n + 1
            orb.since = orb.n < A.ORB_CHARGES and (orb.since + A.ORB_RECHARGE) or nil
        end
    end
    local function orbFractional(t)
        advanceOrb(t)
        return orb.n + (orb.since and (t - orb.since) / A.ORB_RECHARGE or 0)
    end
    local function setGlow(t)
        local on = stacks[A.SALVO] >= 25 or up[A.SOUL] == true
        if on ~= lit then
            lit = on
            Salvo:OnGlow(Salvo.BARRAGE, on, t)
        end
    end
    local function enemyCount(t)
        local n = 0
        for _, last in pairs(enemies) do
            if t - last <= A.ENEMY_WINDOW then n = n + 1 end
        end
        return math.max(n, 1)
    end
    local function state(t, salvo, cumulativePower)
        local touchReady = not lastCast[S.TOUCH] or t - lastCast[S.TOUCH] >= A.TOUCH_CD
        local surgeRemains = lastCast[S.SURGE] and math.max(0, lastCast[S.SURGE] + A.SURGE_CD - t) or 0
        local buffRemains = up[A.SURGE_BUFF] and surgeAt and math.max(0, surgeAt + A.SURGE_BUFF_LENGTH - t) or 0
        return {
            salvo = salvo, clearcasting = stacks[A.CLEARCASTING], charges = charges,
            cumulativePower = cumulativePower, lustrousGleam = 0,
            soul = up[A.SOUL] == true, surgeUp = up[A.SURGE_BUFF] == true, surgeRemains = buffRemains,
            boltReady = up[A.BOLT_PROC] == true, enemies = enemyCount(t), gcdMax = A.GCD, prevGcd = prevGcd,
            ready = { [S.TOUCH] = touchReady, [S.SURGE] = surgeRemains == 0 },
            remains = { [S.SURGE] = surgeRemains, [S.TOUCH] = touchReady and 0 or 1 },
            chargesFractional = { [S.ORB] = orbFractional(t) },
            known = { [S.PULSE] = seen.casts[S.PULSE] or false },
            talent = { spellfire_spheres = seen.auras[A.SPHERE] or false },
            setS2_4pc = seen.auras[A.CUMULATIVE] or false,
        }
    end

    --- A decision point: the state just before the player committed to spellID.
    local function record(t, spellID)
        if not truthKnown then return end
        local estimate, low, high = Salvo:Estimate(t)
        local power, salvo, powerTruth = Power:Estimate(t), stacks[A.SALVO], stacks[A.CUMULATIVE]
        records[#records + 1] = {
            t = t, spell = spellID, est = estimate, low = low, high = high, truth = salvo,
            power = power, powerTruth = powerTruth,
            trueState = state(t, salvo, powerTruth),
            estState = state(t, estimate, power),        -- Kairos: both estimates
            salvoOnlyState = state(t, estimate, powerTruth),
            powerOnlyState = state(t, salvo, power),
        }
    end

    local function each(fn)
        local file = io.open(logPath, "r") or fail("Can't open " .. logPath)
        for line in file:lines() do
            local stamp, payload = line:match("^(%S+ %S+)%s%s(.*)$")
            local fields = payload and splitCSV(payload)
            if fields and fields[3] and fields[3]:sub(1, #player) == player then fn(clock(stamp), fields) end
        end
        file:close()
    end

    -- Pass 1: what the character has (talents and set bonus show up as auras or casts).
    each(function(_, f)
        local id = tonumber(f[10])
        if f[1] == "SPELL_CAST_SUCCESS" and id then seen.casts[id] = true end
        if f[1] == "SPELL_AURA_APPLIED" and id then seen.auras[id] = true end
    end)

    -- Pass 2: the replay.
    each(function(t, f)
        local event, id = f[1], tonumber(f[10])
        if truthKnown and lastEvent and t - lastEvent >= A.GAP then
            Salvo:OnTruth(stacks[A.SALVO])
            Power:OnTruth(stacks[A.CUMULATIVE], t)
            anchors = anchors + 1
        end
        lastEvent = t

        local onMe = f[7] and f[7]:sub(1, #player) == player
        if event:find("^SPELL_AURA") and onMe and id then
            if stacks[id] then
                if event == "SPELL_AURA_APPLIED" then stacks[id] = 1
                elseif event == "SPELL_AURA_REMOVED" then stacks[id] = 0
                elseif event:find("DOSE$") then stacks[id] = tonumber(f[14]) or stacks[id] end
            end
            if event == "SPELL_AURA_APPLIED" then up[id] = true
            elseif event == "SPELL_AURA_REMOVED" then up[id] = nil end
            if id == A.SURGE_BUFF and event == "SPELL_AURA_APPLIED" then surgeAt = t end
            if id == A.SALVO and not truthKnown then
                truthKnown = true
                Salvo:OnTruth(stacks[A.SALVO])
                Power:OnTruth(stacks[A.CUMULATIVE], t)
            end
            if id == A.SALVO or id == A.SOUL then setGlow(t) end
        elseif event == "SPELL_ENERGIZE" and f[#f - 1] == "16" then
            charges = math.min(4, charges + (tonumber(f[#f - 3]) or 0))
        elseif event == "SPELL_DAMAGE" or event == "SPELL_PERIODIC_DAMAGE" then
            if f[6] and f[6]:find("^Creature") then enemies[f[6]] = t end
            if id == A.MISSILE_TICK then lastTick = t end
        elseif event == "SPELL_CAST_START" and id and onGcd[id] then
            record(t, id)
            started[id] = true
        elseif event == "SPELL_CAST_FAILED" and id then
            started[id] = nil
        elseif event == "SPELL_CAST_SUCCESS" and id then
            successes[#successes + 1] = { t = t, spell = id }
            if channelStart and lastTick and lastTick > channelStart then
                Salvo:OnChannelStop(math.min(t, lastTick + 0.05))
                Power:OnChannelStop(math.min(t, lastTick + 0.05))
            end
            channelStart = (id == S.MISSILES) and t or nil
            -- A cast-time spell was decided when its cast started (recorded there); its
            -- success only lands the effects. Instants and channels decide on success.
            if onGcd[id] and not started[id] then record(t, id) end
            started[id] = nil
            Salvo:OnCast(id, t)
            Power:OnCast(id, t)
            lastCast[id] = t
            if id == S.ORB then
                advanceOrb(t)
                orb.n = math.max(0, orb.n - 1)
                orb.since = orb.since or t
            end
            if id == S.BARRAGE then
                charges = 0
                -- The log removes Salvo a few ms after the Barrage that consumed it.
                if not up[A.SOUL] then stacks[A.SALVO] = 0 end
            end
            -- Likewise Cumulative Power at 8, consumed by the Blast or Bolt that lands now.
            if (id == S.BLAST or id == S.BOLT) and stacks[A.CUMULATIVE] == 8 then
                stacks[A.CUMULATIVE] = 0
            end
            if onGcd[id] then prevGcd = id end
        end
    end)
    return records, anchors, APL, successes
end

local function inWindow(records, from, to)
    local out = {}
    for _, r in ipairs(records) do
        if (not from or r.t >= from) and (not to or r.t <= to) then out[#out + 1] = r end
    end
    return out
end

local function rate(list, test, filter)
    local agree, total = 0, 0
    for _, r in ipairs(list) do
        if not filter or filter(r) then
            total = total + 1
            if test(r) then agree = agree + 1 end
        end
    end
    return total > 0 and ("%d/%d (%.0f%%)"):format(agree, total, 100 * agree / total) or "n/a", agree, total
end

-- Scores the Salvo estimator against the log's true stacks at every cast.
function commands.salvo(logPath, player, ...)
    player = player or fail("Pass the player name (the start of the combat log name)")
    local from, to, verbose = parseOptions(...)
    local all, anchors, APL = replayArcane(logPath, player)
    local records = inWindow(all, from, to)
    local S = APL.SPELLS

    local err, maxErr = 0, 0
    for _, r in ipairs(records) do
        local e = math.abs(r.est - r.truth)
        err, maxErr = err + e, math.max(maxErr, e)
    end
    local function same(n) return function(r) return (r.est >= n) == (r.truth >= n) end end
    local nearTwelve = function(r) return r.truth >= 6 and r.truth <= 18 end
    local missilesOrBarrage = function(r) return r.spell == S.MISSILES or r.spell == S.BARRAGE end

    print(("Salvo replay: %d decisions (casts), %d gap re-anchors in the whole log"):format(#records, anchors))
    print(("  mean abs error %.2f, max %d"):format(#records > 0 and err / #records or 0, maxErr))
    print("  same side of 12:          " .. rate(records, same(12)))
    print("    true stacks 6 to 18:    " .. rate(records, same(12), nearTwelve))
    print("    at Missiles or Barrage: " .. rate(records, same(12), missilesOrBarrage))
    print("  same side of 9 (>8):      " .. rate(records, same(9)))
    print("  same answer for =25:      " .. rate(records, same(25)))
    print("  truth inside low..high:   " .. rate(records, function(r)
        return r.truth >= r.low and r.truth <= r.high
    end))
    for _, r in ipairs(records) do
        local wrong = (r.est >= 12) ~= (r.truth >= 12) or (r.est >= 25) ~= (r.truth >= 25)
        if verbose or wrong then
            print(("  %s  %-8s est %2d (%2d-%2d)  true %2d%s"):format(clockText(r.t), tostring(r.spell),
                r.est, r.low, r.high, r.truth, wrong and "  <- wrong side" or ""))
        end
    end
end

--- Clock offset (log time minus recorder GetTime) that lines up the most casts. Both
--- sides are cast successes (the recorder logs UNIT_SPELLCAST_SUCCEEDED).
local function alignRecorder(entries, records)
    local recCasts, logCasts = {}, {}
    for _, e in ipairs(entries) do
        if e.k == "cast" and e.spell and e.t then recCasts[#recCasts + 1] = e end
    end
    for _, r in ipairs(records) do
        local key = r.spell .. ":" .. math.floor(r.t * 10)
        logCasts[key] = true
    end
    local function matches(offset)
        local hits = 0
        for _, e in ipairs(recCasts) do
            local tenth = math.floor((e.t + offset) * 10)
            if logCasts[e.spell .. ":" .. tenth] or logCasts[e.spell .. ":" .. (tenth - 1)]
                or logCasts[e.spell .. ":" .. (tenth + 1)] then
                hits = hits + 1
            end
        end
        return hits
    end
    local best, bestHits = nil, -1
    local probe = recCasts[#recCasts]
    if not probe then return nil, 0, 0 end
    for _, r in ipairs(records) do
        if r.spell == probe.spell then
            local hits = matches(r.t - probe.t)
            if hits > bestHits then best, bestHits = r.t - probe.t, hits end
        end
    end
    return best, bestHits, #recCasts
end

-- Compares, at every cast: Assisted Combat's pick (from the flight recorder), the APL on
-- true state, the APL with Kairos's Salvo estimate in place of the true stacks, and what
-- the player cast. Everything except Salvo comes from the log's true state, so the
-- Kairos-vs-APL gap measures the estimator alone.
function commands.apl(logPath, svPath, player, ...)
    player = player or fail("Usage: apl <WoWCombatLog.txt> <Kairos.lua> <player> [from [to]] [verbose]")
    local from, to, verbose = parseOptions(...)
    local all, _, APL, successes = replayArcane(logPath, player)
    local records = inWindow(all, from, to)
    local S = APL.SPELLS
    local db = loadDB(svPath)
    local names = spellNames(db, loadProbe())
    names[S.BOLT] = names[S.BOLT] or "Prismatic Bolt"

    local recorded = entries(db)
    local offset, hits, recCasts = alignRecorder(recorded, successes)
    local picks = {}
    for _, e in ipairs(recorded) do
        if e.k == "pick" and e.t and offset then
            picks[#picks + 1] = { t = e.t + offset, spell = e.spell, src = e.src }
        end
    end
    local function acAt(t)
        local found
        for _, p in ipairs(picks) do
            if p.t < t - 0.001 then found = p else break end
        end
        return found and found.src == "ac" and found.spell or nil
    end
    -- Prismatic Bolt replaces Arcane Blast on the bar while its proc is up: same button.
    local function button(spell, s)
        if spell == S.BLAST and s.boltReady then return S.BOLT end
        return spell
    end

    for _, r in ipairs(records) do
        r.aplTrue = APL:Evaluate(r.trueState)
        r.aplEst = APL:Evaluate(r.estState)
        r.aplSalvoOnly = APL:Evaluate(r.salvoOnlyState)
        r.aplPowerOnly = APL:Evaluate(r.powerOnlyState)
        local ac = acAt(r.t)
        r.ac = ac and button(ac, r.trueState) or nil
        r.cast = button(r.spell, r.trueState)
    end

    print(("APL replay: %s (SimC %s), %d decisions"):format(APL.name, APL.simc, #records))
    print(("  recorder aligned: %d/%d casts (offset %s)"):format(hits, recCasts, tostring(offset)))
    print("  Kairos (both estimates)  = APL on true state: " .. rate(records, function(r)
        return r.aplEst.spellID == r.aplTrue.spellID end))
    print("    Salvo estimated only:                       " .. rate(records, function(r)
        return r.aplSalvoOnly.spellID == r.aplTrue.spellID end))
    print("    Cumulative Power estimated only:            " .. rate(records, function(r)
        return r.aplPowerOnly.spellID == r.aplTrue.spellID end))
    print("    Cumulative Power estimate, same answer for =8: " .. rate(records, function(r)
        return (r.power == 8) == (r.powerTruth == 8) end))
    print("  Assisted Combat          = APL on true state: " .. rate(records, function(r)
        return r.ac == r.aplTrue.spellID end, function(r) return r.ac ~= nil end))
    print("  Player cast              = APL on true state: " .. rate(records, function(r)
        return r.cast == r.aplTrue.spellID end))

    -- By the APL line that decided the true-state pick.
    local lines, order = {}, {}
    for _, r in ipairs(records) do
        local key = r.aplTrue.line
        local row = lines[key]
        if not row then
            row = { n = 0, kairos = 0, acN = 0, ac = 0, player = 0, acInstead = {} }
            lines[key] = row
            order[#order + 1] = key
        end
        row.n = row.n + 1
        if r.aplEst.spellID == r.aplTrue.spellID then row.kairos = row.kairos + 1 end
        if r.cast == r.aplTrue.spellID then row.player = row.player + 1 end
        if r.ac then
            row.acN = row.acN + 1
            if r.ac == r.aplTrue.spellID then
                row.ac = row.ac + 1
            else
                local label = names[r.ac] or tostring(r.ac)
                row.acInstead[label] = (row.acInstead[label] or 0) + 1
            end
        end
    end
    table.sort(order, function(a, b) return lines[a].n > lines[b].n end)
    print("")
    print("| APL line (true state) | Decisions | Kairos agrees | AC agrees | Player agrees | AC picked instead |")
    print("|---|---|---|---|---|---|")
    for _, key in ipairs(order) do
        local row = lines[key]
        local instead = {}
        for label, n in pairs(row.acInstead) do instead[#instead + 1] = { label, n } end
        table.sort(instead, function(a, b) return a[2] > b[2] end)
        local parts = {}
        for i = 1, math.min(3, #instead) do parts[i] = ("%s %d"):format(instead[i][1], instead[i][2]) end
        print(("| %s | %d | %d | %d/%d | %d | %s |"):format(key, row.n, row.kairos, row.ac, row.acN, row.player,
            table.concat(parts, ", ")))
    end

    if verbose then
        print("")
        for _, r in ipairs(records) do
            print(("%s  salvo %2d (est %2d)  APL %-16s Kairos %-16s AC %-16s cast %-16s %s"):format(clockText(r.t),
                r.truth, r.est, names[r.aplTrue.spellID] or r.aplTrue.spellID,
                names[r.aplEst.spellID] or r.aplEst.spellID, r.ac and (names[r.ac] or r.ac) or "-",
                names[r.cast] or r.cast, r.aplTrue.line))
        end
    end
end

local command = arg and arg[1]
if not command or not commands[command] then
    fail("Usage: lua tools/kairos-dump.lua probes|fights|summary|events|combatlog|salvo <file> [...]")
end
commands[command](select(2, (table.unpack or unpack)(arg)))
