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
--   lua tools/kairos-dump.lua apl <WoWCombatLog.txt> <SavedVariables\Kairos.lua> <player> [from [to]] [verbose]
--       the APL on true state vs Kairos's estimates/live picks, AC and the player's casts
--       (Arcane or Demonology, chosen by the player's first own-spec cast in the log)
--   lua tools/kairos-dump.lua watch <WoWCombatLog.txt> <SavedVariables\Kairos.lua> <player> [auraID ...]
--           [from [to]] [verbose]
--       lines the recorder's watch signatures up with auras from the log (default: Overpowered
--       Missiles, Clearcasting, Arcane Soul) and reports whether any field tracks one
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

-- Per-pull cast/commit archives overlap the flight ring. Sequence IDs preserve
-- event order within coalesced frames and deduplicate that overlap.
local function replayEntries(db)
    local out, seen, order = {}, {}, 0
    local function add(e)
        if e.seq and seen[e.seq] then return end
        if e.seq then seen[e.seq] = true end
        order = order + 1
        out[#out + 1] = { entry = e, order = order }
    end
    for _, e in ipairs(entries(db)) do add(e) end
    for _, pull in ipairs((db.flight or {}).pulls or {}) do
        for _, e in ipairs(pull.entries or {}) do add(e) end
    end
    table.sort(out, function(a, b)
        if a.entry.seq and b.entry.seq then return a.entry.seq < b.entry.seq end
        if a.entry.seq then return false end
        if b.entry.seq then return true end
        return a.order < b.order
    end)
    local result = {}
    for _, item in ipairs(out) do result[#result + 1] = item.entry end
    return result
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
    if k == "commit" then return "commit " .. spellLabel(names, entry.spell) end
    if k == "toggle" then return ("toggle %s %s"):format(entry.key, entry.on and "on" or "off") end
    if k == "ac" then return "charges " .. tostring(entry.n) end
    if k == "shards" then return "shards " .. tostring(entry.n) end
    if k == "demo" then return ("demo   imps~%s after %s"):format(tostring(entry.imps), spellLabel(names, entry.spell)) end
    if k == "cp" then return ("cumpow %s %s"):format(tostring(entry.n), tostring(entry.why)) end
    if k == "watch" then return ("watch  %s %s"):format(spellLabel(names, entry.spell), tostring(entry.sig)) end
    if k == "salvo" then
        return ("salvo  %s (%s-%s) %s"):format(tostring(entry.v), tostring(entry.lo), tostring(entry.hi),
            tostring(entry.why))
    end
    if k == "glow" then return ("glow   %s %s"):format(spellLabel(names, entry.spell), entry.on and "on" or "off") end
    if k == "pick" then
        return ("pick   %s %s%s%s%s%s%s%s"):format(entry.src or "?", spellLabel(names, entry.spell),
            entry.why and (" (" .. entry.why .. ")") or "", entry.label and (" " .. entry.label) or "",
            entry.observed and " (observation only)" or "",
            entry.offGcd and (" NOW " .. spellLabel(names, entry.offGcd)) or "",
            entry.fields and (" unknown: " .. entry.fields) or "",
            entry.paired and (" + " .. spellLabel(names, entry.paired)) or "")
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

--- Calls fn(clock, fields) for every combat log event the player is the source of.
local function eachPlayerEvent(logPath, player, fn)
    local file = io.open(logPath, "r") or fail("Can't open " .. logPath)
    for line in file:lines() do
        local stamp, payload = line:match("^(%S+ %S+)%s%s(.*)$")
        local fields = payload and splitCSV(payload)
        if fields and fields[3] and fields[3]:sub(1, #player) == player then fn(clock(stamp), fields) end
    end
    file:close()
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
        "Specs/MageArcane/CumulativePower.lua", "Specs/MageArcane/APL.lua", "Specs/MageArcane/State.lua" })
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
    local boltProcAt, boltPreviouslyUp

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
    local function record(t, spellID, atSuccess)
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
            atSuccess = atSuccess,
        }
        local result = records[#records]
        -- Barrage generates Bolt before its CAST_SUCCESS is printed (2-5 ms in
        -- build 70575). The proc is an effect of this press, not an available
        -- alternative before the press. Keep it in global state for later casts.
        if spellID == S.BARRAGE and boltProcAt and not boltPreviouslyUp
            and t >= boltProcAt and t - boltProcAt <= 0.01 then
            for _, key in ipairs({ "trueState", "estState", "salvoOnlyState", "powerOnlyState" }) do
                result[key].boltReady = false
            end
            result.barrageProc = true
        end
        return result
    end

    local function each(fn) eachPlayerEvent(logPath, player, fn) end

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
            if id == A.BOLT_PROC and event == "SPELL_AURA_APPLIED" then
                boltProcAt, boltPreviouslyUp = t, up[id] == true
            end
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
            started[id] = record(t, id, false) or true
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
            local decision = started[id]
            if onGcd[id] and not decision then decision = record(t, id, true) end
            if type(decision) == "table" then decision.successIndex = #successes end
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
    return records, anchors, APL, successes, ns.ArcaneState
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
        if not r.referenceUnavailable and (not filter or filter(r)) then
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
    local best, bestHits, tried = nil, 0, {}
    -- The last recorded cast may have happened after logging stopped (buffs, food,
    -- or another character). Seed several recent successes rather than fail outright.
    for i = #recCasts, math.max(1, #recCasts - 31), -1 do
        local probe = recCasts[i]
        for _, r in ipairs(records) do
            if r.spell == probe.spell then
                local offset = r.t - probe.t
                local key = math.floor(offset * 1000)
                if not tried[key] then
                    tried[key] = true
                    local hits = matches(offset)
                    if hits > bestHits then best, bestHits = offset, hits end
                end
            end
        end
    end
    return best, bestHits, #recCasts
end

local function recorderForPlayer(recorded, player, spec)
    local hasSessions = false
    for _, e in ipairs(recorded) do
        if (e.k == "session" and e.char) or e.context then hasSessions = true; break end
    end
    if not hasSessions then return recorded end -- legacy fixtures/recordings
    local out, active = {}, false
    local function matches(char, specID)
        return char and (char == player or char:sub(1, #player + 1) == player .. "-") and specID == spec
    end
    for _, e in ipairs(recorded) do
        if e.k == "session" then
            active = matches(e.char, e.spec)
        end
        local belongs = active
        if e.context then belongs = matches(e.context.char, e.context.spec) end
        if belongs then out[#out + 1] = e end
    end
    return out
end

-- Compare true-state APL picks, the two-estimator replay, recorded live/AC picks and
-- player casts. Only the live column measures the complete in-game adapter; the
-- estimator-only columns hold every other field at the log's reconstructed truth.
local function aplArcane(logPath, svPath, player, ...)
    local from, to, verbose = parseOptions(...)
    local all, _, APL, successes, adapter = replayArcane(logPath, player)
    local records = inWindow(all, from, to)
    local S = APL.SPELLS
    local db = loadDB(svPath)
    local names = spellNames(db, loadProbe())
    names[S.BOLT] = names[S.BOLT] or "Prismatic Bolt"

    local recorded = recorderForPlayer(replayEntries(db), player, 62)
    local offset, hits, recCasts = alignRecorder(recorded, successes)
    -- GetTime can coalesce consecutive successes into one frame. Match each log
    -- success to its ordered recorder cast so a post-cast pick cannot be scored
    -- as the recommendation for that cast, even if its aligned clock is a few ms early.
    local boundaries, lastCastIndex = {}, 0
    if offset then
        for successIndex, success in ipairs(successes) do
            local best, distance
            for index = lastCastIndex + 1, #recorded do
                local entry = recorded[index]
                if entry.t and entry.t + offset > success.t + 0.15 then break end
                if entry.k == "cast" and entry.spell == success.spell and entry.t then
                    local delta = math.abs(entry.t + offset - success.t)
                    if delta <= 0.15 and (not distance or delta < distance) then best, distance = index, delta end
                end
            end
            if best then boundaries[successIndex], lastCastIndex = best, best end
        end
    end
    local picks, hasKairos = {}, false
    local lastSession
    for index, e in ipairs(recorded) do
        local session = e.context and e.context.session
        if offset and e.t and (e.k == "session" or (session and session ~= lastSession)) then
            picks[#picks + 1] = { t = e.t + offset, index = index, reset = true }
        end
        if session then lastSession = session end
        if e.k == "pick" and e.t and offset then
            picks[#picks + 1] = { t = e.t + offset, spell = e.spell, src = e.src,
                label = e.label, observed = e.observed, index = index,
                immediate = e.immediate, queued = e.queued, diagnostic = e.diagnostic, context = e.context }
            if e.src == "kairos" then hasKairos = true end
        end
    end
    local function pickAt(record)
        local found, ac
        local boundary = record.successIndex and boundaries[record.successIndex]
        local success = boundary and recorded[boundary]
        if success and success.context then
            local sample = success
            -- Prefer the pre-refresh START snapshot, including channels whose
            -- START precedes SUCCEEDED in the same frame.
            for i = boundary - 1, 1, -1 do
                local e = recorded[i]
                if e.context and e.context.session ~= success.context.session then break end
                if e.t + offset < record.t - 0.15 then break end
                if e.k == "commit" and e.spell == record.spell
                    and math.abs(e.t + offset - record.t) <= 0.15 then sample = e; break end
            end
            if not record.atSuccess and sample == success then
                return nil, nil, sample.context, "missing cast-start snapshot"
            end
            local rec = sample.recommendation
            if not rec then return nil, nil, sample.context, "no commitment snapshot" end
            local d = rec.diagnostic
            if sample == success and d and d.cast and d.cast.channel and d.cast.startsAt
                and d.cast.spellID == record.spell
                and math.abs(d.cast.startsAt + offset - record.t) <= 0.15 then
                return nil, rec.ac, sample.context, "post-channel forecast"
            end
            return rec, rec.ac, sample.context
        end
        for _, p in ipairs(picks) do
            if boundary and p.index >= boundary then break end
            -- Instants/channels decide on success: recorder order is the boundary.
            -- Cast-time spells still decide at START, before their success boundary.
            if not (boundary and record.atSuccess) and p.t >= record.t - 0.001 then break end
            if p.reset then found, ac = nil, nil
            else
                if not p.observed then found = p end
                if p.src == "ac" then ac = p.spell end
                if p.src == "none" then ac = nil end
            end
        end
        if found and found.context then return nil, nil, found.context, "unmatched commitment" end
        return found, ac
    end
    -- Prismatic Bolt replaces Arcane Blast on the bar while its proc is up: same button.
    local function button(spell, s)
        if spell == S.BLAST and s.boltReady then return S.BOLT end
        return spell
    end

    local stationary = { [S.BLAST] = true, [S.BOLT] = true, [S.SURGE] = true,
        [S.PULSE] = true, [S.MISSILES] = true }
    local function contextualState(s, context, diagnostic)
        -- Change availability only. Never replace combat-log aura/resource truth
        -- with the estimates being tested.
        local out = {}
        for k, v in pairs(s) do
            if type(v) == "table" then
                out[k] = {}
                for key, value in pairs(v) do out[k][key] = value end
            else out[k] = v end
        end
        if context.cooldowns == false then
            for id, tag in pairs(adapter.TAGS) do
                if tag == "cooldowns" then out.ready[id], out.remains[id] = false, adapter.COOLDOWNS[id] end
            end
        end
        if diagnostic then
            local projected = diagnostic.projected
            if projected.orbInFlight then out.known[S.ORB] = false end
            if diagnostic.movement.value == true then
                for id in pairs(stationary) do
                    if id ~= S.MISSILES or not projected.talent.slipstream then out.known[id] = false end
                end
            end
        end
        return out
    end

    local captured, legacy, unscored, immediate = 0, 0, 0, 0
    local function evaluate(s)
        return APL:Evaluate(s) or { spellID = 0, label = "no available action", line = "no available action" }
    end
    for _, r in ipairs(records) do
        local live, ac, context, reason = pickAt(r)
        local diagnostic = live and live.diagnostic
        if context then
            captured = captured + 1
            if type(context.cooldowns) ~= "boolean" then reason = "missing cooldown history" end
            if not diagnostic or diagnostic.v ~= 1 or not diagnostic.projected
                or not diagnostic.current or not diagnostic.movement then
                reason = reason or "missing evaluation state"
            elseif diagnostic.movement.state == "unknown" then
                reason = reason or "unknown movement"
            elseif diagnostic.movement.value and diagnostic.projected.talent.unknown.slipstream then
                reason = reason or "unknown Slipstream"
            end
            if not reason then
                for _, key in ipairs({ "trueState", "estState", "salvoOnlyState", "powerOnlyState" }) do
                    r[key] = contextualState(r[key], context, diagnostic)
                end
            end
        elseif live then legacy = legacy + 1 end
        if reason then unscored = unscored + 1; live, ac = nil, nil end
        r.aplTrue = evaluate(r.trueState)
        r.aplEst = evaluate(r.estState)
        r.aplSalvoOnly = evaluate(r.salvoOnlyState)
        r.aplPowerOnly = evaluate(r.powerOnlyState)
        if r.aplTrue.spellID == 0 then
            r.referenceUnavailable = true
            if not reason then unscored = unscored + 1 end
            reason, live, ac = reason or "no reference action under captured availability", nil, nil
        end
        r.unscored, r.diagnostic = reason, diagnostic
        r.ac = ac and button(ac, r.trueState) or nil
        r.live = live and live.src == "kairos" and button(live.spell, r.trueState) or nil
        r.display = live and button(live.spell, r.trueState) or nil
        r.fallback = live and live.src == "ac" or false
        r.liveLabel = live and live.src == "kairos" and live.label or nil
        r.liveFields = live and live.fields
        r.cast = button(r.spell, r.trueState)
        r.gcdDisplay = r.display
        if live and live.src == "kairos" then
            hasKairos = true
            if live.immediate then
                immediate = immediate + 1
                r.gcdDisplay = button(live.queued, r.trueState)
                local off = APL:OffGcd(r.trueState)
                r.cueMatches = off ~= nil and off.spellID == live.spell
            end
            if diagnostic and diagnostic.v == 1 then
                local ok, result = pcall(adapter.EvaluateStates, adapter,
                    diagnostic.projected, diagnostic.current, diagnostic.movement)
                r.reproduced = ok and not result.uncertain and result.spellID == live.spell
                    and result.label == live.label and (result.immediate or false) == (live.immediate or false)
                    and result.pairedID == live.paired
                    and (not result.queuedUncertain and result.queuedID or nil) == live.queued
            end
        end
    end

    print(("APL replay: %s (SimC %s), %d decisions"):format(APL.name, APL.simc, #records))
    print(("  recorder aligned: %d/%d casts (offset %s)"):format(hits, recCasts, tostring(offset)))
    print(("  commitment context: %d captured, %d unscored, %d legacy samples"):format(captured, unscored, legacy))
    local gaps, gapOrder = {}, {}
    for _, r in ipairs(records) do
        if r.unscored then
            local gap = gaps[r.unscored]
            if not gap then
                gap = { n = 0, first = r.t }
                gaps[r.unscored] = gap
                gapOrder[#gapOrder + 1] = r.unscored
            end
            gap.n, gap.last = gap.n + 1, r.t
        end
    end
    for _, reason in ipairs(gapOrder) do
        local gap = gaps[reason]
        print(("    unscored %d: %s (%s to %s)"):format(gap.n, reason,
            clockText(gap.first), clockText(gap.last)))
    end
    if legacy > 0 then
        print("  Legacy samples assume cooldowns enabled and stationary availability; timing/context remain provisional.")
    end
    if captured > 0 then
        print("  Reference uses captured toggle/movement/Orb availability with aura/resource truth at the press.")
        print("  Captured evaluation reproduction checks the adapter; it is not future-state or DPS agreement.")
    end
    if (db.flight or {}).retiredPulls then
        print(("  Pull archive: %d retained, %d older pulls retired."):format(
            #db.flight.pulls, db.flight.retiredPulls))
    end
    local dropped = 0
    for _, pull in ipairs((db.flight or {}).pulls or {}) do dropped = dropped + (pull.dropped or 0) end
    if dropped > 0 then print(("  Pull archives reached their entry limit: %d entries omitted."):format(dropped)) end
    local barrageProcs = 0
    for _, r in ipairs(records) do if r.barrageProc then barrageProcs = barrageProcs + 1 end end
    if barrageProcs > 0 then print(("  Barrage-generated Bolt procs excluded from pre-press state: %d"):format(barrageProcs)) end
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
    if hasKairos then
        print("  Kairos in game           = APL on true state: " .. rate(records, function(r)
            return r.live == r.aplTrue.spellID end, function(r) return r.live ~= nil end))
        print("    Display including AC fallback:              " .. rate(records, function(r)
            return r.display == r.aplTrue.spellID end, function(r) return r.display ~= nil end))
        print("    AC fallback share of recorded decisions:    " .. rate(records, function(r)
            return r.fallback end, function(r) return r.display ~= nil end))
        if immediate > 0 then
            print("    GCD slot (queued behind NOW cues):          " .. rate(records, function(r)
                return r.gcdDisplay == r.aplTrue.spellID end, function(r) return r.gcdDisplay ~= nil end))
            print("    Immediate cue = off-GCD reference:          " .. rate(records, function(r)
                return r.cueMatches end, function(r) return r.cueMatches ~= nil end))
        end
        if captured > 0 then
            print("    Captured evaluation reproduced:             " .. rate(records, function(r)
                return r.reproduced end, function(r) return r.reproduced ~= nil end))
        end
    end
    print("  Player cast              = APL on true state: " .. rate(records, function(r)
        return r.cast == r.aplTrue.spellID end))

    -- By the APL line (and clause) that decided the true-state pick.
    local lines, order = {}, {}
    for _, r in ipairs(records) do
        if not r.referenceUnavailable then
            local key = r.aplTrue.label or r.aplTrue.line
            local row = lines[key]
            if not row then
                row = { n = 0, kairos = 0, liveN = 0, live = 0, acN = 0, ac = 0,
                    player = 0, acInstead = {}, source = r.aplTrue.line }
                lines[key] = row
                order[#order + 1] = key
            end
            row.n = row.n + 1
            if r.aplEst.spellID == r.aplTrue.spellID then row.kairos = row.kairos + 1 end
            if r.cast == r.aplTrue.spellID then row.player = row.player + 1 end
            if r.live then
                row.liveN = row.liveN + 1
                if r.live == r.aplTrue.spellID then row.live = row.live + 1 end
            end
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
    end
    table.sort(order, function(a, b) return lines[a].n > lines[b].n end)
    print("")
    print("| APL line (true state) | Decisions | Kairos estimates agree |"
        .. (hasKairos and " In game agrees |" or "") .. " AC agrees | Player agrees | AC picked instead |")
    print("|---|---|---|" .. (hasKairos and "---|" or "") .. "---|---|---|")
    for _, key in ipairs(order) do
        local row = lines[key]
        local instead = {}
        for label, n in pairs(row.acInstead) do instead[#instead + 1] = { label, n } end
        table.sort(instead, function(a, b) return a[2] > b[2] end)
        local parts = {}
        for i = 1, math.min(3, #instead) do parts[i] = ("%s %d"):format(instead[i][1], instead[i][2]) end
        local live = hasKairos and (" %d/%d |"):format(row.live, row.liveN) or ""
        print(("| %s | %d | %d |%s %d/%d | %d | %s |"):format(key, row.n, row.kairos, live,
            row.ac, row.acN, row.player, table.concat(parts, ", ")))
    end
    -- What each label stands for: "(i/k)" is the i-th top-level `|` clause of its line.
    local legend, seen = {}, {}
    for _, key in ipairs(order) do
        local base = key:gsub(" %(%d+/%d+%)$", "")
        if not seen[base] and lines[key].source ~= key then
            seen[base] = true
            legend[#legend + 1] = ("  %s: %s"):format(base, lines[key].source)
        end
    end
    if #legend > 0 then
        print("")
        print(table.concat(legend, "\n"))
    end

    if verbose then
        print("")
        for _, r in ipairs(records) do
            print(("%s  salvo %2d (est %2d)  APL %-16s Kairos %-16s AC %-16s cast %-16s %s"):format(clockText(r.t),
                r.truth, r.est, names[r.aplTrue.spellID] or r.aplTrue.spellID,
                names[r.aplEst.spellID] or r.aplEst.spellID, r.ac and (names[r.ac] or r.ac) or "-",
                names[r.cast] or r.cast, r.aplTrue.label or r.aplTrue.line))
            if hasKairos then
                print(("    in game: %s  %s"):format(r.live and (names[r.live] or r.live) or "AC/unrecorded",
                    r.liveLabel or ""))
                if r.unscored then print("    unscored: " .. r.unscored) end
                local d = r.diagnostic
                if d and d.projected and d.movement then
                    local s = d.projected
                    print(("    captured: eval %.3f -> %.3f, moving %s (%s), cast %s, Salvo %s, CP %s, Bolt %s"):format(
                        d.now, s.t, tostring(d.movement.value), d.movement.state,
                        d.cast and tostring(d.cast.spellID) or "none", tostring(s.salvo),
                        tostring(s.cumulativePower), tostring(s.boltReady)))
                    print(("    gates: Surge %s, Touch %s, Orb pending %s; unknown: %s"):format(
                        tostring(s.ready[S.SURGE]), tostring(s.ready[S.TOUCH]), tostring(s.orbInFlight),
                        r.liveFields or "none on evaluated path"))
                end
            end
        end
    end
end

-- Combat log replay for Demonology -------------------------------------------------

local D = {
    CORE = 264173, INFERNAL_PROC = 433891, RUINATION_PROC = 433885, ARGUS = 1276166,
    IMP_NPCS = { ["55659"] = true, ["143622"] = true }, -- Wild Imp, Inner Demons' Wild Imp
    SHARDS = "7", ENEMY_WINDOW = 3, IMP_SLACK = 0.1, GCD = 1.5, GAP = 6, SHARD_SLACK = 0.15,
    PRESS_WINDOW = 1, -- seconds a keypress (SENT) may precede the logged decision
    -- The addon's own talent check, used only when no captured diagnostic names talents.
    DIABOLIST_EVIDENCE = { [433891] = true, [433885] = true, [434506] = true, [434635] = true },
}

local function npcID(guid) return guid and guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-") end

--- Replays the player's Demonology events: true shards (energize gains and known
--- costs, seeded per fight from the client's first traced reading), Demonic Core stacks, Diabolist procs, Dominion of Argus, cooldowns from
--- casts, and Wild Imps from their summons and their own last events (offline only:
--- an imp counts until its death or last action). The live imp estimate replays the
--- same casts through Specs/WarlockDemonology/Demons.lua.
local function replayDemonology(logPath, player, options)
    local haste, toHellAndBack = options.haste, options.toHellAndBack
    local ns = loadAddonFiles({ "Core/Signal.lua", "Specs/WarlockDemonology/Spec.lua",
        "Specs/WarlockDemonology/Demons.lua", "Specs/WarlockDemonology/APL.lua",
        "Specs/WarlockDemonology/State.lua" })
    local APL, adapter, Demons = ns.DemonologyAPL, ns.DemonologyState, ns.DemonologyDemons
    local S, onGcd = APL.SPELLS, ns.Specs[266].onGcd
    -- 12.1.5 casts log only mana; these shard costs match the client's traced readings.
    local COSTS = { [S.HAND] = 3, [S.IMP_LORD] = 1, [S.RAVAGER] = 1, [S.DOOMGUARD] = 1 }

    -- Pass 1: the player's GUID, what they cast, and every Wild Imp's lifetime.
    local playerGUID, seen, imps, casts = nil, { casts = {}, auras = {} }, {}, {}
    local function each(fn)
        local file = io.open(logPath, "r") or fail("Can't open " .. logPath)
        for line in file:lines() do
            local stamp, payload = line:match("^(%S+ %S+)%s%s(.*)$")
            if payload then fn(clock(stamp), splitCSV(payload)) end
        end
        file:close()
    end
    local function mine(f) return f[3] and f[3]:sub(1, #player) == player end
    each(function(t, f)
        local event, id = f[1], tonumber(f[10])
        if mine(f) then
            playerGUID = playerGUID or f[2]
            if event == "SPELL_CAST_SUCCESS" and id then
                seen.casts[id] = true
                casts[#casts + 1] = { t = t, spell = id }
            end
            if event == "SPELL_AURA_APPLIED" and id then seen.auras[id] = true end
            if event == "SPELL_SUMMON" and D.IMP_NPCS[npcID(f[6])] then
                imps[f[6]] = { born = t, last = t }
            end
        end
        -- An imp's own actions bound its life; its last Firebolt lands ~1 s after it despawns.
        local imp = imps[f[2]]
        if imp and not event:find("_DAMAGE$") and not event:find("_MISSED$") then imp.last = math.max(imp.last, t) end
        imp = (event == "UNIT_DIED" or event == "UNIT_DESTROYED") and imps[f[6]]
        if imp then imp.died = imp.died or t end
    end)
    local function trueImps(t)
        local n = 0
        for _, imp in pairs(imps) do
            if imp.born <= t and t < (imp.died or imp.last + D.IMP_SLACK) then n = n + 1 end
        end
        return n
    end

    local shards, core, up, lastCast, enemies = 0, 0, {}, {}, {}
    local doomguardCut, prevGcd, records, successes, started = 0, nil, {}, {}, {}
    -- The log never states shards (12.1.5 casts carry only mana), so the count held at
    -- a pull is unknown. Seed it from the client's first traced reading after each gap;
    -- the later readings then validate the energize/cost model (see the timeline).
    -- Without a trace, decisions count from the first energize and may start offset.
    local readings, combat, counts = {}, {}, {}
    if options.readings then readings, combat, counts = options.readings(casts) end
    local nextReading, nextCombat, nextCount, truthKnown, needSeed, lastMine = 1, 1, 1, false, true, nil
    local timeline, lastGain, ownGains = {}, nil, 0
    local function setShards(t, value)
        shards = math.max(0, math.min(5, value))
        if timeline[#timeline] and timeline[#timeline].t == t then timeline[#timeline].n = shards
        else timeline[#timeline + 1] = { t = t, n = shards } end
    end
    local function enemyCount(t)
        local n = 0
        for _, last in pairs(enemies) do if t - last <= D.ENEMY_WINDOW then n = n + 1 end end
        return math.max(n, 1)
    end
    local function state(t, impCount)
        local s = { unknown = {}, known = { unknown = {} }, talent = { unknown = {} }, ready = {}, remains = {},
            castable = {}, chargesFractional = {}, t = t, fightRemains = 300, prevGcd = prevGcd,
            shards = math.floor(shards + 1e-6), coreStacks = core, coreUp = core > 0,
            infernalReady = up[D.INFERNAL_PROC] == true, ruinationReady = up[D.RUINATION_PROC] == true,
            argusUp = up[D.ARGUS] == true, imps = impCount, enemies = enemyCount(t), gcdMax = D.GCD }
        for id, base in pairs(adapter.COOLDOWNS) do
            local finish = lastCast[id] and lastCast[id] + base - (id == S.DOOMGUARD and doomguardCut or 0)
            s.remains[id] = finish and math.max(0, finish - t) or 0
            s.ready[id] = s.remains[id] == 0
        end
        for _, id in pairs(S) do
            s.known[id] = seen.casts[id] or false
            s.castable[id] = true
        end
        s.talent.diabolic_ritual = false
        for id in pairs(D.DIABOLIST_EVIDENCE) do
            if seen.casts[id] or seen.auras[id] then s.talent.diabolic_ritual = true end
        end
        return s
    end
    local function record(t, spellID, atSuccess)
        if not truthKnown then return end
        local r = { t = t, spell = spellID, atSuccess = atSuccess, truthImps = trueImps(t),
            estImps = Demons:Count(t), shards = math.floor(shards + 1e-6) }
        r.trueState, r.estState = state(t, r.truthImps), state(t, r.estImps)
        records[#records + 1] = r
        return r
    end

    -- Pass 2: the replay.
    each(function(t, f)
        local event, id = f[1], tonumber(f[10])
        -- Imps and Dreadstalkers grant Core, and pets can energize shards, so anything
        -- landing on the player counts. Casts and damage must be the player's own.
        local onMe = playerGUID and f[6] == playerGUID
        if not mine(f) and not onMe then return end
        -- Shards regenerate between pulls: reseed at each client combat start, or after
        -- a gap in the player's casts when there's no trace (auras never go quiet).
        if mine(f) and event:find("^SPELL_CAST_") then
            if #combat == 0 and lastMine and t - lastMine >= D.GAP then needSeed = true end
            lastMine = t
        end
        -- The client's combat changes pause and resume the imp estimate's clock.
        while combat[nextCombat] and combat[nextCombat].t < t do
            Demons:SetCombat(combat[nextCombat].on, combat[nextCombat].t)
            if combat[nextCombat].on then needSeed = true end
            nextCombat = nextCombat + 1
        end
        -- Readable Implosion cast counts (traced by the spell watch) anchor the estimate,
        -- as the live adapter does on every refresh where the count isn't secret.
        while counts[nextCount] and counts[nextCount].t < t do
            if seen.casts[S.IMPLOSION] then Demons:Anchor(counts[nextCount].t, counts[nextCount].n, haste or 0) end
            nextCount = nextCount + 1
        end
        -- Seed from the last reading before the pull: shards regenerate between pulls.
        local seeded = false
        while readings[nextReading] and readings[nextReading].t < t do
            local reading = readings[nextReading]
            if needSeed and reading.t >= t - D.GAP then
                setShards(reading.t, reading.n)
                truthKnown, seeded = true, true
            end
            nextReading = nextReading + 1
        end
        if seeded then needSeed = false end
        if event:find("^SPELL_AURA") and onMe and id then
            if id == D.CORE then
                if event == "SPELL_AURA_APPLIED" then core = 1
                elseif event == "SPELL_AURA_REMOVED" then core = 0
                elseif event:find("DOSE$") then core = tonumber(f[14]) or core end
            end
            if event == "SPELL_AURA_APPLIED" then up[id] = true
            elseif event == "SPELL_AURA_REMOVED" then up[id] = nil end
        elseif event == "SPELL_ENERGIZE" and onMe and f[#f - 1] == D.SHARDS then
            -- 12.1.5 logs shard amounts ("1.0000") against a fragment maximum (50). The
            -- amount is the effective gain; the next field is what the cap wasted.
            local gain = tonumber(f[#f - 3]) or 0
            setShards(t, shards + gain)
            lastGain = { t = t, name = f[11], gain = gain }
            if #readings == 0 then truthKnown = true end
        elseif not mine(f) then
            return
        elseif event == "SPELL_DAMAGE" or event == "SPELL_PERIODIC_DAMAGE" then
            if f[6] and f[6]:find("^Creature") then enemies[f[6]] = t end
        elseif event == "SPELL_CAST_START" and id and onGcd[id] then
            started[id] = record(t, id, false) or true
        elseif event == "SPELL_CAST_FAILED" and id then
            started[id] = nil
        elseif event == "SPELL_CAST_SUCCESS" and id then
            successes[#successes + 1] = { t = t, spell = id }
            local decision = started[id]
            if onGcd[id] and not decision then
                -- An instant Demonbolt's +2 is logged ~1 ms before its own success (12.1.5,
                -- under its energize ID 280127): an effect of the press, not state before it.
                local own = lastGain and lastGain.name == f[11] and t - lastGain.t <= 0.01 and lastGain.gain or 0
                local held = shards
                shards = math.max(0, shards - own)
                decision = record(t, id, true)
                shards = held
                if own > 0 and decision then ownGains = ownGains + 1 end
            end
            if type(decision) == "table" then decision.successIndex = #successes end
            started[id] = nil
            if COSTS[id] then setShards(t, shards - COSTS[id]) end
            if id == S.DEMONBOLT and core > 0 then doomguardCut = doomguardCut + 3 end
            if id == S.DOOMGUARD then doomguardCut = 0 end
            Demons:OnCast(id, t, haste or 0, toHellAndBack)
            lastCast[id] = t
            if onGcd[id] then prevGcd = id end
        end
    end)
    return records, APL, successes, adapter, timeline, ownGains
end

--- The adapter's own route: shared leveling priorities until a hero tree unlocks.
local function pickDemonology(adapter, s)
    local pick, uncertain = adapter:Pick(s)
    return pick or { spellID = 0, label = "no available action", line = "no available action" }, uncertain
end

local function aplDemonology(logPath, svPath, player, ...)
    local from, to, verbose = parseOptions(...)
    local db = loadDB(svPath)
    local recorded = recorderForPlayer(replayEntries(db), player, 266)
    -- The live imp estimate uses cached haste; recover it from a captured GCD.
    local haste, toHellAndBack
    for _, e in ipairs(recorded) do
        local p = e.recommendation and e.recommendation.diagnostic and e.recommendation.diagnostic.projected
        if p and type(p.gcdMax) == "number" and p.gcdMax > 0.75 and not (p.unknown or {}).gcdMax then
            haste = (1.5 / p.gcdMax - 1) * 100
        end
        if p and p.talent then toHellAndBack = p.talent.to_hell_and_back == true end
    end
    -- The client's traced shard readings on the log's clock, aligned by the log's casts.
    local clientReadings, combat, counts = {}, {}, {}
    local function readings(casts)
        local offset = alignRecorder(recorded, casts)
        if not offset then return clientReadings, combat, counts end
        for _, e in ipairs(recorded) do
            local n = e.k == "shards" and e.n or (e.k == "fight" and e.shards)
            if type(n) == "number" and e.t then clientReadings[#clientReadings + 1] = { t = e.t + offset, n = n } end
            if e.k == "fight" and e.t and (e.phase == "start" or e.phase == "end") then
                combat[#combat + 1] = { t = e.t + offset, on = e.phase == "start" }
            end
            local count = e.k == "watch" and e.spell == 196277 and e.t and tonumber((e.sig or ""):match(" cc=(%d+)"))
            if count then counts[#counts + 1] = { t = e.t + offset, n = count } end
        end
        table.sort(clientReadings, function(a, b) return a.t < b.t end)
        table.sort(combat, function(a, b) return a.t < b.t end)
        table.sort(counts, function(a, b) return a.t < b.t end)
        return clientReadings, combat, counts
    end
    local all, APL, successes, adapter, timeline, ownGains = replayDemonology(logPath, player,
        { haste = haste, toHellAndBack = toHellAndBack, readings = readings })
    local records = inWindow(all, from, to)
    local S = APL.SPELLS
    local names = spellNames(db, loadProbe())
    for key, id in pairs(S) do names[id] = names[id] or key:sub(1, 1) .. key:sub(2):lower() end

    local offset, hits, recCasts = alignRecorder(recorded, successes)
    local boundaries, lastCastIndex = {}, 0
    if offset then
        for successIndex, success in ipairs(successes) do
            local best, distance
            for index = lastCastIndex + 1, #recorded do
                local entry = recorded[index]
                if entry.t and entry.t + offset > success.t + 0.15 then break end
                if entry.k == "cast" and entry.spell == success.spell and entry.t then
                    local delta = math.abs(entry.t + offset - success.t)
                    if delta <= 0.15 and (not distance or delta < distance) then best, distance = index, delta end
                end
            end
            if best then boundaries[successIndex], lastCastIndex = best, best end
        end
    end
    -- The keypress (SENT) snapshot holds the instruction on screen at the press. Older
    -- captures fall back to START for cast-time spells and the cast entry for instants,
    -- which a refresh after the press's own GCD began can already have advanced.
    local function sampleAt(r)
        local boundary = r.successIndex and boundaries[r.successIndex]
        local success = boundary and recorded[boundary]
        if not success then return nil, "no aligned recorder cast" end
        local start
        for i = boundary - 1, 1, -1 do
            local e = recorded[i]
            if e.t + offset < r.t - D.PRESS_WINDOW then break end
            if e.spell == r.spell and e.k == "sent" then return e end
            if e.spell == r.spell and e.k == "commit" and not start and e.t + offset >= r.t - 0.15 then start = e end
        end
        if r.atSuccess then return success end
        return start, not start and "missing cast-start snapshot" or nil
    end
    -- A reading validates the log model if the model holds its value within the slack:
    -- a cast's cost and its client update land milliseconds apart on the two clocks.
    local function modelMatches(reading)
        -- The client reports whole shards; the log can carry fragments (a capped 1.8).
        local value, matched = nil, false
        for _, point in ipairs(timeline) do
            if point.t > reading.t + D.SHARD_SLACK then break end
            local whole = math.floor(point.n + 1e-6)
            if point.t >= reading.t - D.SHARD_SLACK and whole == reading.n then matched = true end
            value = whole
        end
        return matched or value == reading.n
    end
    local checked = {}
    for _, reading in ipairs(clientReadings) do
        if (not from or reading.t >= from) and (not to or reading.t <= to) and timeline[1]
            and reading.t > timeline[1].t then
            checked[#checked + 1] = { ok = modelMatches(reading), t = reading.t, n = reading.n }
        end
    end

    -- Display changes (pick entries) on the log's clock, for snapshots that postdate the press.
    local stream = {}
    if offset then
        for _, e in ipairs(recorded) do
            if e.k == "pick" and e.t then stream[#stream + 1] = { t = e.t + offset, entry = e } end
        end
    end
    local function onScreenAt(t)
        local shown, ac
        for _, item in ipairs(stream) do
            if item.t >= t then break end
            local e = item.entry
            if not e.observed then shown = e end
            if e.src == "ac" then ac = e.spell elseif e.src == "none" then ac = nil end
        end
        return shown, ac
    end

    local captured, unscored, gaps, gapOrder, recovered = 0, 0, {}, {}, 0
    local talentSource = "inferred from the log (diabolic_ritual only)"
    for _, r in ipairs(records) do
        local sample, reason = sampleAt(r)
        local rec = sample and sample.recommendation
        if sample and not rec then reason = "no commitment snapshot" end
        if sample and not sample.combat then reason = "out of combat" end
        local d = rec and rec.diagnostic
        if d and d.v == 1 and d.projected then
            captured = captured + 1
            -- Talents, learned spells, haste and movement come from the live client.
            -- Aura, resource, imp and cooldown truth stays with the log.
            local p = d.projected
            for _, key in ipairs({ "trueState", "estState" }) do
                local s = r[key]
                s.talent, s.known, s.castable, s.gcdMax = p.talent, p.known, p.castable, p.gcdMax
                if sample.context and sample.context.cooldowns == false then
                    for id, tag in pairs(adapter.TAGS) do
                        if tag == "cooldowns" then s.ready[id], s.remains[id] = false, adapter.COOLDOWNS[id] end
                    end
                end
            end
            talentSource = "captured from the live client"
        end
        r.aplTrue = pickDemonology(adapter, r.trueState)
        r.aplEst = pickDemonology(adapter, r.estState)
        -- The live adapter sees Core presence, not its count, while the aura is secret.
        if r.trueState.coreUp then
            r.trueState.unknown.coreStacks = true
            local _, uncertain = adapter:Pick(r.trueState)
            r.trueState.unknown.coreStacks = nil
            r.coreForcesAC = uncertain
        else
            r.coreForcesAC = false
        end
        if r.aplTrue.spellID == 0 then r.referenceUnavailable, reason = true, reason or "no reference action" end
        if reason then
            unscored = unscored + 1
            local gap = gaps[reason]
            if not gap then gap = { n = 0, first = r.t }; gaps[reason] = gap; gapOrder[#gapOrder + 1] = reason end
            gap.n, gap.last = gap.n + 1, r.t
        end
        if rec and not reason then
            r.display = rec.spell
            r.live = rec.src == "kairos" and rec.spell or nil
            r.fallback = rec.src == "ac"
            r.liveLabel = r.live and rec.label
            r.ac = rec.ac
            r.liveFields = rec.fields
            if r.live and d and d.v == 1 then
                local ok, again = pcall(adapter.Pick, adapter, d.projected)
                r.reproduced = ok and again ~= nil and again.spellID == rec.spell
                r.rerun = ok and again and again.spellID or nil
            end
        end
        r.diagnostic = d
        r.sampled = sample and sample.k
        -- A snapshot projected well past the press was evaluated after its GCD began
        -- (captures before the recorder's OnScreen). Grade the display stream's pick
        -- from just before that GCD started instead.
        r.postPress = d and d.projected and offset and d.projected.t + offset > r.t + 0.2 or false
        if r.postPress and r.display and not d.cast then
            local shown, ac = onScreenAt(d.projected.t + offset - (d.projected.gcdMax or D.GCD))
            if shown then
                recovered = recovered + 1
                r.display, r.fallback, r.ac = shown.spell, shown.src == "ac", ac
                r.live = shown.src == "kairos" and shown.spell or nil
                r.liveLabel, r.liveFields = r.live and shown.label, shown.fields
                r.sampled, r.postPress = "stream", false
            end
        end
    end

    print(("APL replay: %s (SimC %s), %d decisions"):format(APL.name, APL.simc, #records))
    print(("  recorder aligned: %d/%d casts (offset %s)"):format(hits, recCasts, tostring(offset)))
    print(("  commitment context: %d captured, %d unscored"):format(captured, unscored))
    for _, reason in ipairs(gapOrder) do
        local gap = gaps[reason]
        print(("    unscored %d: %s (%s to %s)"):format(gap.n, reason, clockText(gap.first), clockText(gap.last)))
    end
    print("  Talents and learned spells: " .. talentSource .. ".")
    print("  Reference: shards from energize/costs (seeded per pull from the client), Core stacks,")
    print("  procs, Argus, cooldowns from casts, Wild Imps from their own events; enemies are")
    print("  targets hit in the last 3 s.")
    print("  Log shard model = client reading:             " .. rate(checked, function(c) return c.ok end))
    if ownGains > 0 then print(("  Shards a press generated itself, excluded from its state: %d"):format(ownGains)) end
    print("  Imp estimate = log imps:                      " .. rate(records, function(r)
        return r.estImps == r.truthImps end))
    print("    within one imp:                             " .. rate(records, function(r)
        return math.abs(r.estImps - r.truthImps) <= 1 end))
    print("  Kairos imp estimate      = APL on true state: " .. rate(records, function(r)
        return r.aplEst.spellID == r.aplTrue.spellID end))
    print("  Hidden Core count would force AC:             " .. rate(records, function(r)
        return r.coreForcesAC end))
    print("  Assisted Combat          = APL on true state: " .. rate(records, function(r)
        return r.ac == r.aplTrue.spellID end, function(r) return r.ac ~= nil end))
    print("  Kairos in game           = APL on true state: " .. rate(records, function(r)
        return r.live == r.aplTrue.spellID end, function(r) return r.live ~= nil end))
    print("    Display including AC fallback:              " .. rate(records, function(r)
        return r.display == r.aplTrue.spellID end, function(r) return r.display ~= nil end))
    print("    AC fallback share of recorded decisions:    " .. rate(records, function(r)
        return r.fallback end, function(r) return r.display ~= nil end))
    local sent, sampled = 0, 0
    for _, r in ipairs(records) do
        if r.display then sampled = sampled + 1 end
        if r.display and r.sampled == "sent" then sent = sent + 1 end
    end
    print(("    snapshots at the keypress: %d of %d"):format(sent, sampled))
    if recovered > 0 then
        print(("    post-press snapshots replaced by the pick shown before the GCD: %d"):format(recovered))
    end
    print("    Taken before the press's GCD began:         " .. rate(records, function(r)
        return r.live == r.aplTrue.spellID end, function(r) return r.live ~= nil and not r.postPress end))
    print("    Taken after it (next-GCD forecast):         " .. rate(records, function(r)
        return r.live == r.aplTrue.spellID end, function(r) return r.live ~= nil and r.postPress end))
    print("    Captured evaluation reproduced:             " .. rate(records, function(r)
        return r.reproduced end, function(r) return r.reproduced ~= nil end))
    print("    Current adapter on captured inputs = APL:   " .. rate(records, function(r)
        return r.rerun == r.aplTrue.spellID end, function(r) return r.reproduced ~= nil end))
    print("  Player cast              = APL on true state: " .. rate(records, function(r)
        return r.spell == r.aplTrue.spellID end))

    local lines, order = {}, {}
    for _, r in ipairs(records) do
        if not r.referenceUnavailable then
            local key = r.aplTrue.label or r.aplTrue.line
            local row = lines[key]
            if not row then
                row = { n = 0, est = 0, liveN = 0, live = 0, acN = 0, ac = 0, player = 0, instead = {} }
                lines[key], order[#order + 1] = row, key
            end
            row.n = row.n + 1
            if r.aplEst.spellID == r.aplTrue.spellID then row.est = row.est + 1 end
            if r.spell == r.aplTrue.spellID then row.player = row.player + 1 end
            if r.live then
                row.liveN = row.liveN + 1
                if r.live == r.aplTrue.spellID then row.live = row.live + 1
                else
                    local label = names[r.live] or tostring(r.live)
                    row.instead[label] = (row.instead[label] or 0) + 1
                end
            end
            if r.ac then
                row.acN = row.acN + 1
                if r.ac == r.aplTrue.spellID then row.ac = row.ac + 1 end
            end
        end
    end
    table.sort(order, function(a, b) return lines[a].n > lines[b].n end)
    print("")
    print("| APL line (true state) | Decisions | Imp estimate agrees | In game agrees | AC agrees | Player agrees | In game picked instead |")
    print("|---|---|---|---|---|---|---|")
    for _, key in ipairs(order) do
        local row = lines[key]
        local instead = {}
        for label, n in pairs(row.instead) do instead[#instead + 1] = { label, n } end
        table.sort(instead, function(a, b) return a[2] > b[2] end)
        local parts = {}
        for i = 1, math.min(3, #instead) do parts[i] = ("%s %d"):format(instead[i][1], instead[i][2]) end
        print(("| %s | %d | %d | %d/%d | %d/%d | %d | %s |"):format(key, row.n, row.est, row.live, row.liveN,
            row.ac, row.acN, row.player, table.concat(parts, ", ")))
    end

    if verbose then
        for _, c in ipairs(checked) do
            if not c.ok then
                local model
                for _, point in ipairs(timeline) do if point.t <= c.t then model = point.n else break end end
                print(("%s  shard model %s, client %d"):format(clockText(c.t), tostring(model), c.n))
            end
        end
    end
    for _, r in ipairs(records) do
        local wrong = r.live and r.live ~= r.aplTrue.spellID
        if verbose or wrong or (r.reproduced == false) then
            local s = r.trueState
            print(("%s  APL %-14s in game %-14s AC %-14s cast %-14s %s"):format(clockText(r.t),
                names[r.aplTrue.spellID] or r.aplTrue.spellID,
                r.live and (names[r.live] or r.live) or (r.fallback and "AC" or "-"),
                r.ac and (names[r.ac] or r.ac) or "-", names[r.spell] or r.spell, r.aplTrue.label or ""))
            if r.reproduced == false then
                print(("    current adapter on the captured inputs: %s"):format(names[r.rerun] or tostring(r.rerun)))
            end
            print(("    log: shards %d, core %d, imps %d (est %d), infernal %s, ruination %s, argus %s, enemies %d"):format(
                s.shards, s.coreStacks, r.truthImps, r.estImps, tostring(s.infernalReady),
                tostring(s.ruinationReady), tostring(s.argusUp), s.enemies))
            local d = r.diagnostic
            if d and d.projected then
                local p = d.projected
                print(("    captured: eval %.3f -> %.3f, moving %s, cast %s, shards %s, core %s%s, imps %s, enemies %s; label %s; unknown: %s"):format(
                    d.now, p.t, tostring(d.movement and d.movement.value), d.cast and tostring(d.cast.spellID) or "none",
                    tostring(p.shards), tostring(p.coreStacks), p.unknown and p.unknown.coreStacks and "?" or "",
                    tostring(p.imps), tostring(p.enemies), tostring(r.liveLabel), r.liveFields or "none"))
            end
        end
    end
end

function commands.apl(logPath, svPath, player, ...)
    player = player or fail("Usage: apl <WoWCombatLog.txt> <Kairos.lua> <player> [from [to]] [verbose]")
    -- The player's first own-spec cast picks the replay.
    local demonology = { [105174] = true, [264178] = true, [104316] = true, [265187] = true, [686] = true }
    local file = io.open(logPath, "r") or fail("Can't open " .. logPath)
    local spec
    for line in file:lines() do
        local payload = line:match("^%S+ %S+%s%s(SPELL_CAST_SUCCESS,.*)$")
        local fields = payload and splitCSV(payload)
        if fields and fields[3] and fields[3]:sub(1, #player) == player then
            local id = tonumber(fields[10])
            if demonology[id] then spec = 266; break end
            if id == 30451 or id == 44425 or id == 5143 then spec = 62; break end
        end
    end
    file:close()
    if spec == 266 then return aplDemonology(logPath, svPath, player, ...) end
    return aplArcane(logPath, svPath, player, ...)
end

--- Auras the watch is compared with by default: Overpowered Missiles (secret in combat),
--- plus Clearcasting and Arcane Soul as controls (the Missiles glow tracks Clearcasting).
local WATCH_AURAS = { 1277009, A.CLEARCASTING, A.SOUL }
local WATCH_SLACK = 0.25 -- seconds between an aura change and a field change that count as one

--- Parses a watch signature ("ov=5143 tex=136096 dc=S ...") into its fields, in order.
local function watchFields(sig)
    local order, values = {}, {}
    for key, value in sig:gmatch("(%w+)=(%S*)") do
        order[#order + 1] = key
        values[key] = value
    end
    return order, values
end

-- Lines the recorder's `watch` signatures (Data/Trace.lua) up with auras on the player
-- from the combat log, field by field, over the time spent in fights: does a field change
-- when the aura changes, and does its value tell whether the aura is up?
function commands.watch(logPath, svPath, player, ...)
    player = player or fail("Usage: watch <WoWCombatLog.txt> <Kairos.lua> <player> [auraID ...] [from [to]] [verbose]")
    local auraIDs, options = {}, {}
    for _, option in ipairs({ ... }) do
        if option:match("^%d+$") then auraIDs[#auraIDs + 1] = tonumber(option) else options[#options + 1] = option end
    end
    if #auraIDs == 0 then auraIDs = WATCH_AURAS end
    local from, to, verbose = parseOptions((table.unpack or unpack)(options))

    local wanted, auraNames, changes, casts = {}, {}, {}, {}
    for _, id in ipairs(auraIDs) do wanted[id], changes[id] = true, {} end
    eachPlayerEvent(logPath, player, function(t, f)
        local event, id = f[1], tonumber(f[10])
        if event == "SPELL_CAST_SUCCESS" and id then
            casts[#casts + 1] = { t = t, spell = id }
        elseif id and wanted[id] and f[7] and f[7]:sub(1, #player) == player
            and (event == "SPELL_AURA_APPLIED" or event == "SPELL_AURA_REMOVED") then
            auraNames[id] = f[11]
            changes[id][#changes[id] + 1] = { t = t, up = event == "SPELL_AURA_APPLIED" }
        end
    end)

    local db = loadDB(svPath)
    local names = spellNames(db, loadProbe())
    local recorded = entries(db)
    local offset, hits, recCasts = alignRecorder(recorded, casts)
    if not offset then fail("No recorder casts to align with the log") end

    -- Watch signatures per spell, and the fights, on the log's clock.
    local watches, spellOrder, fightSpans, open = {}, {}, {}, nil
    for _, e in ipairs(recorded) do
        local t = e.t and e.t + offset
        if e.k == "watch" and t and e.sig then
            if not watches[e.spell] then
                watches[e.spell] = {}
                spellOrder[#spellOrder + 1] = e.spell
            end
            local order, values = watchFields(e.sig)
            local list = watches[e.spell]
            list[#list + 1] = { t = t, sig = e.sig, order = order, values = values }
        elseif e.k == "fight" and e.phase == "start" and t then
            open = t
        elseif e.k == "fight" and e.phase == "end" and t and open then
            fightSpans[#fightSpans + 1] = { open, t }
            open = nil
        end
    end
    if #spellOrder == 0 then fail("No watch entries in " .. svPath) end

    --- Seconds of [a, b] spent in fights, inside the from/to window.
    local function fightTime(a, b)
        a, b = math.max(a, from or a), math.min(b, to or b)
        local total = 0
        for _, span in ipairs(fightSpans) do
            local lo, hi = math.max(a, span[1]), math.min(b, span[2])
            if hi > lo then total = total + hi - lo end
        end
        return total
    end
    local function inFight(t) return fightTime(t - 0.001, t + 0.001) > 0 end
    local function auraUp(id, t)
        local list, up = changes[id], nil
        for _, c in ipairs(list) do
            if c.t > t then break end
            up = c.up
        end
        if up == nil then return list[1] ~= nil and not list[1].up end
        return up
    end
    local function near(list, t)
        for _, item in ipairs(list) do
            if math.abs(item.t - t) <= WATCH_SLACK then return true end
        end
        return false
    end

    print(("Watch replay: recorder aligned %d/%d casts (offset %s)"):format(hits, recCasts, tostring(offset)))

    for _, spell in ipairs(spellOrder) do
        local list = watches[spell]
        -- Watched: in a fight and the from/to window, from the spell's first signature to
        -- the last fight end.
        local first, last = list[1].t, fightSpans[#fightSpans] and fightSpans[#fightSpans][2] or list[#list].t
        local function watched(t)
            return t >= first and t <= last and (not from or t >= from) and (not to or t <= to) and inFight(t)
        end
        local total = fightTime(first, last)
        local shownIn = 0
        for _, w in ipairs(list) do if watched(w.t) then shownIn = shownIn + 1 end end
        print("")
        print(("%s: %d signatures, %d in fights, %.1f s of fight time watched"):format(spellLabel(names, spell),
            #list, shownIn, total))
        for _, id in ipairs(auraIDs) do
            local n, upTime, auraList = 0, 0, changes[id]
            for i, c in ipairs(auraList) do
                if watched(c.t) then n = n + 1 end
                if c.up then
                    local nextT = auraList[i + 1] and auraList[i + 1].t or last
                    upTime = upTime + fightTime(math.max(c.t, first), math.min(nextT, last))
                end
            end
            print(("  %s (%d): %d changes, up %.1f s"):format(auraNames[id] or "?", id, n, upTime))
        end
        print("")
        print("Each aura cell: aura changes with a field change within 0.25 s, field changes with an aura")
        print("change within 0.25 s, and how often the field's value gives the aura's state (time-weighted,")
        print("best mapping of value to up or down; in brackets, always guessing the more common state).")
        print("")
        local header, rule = { "| Field | Values in fights" }, { "|---|---" }
        for _, id in ipairs(auraIDs) do
            header[#header + 1] = auraNames[id] or tostring(id)
            rule[#rule + 1] = "---"
        end
        print(table.concat(header, " | ") .. " |")
        print(table.concat(rule, "|") .. "|")

        local tracking = {}
        for _, field in ipairs(list[1].order) do
            -- Value timeline and change times of this field.
            local fieldChanges, seen, seenOrder = {}, {}, {}
            for i, w in ipairs(list) do
                local value = w.values[field]
                if i > 1 and value ~= list[i - 1].values[field] and watched(w.t) then
                    fieldChanges[#fieldChanges + 1] = { t = w.t }
                end
                if watched(w.t) and not seen[value] then
                    seen[value] = true
                    seenOrder[#seenOrder + 1] = value == "" and '""' or value
                end
            end
            local row = { "| " .. field, table.concat(seenOrder, ", ") }
            for _, id in ipairs(auraIDs) do
                local auraChanges, matched, ownMatched, n = {}, 0, 0, 0
                for _, c in ipairs(changes[id]) do
                    if watched(c.t) then
                        n = n + 1
                        auraChanges[#auraChanges + 1] = c
                        if near(fieldChanges, c.t) then matched = matched + 1 end
                    end
                end
                for _, c in ipairs(fieldChanges) do
                    if near(auraChanges, c.t) then ownMatched = ownMatched + 1 end
                end
                -- Time-weighted value-vs-state table over every interval between breakpoints.
                local points = { first, last }
                for _, w in ipairs(list) do points[#points + 1] = w.t end
                for _, c in ipairs(changes[id]) do points[#points + 1] = c.t end
                for _, span in ipairs(fightSpans) do
                    points[#points + 1] = span[1]
                    points[#points + 1] = span[2]
                end
                table.sort(points)
                local byValue, upTotal = {}, 0
                for i = 1, #points - 1 do
                    local a, b = points[i], points[i + 1]
                    local length = (a >= first and b <= last) and fightTime(a, b) or 0
                    if length > 0 then
                        local mid, value = (a + b) / 2, nil
                        for _, w in ipairs(list) do
                            if w.t > mid then break end
                            value = w.values[field]
                        end
                        local up = auraUp(id, mid)
                        local cell = byValue[value or "?"] or { [true] = 0, [false] = 0 }
                        byValue[value or "?"] = cell
                        cell[up] = cell[up] + length
                        if up then upTotal = upTotal + length end
                    end
                end
                local right = 0
                for _, cell in pairs(byValue) do right = right + math.max(cell[true], cell[false]) end
                local accuracy = total > 0 and right / total or 0
                local base = total > 0 and math.max(upTotal, total - upTotal) / total or 0
                row[#row + 1] = ("%d/%d, %d/%d, %.0f%% (%.0f%%)"):format(matched, n, ownMatched, #fieldChanges,
                    100 * accuracy, 100 * base)
                if n > 0 and matched >= 0.8 * n and #fieldChanges > 0 and ownMatched >= 0.8 * #fieldChanges
                    and accuracy >= 0.9 and accuracy > base then
                    tracking[#tracking + 1] = ("%s tracks %s"):format(field, auraNames[id] or tostring(id))
                end
            end
            print(table.concat(row, " | ") .. " |")
        end
        print("")
        print("Tracking: " .. (#tracking > 0 and table.concat(tracking, "; ") or "no field tracks any of these auras"))

        if verbose then
            print("")
            local timeline = {}
            for _, w in ipairs(list) do timeline[#timeline + 1] = { t = w.t, text = "watch  " .. w.sig } end
            for _, id in ipairs(auraIDs) do
                for _, c in ipairs(changes[id]) do
                    timeline[#timeline + 1] = { t = c.t, text = ("aura   %s %s"):format(auraNames[id] or id,
                        c.up and "applied" or "removed") }
                end
            end
            table.sort(timeline, function(a, b) return a.t < b.t end)
            for _, item in ipairs(timeline) do
                if item.t >= first - 1 and item.t <= last + 1 and (not from or item.t >= from)
                    and (not to or item.t <= to) then
                    print(("%s %s %s"):format(clockText(item.t), inFight(item.t) and " " or "*", item.text))
                end
            end
        end
    end
end

local command = arg and arg[1]
if not command or not commands[command] then
    fail("Usage: lua tools/kairos-dump.lua probes|fights|summary|events|combatlog|salvo|apl|watch <file> [...]")
end
commands[command](select(2, (table.unpack or unpack)(arg)))
