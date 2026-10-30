-- Toggles (SPEC §7.5, D18). v1 has one: Cooldowns. When it's off, abilities tagged
-- toggle=cooldowns in spec metadata read as just used (D15): ready=false and remains
-- equal to the full cooldown. Flipping an addon flag isn't protected, so it works in combat.
local _, Kairos = ...
local Toggles = Kairos:NewModule("Toggles")

Toggles.LIST = {
    { key = "cooldowns", label = "Cooldowns", short = "CD" },
}

BINDING_HEADER_KAIROS = "Kairos"
BINDING_NAME_KAIROS_TOGGLE_COOLDOWNS = "Toggle Cooldowns"

function Toggles:Get(key)
    return Kairos.profile.toggles[key] ~= false
end

function Toggles:Set(key, on)
    Kairos.profile.toggles[key] = on and true or false
    Kairos:Fire("KAIROS_TOGGLE_CHANGED", key, self:Get(key))
end

function Toggles:Flip(key)
    self:Set(key, not self:Get(key))
    return self:Get(key)
end

--- True when an ability with this toggle tag must be held (its toggle is off).
--- Untagged abilities are never held.
function Toggles:IsHeld(tag)
    if not tag then return false end
    return not self:Get(tag)
end

--- Applies D15 to a cooldown reading: a held ability looks like it was just pressed.
function Toggles:ApplyToCooldown(tag, ready, remains, fullCooldown)
    if self:IsHeld(tag) then
        return false, fullCooldown
    end
    return ready, remains
end

-- Called from Bindings.xml.
function Kairos.ToggleCooldowns()
    local on = Toggles:Flip("cooldowns")
    Kairos:Print("Cooldowns %s.", on and "|cff40ff40ON|r" or "|cffff4040OFF|r")
end
