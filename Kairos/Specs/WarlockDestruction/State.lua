-- Live Destruction adapter (experimental). Hellcaller and Diabolist priorities come from
-- the generated APL; unknown priority-path reads fall back to AC. No queued pick yet, and
-- no live log input. Shards are fractional; DoTs, Backdraft and Infernal come from casts.
local _, Kairos = ...
local State = Kairos:NewModule("DestructionState")
local Signal = Kairos.Signal
local S = Kairos.DestructionAPL.SPELLS

State.COOLDOWNS = { [S.SOUL_FIRE] = 45, [S.SUMMON_INFERNAL] = 120, [S.MALEVOLENCE] = 60, [S.CATACLYSM] = 30 }
State.TAGS = { [S.SUMMON_INFERNAL] = "cooldowns", [S.MALEVOLENCE] = "cooldowns" }
-- Conflagrate: two charges, 12.96 s each before haste (the cooldown is hasted).
State.CHARGES = { [S.CONFLAGRATE] = { max = 2, recharge = 12.96 } }
State.TALENTS = { wither = 445465, diabolic_ritual = 428514, internal_combustion = 266134,
    soul_fire = 6353, cataclysm = 152108, lake_of_fire = 1244877, conflagration_of_chaos = 387108,
    fire_and_brimstone = 196408, destructive_rapidity = 1244928, roaring_blaze = 1244310,
    backdraft = 196406, secrets_of_the_coven = 428518, ruination = 428522,
    grimoire_of_sacrifice = 108503 }
State.CAST_TIMES = { [S.INCINERATE] = 2, [S.CHAOS_BOLT] = 3, [S.SOUL_FIRE] = 3, [S.IMMOLATE] = 1.5,
    [S.CATACLYSM] = 2, [S.INFERNAL_BOLT] = 2, [S.RUINATION] = 1.5 }
-- Own DoTs on the current target, timed from casts: base seconds, pandemic at 30%.
State.DOTS = {
    immolate = { spell = S.IMMOLATE, aura = 157736, duration = 18 },
    wither = { spell = S.WITHER, aura = 445474, duration = 18 },
}
State.PANDEMIC = 0.3
State.COMBUSTION = 5 -- Internal Combustion: Chaos Bolt takes up to 5 s of Immolate or Wither
State.TIMERS = { infernalRemains = { spell = S.SUMMON_INFERNAL, duration = 30 },
    malevolenceRemains = { spell = S.MALEVOLENCE, duration = 20 } }
-- Fragments per shard is 10. Gains land on cast success; Immolate's ticks are left to readings.
State.GAINS = { [S.INCINERATE] = 0.2, [S.CONFLAGRATE] = 0.5, [S.SOUL_FIRE] = 1, [S.INFERNAL_BOLT] = 3 }
State.COSTS = { [S.CHAOS_BOLT] = 2, [S.RAIN] = 3, [S.SHADOWBURN] = 1 }
-- Backdraft: each Conflagrate adds a stack (at most 2, 10 s); casts it speeds consume one.
State.BACKDRAFT = { aura = 117828, max = 2, duration = 10, speed = 0.7,
    spends = { [S.INCINERATE] = true, [S.CHAOS_BOLT] = true, [S.SOUL_FIRE] = true, [S.INFERNAL_BOLT] = true } }
State.FLIGHT = 1 -- seconds a Chaos Bolt is assumed in flight (estimate, unvalidated)
State.PROCS = { infernalReady = { id = S.INFERNAL_BOLT, base = S.INCINERATE },
    ruinationReady = { id = S.RUINATION, base = S.CHAOS_BOLT } }
