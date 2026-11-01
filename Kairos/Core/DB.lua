-- SavedVariables (SPEC §7.4, D27): KairosDB holds global settings plus one profile per
-- character per spec. Kairos.profile always points at the active profile.
local _, Kairos = ...
local DB = Kairos:NewModule("DB")

DB.SCHEMA = 2

-- One-time upgrades for saved data, keyed by the schema version they bring the data to.
-- Needed when a default changes: applyDefaults never overwrites a saved value.
DB.MIGRATIONS = {
    [2] = function(db) db.global.autoProbe = true end, -- auto-probe became the default
}

DB.globalDefaults = {
    enabled = true,
    recorder = true,
    recorderPulls = 32,       -- bounded cast/commit archives survive flight-ring rollover
    recorderPullEntries = 1200,
    autoProbe = true,
    combatLog = true,
    updateInterval = 0.1,
    auraIDs = {}, -- [aura name] = spell ID, learned by the probe while the aura is readable
}

DB.profileDefaults = {
    display = {
        scale = 1,
        mainSize = 52,
        locked = false,
        showQueued = true,
        showKeybinds = true,
        showInterrupt = true,
        showOffGcd = true,
        showToggles = true,
        point = { "CENTER", "CENTER", 0, -180 },
    },
    toggles = {
        cooldowns = true,
    },
    keybindOverrides = {},
}

local function applyDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then target[key] = {} end
            applyDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
    return target
end
DB.ApplyDefaults = applyDefaults

function DB.CharKey()
    local name = UnitName("player") or "Unknown"
    local realm = GetNormalizedRealmName and GetNormalizedRealmName() or ""
    return realm ~= "" and (name .. "-" .. realm) or name
end

--- The active specialization's ID (62 for Arcane), or 0 when there's none yet.
function DB.CurrentSpecID()
    local getSpec = (C_SpecializationInfo and C_SpecializationInfo.GetSpecialization) or GetSpecialization
    local getInfo = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo) or GetSpecializationInfo
    if not (getSpec and getInfo) then return 0 end
    local index = getSpec()
    if not index or index == 0 then return 0 end
    return (getInfo(index)) or 0
end

function DB:OnInit()
    KairosDB = type(KairosDB) == "table" and KairosDB or {}
    local db = KairosDB
    db.schema = db.schema or DB.SCHEMA
    db.global = applyDefaults(type(db.global) == "table" and db.global or {}, self.globalDefaults)
    db.profiles = type(db.profiles) == "table" and db.profiles or {}
    db.flight = type(db.flight) == "table" and db.flight or {}
    db.probes = type(db.probes) == "table" and db.probes or {}
    for version = db.schema + 1, DB.SCHEMA do
        if DB.MIGRATIONS[version] then DB.MIGRATIONS[version](db) end
    end
    db.schema = DB.SCHEMA
    Kairos.db = db
    -- Placeholder until PLAYER_LOGIN, when the character and spec are known.
    Kairos.profile = applyDefaults({}, self.profileDefaults)
    Kairos.specID = 0
end

function DB:OnLogin()
    self:ActivateProfile()
    Kairos:OnUnit("PLAYER_SPECIALIZATION_CHANGED", "player", function() self:ActivateProfile() end)
end

function DB:ActivateProfile()
    local charKey, specID = DB.CharKey(), DB.CurrentSpecID()
    if charKey == self.activeChar and specID == self.activeSpec then return end

    local profiles = Kairos.db.profiles
    profiles[charKey] = profiles[charKey] or {}
    local profile = applyDefaults(profiles[charKey][specID] or {}, self.profileDefaults)
    profiles[charKey][specID] = profile

    self.activeChar, self.activeSpec = charKey, specID
    Kairos.profile = profile
    Kairos.specID = specID
    Kairos:Fire("KAIROS_PROFILE_CHANGED", charKey, specID)
end
