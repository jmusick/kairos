-- Fight traces (SPEC §7.6, §10.2). Records into the flight recorder what Kairos can see
-- during each fight: Arcane Charges, proc glows, and UNIT_AURA updates to aura instances
-- learned out of combat. Before and after each fight it records the real stacks of the
-- spec's tracked auras. Offline, tools/kairos-dump.lua lines these up with the player's
-- casts and the combat log to work out how hidden stacks (Arcane Salvo) build.
local _, Kairos = ...
local Trace = Kairos:NewModule("Trace")
local Signal = Kairos.Signal

local issecretvalue = issecretvalue or function() return false end

Trace.END_DELAY = 0.3 -- auras turn readable a moment after combat ends

-- Aura instance IDs seen while readable, this session: [auraInstanceID] = name and back.
Trace.instances = {}
Trace.instanceByName = {}
-- Last readable stacks per tracked aura (0 = down). Only updated out of combat.
Trace.known = {}

function Trace:ResetEvents()
    self.events = { events = 0, secret = 0, errors = 0, added = 0, addedSecretSpell = 0, byName = {} }
end
Trace:ResetEvents()

local function tracked()
    local spec = Kairos:CurrentSpec()
    local extra = spec and spec.probe
    return extra and extra.buffs or {}, extra and extra.debuffs or {}
end

local function readAura(unit, name, filter)
    local api = C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName
    if not api then return nil end
    local ok, info = pcall(api, unit, name, filter)
    if not ok or issecretvalue(info) then return nil end
    return info
end

--- Reads the tracked auras while they're readable: learns spell and instance IDs and
--- records stack changes. Lookups return nil for secret auras, so never run in combat.
function Trace:Refresh()
    local auraSecret = Signal.Read(C_Secrets and C_Secrets.ShouldAurasBeSecret)
    if Kairos.State.inCombat or (auraSecret.state == "known" and auraSecret.value) then return end

    local buffs, debuffs = tracked()
    for _, name in ipairs(buffs) do
        local info = readAura("player", name, "HELPFUL")
        local stacks = 0
        if info then
            local applications = Signal.ReadField(info, "applications")
            stacks = math.max(applications.state == "known" and applications.value or 0, 1)
            local spellID = Signal.ReadField(info, "spellId")
            if spellID.state == "known" and type(spellID.value) == "number" then
                Kairos.db.global.auraIDs[name] = spellID.value
            end
            local instanceID = Signal.ReadField(info, "auraInstanceID")
            if instanceID.state == "known" and type(instanceID.value) == "number" then
                self.instances[instanceID.value] = name
                self.instanceByName[name] = instanceID.value
            end
        end
        if (self.known[name] or 0) ~= stacks then
            Kairos.Recorder:Push({ k = "aura", name = name, n = stacks })
        end
        self.known[name] = stacks
        Kairos:Fire("KAIROS_AURA_KNOWN", name, stacks)
    end
    for _, name in ipairs(debuffs) do
        if not Kairos.db.global.auraIDs[name] then
            local info = readAura("target", name, "HARMFUL|PLAYER")
            local spellID = info and Signal.ReadField(info, "spellId")
            if spellID and spellID.state == "known" and type(spellID.value) == "number" then
                Kairos.db.global.auraIDs[name] = spellID.value
            end
        end
    end
end

local function copy(tbl)
    local out = {}
    for k, v in pairs(tbl) do out[k] = v end
    return out
end

function Trace:Resource()
    local spec = Kairos:CurrentSpec()
    local resource = spec and spec.resource
    local powerType = resource and Enum and Enum.PowerType and Enum.PowerType[resource.power]
    if not powerType then return nil end
    local reading = Signal.Read(UnitPower, "player", powerType)
    return reading.state == "known" and reading.value or nil, resource.key
end

function Trace:WithResource(entry)
    local value, key = self:Resource()
    if key then entry[key] = value end
    return entry
end

local function countInstances(self, ids, op)
    local stats = self.events
    if ids == nil then return end
    if issecretvalue(ids) then
        stats.secret = stats.secret + 1
        return
    end
    for _, id in ipairs(ids) do
        if issecretvalue(id) then
            stats.secret = stats.secret + 1
        elseif self.instances[id] then
            local name = self.instances[id]
            local key = name .. " " .. op
            stats.byName[key] = (stats.byName[key] or 0) + 1
            Kairos.Recorder:Push({ k = "aura", name = name, op = op })
        end
    end
end

--- Decodes an in-combat UNIT_AURA payload: counts it, and traces updates and removals
--- of known aura instances plus additions (with their spell ID when readable).
function Trace:NoteAuraEvent(updateInfo)
    local stats = self.events
    stats.events = stats.events + 1
    if updateInfo == nil then return end
    if issecretvalue(updateInfo) then
        stats.secret = stats.secret + 1
        return
    end
    local ok = pcall(function()
        countInstances(self, updateInfo.updatedAuraInstanceIDs, "upd")
        countInstances(self, updateInfo.removedAuraInstanceIDs, "rem")
        local added = updateInfo.addedAuras
        if added ~= nil and not issecretvalue(added) then
            for _, aura in ipairs(added) do
                stats.added = stats.added + 1
                local secret = issecretvalue(aura) or issecretvalue(aura.spellId)
                if secret then stats.addedSecretSpell = stats.addedSecretSpell + 1 end
                Kairos.Recorder:Push({ k = "aura", op = "add", spell = not secret and aura.spellId or nil })
            end
        end
    end)
    if not ok then stats.errors = stats.errors + 1 end
