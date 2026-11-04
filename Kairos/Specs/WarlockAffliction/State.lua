-- Live Affliction adapter (experimental). Soul Harvester and Hellcaller priorities come
-- from the generated APL; unknown priority-path reads fall back to AC. No queued pick yet,
-- and no live log input. Own DoTs, Darkglare and Malevolence are timed from own casts.
local _, Kairos = ...
local State = Kairos:NewModule("AfflictionState")
local Signal = Kairos.Signal
local S = Kairos.AfflictionAPL.SPELLS

State.COOLDOWNS = { [S.HAUNT] = 15, [S.HARVEST] = 60, [S.DARKGLARE] = 120, [S.MALEVOLENCE] = 60 }
State.TAGS = { [S.DARKGLARE] = "cooldowns", [S.MALEVOLENCE] = "cooldowns" }
State.TALENTS = { demonic_soul = 449614, wither = 445465, summon_darkglare = 205180,
    cascading_calamity = 1261124, sow_the_seeds = 196226, siphon_life = 452999,
    absolute_corruption = 196103, drain_soul = 388667, malefic_grasp = 1261149,
    grimoire_of_sacrifice = 108503, fatal_echoes = 1260229 }
-- Base cast or channel seconds; Malefic Grasp, Drain Soul and Dark Harvest channel.
State.CAST_TIMES = { [S.SHADOW] = 2, [S.HAUNT] = 1.5, [S.UA] = 1.5, [S.SEED] = 2,
    [S.GRASP] = 4, [S.DRAIN] = 5, [S.HARVEST] = 3 }
-- Own DoTs on the current target, timed from casts: base seconds, pandemic at 30%.
State.DOTS = {
    agony = { spell = S.AGONY, aura = 980, duration = 18 },
    corruption = { spell = S.CORRUPTION, aura = 146739, duration = 14, absolute = true },
    wither = { spell = S.WITHER, aura = 445474, duration = 18, absolute = true },
    seed = { spell = S.SEED, aura = 27243, duration = 12 },
    ua = { spell = S.UA, aura = 1259790, duration = 8, fixed = true }, -- a refresh resets it to 8 s
}
State.PANDEMIC = 0.3
-- Own summons and buffs that last a fixed time from their cast.
State.TIMERS = { darkglareRemains = { spell = S.DARKGLARE, duration = 20 },
    malevolenceRemains = { spell = S.MALEVOLENCE, duration = 20 } }
-- Player auras read directly. Secret in combat (12.1.5 probe), where Nightfall's glow on
-- Shadow Bolt and Shard Instability's on Unstable Affliction and Seed prove presence only.
State.AURAS = { nightfall = 264571, shardInstability = 1260269 }
State.GLOWS = { nightfall = { S.SHADOW, S.DRAIN }, shardInstability = { S.UA, S.SEED } }
State.AURA_REMAINS = { empowermentRemains = 1305774 }
-- Cascading Calamity: a UA that lands while our UA still ticks on the target (SimC's
-- impact). Fatal Echoes can also grant it at random, so without one it's unknown then.
State.CALAMITY = { aura = 1261125, duration = 15 }
State.NIGHTFALL_MAX = 2
State.GAINS = {} -- Agony's shards are random; readings correct the projection
State.COSTS = { [S.UA] = 1, [S.SEED] = 1 }
State.SEED_FLIGHT = 1 -- seconds a Seed is assumed in flight (estimate, unvalidated)
State.SET_BONUS = 1296569 -- Affliction 12.1 Class Set 4pc
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
local function shards()
    local power = Enum and Enum.PowerType and Enum.PowerType.SoulShards
    return power and Signal.Read(UnitPower, "player", power) or Signal.Unknown("power-type")
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
local function stacks(id)
    local r = playerAura(id)
    if r.state == "unknown" then return r end
    if r.value == nil then return Signal.Known(0) end
    local n = field(r, "applications")
    return numeric(n) and Signal.Known(math.max(1, n.value)) or Signal.Unknown("aura-count")
end
-- Seconds left on an aura, from its expiration; zero when absent, huge when permanent.
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
-- The target's identity when readable, so DoT timers survive switching back to it.
local function targetKey()
    local guid = Signal.Read(UnitGUID, "target")
    if guid.state ~= "unknown" and type(guid.value) == "string" then return guid.value end