State.RITUALS = { ritualMother = 432815, ritualOverlord = 431944, ritualPitLord = 432816 }
State.ARTS = { 432794, 428524, 432795 }
State.CRUELTY = 1245664
State.RAIN_TARGETED = 1214467 -- Rain of Fire's on-target version, when the reticle one isn't learned
State.IMP, State.SACRIFICE, State.SACRIFICE_BUFF = 688, 108503, 196099

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
-- Destruction's shards come in tenths: the unmodified reading is fragments.
local function shards()
    local power = Enum and Enum.PowerType and Enum.PowerType.SoulShards
    if not power then return Signal.Unknown("power-type") end
    local r = Signal.Read(UnitPower, "player", power, true)
    if numeric(r) and not Signal.IsSecret(r.value) then return Signal.Known(r.value / 10) end
    return r.state == "unknown" and r or Signal.Unknown("power")
end
local function put(s, key, r, default)
    if r and r.state ~= "unknown" and not Signal.IsSecret(r.value) and type(r.value) == type(default) then
        s[key] = r.value
    else s[key], s.unknown[key] = default, true end
end

-- A secret aura can return nil. Only a confirmed non-secret query proves absence.
local function hidden(id)
    local r = Signal.Read(C_Secrets and C_Secrets.ShouldSpellAuraBeSecret, id)
    return not boolean(r) or r.value
end
local function playerAura(id)
    if hidden(id) then return Signal.Unknown("restricted-aura") end
    return Signal.Read(C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID, id)
end
local function present(id)
    local r = playerAura(id)
    if r.state == "unknown" then return r end
    return Signal.Known(r.value ~= nil)
end
local function remaining(r, now)
    if r.state == "unknown" then return r end
    if r.value == nil then return Signal.Known(0) end
    local expires = field(r, "expirationTime")
    if not numeric(expires) then return Signal.Unknown("aura-expiry") end
    if expires.value == 0 then return Signal.Known(math.huge) end
    return Signal.Known(math.max(0, expires.value - now))
end
local function targetAura(id)
    if hidden(id) then return Signal.Unknown("restricted-aura") end
    local name = Signal.Read(C_Spell and C_Spell.GetSpellName, id)
    if name.state == "unknown" or type(name.value) ~= "string" then return Signal.Unknown("spell-name") end
    return Signal.Read(C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName, "target", name.value, "HARMFUL|PLAYER")
end
local function targetKey()
    local guid = Signal.Read(UnitGUID, "target")
    if guid.state ~= "unknown" and type(guid.value) == "string" then return guid.value end
end

function State:Reset()
    self.cache, self.cooldowns, self.charges, self.refreshedAt, self.timers = nil, {}, {}, nil, {}
    self.dots, self.anonymous, self.boltAt, self.backdraft = {}, {}, nil, nil
end
State:Reset()

function State:Refresh(t)
    if Kairos.specID ~= 267 or Kairos.State.inCombat then return end
    local lock = Signal.Read(InCombatLockdown)
    if not boolean(lock) or lock.value then return end
    self.refreshedAt = t
    local c = self.cache or { known = {}, talent = {} }
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
    end
    for _, id in ipairs({ self.IMP, self.SACRIFICE }) do
        local r = knows(id)
        if boolean(r) then c.known[id] = r end
    end
    local targeted = knows(self.RAIN_TARGETED)
    if boolean(targeted) and targeted.value then c.known[S.RAIN] = targeted end
    -- Proc replacements and the hero DoT aren't necessarily in the spellbook; Wither
    -- replaces Immolate.
    for id, talent in pairs({ [S.INFERNAL_BOLT] = "secrets_of_the_coven", [S.RUINATION] = "ruination",
        [S.WITHER] = "wither" }) do
        local r = c.talent[talent]
        if r then c.known[id] = r end
    end
    if c.talent.wither and c.talent.wither.value then c.known[S.IMMOLATE] = Signal.Known(false) end
    for id, base in pairs(self.COOLDOWNS) do
        local info = Signal.Read(C_Spell and C_Spell.GetSpellCooldown, id)
        local start, duration, rate = field(info, "startTime"), field(info, "duration"), field(info, "modRate")
        if numeric(start) and numeric(duration) and numeric(rate) and rate.value > 0 then
            local own = self.cooldowns[id]
            if duration.value > 2 then
                self.cooldowns[id] = { finish = start.value + duration.value / rate.value,
                    base = duration.value / rate.value, cast = own and own.cast }
            elseif not (own and own.cast and own.finish > t and t - own.cast < 2) then
                -- An idle read can lag our own cast; it can't cancel that cooldown at once.
                self.cooldowns[id] = { finish = t, base = base }
            end
        end
    end
    for id, model in pairs(self.CHARGES) do
        local info = Signal.Read(C_Spell and C_Spell.GetSpellCharges, id)
        local count, max = field(info, "currentCharges"), field(info, "maxCharges")
        local start, duration = field(info, "cooldownStartTime"), field(info, "cooldownDuration")
        if numeric(count) and numeric(max) and numeric(start) and numeric(duration) then
            self.charges[id] = { count = count.value, max = max.value, start = start.value,
                recharge = duration.value > 0 and duration.value or model.recharge / (1 + (c.haste or 0) / 100) }
        end
    end
