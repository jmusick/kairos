-- Live Demonology adapter. Diabolist and the shared leveling priorities come from
-- the generated APL; unknown priority-path reads fall back to AC. No live log input.
local _, Kairos = ...
local State = Kairos:NewModule("DemonologyState")
local Signal = Kairos.Signal
local S = Kairos.DemonologyAPL.SPELLS

State.COOLDOWNS = { [S.DOGS] = 20, [S.TYRANT] = 60, [S.SIPHON] = 30, [S.IMPLOSION] = 15,
    [S.IMP_LORD] = 120, [S.RAVAGER] = 120, [S.DOOMGUARD] = 120 }
State.TAGS = { [S.TYRANT] = "cooldowns", [S.IMP_LORD] = "cooldowns",
    [S.RAVAGER] = "cooldowns", [S.DOOMGUARD] = "cooldowns" }
State.TALENTS = { diabolic_ritual = 428514, demonic_soul = 449614, reign_of_tyranny = 1276748,
    to_hell_and_back = 1281511, doom = 460551, argus = 1276163, argus3 = 1276222,
    secrets_of_the_coven = 428518, ruination = 428522, demoniac = 426115 }
State.CAST_TIMES = { [S.SHADOW] = 2, [S.HAND] = 1.5, [S.DEMONBOLT] = 4.5,
    [S.DOGS] = 2, [S.TYRANT] = 2, [S.INFERNAL] = 2, [S.RUINATION] = 1.5 }
State.FELGUARD, State.IMP = 30146, 688

local function numeric(r) return r.state ~= "unknown" and type(r.value) == "number" end
local function boolean(r) return r.state ~= "unknown" and type(r.value) == "boolean" end
local function field(r, key)
    return r.state == "unknown" and r or Signal.ReadField(r.value, key)
end
local function clock()
    local r = Signal.Read(GetTime)
    if numeric(r) then return r.value end
end
local function knows(id)
    return Signal.Read(C_SpellBook and C_SpellBook.IsSpellKnown or IsPlayerSpell or IsSpellKnown, id)
end
local function put(s, key, r, default)
    if r and r.state ~= "unknown" and not Signal.IsSecret(r.value) and type(r.value) == type(default) then
        s[key] = r.value
    else s[key], s.unknown[key] = default, true end
end

function State:Reset()
    self.cache, self.cooldowns, self.refreshedAt, self.argusUntil = nil, {}, nil, 0
    Kairos.DemonologyDemons:Reset()
end
State:Reset()

function State:Refresh(t)
    if Kairos.specID ~= 266 or Kairos.State.inCombat then return end
    local lock = Signal.Read(InCombatLockdown)
    if not boolean(lock) or lock.value then return end
    self.refreshedAt = t
    local c = self.cache or { known = {}, talent = {}, castTimes = {} }
    self.cache = c
    local haste = Signal.Read(UnitSpellHaste, "player")
    if numeric(haste) then c.haste = haste.value; c.gcdMax = math.max(0.75, 1.5 / (1 + haste.value / 100)) end
    for key, id in pairs(self.TALENTS) do
        local r = knows(id)
        if boolean(r) then c.talent[key] = r end
    end
    for _, id in pairs(S) do
        local r = knows(id)
        if boolean(r) then c.known[id] = r end
        local info = Signal.Read(C_Spell and C_Spell.GetSpellInfo, id)
        local cast = field(info, "castTime")
        if numeric(cast) then c.castTimes[id] = cast.value / 1000 end
    end
    for _, id in ipairs({ self.FELGUARD, self.IMP }) do
        local r = knows(id)
        if boolean(r) then c.known[id] = r end
    end
    -- Proc replacements aren't necessarily in the spellbook before their proc.
    for id, talent in pairs({ [S.INFERNAL] = "secrets_of_the_coven", [S.RUINATION] = "ruination" }) do
        local r = c.talent[talent]
        if r then c.known[id] = r end
    end
    local hand = knows(1250273) -- Midnight's passive teaches the actual 105174 cast
    if boolean(hand) and hand.value then c.known[S.HAND] = hand end
    if c.talent.demoniac and c.talent.demoniac.value then c.known[S.DEMONBOLT] = c.talent.demoniac end
    for id, base in pairs(self.COOLDOWNS) do
        local info = Signal.Read(C_Spell and C_Spell.GetSpellCooldown, id)
        local start, duration, rate = field(info, "startTime"), field(info, "duration"), field(info, "modRate")
        if numeric(start) and numeric(duration) and numeric(rate) and rate.value > 0 then
            self.cooldowns[id] = { finish = duration.value > 2 and start.value + duration.value / rate.value or t,
                base = duration.value > 2 and duration.value / rate.value or base }
        end
    end
