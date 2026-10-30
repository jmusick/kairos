-- State model (SPEC §7.2), 0.1.0 slice: own casts, the cast in progress, combat,
-- movement and enemy count. Cooldown, aura and resource models arrive with the APL runtime.
local _, Kairos = ...
local State = Kairos:NewModule("State")
local Signal = Kairos.Signal

State.MAX_CASTS = 10

State.casts = {}        -- newest first: { spellID, t }
State.cast = nil        -- { spellID, endsAt, channel } while casting or channeling
State.inCombat = false
State.nameplates = {}   -- [unitToken] = true

function State:RecordCast(spellID, t)
    table.insert(self.casts, 1, { spellID = spellID, t = t })
    self.casts[self.MAX_CASTS + 1] = nil
end

--- The nth most recent successful cast (1 = last), or nil.
function State:PrevCast(n)
    local entry = self.casts[n or 1]
    return entry and entry.spellID
end

function State:UpdateCast(channel)
    -- UnitCastingInfo returns spellID 9th, UnitChannelInfo 8th; both return endTimeMS 5th.
    local fn = channel and UnitChannelInfo or UnitCastingInfo
    local spellIndex = channel and 8 or 9
    local spellID = Signal.Read(function() return (select(spellIndex, fn("player"))) end)
    local endMS = Signal.Read(function() return (select(5, fn("player"))) end)
    if spellID.state == "known" and spellID.value and endMS.state == "known" and endMS.value then
        self.cast = { spellID = spellID.value, endsAt = endMS.value / 1000, channel = channel }
    else
        self.cast = nil
    end
end

--- known(true/false) when GetUnitSpeed is readable, else unknown.
function State:Moving()
    local speed = Signal.Read(GetUnitSpeed, "player")
    if speed.state ~= "known" then return speed end
    return Signal.Known((speed.value or 0) > 0)
end

--- Count of hostile, in-combat enemy nameplates (D24). Unknown if any read is secret.
function State:EnemyCount()
    local count = 0
    for unit in pairs(self.nameplates) do
        local hostile = Signal.Read(UnitCanAttack, "player", unit)
        local fighting = Signal.Read(UnitAffectingCombat, unit)
        if hostile.state ~= "known" or fighting.state ~= "known" then
            return Signal.Unknown(hostile.state ~= "known" and hostile.reason or fighting.reason)
        end
        if hostile.value and fighting.value then count = count + 1 end
    end
    return Signal.Known(count)
end

function State:OnInit()
    Kairos:OnUnit("UNIT_SPELLCAST_SUCCEEDED", "player", function(_, _, _, spellID)
        if Signal.IsSecret(spellID) then return end
        self:RecordCast(spellID, GetTime())
        Kairos:Fire("KAIROS_PLAYER_CAST", spellID)
    end)
    for _, event in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_DELAYED", "UNIT_SPELLCAST_STOP",
        "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED" }) do
        Kairos:OnUnit(event, "player", function() self:UpdateCast(false) end)
    end
    for _, event in ipairs({ "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_UPDATE",
        "UNIT_SPELLCAST_CHANNEL_STOP" }) do
        Kairos:OnUnit(event, "player", function() self:UpdateCast(true) end)
    end

    Kairos:On("PLAYER_REGEN_DISABLED", function()
        self.inCombat = true
        Kairos:Fire("KAIROS_COMBAT_CHANGED", true)
    end)
    Kairos:On("PLAYER_REGEN_ENABLED", function()
        self.inCombat = false
        Kairos:Fire("KAIROS_COMBAT_CHANGED", false)
    end)

    Kairos:On("NAME_PLATE_UNIT_ADDED", function(_, unit)
        if not Signal.IsSecret(unit) then self.nameplates[unit] = true end
    end)
    Kairos:On("NAME_PLATE_UNIT_REMOVED", function(_, unit)
        if not Signal.IsSecret(unit) then self.nameplates[unit] = nil end
    end)
end

function State:OnLogin()
    local combat = Signal.Read(UnitAffectingCombat, "player")
    self.inCombat = combat.state == "known" and combat.value == true
end