end

function Trace:FightStart()
    self:ResetEvents()
    self.fightStart = GetTime()
    Kairos.Recorder:Push(self:WithResource({ k = "fight", phase = "start", at = time(), auras = copy(self.known) }))
end

--- Marks the end right away, then reads the auras once they turn readable. Open-world
--- dummies drop combat within seconds of a pause, so combat can restart inside that
--- delay; the "after" read is skipped then rather than landing in the next fight.
function Trace:FightEnd()
    local stats = self.events
    Kairos.Recorder:Push({
        k = "fight", phase = "end", at = time(),
        length = self.fightStart and (GetTime() - self.fightStart) or nil,
        auraEvents = stats.events, secret = stats.secret, added = stats.added,
    })
    C_Timer.After(self.END_DELAY, function()
        if Kairos.State.inCombat then return end
        self:Refresh()
        Kairos.Recorder:Push(self:WithResource({ k = "fight", phase = "after", auras = copy(self.known) }))
    end)
end

-- Spell watch. For the spec's `watch` spells, records what the client shows on the spell
-- and its action button whenever any of it changes, as one signature string. Offline,
-- `tools/kairos-dump.lua watch` lines the signatures up with hidden auras from the combat
-- log (Overpowered Missiles) to find out whether a secret proc changes anything visible.
Trace.watched = {}
Trace.watchSlots = {}

--- A reading as text: the value, "S" if secret, "E" on error, "-" if the API is missing.
local function shown(fn, ...)
    if type(fn) ~= "function" then return "-" end
    local ok, value = pcall(fn, ...)
    if not ok then return "E" end
    if issecretvalue(value) then return "S" end
    return tostring(value)
end

function Trace:WatchSlot(spellID)
    if self.watchSlots[spellID] == nil then
        local slots = Signal.Read(C_ActionBar and C_ActionBar.FindSpellActionButtons, spellID)
        local slot = slots.state == "known" and type(slots.value) == "table" and slots.value[1]
        self.watchSlots[spellID] = (type(slot) == "number" and not issecretvalue(slot)) and slot or false
    end
    return self.watchSlots[spellID] or nil
end

function Trace:Watch()
    local spec = Kairos:CurrentSpec()
    if not (spec and spec.watch) then return end
    local spells, bar = C_Spell or {}, C_ActionBar or {}
    local overlay = C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed
    for _, spellID in ipairs(spec.watch) do
        local slot = self:WatchSlot(spellID)
        local signature = table.concat({
            "ov=" .. shown(spells.GetOverrideSpell, spellID),
            "tex=" .. shown(spells.GetSpellTexture, spellID),
            "dc=" .. shown(spells.GetSpellDisplayCount, spellID),
            "cc=" .. shown(spells.GetSpellCastCount, spellID),
            "glow=" .. shown(overlay, spellID),
            "slot=" .. tostring(slot or "-"),
            "atex=" .. (slot and shown(bar.GetActionTexture, slot) or "-"),
            "adc=" .. (slot and shown(bar.GetActionDisplayCount, slot) or "-"),
            "atext=" .. (slot and shown(bar.GetActionText, slot) or "-"),
        }, " ")
        if signature ~= self.watched[spellID] then
            self.watched[spellID] = signature
            Kairos.Recorder:Push({ k = "watch", spell = spellID, sig = signature })
        end
    end
end

function Trace:OnInit()
    Kairos:OnUnit("UNIT_AURA", "player", function(_, _, updateInfo)
        if Kairos.State.inCombat then
            self:NoteAuraEvent(updateInfo)
        else
            self:Refresh()
        end
        -- Aura events still fire in combat when a secret proc is applied: check the watch.
        self:Watch()
    end)
    Kairos:On("KAIROS_COMBAT_CHANGED", function(_, inCombat)
        if inCombat then self:FightStart() else self:FightEnd() end
    end)
    Kairos:On("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", function(_, spellID)
        if not issecretvalue(spellID) then Kairos.Recorder:Push({ k = "glow", spell = spellID, on = true }) end
        self:Watch()
    end)
    Kairos:On("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE", function(_, spellID)
        if not issecretvalue(spellID) then Kairos.Recorder:Push({ k = "glow", spell = spellID, on = false }) end
        self:Watch()
    end)
    for _, event in ipairs({ "KAIROS_PLAYER_CAST", "SPELL_UPDATE_ICON", "ACTIONBAR_UPDATE_STATE" }) do
        Kairos:On(event, function() self:Watch() end)
    end
    Kairos:On("ACTIONBAR_SLOT_CHANGED", function() self.watchSlots = {} end)
    Kairos:On("KAIROS_PROFILE_CHANGED", function()
        self.watchSlots = {}
        self.watched = {}
        self.lastResource = nil
    end)
    Kairos:OnUnit("UNIT_POWER_UPDATE", "player", function(_, _, powerType)
        if issecretvalue(powerType) then return end
        local spec = Kairos:CurrentSpec()
        if not spec or not spec.resource or powerType ~= spec.resource.token then return end
        local value, key = self:Resource()
        if value ~= nil and value ~= self.lastResource then
            self.lastResource = value
            Kairos.Recorder:Push({ k = key, n = value })
        end
    end)
end

function Trace:OnLogin()
    self:Refresh()
    self.lastResource = self:Resource()
end
