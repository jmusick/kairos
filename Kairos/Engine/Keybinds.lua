-- Keybind text (SPEC §7.4, D26). Lookup order: manual override, then the action bar
-- slot holding the spell (directly or through a macro). The slot map is cached and
-- rebuilt when bars, bindings or macros change.
local _, Kairos = ...
local Keybinds = Kairos:NewModule("Keybinds")
local Signal = Kairos.Signal

-- Default action bar slot ranges and the binding command for each button.
Keybinds.BARS = {
    { first = 25, last = 36, command = "MULTIACTIONBAR3BUTTON" },  -- Right Bar 1
    { first = 37, last = 48, command = "MULTIACTIONBAR4BUTTON" },  -- Right Bar 2
    { first = 49, last = 60, command = "MULTIACTIONBAR2BUTTON" },  -- Bottom Right
    { first = 61, last = 72, command = "MULTIACTIONBAR1BUTTON" },  -- Bottom Left
    { first = 145, last = 156, command = "MULTIACTIONBAR5BUTTON" }, -- Bar 6
    { first = 157, last = 168, command = "MULTIACTIONBAR6BUTTON" }, -- Bar 7
    { first = 169, last = 180, command = "MULTIACTIONBAR7BUTTON" }, -- Bar 8
}

local KEY_ABBREVIATIONS = {
    { "SHIFT%-", "S" },
    { "CTRL%-", "C" },
    { "ALT%-", "A" },
    { "META%-", "Mt" },
    { "MOUSEWHEELUP", "MwU" },
    { "MOUSEWHEELDOWN", "MwD" },
    { "MIDDLEBUTTON", "M3" },
    { "BUTTON(%d+)", "M%1" },
    { "NUMPADPLUS", "N+" },
    { "NUMPADMINUS", "N-" },
    { "NUMPADMULTIPLY", "N*" },
    { "NUMPADDIVIDE", "N/" },
    { "NUMPADDECIMAL", "N." },
    { "NUMPAD", "N" },
    { "BACKSPACE", "BkSp" },
    { "SPACE", "Spc" },
    { "CAPSLOCK", "Caps" },
    { "INSERT", "Ins" },
    { "DELETE", "Del" },
    { "HOME", "Hm" },
    { "PAGEUP", "PU" },
    { "PAGEDOWN", "PD" },
}

--- "SHIFT-BUTTON4" -> "SM4", "CTRL-NUMPAD5" -> "CN5".
function Keybinds.Format(key)
    if not key or key == "" then return nil end
    key = key:upper()
    for i = 1, #KEY_ABBREVIATIONS do
        local pair = KEY_ABBREVIATIONS[i]
        key = key:gsub(pair[1], pair[2])
    end
    return key
end

local function get(namespace, name, legacy)
    return (namespace and namespace[name]) or legacy
end

--- The slot the main bar's Nth button currently shows, following paging and bonus bars
--- (stances, forms, stealth).
function Keybinds.MainBarSlot(n)
    local getPage = get(C_ActionBar, "GetActionBarPage", GetActionBarPage)
    local getOffset = get(C_ActionBar, "GetBonusBarOffset", GetBonusBarOffset)
    local page = getPage and getPage() or 1
    local offset = getOffset and getOffset() or 0
    if page == 1 and offset > 0 then
        return (6 + offset - 1) * 12 + n
    end
    return (page - 1) * 12 + n
end

--- Spell in a slot, resolving macros. Returns spellID or nil, plus true if a read was secret.
function Keybinds.SpellForSlot(slot)
    if C_ActionBar and C_ActionBar.GetSpell then
        local reading = Signal.Read(C_ActionBar.GetSpell, slot)
        if reading.state == "known" and reading.value and reading.value ~= 0 then
            return reading.value, false
        elseif reading.reason == "secret" then
            return nil, true
        end
    end
    if not GetActionInfo then return nil, false end
    local ok, actionType, id, subType = pcall(GetActionInfo, slot)
    if not ok then return nil, false end
    if Signal.IsSecret(actionType) or Signal.IsSecret(id) then return nil, true end
    if actionType == "spell" then
        return id, false
    elseif actionType == "macro" then
        if subType == "spell" then return id, false end
        local macroSpell = Signal.Read(GetMacroSpell, id)
        if macroSpell.reason == "secret" then return nil, true end
        return macroSpell.value, false
    end
    return nil, false
end

--- Builds spellID -> formatted key. Returns the map and whether any read was secret.
function Keybinds.BuildMap()
    local map, sawSecret = {}, false

    local function add(slot, command)
        local spellID, secret = Keybinds.SpellForSlot(slot)
        sawSecret = sawSecret or secret
        if not spellID or map[spellID] then return end
        local key = Signal.Read(GetBindingKey, command)
        if key.reason == "secret" then sawSecret = true end
        local text = key.state == "known" and Keybinds.Format(key.value) or nil
        if text then map[spellID] = text end
    end

    for n = 1, 12 do
        add(Keybinds.MainBarSlot(n), "ACTIONBUTTON" .. n)
    end
    for _, bar in ipairs(Keybinds.BARS) do
        for slot = bar.first, bar.last do
            add(slot, bar.command .. (slot - bar.first + 1))
        end
    end
    return map, sawSecret
end

Keybinds.map = {}
Keybinds.dirty = true
Keybinds.REBUILD_INTERVAL = 1
Keybinds.lastBuild = -math.huge

function Keybinds:Rebuild()
    -- A map that stays dirty (secret reads in combat) retries at most once a second.
    local now = GetTime()
    if now - self.lastBuild < self.REBUILD_INTERVAL then return end
    self.lastBuild = now
    local map, sawSecret = Keybinds.BuildMap()
    -- In combat a partly secret read would drop entries; keep the last full map instead.
    if sawSecret and next(self.map) then
        self.dirty = true
        return
    end
    self.map = map
    self.dirty = sawSecret
end

--- Keybind text for a spell, or nil.
function Keybinds:Lookup(spellID)
    if not spellID then return nil end
    local overrides = Kairos.profile and Kairos.profile.keybindOverrides
    if overrides and overrides[spellID] then return overrides[spellID] end
    if self.dirty then self:Rebuild() end
    local text = self.map[spellID]
    if text then return text end
    -- Bars hold base spells, recommendations can be overrides (and the reverse).
    local base = C_Spell and C_Spell.GetBaseSpell and Signal.Read(C_Spell.GetBaseSpell, spellID)
    if base and base.state == "known" and base.value and base.value ~= spellID then
        text = (overrides and overrides[base.value]) or self.map[base.value]
        if text then return text end
    end
    local override = C_Spell and C_Spell.GetOverrideSpell and Signal.Read(C_Spell.GetOverrideSpell, spellID)
    if override and override.state == "known" and override.value and override.value ~= spellID then
        return self.map[override.value]
    end
    return nil
end

function Keybinds:SetOverride(spellID, text)
    Kairos.profile.keybindOverrides[spellID] = (text and text ~= "") and text or nil
end

function Keybinds:OnInit()
    local function markDirty()
        self.dirty = true
        self.lastBuild = -math.huge
    end
    for _, event in ipairs({ "ACTIONBAR_SLOT_CHANGED", "UPDATE_BINDINGS", "UPDATE_MACROS",
        "ACTIONBAR_PAGE_CHANGED", "UPDATE_BONUS_ACTIONBAR", "PLAYER_REGEN_ENABLED" }) do
        Kairos:On(event, markDirty)
    end
    Kairos:On("KAIROS_PROFILE_CHANGED", markDirty)
end