end

-- Charges at time t from the last reading or cast: whole charges plus recharge progress.
function State:ChargesAt(id, t)
    local ch = self.charges[id]
    if not ch then return nil end
    local count = ch.count
    if count >= ch.max then return count end
    local progress = (t - ch.start) / ch.recharge
    local gained = math.floor(progress)
    if count + gained >= ch.max then return ch.max end
    return count + gained + (progress - gained)
end

function State:OnCast(id, t)
    local c = self.cache or { talent = {} }
    local function talent(name) return c.talent[name] and c.talent[name].value end
    if self.COOLDOWNS[id] then
        local previous = self.cooldowns[id]
        local base = previous and previous.base or self.COOLDOWNS[id]
        self.cooldowns[id] = { finish = t + base, base = base, cast = t }
    end
    local model, ch = self.CHARGES[id], self.charges[id]
    if model then
        local recharge = ch and ch.recharge or model.recharge / (1 + (c.haste or 0) / 100)
        local now = self:ChargesAt(id, t) or model.max
        local whole = math.floor(now)
        local start = whole >= (ch and ch.max or model.max) and t or t - (now - whole) * recharge
        self.charges[id] = { count = math.max(0, whole - 1), max = ch and ch.max or model.max, start = start,
            recharge = recharge }
    end
    for key, timer in pairs(self.TIMERS) do
        if timer.spell == id then self.timers[key] = t + timer.duration end
    end
    local slot = targetKey() or self.anonymous
    for key, dot in pairs(self.DOTS) do
        if dot.spell == id then
            self.dots[slot] = self.dots[slot] or {}
            local left = math.max(0, (self.dots[slot][key] or t) - t)
            self.dots[slot][key] = t + dot.duration + math.min(left, dot.duration * self.PANDEMIC)
        end
    end
    if id == S.CHAOS_BOLT then
        self.boltAt = t
        local timers = self.dots[slot]
        if talent("internal_combustion") and timers then
            for key in pairs(self.DOTS) do
                if timers[key] then timers[key] = math.max(t, timers[key] - self.COMBUSTION) end
            end
        end
    end
    local B, held = self.BACKDRAFT, self.backdraft
    local stacks = held and held.expires > t and held.stacks or 0
    if id == S.CONFLAGRATE and talent("backdraft") then
        self.backdraft = { stacks = math.min(B.max, stacks + 1), expires = t + B.duration }
    elseif B.spends[id] and stacks > 0 then
        self.backdraft = { stacks = stacks - 1, expires = held.expires }
    end
    Kairos.Recorder:Push({ k = "destruction", spell = id })
end

