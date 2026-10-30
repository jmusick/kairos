-- Core: the addon namespace, module registry, and event bus.
-- Every other file opens with `local _, Kairos = ...` and registers itself with NewModule.
local addonName, Kairos = ...

_G.Kairos = Kairos

Kairos.name = addonName
Kairos.version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version")) or "dev"

local modules = {}
Kairos.modules = modules

--- Registers a module. Modules get OnInit (ADDON_LOADED, SavedVariables ready) and
--- OnLogin (PLAYER_LOGIN, character info ready) calls in TOC load order.
function Kairos:NewModule(name)
    local module = { name = name }
    modules[#modules + 1] = module
    self[name] = module
    return module
end

-- Event bus. Names starting with KAIROS_ are internal messages and never reach the client.
local call = securecallfunction or function(fn, ...) return fn(...) end
local eventFrame = CreateFrame("Frame")
local listeners = {}

local function dispatch(event, ...)
    local list = listeners[event]
    if not list then return end
    for i = 1, #list do
        call(list[i], event, ...)
    end
end

eventFrame:SetScript("OnEvent", function(_, event, ...) dispatch(event, ...) end)

function Kairos:On(event, fn)
    local list = listeners[event]
    if not list then
        list = {}
        listeners[event] = list
        if event:sub(1, 7) ~= "KAIROS_" then
            eventFrame:RegisterEvent(event)
        end
    end
    list[#list + 1] = fn
end

--- Unit events get their own frame so the client filters by unit. Comparing a unit token
--- from an event payload can raise on a secret, so we never filter in Lua.
function Kairos:OnUnit(event, unit, fn)
    local frame = CreateFrame("Frame")
    frame:RegisterUnitEvent(event, unit)
    frame:SetScript("OnEvent", function(_, ...) call(fn, ...) end)
end

function Kairos:Fire(event, ...)
    dispatch(event, ...)
end

function Kairos:Print(fmt, ...)
    local msg = select("#", ...) > 0 and fmt:format(...) or tostring(fmt)
    DEFAULT_CHAT_FRAME:AddMessage("|cff8fd3ffKairos|r: " .. msg)
end

function Kairos.SpellName(spellID)
    if not spellID then return "none" end
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
    return name or ("spell " .. tostring(spellID))
end

--- Resolves a spell ID or name typed by the player to a spell ID.
function Kairos.ResolveSpell(input)
    if input == nil or input == "" then return nil end
    local id = tonumber(input)
    if id then return id end
    if C_Spell and C_Spell.GetSpellIDForSpellIdentifier then
        id = C_Spell.GetSpellIDForSpellIdentifier(input)
        if id then return id end
    end
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(input)
    return info and info.spellID or nil
end

Kairos:On("ADDON_LOADED", function(_, name)
    if name ~= addonName then return end
    for i = 1, #modules do
        local module = modules[i]
        if module.OnInit then module:OnInit() end
    end
end)

Kairos:On("PLAYER_LOGIN", function()
    for i = 1, #modules do
        local module = modules[i]
        if module.OnLogin then module:OnLogin() end
    end
end)