end

function State:Reset()
    self.cache, self.cooldowns, self.refreshedAt, self.timers = nil, {}, nil, {}
    self.dots, self.anonymous, self.seedAt, self.calamityUntil = {}, {}, nil, nil
end
State:Reset()

function State:Refresh(t)
    if Kairos.specID ~= 265 or Kairos.State.inCombat then return end
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
    local set = knows(self.SET_BONUS)
    if boolean(set) then c.setS2_4pc = set end
    for _, id in pairs(S) do
        local r = knows(id)
        if boolean(r) then c.known[id] = r end
        local cast = field(Signal.Read(C_Spell and C_Spell.GetSpellInfo, id), "castTime")
        if numeric(cast) and cast.value > 0 then c.castTimes[id] = cast.value / 1000 end
    end
    for _, id in ipairs({ self.IMP, self.SACRIFICE }) do
        local r = knows(id)
        if boolean(r) then c.known[id] = r end
    end
    -- Talented casts aren't necessarily their own spellbook entries; Wither replaces Corruption.
    for id, talent in pairs({ [S.DRAIN] = "drain_soul", [S.GRASP] = "malefic_grasp", [S.WITHER] = "wither" }) do
        local r = c.talent[talent]
        if r and r.value then c.known[id] = r end
    end
    if c.talent.wither and c.talent.wither.value then c.known[S.CORRUPTION] = Signal.Known(false) end
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
end

-- Pandemic: a refresh keeps up to 30% of the duration that was left.
function State:OnCast(id, t)
    local c = self.cache or { talent = {} }
    local function talent(name) return c.talent[name] and c.talent[name].value end
    if self.COOLDOWNS[id] then
        local previous = self.cooldowns[id]
        local base = previous and previous.base or self.COOLDOWNS[id]
        self.cooldowns[id] = { finish = t + base, base = base, cast = t }
    end
    for key, timer in pairs(self.TIMERS) do
        if timer.spell == id then self.timers[key] = t + timer.duration end
    end
    local slot = targetKey() or self.anonymous
    local timers = self.dots[slot]
    if id == S.UA and talent("cascading_calamity") and timers and timers.ua and timers.ua > t then
        self.calamityUntil = t + self.CALAMITY.duration
    end
    for key, dot in pairs(self.DOTS) do
        if dot.spell == id then
            self.dots[slot] = self.dots[slot] or {}
            local absolute = dot.absolute and c.talent.absolute_corruption and c.talent.absolute_corruption.value
            local left = dot.fixed and 0 or math.max(0, (self.dots[slot][key] or t) - t)
            self.dots[slot][key] = absolute and math.huge
                or t + dot.duration + math.min(left, dot.duration * self.PANDEMIC)
        end
    end
    if id == S.SEED then self.seedAt = t end
    Kairos.Recorder:Push({ k = "affliction", spell = id })
end

-- Shard Instability makes the spell free and is spent first; a glow hides how many are left.
function State:Project(s, id, finish)
    if self.COSTS[id] then
        if s.shardInstability > 0 then
            s.shardInstability = s.shardInstability - 1
            if s.shardInstabilityHidden then s.unknown.shardInstability = true end
        else s.shards = math.max(0, s.shards - self.COSTS[id]) end
    end
    if id == S.UA and s.talent.cascading_calamity and s.uaRemains > 0 then
        s.calamityRemains = self.CALAMITY.duration - (s.t - finish)
        s.unknown.calamityRemains = s.unknown.uaRemains
    end
    for key, timer in pairs(self.TIMERS) do
        if timer.spell == id then s[key] = math.max(0, finish + timer.duration - s.t) end
    end
    for key, dot in pairs(self.DOTS) do
        if dot.spell == id and not s.unknown[key .. "Remains"] then
            local permanent = dot.absolute and s.talent.absolute_corruption
            local left = dot.fixed and 0 or s[key .. "Remains"]
            s[key .. "Remains"] = permanent and math.huge
                or dot.duration + math.min(left, dot.duration * self.PANDEMIC) - (s.t - finish)
            s[key .. "Refreshable"] = s[key .. "Remains"] < dot.duration * self.PANDEMIC
        end
    end
    if id == S.SEED then s.seedInFlight = true end
    if self.COOLDOWNS[id] then
        s.ready[id], s.remains[id] = false, math.max(0, self.COOLDOWNS[id] - (s.t - finish))
        s.unknown["ready:" .. id], s.unknown["remains:" .. id] = nil, nil
    end
    s.prevGcd = id
