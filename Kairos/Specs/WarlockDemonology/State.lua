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
    secrets_of_the_coven = 428518, ruination = 428522, demoniac = 426115, infernal_machine = 429917,
    inner_demons = 267216 }
State.CAST_TIMES = { [S.SHADOW] = 2, [S.HAND] = 1.5, [S.DEMONBOLT] = 4.5,
    [S.DOGS] = 2, [S.TYRANT] = 2, [S.INFERNAL] = 2, [S.RUINATION] = 1.5 }
State.FELGUARD, State.IMP = 30146, 688
State.READ_LAG = 2 -- seconds a cast's own cooldown outranks an idle client read
State.ART_LAG = 0.5 -- seconds after a Hand its Demonic Art proc may still be landing (log: 0-0.1 s)
-- Infernal Bolt and Ruination procs left unused end 20.0 s after they appear (12.1.5 log: 16 of 16).
State.PROC_LIFE = 20
State.PROCS = { infernalReady = S.INFERNAL, ruinationReady = S.RUINATION }
-- Shards each Diabolic Ritual spender takes off the ritual (Dreadstalkers is free in 12.1.5,
-- but still starts one); the ritual model is in Ritual.lua.
State.SPENDERS = { [S.HAND] = 3, [S.DOGS] = 0, [S.IMP_LORD] = 1, [S.RAVAGER] = 1, [S.DOOMGUARD] = 1 }
State.GAINS ={ [S.SHADOW] = 1, [S.DEMONBOLT] = 2, [S.INFERNAL] = 3 }
-- A finished cast's shards reach UnitPower after UNIT_SPELLCAST_SUCCEEDED (12.1.5 trace: Shadow
-- Bolt 0-0.3 s later, after a refresh in 63 of 95 casts). Its gain is held until the reading moves.
State.POWER_LAG = 0.5
-- Dominion of Argus is one four-rank node: rank 1 opens it, ranks 2-3 add 5 s each, rank 4
-- refunds shards. 12.1.5 logs: exactly 15.0 s (rank 1, 33 windows) and 20.0 s (rank 2, 5),
-- timed from Tyrant; Hand of Gul'dan never refreshed it.
State.ARGUS = { node = 110404, aura = 1276166, base = 15, perRank = 5, extraRanks = 2 }

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
local function rank(node)
    local config = Signal.Read(C_ClassTalents and C_ClassTalents.GetActiveConfigID)
    if not numeric(config) then return Signal.Unknown("talent-config") end
    return field(Signal.Read(C_Traits and C_Traits.GetNodeInfo, config.value, node), "currentRank")
end
local function put(s, key, r, default)
    if r and r.state ~= "unknown" and not Signal.IsSecret(r.value) and type(r.value) == type(default) then
        s[key] = r.value
    else s[key], s.unknown[key] = default, true end
end

