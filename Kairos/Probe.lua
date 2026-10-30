-- Secrecy probe (SPEC §8.1, §7.6). Records, for the current context, which reads come
-- back ok, secret, nil, erroring or missing. It runs by itself (at login, early in each
-- fight, right after each fight, and at encounter and keystone starts) and keeps runs in
-- KairosDB.probes, which tools/kairos-dump.lua reads offline. `/kairos probe` runs it by
-- hand, and `/kairos probe report` renders a copyable Markdown matrix in game.
local _, Kairos = ...
local Probe = Kairos:NewModule("Probe")
local Signal = Kairos.Signal

local issecretvalue = issecretvalue or function() return false end

-- Bump when the set of checks changes, so report columns from different builds are
-- told apart (the addon version alone doesn't change between probe edits).
-- 1: first release. 2: aura IDs. 3: aura instances and events, haste, movement, threat.
-- 4: automatic runs, compact storage, aura tracking moved to Trace.
Probe.REVISION = 4
Probe.MAX_RUNS = 40
Probe.AUTO_THROTTLE = 60
Probe.LOGIN_DELAY = 10
Probe.GCD_SPELL = 61304

-- Spec extras on top of Assisted Combat's rotation spells. Names, not IDs: several
-- Midnight spells are new, and the client resolves names for known spells and auras.
Probe.EXTRA = {
    [62] = { -- Arcane Mage (SPEC §10.2)
        spells = { "Arcane Blast", "Arcane Barrage", "Arcane Missiles", "Arcane Orb", "Arcane Pulse",
            "Arcane Explosion", "Arcane Surge", "Touch of the Magi", "Evocation", "Presence of Mind",
            "Counterspell", "Arcane Intellect" },
        buffs = { "Clearcasting", "Arcane Salvo", "Arcane Soul", "Intuition", "Arcane Surge", "Presence of Mind",
            "Prismatic Bolt", "Overpowered Missiles", "Lustrous Gleam", "Cumulative Power", "Arcane Intellect" },
        debuffs = { "Touch of the Magi" },
        powers = { "Mana", "ArcaneCharges" },
    },
}

-- Auras often have their own spell ID, different from the spell that applies them
-- (Arcane Surge casts 365350 but its buff is 365362). IDs learned in game win over these.
Probe.AURA_IDS = {
    ["Clearcasting"] = 263725,
    ["Arcane Surge"] = 365362,
    ["Touch of the Magi"] = 210824,
    ["Presence of Mind"] = 205025,
    ["Arcane Intellect"] = 1459,
    -- From the 12.1.5 combat log: both make Arcane Barrage glow, as does Salvo at 25.
    ["Arcane Soul"] = 451038,
    ["Intuition"] = 1223797,
}

local function describe(value)
    local kind = type(value)
    if kind == "number" or kind == "boolean" then return tostring(value) end
    if kind == "string" then return value:sub(1, 40) end
    return kind
end

--- Classifies pcall results: "ok" (+ value), "secret", "nil" or "error" (+ message).
function Probe.Classify(ok, ...)
    if not ok then return "error", tostring((...)):sub(1, 120) end
    for i = 1, select("#", ...) do
        if issecretvalue((select(i, ...))) then return "secret" end
    end
    local first = ...
    if first == nil then return "nil" end
    return "ok", describe(first)
end

-- Results are stored as "key\tstatus\tvalue" strings: runs happen automatically, and
-- one string per check keeps SavedVariables a fraction of the size of a table per check.
function Probe.Encode(key, status, value)
    if value == nil then return key .. "\t" .. status end
    return key .. "\t" .. status .. "\t" .. tostring(value):gsub("[\t\r\n]", " ")
end

--- key, status, value from a stored result (also reads the older table format).
function Probe.Decode(entry)
    if type(entry) == "table" then return entry.key, entry.status, entry.value end
    local key, status, value = entry:match("^(.-)\t([^\t]*)\t?(.*)$")
    return key, status, (value ~= "" and value or nil)
end

--- Decoded results as { [key] = { status, value } } plus the keys in check order.
function Probe.Results(run)
    local byKey, order = {}, {}
    for _, entry in ipairs(run.results) do
        local key, status, value = Probe.Decode(entry)
        if not byKey[key] then order[#order + 1] = key end
        byKey[key] = { status = status, value = value }
    end
    return byKey, order
end

local Run = {}
Run.__index = Run

function Run:Add(key, status, value)
    self.results[#self.results + 1] = Probe.Encode(key, status, value)
end

function Run:Check(key, fn, ...)
    if type(fn) ~= "function" then return self:Add(key, "missing") end
    self:Add(key, Probe.Classify(pcall(fn, ...)))
end

--- Calls fn(...) for an info table and checks each field separately.
function Run:CheckFields(key, fields, fn, ...)
    if type(fn) ~= "function" then return self:Add(key, "missing") end
    local ok, info = pcall(fn, ...)
    if not ok then return self:Add(key, "error", tostring(info):sub(1, 120)) end
    if issecretvalue(info) then return self:Add(key, "secret") end
    if info == nil then return self:Add(key, "nil") end
    for _, field in ipairs(fields) do
        self:Add(key .. "." .. field, Probe.Classify(pcall(function() return info[field] end)))
    end
end

local function readOr(fn, ...)
    local reading = Signal.Read(fn, ...)
    if reading.state == "known" then return reading.value end
    return reading.reason
end

local function spellIDFor(name)
    return Kairos.ResolveSpell(name)
end

function Probe:Context()
    Signal:RefreshRestrictions()
    local instanceType = readOr(function() return (select(2, IsInInstance())) end)
    local difficultyID = readOr(function() return (select(3, GetInstanceInfo())) end)
    return {
        combat = readOr(InCombatLockdown),
        restrictions = Signal:DescribeRestrictions(),
        instance = instanceType,
        difficulty = difficultyID,
        keystone = readOr(C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive),
        encounter = self.encounterActive or false,
        hasSecretRestrictions = readOr(C_Secrets and C_Secrets.HasSecretRestrictions),
    }
end

function Probe:CheckSpell(run, spellID, label)
    local key = ("spell %s (%d)"):format(label or Kairos.SpellName(spellID), spellID)
    local secrets = C_Secrets or {}
    run:Check(key .. " cooldownSecrecy", secrets.GetSpellCooldownSecrecy, spellID)
    run:CheckFields(key .. " cooldown", { "startTime", "duration", "isEnabled", "modRate" },
        C_Spell.GetSpellCooldown, spellID)
    run:CheckFields(key .. " charges", { "currentCharges", "maxCharges", "cooldownStartTime", "cooldownDuration" },
        C_Spell.GetSpellCharges, spellID)
    run:Check(key .. " usable", C_Spell.IsSpellUsable, spellID)
    run:Check(key .. " inRange(target)", C_Spell.IsSpellInRange, spellID, "target")
    run:Check(key .. " overlayGlow", C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed, spellID)
    run:Check(key .. " castSecrecy", secrets.GetSpellCastSecrecy, spellID)
end

--- The aura's spell ID and where it came from: "seen" (learned in game), "table"
--- (Probe.AURA_IDS) or "name" (resolved from the spell name, often the wrong ID).
function Probe:AuraID(name)
    local learned = Kairos.db.global.auraIDs[name]
    if learned then return learned, "seen" end
    if self.AURA_IDS[name] then return self.AURA_IDS[name], "table" end
    local spellID = spellIDFor(name)
    if spellID then return spellID, "name" end
    return nil
end

function Probe:CheckAura(run, unit, name, filter)
    local key = ("aura %s on %s"):format(name, unit)
    local auras = C_UnitAuras or {}
    run:CheckFields(key, { "applications", "expirationTime", "duration", "spellId" },
        auras.GetAuraDataBySpellName, unit, name, filter)
    local spellID, source = self:AuraID(name)
    if not spellID then return run:Add(key .. " auraID", "unresolved") end
    run:Add(key .. " auraID", "ok", ("%d %s"):format(spellID, source))
    local secrets = C_Secrets or {}
    run:Check(key .. " auraSecrecy", secrets.GetSpellAuraSecrecy, spellID)
    run:Check(key .. " shouldBeSecret", secrets.ShouldSpellAuraBeSecret, spellID)
    if unit ~= "player" then return end
    run:CheckFields(key .. " bySpellID", { "applications", "auraInstanceID" },
        auras.GetPlayerAuraBySpellID, spellID)

    -- Instance-ID paths: the ones that might still work in combat.
    local instanceID = Kairos.Trace.instanceByName[name]
    if not instanceID then return run:Add(key .. " instanceID", "unresolved") end
    run:Add(key .. " instanceID", "ok", tostring(instanceID))
    run:CheckFields(key .. " byInstance", { "applications", "spellId" },
        auras.GetAuraDataByAuraInstanceID, "player", instanceID)
    run:Check(key .. " displayCount", auras.GetAuraApplicationDisplayCount, "player", instanceID)
end

function Probe:CheckPower(run, powerName)
    local powerType = Enum and Enum.PowerType and Enum.PowerType[powerName]
    if not powerType then return run:Add("power " .. powerName, "missing") end
    local key = ("power %s (%d)"):format(powerName, powerType)
    run:Check(key .. " current", UnitPower, "player", powerType)
    run:Check(key .. " max", UnitPowerMax, "player", powerType)
    run:Check(key .. " secrecy", C_Secrets and C_Secrets.GetPowerTypeSecrecy, powerType)
end

function Probe:Collect(run)
    local secrets = C_Secrets or {}
    local extra = self.EXTRA[Kairos.specID] or {}
    Kairos.Trace:Refresh() -- fresh aura and instance IDs (does nothing in combat)

    run:Check("secrets HasSecretRestrictions", secrets.HasSecretRestrictions)
    run:Check("secrets ShouldCooldownsBeSecret", secrets.ShouldCooldownsBeSecret)
    run:Check("secrets ShouldAurasBeSecret", secrets.ShouldAurasBeSecret)

    run:Check("assisted GetNextCastSpell", C_AssistedCombat and C_AssistedCombat.GetNextCastSpell, false)
    run:Check("assisted IsAvailable", C_AssistedCombat and C_AssistedCombat.IsAvailable)

    -- Resources: the spec's extras plus whatever the player's primary power is.
    local powers, seen = {}, {}
    for _, name in ipairs(extra.powers or {}) do powers[#powers + 1] = name end
    local primary = Signal.Read(function() return (select(2, UnitPowerType("player"))) end)
    if primary.state == "known" and primary.value then
        local token = primary.value:lower():gsub("_(%a)", string.upper):gsub("^%a", string.upper)
        powers[#powers + 1] = token
    end
    for _, name in ipairs(powers) do
        if not seen[name] then
            seen[name] = true
            self:CheckPower(run, name)
        end
    end

    for _, unit in ipairs({ "player", "target" }) do
        run:Check("unit " .. unit .. " health", UnitHealth, unit)
        run:Check("unit " .. unit .. " healthMax", UnitHealthMax, unit)
    end
    run:Check("unit target exists", UnitExists, "target")
    run:Check("unit target canAttack", UnitCanAttack, "player", "target")
    run:Check("unit target affectingCombat", UnitAffectingCombat, "target")
    run:Check("unit target castingInfo", UnitCastingInfo, "target")
    run:Check("unit target channelInfo", UnitChannelInfo, "target")
    run:Check("unit player castingInfo", UnitCastingInfo, "player")
    run:Check("unit player speed", GetUnitSpeed, "player")
    run:Check("unit player spellHaste", UnitSpellHaste, "player")
    run:Check("unit player GetHaste", GetHaste)
    run:Check("unit target threatSituation", UnitThreatSituation, "player", "target")
    run:Check("movement IsPlayerMoving", IsPlayerMoving)
    run:Add("movement events since combat start", "ok", tostring(Kairos.State.moveEvents))

    local events = Kairos.Trace.events
    run:Add("auraEvents since combat start", "ok", tostring(events.events))
    run:Add("auraEvents secret parts", "ok", tostring(events.secret))
    run:Add("auraEvents added", "ok", tostring(events.added))
    run:Add("auraEvents added with secret spellId", "ok", tostring(events.addedSecretSpell))
    run:Add("auraEvents errors", "ok", tostring(events.errors))
    for _, name in ipairs(extra.buffs or {}) do
        for op, verb in pairs({ upd = "updated", rem = "removed" }) do
            local count = events.byName[name .. " " .. op]
            if count then run:Add("auraEvents " .. name .. " " .. verb, "ok", tostring(count)) end
        end
    end

    local plate = next(Kairos.State.nameplates)
    if plate then
        run:Check("nameplate canAttack", UnitCanAttack, "player", plate)
        run:Check("nameplate affectingCombat", UnitAffectingCombat, plate)
        run:Check("nameplate threatSituation", UnitThreatSituation, "player", plate)
        run:Check("nameplate GUID", UnitGUID, plate)
        local reference = spellIDFor((extra.spells or {})[1] or "")
        if reference then
            run:Check("nameplate inRange", C_Spell.IsSpellInRange, reference, plate)
        end
    else
        run:Add("nameplate canAttack", "nil", "no plates")
    end

    run:Check("actionbar GetSpell(1)", C_ActionBar and C_ActionBar.GetSpell, 1)
    run:Check("actionbar GetActionInfo(1)", GetActionInfo, 1)
    run:Check("actionbar GetBindingKey(ACTIONBUTTON1)", GetBindingKey, "ACTIONBUTTON1")
    run:Check("actionbar ShouldActionCooldownBeSecret(1)", secrets.ShouldActionCooldownBeSecret, 1)
    run:Check("spellqueue C_Spell.GetSpellQueueWindow", C_Spell.GetSpellQueueWindow)
    run:Check("spellqueue CVar", GetCVar, "SpellQueueWindow")

    self:CheckSpell(run, self.GCD_SPELL, "GCD")

    -- Spells: Blizzard's rotation list for the spec, then the spec extras by name.
    local spellSeen = { [self.GCD_SPELL] = true }
    for _, spellID in ipairs(Kairos.Assisted:RotationSpells()) do
        if not spellSeen[spellID] then
            spellSeen[spellID] = true
            self:CheckSpell(run, spellID)
        end
    end
    -- Match extras against the rotation list's names first: name lookup misses some known spells.
    local idByName = {}
    for spellID in pairs(spellSeen) do idByName[Kairos.SpellName(spellID)] = spellID end
    for _, name in ipairs(extra.spells or {}) do
        local spellID = idByName[name] or spellIDFor(name)
        if not spellID then
            run:Add("spell " .. name, "unresolved")
        elseif not spellSeen[spellID] then
            spellSeen[spellID] = true
            self:CheckSpell(run, spellID, name)
        end
    end

    for _, name in ipairs(extra.buffs or {}) do self:CheckAura(run, "player", name, "HELPFUL") end
    for _, name in ipairs(extra.debuffs or {}) do self:CheckAura(run, "target", name, "HARMFUL|PLAYER") end
end

function Probe:Run(label)
    local version, build = GetBuildInfo()
    local run = setmetatable({
        label = label or "manual",
        at = time(),
        client = ("%s (%s)"):format(tostring(version), tostring(build)),
        kairos = Kairos.version,
        rev = self.REVISION,
        spec = Kairos.specID,
        context = self:Context(),
        results = {},
    }, Run)
    self:Collect(run)
    setmetatable(run, nil)

    local runs = Kairos.db.probes
    runs[#runs + 1] = run
    while #runs > self.MAX_RUNS do table.remove(runs, 1) end
    return run
end

function Probe.Summarize(run)
    local counts = { ok = 0, secret = 0, ["nil"] = 0, error = 0, missing = 0 }
    for _, entry in ipairs(run.results) do
        local _, status = Probe.Decode(entry)
        counts[status] = (counts[status] or 0) + 1
    end
    return counts
end

local function cell(result)
    if not result then return "" end
    if result.status == "ok" then return ((result.value or "ok"):gsub("|", "\\|")) end
    if result.status == "secret" then return "**SECRET**" end
    if result.status == "missing" then return "n/a" end
    if result.status == "unresolved" then return "not found" end
    if result.status == "error" then return "error" end
    return result.status
end

--- Markdown matrix of the last `count` runs (default 8): one row per check, one column per run.
function Probe.Report(runs, count)
    count = count or 8
    local first = math.max(1, #runs - count + 1)
    local lines = { "# Kairos secrecy probe", "" }
    if #runs == 0 then
        lines[#lines + 1] = "No probe runs yet. Use /kairos probe."
        return table.concat(lines, "\n")
    end

    lines[#lines + 1] = "| Run | Label | Client | Kairos | Probe | Spec | Combat | Restrictions | Instance"
        .. " | Difficulty | Keystone | Encounter |"
    lines[#lines + 1] = "|---|---|---|---|---|---|---|---|---|---|---|---|"
    local keys, keyIndex, header, divider = {}, {}, { "| Check |" }, { "|---|" }
    for i = first, #runs do
        local run, ctx = runs[i], runs[i].context
        lines[#lines + 1] = ("| #%d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |"):format(i, run.label,
            run.client, tostring(run.kairos), tostring(run.rev or 1), tostring(run.spec), tostring(ctx.combat),
            tostring(ctx.restrictions), tostring(ctx.instance), tostring(ctx.difficulty), tostring(ctx.keystone),
            tostring(ctx.encounter))
        header[#header + 1] = (" #%d |"):format(i)
        divider[#divider + 1] = "---|"
    end

    local byKey = {}
    for i = first, #runs do
        local index, order = Probe.Results(runs[i])
        byKey[i] = index
        for _, key in ipairs(order) do
            if not keyIndex[key] then
                keyIndex[key] = true
                keys[#keys + 1] = key
            end
        end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = table.concat(header)
    lines[#lines + 1] = table.concat(divider)
    for _, key in ipairs(keys) do
        local row = { "| " .. key .. " |" }
        for i = first, #runs do
            row[#row + 1] = " " .. cell(byKey[i][key]) .. " |"
        end
        lines[#lines + 1] = table.concat(row)
    end
    return table.concat(lines, "\n")
end

function Probe:RunAndReport(label)
    local run = self:Run(label)
    local counts = Probe.Summarize(run)
    local combat = run.context.combat == true and "|cffff4040in combat|r" or "|cff40ff40out of combat|r"
    Kairos:Print("Probe #%d (%s, %s): %d ok, |cffff8040%d secret|r, %d nil, %d error, %d missing. "
        .. "/kairos probe report", #Kairos.db.probes, run.label, combat, counts.ok, counts.secret, counts["nil"],
        counts.error, counts.missing)
end

--- Runs the probe after a delay, so it can land mid-fight without typing in combat.
function Probe:Schedule(seconds, label)
    Kairos:Print("Probing in %d s (%s). Keep casting.", seconds, label)
    C_Timer.After(seconds, function() self:RunAndReport(label) end)
end

Probe.lastAuto = {}

function Probe:Auto(label, delay)
    if not Kairos.db.global.autoProbe then return end
    local now = GetTime()
    if now - (self.lastAuto[label] or -math.huge) < self.AUTO_THROTTLE then return end
    self.lastAuto[label] = now
    -- Silent: auto runs happen every fight, and the data is read offline.
    C_Timer.After(delay or 2, function() self:Run("auto " .. label) end)
end

function Probe:OnInit()
    Kairos:On("ENCOUNTER_START", function()
        self.encounterActive = true
        self:Auto("encounter", 3)
    end)
    Kairos:On("ENCOUNTER_END", function() self.encounterActive = false end)
    Kairos:On("CHALLENGE_MODE_START", function() self:Auto("keystone", 5) end)
    -- "combat" lands a few casts into the pull; "after" lands once Trace has read the
    -- post-fight auras, and reports that fight's aura event counts.
    Kairos:On("KAIROS_COMBAT_CHANGED", function(_, inCombat)
        if inCombat then
            self:Auto("combat", 3)
        else
            self:Auto("after", 1.5)
        end
    end)
end

function Probe:OnLogin()
    self:Auto("login", self.LOGIN_DELAY)
end