end

-- A secret aura can return nil. Only a confirmed non-secret query proves absence.
local function aura(id)
    local hidden = Signal.Read(C_Secrets and C_Secrets.ShouldSpellAuraBeSecret, id)
    if not boolean(hidden) or hidden.value then return Signal.Unknown("restricted-aura") end
    local r = Signal.Read(C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID, id)
    if r.state == "unknown" then return r end
    if r.value == nil then return Signal.Known(0) end
    local stacks = field(r, "applications")
    return numeric(stacks) and Signal.Known(math.max(1, stacks.value)) or Signal.Unknown("aura-count")
end

function State:Proc(id, base, known)
    if known == false then return Signal.Known(false) end
    local override = Signal.Read(C_Spell and C_Spell.GetOverrideSpell, base)
    if override.state ~= "unknown" then return Signal.Known(override.value == id) end
    return override
end

function State:OnCast(id, t)
    local c = self.cache or { talent = {} }
    local function talent(name) return c.talent[name] and c.talent[name].value end
    if self.COOLDOWNS[id] then
        local previous = self.cooldowns[id]
        local base = previous and previous.base or self.COOLDOWNS[id]
        self.cooldowns[id] = { finish = t + base, base = base }
    end
    if id == S.DEMONBOLT and self.lastCoreUp and self.cooldowns[S.DOOMGUARD] then
        self.cooldowns[S.DOOMGUARD].finish = math.max(t, self.cooldowns[S.DOOMGUARD].finish - 3)
    end
    Kairos.DemonologyDemons:OnCast(id, t, c.haste or 0)
    if id == S.TYRANT and talent("argus") then self.argusUntil = t + 15
    elseif (id == S.HAND or id == S.RUINATION) and self.argusUntil > t then self.argusUntil = t + 15 end
    Kairos.Recorder:Push({ k = "demo", imps = Kairos.DemonologyDemons:Count(t), spell = id })
end

-- Project only deterministic effects. Random Core gains/extra guardians remain
-- outside the model and will be corrected by readable shards, glows and future probes.
function State:Project(s, id, finish)
    local gain = { [S.SHADOW] = 1, [S.DEMONBOLT] = 2, [S.INFERNAL] = 3 }
    local cost = { [S.HAND] = 3, [S.DOGS] = 2, [S.IMP_LORD] = 1, [S.RAVAGER] = 1, [S.DOOMGUARD] = 1 }
    if gain[id] then s.shards = math.min(5, s.shards + gain[id])
    elseif cost[id] then s.shards = math.max(0, s.shards - cost[id]) end
    if id == S.HAND or id == S.RUINATION then
        s.imps = s.imps + 3
        if s.argusUp and s.talent.argus3 then s.shards = math.min(5, s.shards + 1) end
        if s.argusUp and s.talent.unknown.argus3 then s.unknown.shards = true end
    end
    if id == S.RUINATION then s.ruinationReady, s.unknown.ruinationReady = false, nil end
    if id == S.INFERNAL then s.infernalReady, s.unknown.infernalReady = false, nil end
    if id == S.TYRANT and s.talent.argus then s.argusUp = true end
    if id == S.DEMONBOLT and s.coreUp then
        -- If the hidden count was 1..4, after consumption it is 0..3: presence unknown.
        if s.unknown.coreStacks then s.unknown.coreUp = true
        else s.coreStacks = math.max(0, s.coreStacks - 1); s.coreUp = s.coreStacks > 0 end
    end
    if self.COOLDOWNS[id] then
        local base = self.COOLDOWNS[id]
        s.ready[id], s.remains[id] = false, math.max(0, base - (s.t - finish))
        s.unknown["ready:" .. id], s.unknown["remains:" .. id] = nil, nil
    end
    s.prevGcd = id
