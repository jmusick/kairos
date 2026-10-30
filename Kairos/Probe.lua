-- Secrecy probe (SPEC §8.1, §7.6). `/kairos probe` records, for the current context,
-- which reads come back ok, secret, nil, erroring or missing. Runs are kept in
-- KairosDB.probes, and `/kairos probe report` renders them as a copyable Markdown matrix.
local _, Kairos = ...
local Probe = Kairos:NewModule("Probe")
local Signal = Kairos.Signal

local issecretvalue = issecretvalue or function() return false end

Probe.MAX_RUNS = 50
Probe.AUTO_THROTTLE = 60
Probe.GCD_SPELL = 61304

-- Spec extras on top of Assisted Combat's rotation spells. Names, not IDs: several
-- Midnight spells are new, and the client resolves names for known spells and auras.
Probe.EXTRA = {
    [62] = { -- Arcane Mage (SPEC §10.2)
        spells = { "Arcane Blast", "Arcane Barrage", "Arcane Missiles", "Arcane Orb", "Arcane Pulse",
            "Arcane Explosion", "Arcane Surge", "Touch of the Magi", "Evocation", "Presence of Mind",
            "Counterspell", "Arcane Intellect" },
        buffs = { "Clearcasting", "Arcane Salvo", "Arcane Soul", "Arcane Surge", "Presence of Mind",
            "Prismatic Bolt", "Overpowered Missiles", "Lustrous Gleam", "Cumulative Power", "Arcane Intellect" },
        debuffs = { "Touch of the Magi" },
        powers = { "Mana", "ArcaneCharges" },
    },
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

local Run = {}
Run.__index = Run

function Run:Add(key, status, value)
    self.results[#self.results + 1] = { key = key, status = status, value = value }
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

function Probe:CheckAura(run, unit, name, filter)
    local key = ("aura %s on %s"):format(name, unit)
    local auras = C_UnitAuras or {}
    run:CheckFields(key, { "applications", "expirationTime", "duration", "spellId" },
        auras.GetAuraDataBySpellName, unit, name, filter)
    local spellID = spellIDFor(name)
    if spellID and C_Secrets then
        run:Check(key .. " auraSecrecy", C_Secrets.GetSpellAuraSecrecy, spellID)
    end
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

    local plate = next(Kairos.State.nameplates)
    if plate then
        run:Check("nameplate canAttack", UnitCanAttack, "player", plate)
        run:Check("nameplate affectingCombat", UnitAffectingCombat, plate)
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
    for _, name in ipairs(extra.spells or {}) do
        local spellID = spellIDFor(name)
        if not spellID then
            run:Add("spell " .. name, "missing", "not known")
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
    for _, result in ipairs(run.results) do
        counts[result.status] = (counts[result.status] or 0) + 1
    end
    return counts
end

local function cell(result)
    if not result then return "" end
    if result.status == "ok" then return ((result.value or "ok"):gsub("|", "\\|")) end
    if result.status == "secret" then return "**SECRET**" end
    if result.status == "missing" then return "n/a" end
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

    lines[#lines + 1] = "| Run | Label | Client | Kairos | Spec | Combat | Restrictions | Instance | Difficulty"
        .. " | Keystone | Encounter |"
    lines[#lines + 1] = "|---|---|---|---|---|---|---|---|---|---|---|"
    local keys, keyIndex, header, divider = {}, {}, { "| Check |" }, { "|---|" }
    for i = first, #runs do
        local run, ctx = runs[i], runs[i].context
        lines[#lines + 1] = ("| #%d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |"):format(i, run.label,
            run.client, tostring(run.kairos), tostring(run.spec), tostring(ctx.combat), tostring(ctx.restrictions),
            tostring(ctx.instance), tostring(ctx.difficulty), tostring(ctx.keystone), tostring(ctx.encounter))
        header[#header + 1] = (" #%d |"):format(i)
        divider[#divider + 1] = "---|"
        for _, result in ipairs(run.results) do
            if not keyIndex[result.key] then
                keyIndex[result.key] = true
                keys[#keys + 1] = result.key
            end
        end
    end

    local byKey = {}
    for i = first, #runs do
        local index = {}
        for _, result in ipairs(runs[i].results) do index[result.key] = result end
        byKey[i] = index
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
    Kairos:Print("Probe #%d (%s): %d ok, |cffff8040%d secret|r, %d nil, %d error, %d missing. "
        .. "/kairos probe report", #Kairos.db.probes, run.label, counts.ok, counts.secret, counts["nil"],
        counts.error, counts.missing)
end

Probe.lastAuto = {}

function Probe:Auto(label, delay)
    if not Kairos.db.global.autoProbe then return end
    local now = GetTime()
    if now - (self.lastAuto[label] or -math.huge) < self.AUTO_THROTTLE then return end
    self.lastAuto[label] = now
    C_Timer.After(delay or 2, function() self:RunAndReport("auto " .. label) end)
end

function Probe:OnInit()
    Kairos:On("ENCOUNTER_START", function()
        self.encounterActive = true
        self:Auto("encounter", 3)
    end)
    Kairos:On("ENCOUNTER_END", function() self.encounterActive = false end)
    Kairos:On("CHALLENGE_MODE_START", function() self:Auto("keystone", 5) end)
    Kairos:On("KAIROS_COMBAT_CHANGED", function(_, inCombat)
        if inCombat then self:Auto("combat", 2) end
    end)
end
