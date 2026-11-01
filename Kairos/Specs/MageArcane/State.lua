-- Live contract for the generated Sunfury APL. All client data enters through Signal.
-- Unknown inputs use harmless placeholders ONLY behind an access-tracking proxy: any
-- unknown read on the priority path (including rejected earlier rules) forces AC.
-- Estimates count as known. No generated code or live estimator is mutated by lookahead.
local _, Kairos = ...
local State = Kairos:NewModule("ArcaneState")
local Signal = Kairos.Signal
local S = Kairos.ArcaneAPL.SPELLS

-- Probe 70575: actual cooldowns, not haste-scaled; keep toggle tags in step with
-- translator/metadata/mage_arcane.json. Pulse is the Mage spell, not the Nightborne racial.
State.COOLDOWNS = { [S.TOUCH] = 45, [S.SURGE] = 90, [S.ORB] = 20, [S.PULSE] = 15 }
State.TAGS = { [S.TOUCH] = "cooldowns", [S.SURGE] = "cooldowns" }
State.SURGE_DURATION = 17.4
-- Pinned SimC gives Orb 30 yd/s over 40 yd; allow a small delivery margin.
-- Own-cast guard only: don't spend the second charge while the first Orb arrives.
State.ORB_FLIGHT_WINDOW = 1.5
State.SET_BONUS = 1296582 -- Mage Arcane 12.1 Class Set 4pc (passive, not the stack aura)
State.SET_ID = 2060 -- Primal Leywarden's Attire, pinned item_set_bonus.inc
State.GLEAM = 1295147
-- Spell IDs also resolve unselected hero talents, whose names need not be cached.
State.TALENTS = { spellfire_spheres = 448601, splintering_sorcery = 443739, slipstream = 236457 }
local stationary = { [S.BLAST] = true, [S.BOLT] = true, [S.SURGE] = true, [S.PULSE] = true, [S.MISSILES] = true }

local function number(reading)
    return reading.state ~= "unknown" and type(reading.value) == "number"
end

local function field(info, key)
    if info.state == "unknown" then return info end
    return Signal.ReadField(info.value, key)
end

local function knows(id)
    return Signal.Read(C_SpellBook and C_SpellBook.IsSpellKnown or IsPlayerSpell or IsSpellKnown, id)
end

function State:Reset()
    self.static, self.cooldowns, self.orb = nil, {}, nil
    self.refreshedAt, self.surgeAt, self.salvoUnmodeled = nil, nil, false
    self.orbPendingUntil = nil
end
State:Reset()

function State:ReadSetBonus()
    local count, unknown = 0, 0
    for _, slot in ipairs({ 1, 3, 5, 7, 10 }) do
        local item = Signal.Read(GetInventoryItemID, "player", slot)
        if item.state == "unknown" then unknown = unknown + 1
        elseif item.value ~= nil then
            local name = Signal.Read(C_Item and C_Item.GetItemInfo, item.value)
            local set = Signal.Read(function()
                return (select(16, C_Item.GetItemInfo(item.value)))
            end)
            if name.state == "unknown" or name.value == nil or set.state == "unknown" then unknown = unknown + 1
            elseif set.value == self.SET_ID then count = count + 1 end
        end
    end
    if count >= 4 then return Signal.Known(true) end
    if count + unknown < 4 then return Signal.Known(false) end
    return Signal.Unknown("item-data")
end