function State:Project(s, id, finish)
    if self.GAINS[id] then s.shards = math.min(5, s.shards + self.GAINS[id])
    elseif self.COSTS[id] then s.shards = math.max(0, s.shards - self.COSTS[id]) end
    for key, timer in pairs(self.TIMERS) do
        if timer.spell == id then s[key] = math.max(0, finish + timer.duration - s.t) end
    end
    for key, dot in pairs(self.DOTS) do
        local name = key .. "Remains"
        if dot.spell == id and not s.unknown[name] then
            s[name] = dot.duration + math.min(s[name], dot.duration * self.PANDEMIC) - (s.t - finish)
        elseif id == S.CHAOS_BOLT and s.talent.internal_combustion and not s.unknown[name] then
            s[name] = math.max(0, s[name] - self.COMBUSTION)
        end
        s[key .. "Refreshable"] = s[name] < dot.duration * self.PANDEMIC
    end
    if id == S.CHAOS_BOLT then s.chaosBoltInFlight = true end
    if id == S.CONFLAGRATE and s.talent.backdraft then s.backdraft = math.min(self.BACKDRAFT.max, s.backdraft + 1)
    elseif self.BACKDRAFT.spends[id] then s.backdraft = math.max(0, s.backdraft - 1) end
    if id == S.INFERNAL_BOLT then s.infernalReady, s.unknown.infernalReady = false, nil end
    if id == S.RUINATION then s.ruinationReady, s.unknown.ruinationReady = false, nil end
    if self.COOLDOWNS[id] then
        s.ready[id], s.remains[id] = false, math.max(0, self.COOLDOWNS[id] - (s.t - finish))
        s.unknown["ready:" .. id], s.unknown["remains:" .. id] = nil, nil
    end
    if self.CHARGES[id] and not s.unknown["chargesFractional:" .. id] then
        s.chargesFractional[id] = math.max(0, s.chargesFractional[id] - 1)
    end
    s.prevGcd = id
end

-- From base and haste: a client cast time read out of combat could include Backdraft.
function State:CastTime(id, haste, backdraft)
    local time = (self.CAST_TIMES[id] or 0) / (1 + (haste or 0) / 100)
    if backdraft and self.BACKDRAFT.spends[id] then time = time * self.BACKDRAFT.speed end
    return time
end

function State:Proc(proc, known)
    if known == false then return Signal.Known(false) end
    local override = Signal.Read(C_Spell and C_Spell.GetOverrideSpell, proc.base)
    if override.state ~= "unknown" then return Signal.Known(override.value == proc.id) end
    return override
end