end

function State:CastTime(id, haste)
    local time = self.cache and self.cache.castTimes[id]
    if time then return time end
    return (self.CAST_TIMES[id] or 0) / (1 + (haste or 0) / 100)
end

function State:Build(now)
    if not self.refreshedAt or now - self.refreshedAt >= 1 then self:Refresh(now) end
    local c = self.cache or { known = {}, talent = {}, castTimes = {} }
    local s = { unknown = {}, known = { unknown = {} }, talent = { unknown = {} }, ready = {}, remains = {},
        castable = {}, execute = {}, t = now, fightRemains = 300, prevGcd = Kairos.State:PrevGcd() }
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
    put(s, "setS2_4pc", c.setS2_4pc, false)
    if c.gcdMax then s.gcdMax = c.gcdMax else s.gcdMax, s.unknown.gcdMax = 1.5, true end
    for _, id in pairs(S) do
        s.execute[id] = math.max(s.gcdMax, self:CastTime(id, c.haste))
        if not c.gcdMax then s.unknown["execute:" .. id] = true end
    end

    -- A readable count, else a glow's presence with the count left open.
    for key, id in pairs(self.AURAS) do
        local count = stacks(id)
        if numeric(count) then s[key] = count.value
        else
            s[key] = 0
            for _, spell in ipairs(self.GLOWS[key]) do
                local lit = Signal.Read(C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed, spell)
                if not boolean(lit) then s.unknown[key] = true elseif lit.value then s[key] = 1 end
            end
            if s[key] > 0 then s.unknown[key], s[key .. "Hidden"] = true, true end
        end
    end
    -- The APL reads Shard Instability only as presence; Nightfall's count is enumerated in Pick.
    if s.shardInstabilityHidden then s.unknown.shardInstability = nil end
    for key, id in pairs(self.AURA_REMAINS) do put(s, key, remaining(playerAura(id), s.t), 0) end
    for key in pairs(self.TIMERS) do s[key] = math.max(0, (self.timers[key] or 0) - s.t) end

    -- DoTs: a readable debuff wins, then our own timers for this target. A target we can
    -- identify and never dotted has none; one we can't could have any from before.
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
        s[key .. "Refreshable"] = s[name] < dot.duration * self.PANDEMIC
        if s.unknown[name] then s.unknown[key .. "Refreshable"] = true end
    end
    s.seedInFlight = self.seedAt ~= nil and s.t - self.seedAt < self.SEED_FLIGHT
    local calamity = remaining(playerAura(self.CALAMITY.aura), s.t)
    if numeric(calamity) then s.calamityRemains = calamity.value
    else
        s.calamityRemains = math.max(0, (self.calamityUntil or 0) - s.t)
        if s.calamityRemains == 0 and s.talent.fatal_echoes then s.unknown.calamityRemains = true end
    end

    -- SimC counts the target itself: at least one enemy whenever there's something to hit.
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
    local function evaluate()
        if not proxy.talent.demonic_soul and not proxy.talent.wither then
            return Kairos.AfflictionAPL:Leveling(proxy)
        end
        return Kairos.AfflictionAPL:Evaluate(proxy)
    end
    local pick = evaluate()
    -- A lit glow proves Nightfall, not its count: accept a spell shared by every count.
    if reads.nightfall and s.nightfallHidden then
        local original, same = s.nightfall, true
        for n = 1, self.NIGHTFALL_MAX do
            s.nightfall = n
            local other = evaluate()
            if (other and other.spellID) ~= (pick and pick.spellID) then same = false end
        end
        s.nightfall = original
        if same then reads.nightfall = nil end
    end
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
                line = "actions.precombat+=/grimoire_of_sacrifice,if=talent.grimoire_of_sacrifice",
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
    Kairos.APL:Register(265, self)
    local function refresh()
        local now = clock()
        if now then self:Refresh(now) end
    end
    Kairos:On("KAIROS_PROFILE_CHANGED", function() self:Reset(); refresh() end)
    Kairos:On("KAIROS_PLAYER_CAST", function(_, id)
        if Kairos.specID ~= 265 then return end
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