-- Called on login/context changes and at most once a second outside combat. Never
-- replace a good cache with a secret read at a restriction transition.
function State:Refresh(t)
    if Kairos.specID ~= 62 or Kairos.State.inCombat then return end
    local locked = Signal.Read(InCombatLockdown)
    if locked.state ~= "known" or locked.value then return end
    self.refreshedAt = t
    local cache = self.static or { known = {}, talent = {} }
    self.static = cache
    local haste = Signal.Read(UnitSpellHaste, "player")
    if number(haste) then cache.gcdMax = Signal.Estimated(math.max(0.75, 1.5 / (1 + haste.value / 100))) end
    for _, id in pairs(S) do
        local reading = knows(id)
        if reading.state ~= "unknown" then cache.known[id] = reading end
    end
    -- Bolt temporarily overrides Blast; absence from the pre-pull spellbook is normal.
    cache.known[S.BOLT] = cache.known[S.BLAST]
    for key, id in pairs(self.TALENTS) do
        local reading = knows(id)
        if reading.state ~= "unknown" then cache.talent[key] = reading end
    end
    local set = knows(self.SET_BONUS)
    local hidden = Signal.Read(C_Secrets and C_Secrets.ShouldAurasBeSecret)
    local canReadAuras = hidden.state == "known" and hidden.value == false
    local setHidden = Signal.Read(C_Secrets and C_Secrets.ShouldSpellAuraBeSecret, self.SET_BONUS)
    local canReadSet = canReadAuras and setHidden.state == "known" and setHidden.value == false
    local passive = canReadSet and Signal.Read(C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID, self.SET_BONUS)
        or Signal.Unknown("restricted-aura")
    if passive.state == "known" and passive.value ~= nil then
        cache.setS2_4pc = Signal.Known(true)
    elseif set.state == "known" and set.value == true then
        cache.setS2_4pc = set
    else
        -- Item-effect passives need not be in the spellbook. A false spell-knowledge
        -- result cannot prove the four-piece is absent.
        local equipped = self:ReadSetBonus()
        if equipped.state ~= "unknown" then cache.setS2_4pc = equipped end
    end
    -- Use the pinned aura ID; an unresolved name must not block every ready Surge.
    local gleamHidden = Signal.Read(C_Secrets and C_Secrets.ShouldSpellAuraBeSecret, self.GLEAM)
    local gleam = canReadAuras and gleamHidden.state == "known" and gleamHidden.value == false
        and Signal.Read(C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName,
        "player", "Lustrous Gleam", "HELPFUL") or Signal.Unknown("restricted-aura")
    if gleam.state == "known" then
        if gleam.value == nil then cache.lustrousGleam = Signal.Estimated(0)
        else
            local stacks = field(gleam, "applications")
            if number(stacks) then cache.lustrousGleam = Signal.Estimated(stacks.value) end
        end
    end
    for id, base in pairs(self.COOLDOWNS) do
        local info = Signal.Read(C_Spell and C_Spell.GetSpellCooldown, id)
        local start, duration, rate = field(info, "startTime"), field(info, "duration"), field(info, "modRate")
        if number(start) and number(duration) and number(rate) and rate.value > 0 then
            -- A normal spell read can be just the GCD. Don't anchor a 90 s cooldown to it.
            local finish = duration.value > 2 and start.value + duration.value / rate.value or t
            self.cooldowns[id] = { finish = finish, base = base }
        end
    end
    local info = Signal.Read(C_Spell and C_Spell.GetSpellCharges, S.ORB)
    local n, max = field(info, "currentCharges"), field(info, "maxCharges")
    local start, duration = field(info, "cooldownStartTime"), field(info, "cooldownDuration")
    local rate = field(info, "chargeModRate")
    if number(n) and number(max) and number(start) and number(duration) then
        local recharge = duration.value / (number(rate) and rate.value > 0 and rate.value or 1)
        if recharge > 0 then
            self.orb = { n = n.value, max = max.value, start = start.value, duration = recharge }
        end
    end
end

local function orbAt(orb, t)
    if not orb then return nil end
    if orb.n >= orb.max then return orb.max end
    return math.min(orb.max, orb.n + math.max(0, t - orb.start) / orb.duration)
end

function State:OnCast(id, t)
    if self.COOLDOWNS[id] then self.cooldowns[id] = { finish = t + self.COOLDOWNS[id] } end
    if id == S.SURGE then self.surgeAt = t end
    if id == S.PULSE then self.salvoUnmodeled = true end
    if id == S.BARRAGE and not Kairos.ArcaneSalvo:InSoul(t) then self.salvoUnmodeled = false end
    if id == S.BARRAGE then self.orbPendingUntil = nil end -- new spend can need Orb again
    if id == S.ORB then
        self.orbPendingUntil = t + self.ORB_FLIGHT_WINDOW
        local n = orbAt(self.orb, t)
        if n then
            local whole = math.floor(n)
            self.orb = { n = math.max(0, whole - 1), max = self.orb.max,
                start = whole >= self.orb.max and t or self.orb.start + (whole - self.orb.n) * self.orb.duration,
                duration = self.orb.duration }
        end
    end