function State:Reset()
    self.cache, self.cooldowns, self.refreshedAt, self.argusAt, self.handAt = nil, {}, nil, nil, nil
    self.castShards, self.heldGain, self.procSince = nil, nil, {}
    self.tyrantAt, self.artProc, self.handArt = nil, nil, nil
    Kairos.DemonologyDemons:Reset()
    Kairos.DemonologyRitual:Reset()
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
    if c.talent.inner_demons then Kairos.DemonologyDemons.innerTalent = c.talent.inner_demons.value end
    local A = self.ARGUS
    local argusRank = rank(A.node)
    if numeric(argusRank) then
        c.argusDuration = A.base + A.perRank * math.max(0, math.min(A.extraRanks, argusRank.value - 1))
    end
    -- A running Argus (a pull that ended inside it) states its own duration out of combat.
    local hidden = Signal.Read(C_Secrets and C_Secrets.ShouldSpellAuraBeSecret, A.aura)
    if boolean(hidden) and not hidden.value then
        local duration = field(Signal.Read(C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID, A.aura), "duration")
        if numeric(duration) and duration.value > 0 then c.argusDuration = duration.value end
    end
    self:AnchorRitual(t)
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
        local enabled = field(info, "isEnabled")
        if numeric(start) and numeric(duration) and numeric(rate) and rate.value > 0 then
            local own = self.cooldowns[id]
            local cast = own and own.cast
            if boolean(enabled) and not enabled.value then
                -- A deferred cooldown starts when its effect ends: at least a full one from now.
                self.cooldowns[id] = { finish = t + (own and own.base or base), base = own and own.base or base,
                    cast = cast }
            elseif duration.value > 2 then
                self.cooldowns[id] = { finish = start.value + duration.value / rate.value,
                    base = duration.value / rate.value, cast = cast }
            else
                -- An idle read can't cancel our own cast's cooldown while the client catches
                -- up: the read can lag the cast event, and a Grimoire replaced after casting
                -- (12.1.5: Imp Lord's entry becomes 132411) reads its original ID as idle.
                local override = Signal.Read(C_Spell and C_Spell.GetOverrideSpell, id)
                local replaced = numeric(override) and override.value ~= id
                if not (cast and own.finish > t and (t - cast < self.READ_LAG or replaced)) then
                    self.cooldowns[id] = { finish = t, base = base }
                end
            end
        end
    end
end

-- Ritual and Art auras are readable out of combat: they anchor the ritual model. Any
-- unknown read leaves the model as it was.
function State:AnchorRitual(t)
    local R, readings = Kairos.DemonologyRitual, {}
    for kind, ids in pairs(R.AURAS) do
        readings[kind] = {}
        for slot, id in pairs(ids) do
            local hidden = Signal.Read(C_Secrets and C_Secrets.ShouldSpellAuraBeSecret, id)
            if not boolean(hidden) or hidden.value then return end
            local r = Signal.Read(C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID, id)
            if r.state == "unknown" then return end
            local expires = r.value ~= nil and field(r, "expirationTime")
            if expires and not numeric(expires) then return end
            readings[kind][slot] = expires and expires.value or false
        end
    end
    R:Anchor(t, readings)
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
        self.cooldowns[id] = { finish = t + base, base = base, cast = t }
    end
    if id == S.DEMONBOLT and self.lastCoreUp and self.cooldowns[S.DOOMGUARD] then
        self.cooldowns[S.DOOMGUARD].finish = math.max(t, self.cooldowns[S.DOOMGUARD].finish - 3)
    end
    if id == S.HAND then self.handAt = t end
    if id == S.INFERNAL or id == S.RUINATION then self.procSince[id] = nil end
    -- The base is the reading during the cast, or at the keypress for an instant (live, an
    -- instant Demonbolt's +2 also lands after its success); the gain counts until the
    -- reading leaves it. A hold still waiting on the same base adds to this one.
    local casting, sent = self.castShards, self.sentShards
    self.castShards, self.sentShards = nil, nil
    local base = casting and casting.spellID == id and casting.base
    if not base and sent and t - sent.at < self.POWER_LAG then base = sent.base end
    local own = self.GAINS[id]
    -- A Hand inside Dominion of Argus (rank 4) refunds a shard ~20 ms after its success, while
    -- the reading already shows its cost (12.1.5 key: 66 refunds): hold it from the paid base.
    local argus = self.argusAt and t < self.argusAt + (c.argusDuration or self.ARGUS.base)
    if id == S.HAND and argus and talent("argus3") and base then own, base = 1, math.max(0, base - 3) end
    if base and own then
        local held = self.heldGain
        local gain = own + (held and held.base == base and t - held.at < self.POWER_LAG and held.gain or 0)
        self.heldGain = { gain = gain, base = base, at = t }
    end
    -- Diabolic Ritual: spenders in combat advance it, and a Hand consumes the Art that was up
    -- when its cast began. That Art's proc lands 0-0.1 s after the Hand (ART_LAG).
    if id == S.HAND then self.handArt = nil end
    if self.SPENDERS[id] and talent("diabolic_ritual") and Kairos.State.inCombat then
        local R = Kairos.DemonologyRitual
        local machine = talent("infernal_machine") and self.tyrantAt ~= nil
            and t < self.tyrantAt + R.TYRANT + (talent("reign_of_tyranny") and R.REIGN or 0)
        local spent = self.SPENDERS[id]
        if id == S.HAND then
            if casting and casting.spellID == id then spent = math.min(spent, casting.base) end
            local cast = Kairos.State.cast
            local start = cast and cast.spellID == S.HAND and cast.startsAt or t - self:CastTime(S.HAND)
            self.handArt = R:Hand(t, start, spent, machine)
            local key = self.handArt and R.PROCS[self.handArt]
            self.artProc = key and { key = key, at = t } or nil
        else R:Spend(t, spent, machine) end
    end
    if id == S.TYRANT then self.tyrantAt = t end
    Kairos.DemonologyDemons:OnCast(id, t, c.haste or 0, talent("to_hell_and_back"))
    if id == S.TYRANT and talent("argus") then self.argusAt = t end
    Kairos.Recorder:Push({ k = "demo", imps = Kairos.DemonologyDemons:Count(t), spell = id,
        art = id == S.HAND and (self.handArt == false and "none" or self.handArt) or nil })
end

-- Project only deterministic effects. Random Core gains/extra guardians remain
-- outside the model and will be corrected by readable shards, glows and future probes.
-- start is when the cast began: a Hand consumes the Demonic Art up then.
function State:Project(s, id, finish, start)
    local gain = self.GAINS
    -- 12.1.5 client readings: Dreadstalkers spends no shards (7/7 casts), Imp Lord one.
    local cost = { [S.HAND] = 3, [S.IMP_LORD] = 1, [S.RAVAGER] = 1, [S.DOOMGUARD] = 1 }
    if gain[id] then s.shards = math.min(5, s.shards + gain[id])
    elseif cost[id] then s.shards = math.max(0, s.shards - cost[id]) end
    if id == S.HAND or id == S.RUINATION then
        -- Ruination's imps land after a delay, possibly past the evaluated boundary.
        if id == S.HAND or finish + Kairos.DemonologyDemons.RUINATION_DELAY <= s.t then s.imps = s.imps + 3 end
        if s.argusUp and s.talent.argus3 then s.shards = math.min(5, s.shards + 1) end
        if s.argusUp and s.talent.unknown.argus3 then s.unknown.shards = true end
    end
    if id == S.HAND and s.talent.diabolic_ritual and start then
        local R = Kairos.DemonologyRitual
        local kind = R:ArtAt(start)
        s.handArtKnown = kind ~= nil
        local key = kind and R.PROCS[kind]
        if key then s[key], s.unknown[key] = true, nil end
    end
    if id == S.RUINATION then s.ruinationReady, s.unknown.ruinationReady = false, nil end
    if id == S.INFERNAL then s.infernalReady, s.unknown.infernalReady = false, nil end
    if id == S.TYRANT and s.talent.argus then self:ArgusFrom(s, finish) end
    if id == S.IMPLOSION then
        s.imps = s.talent.to_hell_and_back and 3 or 0
        if s.talent.unknown.to_hell_and_back then s.unknown.imps = true end
    elseif id == S.SIPHON then s.imps = math.max(0, s.imps - 2) end
    if id == S.DEMONBOLT and s.coreUp then
        -- A hidden count keeps coreStacks as its lower bound: 1..4 becomes 0..3, so
        -- presence is unknown.
        s.coreStacks = math.max(0, s.coreStacks - 1)
        if s.unknown.coreStacks then s.unknown.coreUp = true else s.coreUp = s.coreStacks > 0 end
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
    put(s, "shards", shards(), 0)
    local reading = not s.unknown.shards and s.shards or nil
    local held = self.heldGain
    if held and (reading ~= held.base or now - held.at >= self.POWER_LAG) then self.heldGain, held = nil, nil end
    if held then s.shards, s.heldShards = math.min(5, s.shards + held.gain), held.gain end
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
    -- A proc is timed from the first refresh that sees its override; one that will have
    -- ended by the time the GCD does isn't available.
    s.procUntil = {}
    local R = Kairos.DemonologyRitual
    for key, id in pairs(self.PROCS) do
        if not s.unknown[key] then
            -- Only a Hand's Art grants these: a new one names the Art it consumed.
            if s[key] and not self.procSince[id] and self.handAt and now - self.handAt < 2 then
                R:Learn(key == "infernalReady" and "mother" or "pit_lord")
            end
            self.procSince[id] = s[key] and (self.procSince[id] or now) or nil
            if self.procSince[id] then
                s.procUntil[key] = self.procSince[id] + self.PROC_LIFE
                if s.procUntil[key] <= s.t then s[key] = false end
            end
        end
    end
    -- A Hand in progress or just landed may still grant its Demonic Art's proc. When the
    -- ritual model says which Art the landed one consumed, its proc counts before it shows.
    local casting = cast and cast.spellID == S.HAND and cast.endsAt > now
    local landed = self.handAt ~= nil and now - self.handAt < self.ART_LAG
    s.handPending = casting or landed
    local proc = self.artProc
    if proc and now - proc.at < self.ART_LAG and not s[proc.key] then
        s[proc.key], s.unknown[proc.key] = true, nil
    end
    s.argusDuration = c.argusDuration
    s.argusUp = false
    if self.argusAt and s.talent.argus then self:ArgusFrom(s, self.argusAt) end
    if s.talent.unknown.argus then s.unknown.argusUp = true end
    -- Where readable, Implosion's cast count is the true imp count (see Demons.lua).
    if s.known[S.IMPLOSION] then
        local count = Signal.Read(C_Spell and C_Spell.GetSpellCastCount, S.IMPLOSION)
        if numeric(count) then Kairos.DemonologyDemons:Anchor(now, count.value, c.haste or 0) end
    end
    s.imps = Kairos.DemonologyDemons:Read(s.t).value
    s.impExpiry = Kairos.DemonologyDemons:Expiries(s.t)
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
    if cast and not cast.channel and cast.endsAt > now then
        self.castShards = reading and { spellID = cast.spellID, base = reading } or nil
        self:Project(s, cast.spellID, cast.endsAt, cast.startsAt)
    end
    if s.handPending then
        s.pendingArtKnown = (casting and s.handArtKnown) or (not casting and landed and self.handArt ~= nil) or false
    end
    self:Castable(s, Kairos.State:Moving())
    return s
end

-- Dominion of Argus from a Tyrant at `from`. Without a known rank it surely lasts the base
-- duration and possibly every extra rank's; only that span is unknown.
function State:ArgusFrom(s, from)
    local A = self.ARGUS
    s.argusUntil = from + (s.argusDuration or A.base + A.perRank * A.extraRanks)
    s.argusSure = from + (s.argusDuration or A.base)
    s.argusUp = s.argusUntil > s.t
    s.unknown.argusUp = (s.argusUp and s.argusSure <= s.t) or s.talent.unknown.argus or nil
end

function State:CastTime(id, coreUp)
    if id == S.DEMONBOLT and coreUp then return 0 end
    local time = self.cache and self.cache.castTimes[id]
    if time == nil then time = self.CAST_TIMES[id] or 0 end
    return time
end

-- Movement filters availability before the APL picks, so moving prefers instants.
function State:Castable(s, moving)
    local stationary = moving.state ~= "unknown" and not moving.value
    for _, id in pairs(S) do
        local time = self:CastTime(id, s.coreUp)
        s.castable[id] = time == 0 or stationary
        s.unknown["castable:" .. id] = time > 0 and moving.state == "unknown" or nil
    end
end

local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = type(v) == "table" and copy(v) or v end
    return out
end

-- One lookahead step (SPEC §7.3): a copy of the state when the main pick's cast or GCD
-- ends, with only its deterministic effects applied.
function State:Advance(s, id, moving)
    local q = copy(s)
    local cast = self:CastTime(id, s.coreUp)
    local start, finish = s.t + cast, s.t + math.max(cast, s.gcdMax)
    q.t = finish
    for cd, remains in pairs(q.remains) do
        if remains > 0 then
            q.remains[cd] = math.max(0, remains - (finish - s.t))
            q.ready[cd] = q.remains[cd] == 0
        end
    end
    -- Power Siphon takes the oldest imps first, which are the ones about to expire.
    local expiring = 0
    for _, batch in ipairs(s.impExpiry or {}) do
        if batch.at <= finish then expiring = expiring + batch.n end
    end
    if id == S.SIPHON then expiring = math.max(0, expiring - 2) end
    q.imps = math.max(0, q.imps - expiring)
    if q.argusUp and q.argusUntil and q.argusUntil <= start then q.argusUp = false end
    self:Project(q, id, start, s.t)
    if q.argusUp and q.argusUntil and q.argusUntil <= finish then q.argusUp = false end
    if q.argusUp and q.argusSure and q.argusSure <= finish then q.unknown.argusUp = true end
    for key in pairs(self.PROCS) do
        if q[key] and q.procUntil and q.procUntil[key] and q.procUntil[key] <= finish then q[key] = false end
    end
    self:Castable(q, moving)
    return q
end

-- The queued pick has to hold whatever the model can't time inside the window: Demonic
-- Cores from imps or Dreadstalkers (every count from the lower bound to the cap, which
-- also covers a hidden count) and Infernal Bolt or Ruination. Those come only from the
-- Hand of Gul'dan that consumes a Demonic Art (12.1.5 log: Mother of Chaos gives Infernal
-- Bolt, Pit Lord Ruination, within 0.1 s), so they're possible only after a Hand. Any
-- disagreement or unknown read hides the queued icon (G3).
function State:Queue(s, id, moving)
    local q = self:Advance(s, id, moving)
    -- Unless the ritual model knows which Art a Hand consumes, it may bring either proc.
    local art = (id == S.HAND and not q.handArtKnown) or (s.handPending and not s.pendingArtKnown)
    local procs = {}
    for key, proc in pairs({ infernalReady = S.INFERNAL, ruinationReady = S.RUINATION }) do
        local learnable = q.known[proc] or q.known.unknown[proc]
        if q.unknown[key] or (art and not q[key] and learnable) then procs[key] = { false, true }
        else procs[key] = { q[key] } end
    end
    local first, cap = nil, (q.talent.demoniac or q.talent.unknown.demoniac) and 4 or q.coreStacks
    for n = q.coreStacks, cap do
        for _, infernal in ipairs(procs.infernalReady) do
            for _, ruination in ipairs(procs.ruinationReady) do
                q.coreStacks, q.coreUp, q.infernalReady, q.ruinationReady = n, n > 0, infernal, ruination
                q.unknown.coreStacks, q.unknown.coreUp = nil, nil
                q.unknown.infernalReady, q.unknown.ruinationReady = nil, nil
                self:Castable(q, moving)
                local pick, uncertain = self:Pick(q)
                if uncertain or not pick or (first and pick.spellID ~= first.spellID) then return nil end
                first = first or pick
            end
        end
    end
    return first
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
    pick.uncertain = uncertain
    local queued = not uncertain and pick.spellID and self:Queue(s, pick.spellID, Kairos.State:Moving())
    pick.queuedID, pick.queuedLabel = queued and queued.spellID or nil, queued and queued.label or nil
    pick.queuedUncertain = not queued
    -- Secret-checked contract inputs; the recorder copies them only when it persists.
    if Kairos.Recorder:Enabled() then
        pick.diagnostic = { v = 1, now = now, projected = s, movement = Kairos.State:Moving(),
            cast = Kairos.State.cast }
    end
    return pick
end

function State:OnInit()
    Kairos.APL:Register(266, self)
    local function refresh()
        local now = clock()
        if now then self:Refresh(now) end
    end
    Kairos:On("KAIROS_PROFILE_CHANGED", function() self:Reset(); refresh() end)
    -- The keypress comes before the cast can change shards: an instant's hold base.
    Kairos:OnUnit("UNIT_SPELLCAST_SENT", "player", function()
        local now, reading = clock(), shards()
        if Kairos.specID == 266 and now and numeric(reading) and not Signal.IsSecret(reading.value) then
            self.sentShards = { at = now, base = reading.value }
        end
    end)
    Kairos:On("KAIROS_PLAYER_CAST", function(_, id)
        if Kairos.specID ~= 266 then return end
        local now = clock()
        if now then self:OnCast(id, now) end
    end)
    Kairos:On("KAIROS_COMBAT_CHANGED", function(_, on)
        local now = clock()
        if Kairos.specID == 266 and now then Kairos.DemonologyDemons:SetCombat(on, now) end
        -- The pull's archive keeps the phase learned out of combat, for the offline replay.
        local phase = Kairos.DemonologyDemons.inner
        if Kairos.specID == 266 and on and phase then Kairos.Recorder:Push({ k = "inner", phase = phase }) end
    end)
    Kairos:On("KAIROS_TARGET_CHANGED", function(_, on)
        local now = clock()
        if Kairos.specID == 266 and now then Kairos.DemonologyDemons:SetTarget(on, now) end
    end)
    for _, event in ipairs({ "SPELLS_CHANGED", "TRAIT_CONFIG_UPDATED", "PLAYER_REGEN_ENABLED" }) do
        Kairos:On(event, refresh)
    end
    -- A loading screen can move Inner Demons' phase; it's relearned out of combat.
    Kairos:On("PLAYER_ENTERING_WORLD", function() Kairos.DemonologyDemons:Zone() end)
    Kairos:OnUnit("UNIT_SPELL_HASTE", "player", refresh)
end

function State:OnLogin()
    local now = clock()
    if now then self:Refresh(now) end
end
