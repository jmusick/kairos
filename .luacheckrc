std = "lua51"
max_line_length = 120
exclude_files = { ".release/" }

-- Globals Kairos writes.
globals = {
    "Kairos", "KairosDB",
    "BINDING_HEADER_KAIROS", "BINDING_NAME_KAIROS_TOGGLE_COOLDOWNS",
    "SLASH_KAIROS1", "SLASH_KAIROS2", "SlashCmdList",
}

-- WoW API and FrameXML globals Kairos reads.
read_globals = {
    "C_ActionBar", "C_AddOns", "C_AssistedCombat", "C_ChallengeMode", "C_RestrictedActions", "C_Secrets",
    "C_SpecializationInfo", "C_Spell", "C_SpellActivationOverlay", "C_Timer", "C_UnitAuras", "Enum",
    "CreateFrame", "DEFAULT_CHAT_FRAME", "UIParent", "UISpecialFrames", "Settings",
    "MinimalSliderWithSteppersMixin", "ChatFontNormal", "tinsert", "time",
    "issecretvalue", "securecallfunction", "InCombatLockdown",
    "GetActionBarPage", "GetActionInfo", "GetBindingKey", "GetBonusBarOffset", "GetBuildInfo", "GetCVar",
    "GetInstanceInfo", "GetMacroSpell", "GetNormalizedRealmName", "GetSpecialization",
    "GetSpecializationInfo", "GetTime", "GetUnitSpeed", "GetHaste", "IsInInstance", "IsPlayerMoving",
    "UnitThreatSituation", "LoggingCombat", "C_CVar",
    "UnitAffectingCombat", "UnitCanAttack", "UnitCastingInfo", "UnitChannelInfo", "UnitExists", "UnitGUID",
    "UnitHealth", "UnitHealthMax", "UnitName", "UnitPower", "UnitPowerMax", "UnitPowerType", "UnitSpellHaste",
}

-- The dump tool defines no globals but reads the one SavedVariables defines.
files["tools/"] = { read_globals = { "KairosDB" } }

-- Specs replace WoW globals through the stub, and the runner defines busted's API.
files["tests/"] = {
    std = "+busted",
    allow_defined_top = true,
    globals = { "_G", "assert", "describe", "it", "before_each" },
    ignore = { "111", "112", "113", "121", "122" },
    max_line_length = 140,
}