end

local function put(s, key, reading, default)
    if reading and reading.state ~= "unknown" and not Signal.IsSecret(reading.value)
        and type(reading.value) == type(default) then
        s[key] = reading.value
    else
        s[key] = default
        s.unknown[key] = true
    end
end

-- Effects landing at the evaluation boundary. Proc generation is stochastic; leave
-- the observed presence alone for the main pick, an estimate like the stack models.
function State:FinishCast(s, id, t)
    s.prevGcd = id
    if id == S.BLAST or id == S.BOLT then
        -- Offline 70575 log: Blast grants 1; Bolt grants 4 (including overflow).
        s.charges = math.min(4, s.charges + (id == S.BOLT and 4 or 1))
        if id == S.BOLT then s.unknown.charges = nil end
        s.salvo = math.min(25, s.salvo + Kairos.ArcaneSalvo.GAINS[id][1])
        if s.cumulativePower == 8 then s.cumulativePower = 0 end
        if id == S.BOLT then s.boltReady = false; s.unknown.boltReady = nil end
    elseif id == S.SURGE then
        s.surgeUp, s.surgeRemains = true, self.SURGE_DURATION
        s.ready[id], s.remains[id] = false, self.COOLDOWNS[id]
        s.physicalRemains[id] = self.COOLDOWNS[id]
        s.unknown["ready:" .. id], s.unknown["remains:" .. id] = nil, nil
    elseif id ~= S.MISSILES then
        -- An unmodeled in-progress cast must not silently supply a guessed next state.
        s.unknown.charges, s.unknown.salvo = true, true
    end
    s.t = t
end

function State:Build(now, immediate)
    if not self.refreshedAt or now - self.refreshedAt >= 1 then self:Refresh(now) end
    local cache = self.static or { known = {}, talent = {} }
    local s = { unknown = {}, ready = {}, remains = {}, chargesFractional = {},
        known = { unknown = {} }, talent = { unknown = {} }, t = now }
    -- Compare with NOW, not the projected GCD end: advance the icon as soon as
    -- Orb succeeds, even when its hits will land before the next action is queued.
    s.orbInFlight = self.orbPendingUntil ~= nil and now < self.orbPendingUntil
    s.timingUnknown = not immediate and Kairos.State.castUnknown
    local t, cast = now, Kairos.State.cast
    if not immediate then
        if cast then t = math.max(t, cast.endsAt) end
        local gcd = Signal.Read(C_Spell and C_Spell.GetSpellCooldown, 61304)
        local start, duration, rate = field(gcd, "startTime"), field(gcd, "duration"), field(gcd, "modRate")
        if number(start) and number(duration) and rate.state ~= "unknown" then
            t = math.max(t, start.value + duration.value / (number(rate) and rate.value > 0 and rate.value or 1))
        else s.timingUnknown = true end
    end
    s.t = t
    put(s, "charges", Signal.Read(UnitPower, "player", Enum and Enum.PowerType and Enum.PowerType.ArcaneCharges), 0)
    local overlay = C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed
    local cc = Signal.Read(overlay, S.MISSILES)
    put(s, "clearcasting", cc.state ~= "unknown" and Signal.Known(cc.value and 1 or 0) or cc, 0)
    put(s, "boltReady", Signal.Read(overlay, S.BOLT), false)
    put(s, "salvo", Kairos.ArcaneSalvo:Read(t), 0)
    if self.salvoUnmodeled then s.unknown.salvo = true end
    put(s, "cumulativePower", Kairos.ArcaneCumulativePower:Read(t), 0)
    s.soul = Kairos.ArcaneSalvo:InSoul(t)
    s.surgeRemains = self.surgeAt and math.max(0, self.surgeAt + self.SURGE_DURATION - t) or 0
    s.surgeUp = s.surgeRemains > 0
    s.prevGcd = Kairos.State:PrevGcd()
    put(s, "gcdMax", cache.gcdMax, 1.5)
    put(s, "setS2_4pc", cache.setS2_4pc, false)
    put(s, "lustrousGleam", cache.lustrousGleam, 0)
    local enemies = 0
    for unit in pairs(Kairos.State.nameplates) do
        local hostile = Signal.Read(UnitCanAttack, "player", unit)
        if hostile.state == "unknown" then s.unknown.enemies = true
        elseif hostile.value then enemies = enemies + 1 end
    end
    s.enemies = enemies -- D24; dummies can report UnitAffectingCombat=false.
    for _, id in pairs(S) do put(s.known, id, cache.known[id], false) end
    for key in pairs(self.TALENTS) do put(s.talent, key, cache.talent[key], false) end
    s.physicalRemains = {}
    for id, base in pairs(self.COOLDOWNS) do
        local cd = self.cooldowns[id]
        local remains = cd and math.max(0, cd.finish - t) or base
        s.physicalRemains[id] = cd and remains or nil
        s.ready[id], s.remains[id] = Kairos.Toggles:ApplyToCooldown(self.TAGS[id], remains == 0, remains, base)
        if not cd and not Kairos.Toggles:IsHeld(self.TAGS[id]) then
            s.unknown["ready:" .. id], s.unknown["remains:" .. id] = true, true
        end
    end
    local orb = orbAt(self.orb, t)
    s.chargesFractional[S.ORB] = orb or 0
    if orb then
        s.ready[S.ORB] = orb >= 1
        s.remains[S.ORB] = orb >= 1 and 0 or (1 - orb) * self.orb.duration
        s.unknown["ready:" .. S.ORB], s.unknown["remains:" .. S.ORB] = nil, nil
    else
        s.unknown["chargesFractional:" .. S.ORB] = true
        s.unknown["ready:" .. S.ORB], s.unknown["remains:" .. S.ORB] = true, true
    end
    s.chargesFractional[S.PULSE] = s.known[S.PULSE]
        and math.max(0, 1 - s.remains[S.PULSE] / self.COOLDOWNS[S.PULSE]) or 0
    if s.known.unknown[S.PULSE] or (s.known[S.PULSE] and s.unknown["remains:" .. S.PULSE]) then
        s.unknown["chargesFractional:" .. S.PULSE] = true
    end
    if not immediate and cast and not cast.channel and cast.endsAt > now then
        self:FinishCast(s, cast.spellID, t)
        if cast.spellID == S.SURGE then s.surgeRemains = math.max(0, self.SURGE_DURATION - (t - cast.endsAt)) end
    end
    -- An already successful Missiles is being projected by the estimators' Read(t).
    return s