function State:Build(now)
    if not self.refreshedAt or now - self.refreshedAt >= 1 then self:Refresh(now) end
    local c = self.cache or { known = {}, talent = {} }
    local s = { unknown = {}, known = { unknown = {} }, talent = { unknown = {} }, ready = {}, remains = {},
        castable = {}, execute = {}, chargesFractional = {}, t = now, fightRemains = 300,
        prevGcd = Kairos.State:PrevGcd() }
    s.timingUnknown = Kairos.State.castUnknown
    local cast = Kairos.State.cast
    if cast then s.t = math.max(s.t, cast.endsAt) end
    local gcd = Signal.Read(C_Spell and C_Spell.GetSpellCooldown, 61304)
    local start, duration, rate = field(gcd, "startTime"), field(gcd, "duration"), field(gcd, "modRate")
    if numeric(start) and numeric(duration) and rate.state ~= "unknown" then
        s.t = math.max(s.t, start.value + duration.value / (numeric(rate) and rate.value > 0 and rate.value or 1))
    else s.timingUnknown = true end
    put(s, "shards", shards(), 0)
    for _, id in pairs(S) do put(s.known, id, c.known[id], false) end
    for key in pairs(self.TALENTS) do put(s.talent, key, c.talent[key], false) end
    if c.gcdMax then s.gcdMax = c.gcdMax else s.gcdMax, s.unknown.gcdMax = 1.5, true end

    -- Backdraft: a readable count, else the cast model (its stacks are deterministic).
    local B = self.BACKDRAFT
    local aura = playerAura(B.aura)
    if aura.state ~= "unknown" then
        local n = aura.value and field(aura, "applications")
        s.backdraft = aura.value and (n and numeric(n) and math.max(1, n.value) or 1) or 0
    else
        local held = self.backdraft
        s.backdraft = held and held.expires > s.t and held.stacks or 0
    end
    for _, id in pairs(S) do
        s.execute[id] = math.max(s.gcdMax, self:CastTime(id, c.haste, s.backdraft > 0))
        if not c.gcdMax then s.unknown["execute:" .. id] = true end
    end

    put(s, "fiendishCruelty", present(self.CRUELTY), false)
    for key, id in pairs(self.RITUALS) do put(s, key, remaining(playerAura(id), s.t), 0) end
    s.demonicArt = false
    for _, id in ipairs(self.ARTS) do
        local r = present(id)
        if r.state == "unknown" then s.unknown.demonicArt = true elseif r.value then s.demonicArt = true end
    end
    if s.demonicArt then s.unknown.demonicArt = nil end
    for key, proc in pairs(self.PROCS) do put(s, key, self:Proc(proc, s.known[proc.id]), false) end
    if s.known.unknown[S.INFERNAL_BOLT] then s.unknown.infernalReady = true end
    if s.known.unknown[S.RUINATION] then s.unknown.ruinationReady = true end
    for key in pairs(self.TIMERS) do s[key] = math.max(0, (self.timers[key] or 0) - s.t) end

    -- Target health is secret in restricted content; the rules that need it fall back to AC.
    local health, max = Signal.Read(UnitHealth, "target"), Signal.Read(UnitHealthMax, "target")
    if numeric(health) and numeric(max) and max.value > 0 then s.targetHealthPct = 100 * health.value / max.value
    else s.targetHealthPct, s.unknown.targetHealthPct = 100, true end

    local slot, target = targetKey(), Kairos.State:Target()
    local timers = self.dots[slot or self.anonymous]
    for key, dot in pairs(self.DOTS) do
        local read = remaining(targetAura(dot.aura), s.t)
        local name = key .. "Remains"
        if numeric(read) then s[name] = read.value
        elseif timers and timers[key] then s[name] = math.max(0, timers[key] - s.t)
        else
            s[name] = 0
            if not slot and target ~= false then s.unknown[name] = true end
        end
        s[key .. "Duration"] = dot.duration
        s[key .. "Refreshable"] = s[name] < dot.duration * self.PANDEMIC
        if s.unknown[name] then s.unknown[key .. "Refreshable"] = true end
    end
    s.chaosBoltInFlight = self.boltAt ~= nil and s.t - self.boltAt < self.FLIGHT

    -- Only hostile nameplates in combat count (D24): training dummies report no combat, so a
    -- dummy area is the one target, not every dummy in sight (12.1.5: 11 in Silvermoon).
    local enemies = 0
    for unit in pairs(Kairos.State.nameplates) do
        local hostile = Signal.Read(UnitCanAttack, "player", unit)
        local fighting = hostile.value == true and Signal.Read(UnitAffectingCombat, unit) or Signal.Known(false)
        if not boolean(hostile) or not boolean(fighting) then s.unknown.enemies = true
        elseif fighting.value then enemies = enemies + 1 end
    end
    s.enemies = math.max(1, enemies)
    for id, base in pairs(self.COOLDOWNS) do
        local cd = self.cooldowns[id]
        local remains = cd and math.max(0, cd.finish - s.t) or base
        s.ready[id], s.remains[id] = Kairos.Toggles:ApplyToCooldown(self.TAGS[id], remains == 0,
            remains, cd and cd.base or base)
        if not cd and not Kairos.Toggles:IsHeld(self.TAGS[id]) then
            s.unknown["ready:" .. id], s.unknown["remains:" .. id] = true, true
        end
    end
    for id in pairs(self.CHARGES) do
        local n = self:ChargesAt(id, s.t)
        s.chargesFractional[id] = n or 0
        if not n then s.unknown["chargesFractional:" .. id] = true end
    end
    if cast and not cast.channel and cast.endsAt > now then self:Project(s, cast.spellID, cast.endsAt) end
    self:Castable(s, Kairos.State:Moving())
    return s
end