end

function State:Build(now)
    if not self.refreshedAt or now - self.refreshedAt >= 1 then self:Refresh(now) end
    local c = self.cache or { known = {}, talent = {}, castTimes = {} }
    local s = { unknown = {}, known = { unknown = {} }, talent = { unknown = {} }, ready = {}, remains = {},
        castable = {}, chargesFractional = {}, t = now, fightRemains = 300, prevGcd = Kairos.State:PrevGcd() }
    s.timingUnknown = Kairos.State.castUnknown
    local cast = Kairos.State.cast
    if cast then s.t = math.max(s.t, cast.endsAt) end
    local gcd = Signal.Read(C_Spell and C_Spell.GetSpellCooldown, 61304)
    local start, duration, rate = field(gcd, "startTime"), field(gcd, "duration"), field(gcd, "modRate")
    if numeric(start) and numeric(duration) and rate.state ~= "unknown" then
        s.t = math.max(s.t, start.value + duration.value / (numeric(rate) and rate.value > 0 and rate.value or 1))
    else s.timingUnknown = true end
    local power = Enum and Enum.PowerType and Enum.PowerType.SoulShards
    put(s, "shards", power and Signal.Read(UnitPower, "player", power) or Signal.Unknown("power-type"), 0)
    for _, id in pairs(S) do put(s.known, id, c.known[id], false) end
    for key in pairs(self.TALENTS) do put(s.talent, key, c.talent[key], false) end
    if c.gcdMax then s.gcdMax = c.gcdMax else s.gcdMax, s.unknown.gcdMax = 1.5, true end
    local core = s.talent.demoniac and aura(264173) or Signal.Known(0)
    if s.talent.unknown.demoniac then core = Signal.Unknown("talent") end
    if numeric(core) then
        s.coreStacks, s.coreUp = core.value, core.value > 0
    else
        local glow = Signal.Read(C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed, S.DEMONBOLT)
        put(s, "coreUp", glow, false)
        s.coreStacks = s.coreUp and 1 or 0
        if s.coreUp or s.unknown.coreUp then s.unknown.coreStacks = true end
    end
    self.lastCoreUp = not s.unknown.coreUp and s.coreUp
    put(s, "infernalReady", self:Proc(S.INFERNAL, S.SHADOW, s.known[S.INFERNAL]), false)
    put(s, "ruinationReady", self:Proc(S.RUINATION, S.HAND, s.known[S.RUINATION]), false)
    if s.known.unknown[S.INFERNAL] then s.unknown.infernalReady = true end
    if s.known.unknown[S.RUINATION] then s.unknown.ruinationReady = true end
    s.argusUp = s.talent.argus and self.argusUntil > s.t
    if s.talent.unknown.argus then s.unknown.argusUp = true end
    s.imps = Kairos.DemonologyDemons:Read(s.t).value
    local enemies = 0
    for unit in pairs(Kairos.State.nameplates) do
        local r = Signal.Read(UnitCanAttack, "player", unit)
        if not boolean(r) then s.unknown.enemies = true elseif r.value then enemies = enemies + 1 end
    end
    s.enemies = enemies
    for id, base in pairs(self.COOLDOWNS) do
        local cd = self.cooldowns[id]
        local remains = cd and math.max(0, cd.finish - s.t) or base
        s.ready[id], s.remains[id] = Kairos.Toggles:ApplyToCooldown(self.TAGS[id], remains == 0,
            remains, cd and cd.base or base)
        if not cd and not Kairos.Toggles:IsHeld(self.TAGS[id]) then
            s.unknown["ready:" .. id], s.unknown["remains:" .. id] = true, true
        end
    end
    if cast and not cast.channel and cast.endsAt > now then self:Project(s, cast.spellID, cast.endsAt) end
    -- Movement filters availability before the APL picks, so moving prefers instants.
    local moving = Kairos.State:Moving()
    for _, id in pairs(S) do
        local time = c.castTimes[id]
        if time == nil then time = self.CAST_TIMES[id] or 0 end
        if id == S.DEMONBOLT and s.coreUp then time = 0 end
        s.castable[id] = time == 0 or (moving.state ~= "unknown" and not moving.value)
        if time > 0 and moving.state == "unknown" then s.unknown["castable:" .. id] = true end
    end
    return s