end

-- Proxy leaf reads, including short-circuited availability and higher-priority rules.
-- This is conservative: an unknown read anywhere before the returned pick forces AC,
-- even if a later OR clause could independently prove the same pick.
function State:Pick(s, offGcd, moving)
    local reads = {}
    if s.timingUnknown then reads.timing = true end
    local proxy = setmetatable({}, { __index = function(_, key)
        if s.unknown[key] then reads[key] = true end
        return s[key]
    end })
    for _, key in ipairs({ "ready", "remains", "chargesFractional", "known", "talent" }) do
        proxy[key] = setmetatable({}, { __index = function(_, id)
            if key == "known" and id == S.ORB and s.orbInFlight then return false end
            -- The generated availability gate uses known[]. Block stationary actions
            -- here without changing the cached spellbook or the generated source.
            if key == "known" and moving and stationary[id] then
                if id ~= S.MISSILES or not s.talent.slipstream then
                    if id == S.MISSILES and s.talent.unknown.slipstream then reads["talent:slipstream"] = true end
                    return false
                end
            end
            if s.unknown[key .. ":" .. id] or (s[key].unknown and s[key].unknown[id]) then
                reads[key .. ":" .. id] = true
            end
            return s[key][id]
        end })
    end
    -- Spellslinger is outside the generated contract, even if cooldowns could return.
    if s.talent.splintering_sorcery or s.talent.unknown.splintering_sorcery then
        reads["talent:splintering_sorcery"] = true
    end
    local pick
    if offGcd then pick = Kairos.ArcaneAPL:OffGcd(proxy) else pick = Kairos.ArcaneAPL:Evaluate(proxy) end
    local fields = {}
    for key in pairs(reads) do fields[#fields + 1] = key end
    table.sort(fields)
    return pick, #fields > 0, #fields > 0 and table.concat(fields, ", ") or nil
end

-- Pure evaluation entry for offline reproduction of captured live inputs.
function State:EvaluateStates(s, current, moving)
    local isMoving = moving.state ~= "unknown" and moving.value == true
    local pick, uncertain, fields = self:Pick(s, false, isMoving)
    pick = pick or {}
    if (stationary[pick.spellID] and moving.state == "unknown") or (isMoving and not pick.spellID) then
        uncertain = true
        fields = fields and (fields .. ", movement") or "movement"
    end
    pick.uncertain = uncertain
    pick.unknownFields = fields
    local off, offUncertain, offFields = self:Pick(current, true)
    if off and not offUncertain then
        -- Off-GCD Touch is the next button to press now. Preserve the independently
        -- evaluated on-GCD action in the smaller slot, without inventing a future proc.
        off.immediate = true
        off.queuedID = not uncertain and pick.spellID or nil
        off.queuedLabel = pick.label
        off.queuedUncertain = uncertain
        return off
    elseif offUncertain then
        pick.uncertain = true
        pick.unknownFields = fields and (fields .. ", " .. offFields) or offFields
    end
    if not pick.uncertain and pick.spellID == S.BARRAGE then
        -- The user's Barrage/Touch macro presses Touch immediately after Barrage.
        -- Ask the generated rule whether Touch follows at this same boundary;
        -- only prevGcd changes in the fields that its condition reads. This is a
        -- paired cue, not permission to replace the selected on-GCD action.
        local previous = s.prevGcd
        s.prevGcd = S.BARRAGE
        local paired, pairedUncertain = self:Pick(s, true)
        s.prevGcd = previous
        if paired and not pairedUncertain then
            pick.pairedID, pick.pairedLabel = paired.spellID, paired.label
        end
    end
    -- One-step future proc changes aren't modeled yet; keep the queue hidden (G3).
    pick.queuedUncertain = true
    return pick
end

function State:Evaluate()
    local now = Signal.Read(GetTime)
    if not number(now) then return { uncertain = true } end
    local s, current = self:Build(now.value), self:Build(now.value, true)
    local moving = Kairos.State:Moving()
    local pick = self:EvaluateStates(s, current, moving)
    -- These are already secret-checked contract inputs. The recorder takes an
    -- owned, secret-filtered copy only at pick transitions and cast commitment.
    if Kairos.Recorder:Enabled() then
        pick.diagnostic = { v = 1, now = now.value, projected = s, current = current,
            movement = moving, cast = Kairos.State.cast }
    end
    return pick
end

function State:OffGcd()
    local now = Signal.Read(GetTime)
    if not number(now) then return nil end
    local pick, uncertain = self:Pick(self:Build(now.value, true), true)
    if pick then pick.uncertain = uncertain end
    return pick
end

function State:OnInit()
    Kairos.APL:Register(62, self)
    Kairos:On("KAIROS_PLAYER_CAST", function(_, id)
        if Kairos.specID ~= 62 then return end
        local now = Signal.Read(GetTime)
        if number(now) then self:OnCast(id, now.value) end
    end)
    local function refresh()
        local now = Signal.Read(GetTime)
        if number(now) then self:Refresh(now.value) end
    end
    Kairos:On("KAIROS_PROFILE_CHANGED", function()
        self:Reset()
        refresh()
    end)
    for _, event in ipairs({ "PLAYER_REGEN_ENABLED", "SPELLS_CHANGED", "TRAIT_CONFIG_UPDATED", "GET_ITEM_INFO_RECEIVED" }) do
        Kairos:On(event, refresh)
    end
    Kairos:On("PLAYER_EQUIPMENT_CHANGED", function()
        if self.static then self.static.setS2_4pc = nil end
        refresh()
    end)
    Kairos:On("KAIROS_AURA_KNOWN", function(_, name)
        if Kairos.specID == 62 and name == "Arcane Salvo" then self.salvoUnmodeled = false end
    end)
    Kairos:OnUnit("UNIT_SPELL_HASTE", "player", refresh)
end

function State:OnLogin()
    local now = Signal.Read(GetTime)
    if number(now) then self:Refresh(now.value) end
end