-- Movement filters availability before the APL picks, so moving prefers instants.
function State:Castable(s, moving)
    local stationary = moving.state ~= "unknown" and not moving.value
    for _, id in pairs(S) do
        local timed = (self.CAST_TIMES[id] or 0) > 0
        s.castable[id] = not timed or stationary
        s.unknown["castable:" .. id] = timed and moving.state == "unknown" or nil
    end
end

function State:Pick(s)
    local reads = {}
    local proxy = setmetatable({}, { __index = function(_, key)
        if s.unknown[key] then reads[key] = true end
        return s[key]
    end })
    for key, value in pairs(s) do
        if type(value) == "table" and key ~= "unknown" then
            proxy[key] = setmetatable({}, { __index = function(_, id)
                local name = key .. ":" .. id
                if s.unknown[name] or (value.unknown and value.unknown[id]) then reads[name] = true end
                return value[id]
            end })
        end
    end
    local pick = Kairos.DestructionAPL:Evaluate(proxy)
    return pick, s.timingUnknown or next(reads) ~= nil
end

-- Out of combat: the source's precombat summon_pet, then Grimoire of Sacrifice if talented.
function State:Precombat(s)
    local c = self.cache
    local function learned(id) return c and c.known[id] and c.known[id].value end
    local pet, dead = Signal.Read(UnitExists, "pet"), Signal.Read(UnitIsDeadOrGhost, "pet")
    if not boolean(pet) or not boolean(dead) then return { uncertain = true } end
    local alive = pet.value and not dead.value
    if learned(self.SACRIFICE) then
        local buff = playerAura(self.SACRIFICE_BUFF)
        if buff.state == "unknown" then return { uncertain = true } end
        if buff.value ~= nil then return nil end
        if alive then
            return { spellID = self.SACRIFICE, label = "precombat:grimoire_of_sacrifice",
                line = "actions.precombat+=/grimoire_of_sacrifice,if=talent.grimoire_of_sacrifice.enabled",
                uncertain = s.timingUnknown }
        end
    elseif alive then return nil end
    if learned(self.IMP) then
        local moving = Kairos.State:Moving()
        return { spellID = self.IMP, line = "actions.precombat=summon_pet", label = "precombat:summon_pet",
            uncertain = s.timingUnknown or moving.state == "unknown" or moving.value == true }
    end
end

function State:Evaluate()
    local now = clock()
    if not now then return { uncertain = true } end
    local s = self:Build(now)
    if not Kairos.State.inCombat and not Kairos.State.cast then
        local pre = self:Precombat(s)
        if pre then return pre end
    end
    local pick, uncertain = self:Pick(s)
    pick = pick or {}
    pick.uncertain = uncertain
    pick.queuedUncertain = true -- no lookahead model yet
    if Kairos.Recorder:Enabled() then
        pick.diagnostic = { v = 1, now = now, projected = s, movement = Kairos.State:Moving(),
            cast = Kairos.State.cast }
    end
    return pick
end

function State:OnInit()
    Kairos.APL:Register(267, self)
    local function refresh()
        local now = clock()
        if now then self:Refresh(now) end
    end
    Kairos:On("KAIROS_PROFILE_CHANGED", function() self:Reset(); refresh() end)
    Kairos:On("KAIROS_PLAYER_CAST", function(_, id)
        if Kairos.specID ~= 267 then return end
        local now = clock()
        if now then self:OnCast(id, now) end
    end)
    -- A target we can't identify starts with unknown DoTs; leaving combat ends them all.
    Kairos:On("PLAYER_TARGET_CHANGED", function() self.anonymous = {} end)
    Kairos:On("KAIROS_COMBAT_CHANGED", function(_, on) if not on then self.dots = {} end end)
    for _, event in ipairs({ "SPELLS_CHANGED", "TRAIT_CONFIG_UPDATED", "PLAYER_REGEN_ENABLED" }) do
        Kairos:On(event, refresh)
    end
    Kairos:OnUnit("UNIT_SPELL_HASTE", "player", refresh)
end

function State:OnLogin()
    local now = clock()
    if now then self:Refresh(now) end
end
