-- SavedVariables (SPEC §7.4, D27, D41): KairosDB holds account-wide settings, including the
-- display, plus one profile per character per spec for toggles and keybind overrides.
-- Kairos.profile always points at the active profile.
local _, Kairos = ...
local DB = Kairos:NewModule("DB")

DB.SCHEMA = 4

-- One-time upgrades for saved data, keyed by the schema version they bring the data to.
-- Needed when a default changes: applyDefaults never overwrites a saved value.
DB.MIGRATIONS = {
    [2] = function(db) db.global.autoProbe = true end, -- auto-probe became the default
    -- 32 pulls kept only the last half hour of a dungeon night; keep a customized limit.
    [3] = function(db) if db.global.recorderPulls == 32 then db.global.recorderPulls = 300 end end,
    -- Display settings became account-wide (D41): keep this character's, else another's.
    [4] = function(db) db.global.display = DB.TakeDisplay(db.profiles) end,
}

DB.globalDefaults = {
    enabled = true,
    recorder = true,
    recorderPulls = 300,      -- bounded per-pull archives survive flight-ring rollover
    recorderPullEntries = 1200,
    autoProbe = true,
    combatLog = true,
    updateInterval = 0.1,
    auraIDs = {}, -- [aura name] = spell ID, learned by the probe while the aura is readable
    display = { -- shared by every character and spec (D41)
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
}

DB.profileDefaults = {
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

--- Removes every profile's old per-profile display table and returns the one to keep:
--- the logged-in character's current spec, else its lowest spec, else the first character's.
function DB.TakeDisplay(profiles)
    local chosen
    local function pick(specs, preferred)
        if type(specs) ~= "table" then return end
        if type(specs[preferred]) == "table" and type(specs[preferred].display) == "table" then
            return specs[preferred].display
        end
        local ids = {}
        for id, profile in pairs(specs) do
            if type(profile) == "table" and type(profile.display) == "table" then ids[#ids + 1] = id end
        end
        table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
        return ids[1] and specs[ids[1]].display
    end
    chosen = pick(profiles[DB.CharKey()], DB.CurrentSpecID())
    if not chosen then
        local chars = {}
        for key in pairs(profiles) do chars[#chars + 1] = key end
        table.sort(chars)
        for _, key in ipairs(chars) do
            chosen = pick(profiles[key])
            if chosen then break end
        end
    end
    for _, specs in pairs(profiles) do
        if type(specs) == "table" then
            for _, profile in pairs(specs) do
                if type(profile) == "table" then profile.display = nil end
            end
        end
    end
    return chosen
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
    db.global = type(db.global) == "table" and db.global or {}
    db.profiles = type(db.profiles) == "table" and db.profiles or {}
    db.flight = type(db.flight) == "table" and db.flight or {}
    db.probes = type(db.probes) == "table" and db.probes or {}
    for version = db.schema + 1, DB.SCHEMA do
        if DB.MIGRATIONS[version] then DB.MIGRATIONS[version](db) end
    end
    applyDefaults(db.global, self.globalDefaults)
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