end

function State:Pick(s)
    local reads = {}
    local proxy = setmetatable({}, { __index = function(_, key)
        if s.unknown[key] then reads[key] = true end
        return s[key]
    end })
    for _, key in ipairs({ "known", "talent", "ready", "remains", "castable" }) do
        proxy[key] = setmetatable({}, { __index = function(_, id)
            local name = key .. ":" .. id
            if s.unknown[name] or (s[key].unknown and s[key].unknown[id]) then reads[name] = true end
            return s[key][id]
        end })
    end
    local function evaluate()
        if not proxy.talent.diabolic_ritual and not proxy.talent.demonic_soul then
            return Kairos.DemonologyAPL:Leveling(proxy)
        end
        return Kairos.DemonologyAPL:Evaluate(proxy)
    end
    local pick = evaluate()
    -- A lit glow proves presence, not count. Accept only a spell shared by every
    -- possible 1..4 stack value; differing choices (notably Siphon) must use AC.
    if reads.coreStacks and s.coreUp and not s.unknown.coreUp then
        local original, same, labels = s.coreStacks, true, false
        for n = 1, 4 do
            s.coreStacks = n
            local other = evaluate()
            if (other and other.spellID) ~= (pick and pick.spellID) then same = false end
            if other and pick and other.label ~= pick.label then labels = true end
        end
        s.coreStacks = original
        if same then
            reads.coreStacks = nil
            if labels and pick then pick.label = pick.label .. " [core stack independent]" end
        end
    end
    local uncertain = s.timingUnknown or next(reads) ~= nil
    return pick, uncertain
end

function State:Evaluate()
    local now = clock()
    if not now then return { uncertain = true } end
    local s = self:Build(now)
    if not Kairos.State.inCombat and not Kairos.State.cast then
        local pet = Signal.Read(UnitExists, "pet")
        local dead = Signal.Read(UnitIsDeadOrGhost, "pet")
        if boolean(pet) and boolean(dead) and (not pet.value or dead.value) then
            local c = self.cache
            for _, id in ipairs({ self.FELGUARD, self.IMP }) do
                if c and c.known[id] and c.known[id].value then
                    local moving = Kairos.State:Moving()
                    return { spellID = id, line = "actions.precombat=summon_pet", label = "precombat:summon_pet",
                        uncertain = s.timingUnknown or moving.state == "unknown" or moving.value == true }
                end
            end
        elseif not boolean(pet) or not boolean(dead) then return { uncertain = true } end
    end
    local pick, uncertain = self:Pick(s)
    pick = pick or {}
    pick.uncertain, pick.queuedUncertain = uncertain, true
    return pick
end

function State:OnInit()
    Kairos.APL:Register(266, self)
    local function refresh()
        local now = clock()
        if now then self:Refresh(now) end
    end
    Kairos:On("KAIROS_PROFILE_CHANGED", function() self:Reset(); refresh() end)
    Kairos:On("KAIROS_PLAYER_CAST", function(_, id)
        if Kairos.specID ~= 266 then return end
        local now = clock()
        if now then self:OnCast(id, now) end
    end)
    for _, event in ipairs({ "SPELLS_CHANGED", "TRAIT_CONFIG_UPDATED", "PLAYER_REGEN_ENABLED" }) do
        Kairos:On(event, refresh)
    end
    Kairos:OnUnit("UNIT_SPELL_HASTE", "player", refresh)
end

function State:OnLogin()
    local now = clock()
    if now then self:Refresh(now) end
end
