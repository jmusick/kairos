-- Signal layer (SPEC §7.1). Every client read goes through here. A read returns
-- known(v), estimated(v, err) or unknown(reason) and never throws on a secret value.
local _, Kairos = ...
local Signal = Kairos:NewModule("Signal")

local issecretvalue = issecretvalue or function() return false end

Signal.KNOWN = "known"
Signal.ESTIMATED = "estimated"
Signal.UNKNOWN = "unknown"

function Signal.Known(value)
    return { state = "known", value = value }
end

function Signal.Estimated(value, err)
    return { state = "estimated", value = value, err = err or 0 }
end

--- reason: "secret", "error", "missing" (API not present), or a module-specific string.
function Signal.Unknown(reason)
    return { state = "unknown", reason = reason }
end

function Signal.IsSecret(value)
    return issecretvalue(value) == true
end

function Signal.IsKnown(reading)
    return reading.state ~= "unknown"
end

--- Calls fn(...) and wraps its first return value.
function Signal.Read(fn, ...)
    if type(fn) ~= "function" then return Signal.Unknown("missing") end
    local ok, value = pcall(fn, ...)
    if not ok then return Signal.Unknown("error") end
    if issecretvalue(value) then return Signal.Unknown("secret") end
    return Signal.Known(value)
end

--- Reads tbl[key] from a returned info table whose fields may be secret.
function Signal.ReadField(tbl, key)
    if tbl == nil then return Signal.Unknown("missing") end
    if issecretvalue(tbl) then return Signal.Unknown("secret") end
    local ok, value = pcall(function() return tbl[key] end)
    if not ok then return Signal.Unknown("error") end
    if issecretvalue(value) then return Signal.Unknown("secret") end
    return Signal.Known(value)
end

-- Restriction tracking. ADDON_RESTRICTION_STATE_CHANGED carries the new state, and
-- IsAddOnRestrictionActive reads false during that event's dispatch, so trust the event.
Signal.restrictions = {}

local function restrictionName(id)
    local types = Enum and Enum.AddOnRestrictionType
    if types then
        for name, value in pairs(types) do
            if value == id then return name end
        end
    end
    return tostring(id)
end

function Signal:RefreshRestrictions()
    local api = C_RestrictedActions
    local types = Enum and Enum.AddOnRestrictionType
    if not (api and api.IsAddOnRestrictionActive and types) then return end
    for name, id in pairs(types) do
        local reading = Signal.Read(api.IsAddOnRestrictionActive, id)
        self.restrictions[name] = reading.state == "known" and reading.value == true
    end
end

function Signal:IsRestricted()
    for _, active in pairs(self.restrictions) do
        if active then return true end
    end
    return false
end

--- Comma-separated list of active restrictions, or "none".
function Signal:DescribeRestrictions()
    local active = {}
    for name, on in pairs(self.restrictions) do
        if on then active[#active + 1] = name end
    end
    table.sort(active)
    return #active > 0 and table.concat(active, ",") or "none"
end

function Signal:OnInit()
    self:RefreshRestrictions()
    Kairos:On("ADDON_RESTRICTION_STATE_CHANGED", function(_, restrictionType, state)
        if issecretvalue(restrictionType) or issecretvalue(state) then
            self:RefreshRestrictions()
        else
            local inactive = Enum and Enum.AddOnRestrictionState and Enum.AddOnRestrictionState.Inactive or 0
            self.restrictions[restrictionName(restrictionType)] = state ~= inactive
        end
        Kairos:Fire("KAIROS_RESTRICTIONS_CHANGED", self:IsRestricted())
    end)
end
