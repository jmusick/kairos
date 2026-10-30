-- Blizzard's Assisted Combat (SPEC §4): the fallback floor. Shown with an "AC" badge
-- whenever Kairos has no APL for the spec (D33) or isn't sure of its own pick (D17).
local _, Kairos = ...
local Assisted = Kairos:NewModule("Assisted")
local Signal = Kairos.Signal

--- known(true/false) plus failureReason, or unknown.
function Assisted:IsAvailable()
    local api = C_AssistedCombat
    if not (api and api.IsAvailable) then return Signal.Unknown("missing") end
    local ok, available, failureReason = pcall(api.IsAvailable)
    if not ok then return Signal.Unknown("error") end
    if Signal.IsSecret(available) then return Signal.Unknown("secret") end
    local reading = Signal.Known(available)
    if not Signal.IsSecret(failureReason) then reading.failureReason = failureReason end
    return reading
end

--- Blizzard's next spell, or nil.
function Assisted:NextSpell()
    local api = C_AssistedCombat
    local reading = Signal.Read(api and api.GetNextCastSpell, false)
    if reading.state == "known" and reading.value and reading.value ~= 0 then
        return reading.value
    end
    return nil
end

--- Blizzard's rotation spell list for the current spec (used by the probe).
function Assisted:RotationSpells()
    local api = C_AssistedCombat
    local reading = Signal.Read(api and api.GetRotationSpells)
    if reading.state == "known" and type(reading.value) == "table" then
        return reading.value
    end
    return {}
end
