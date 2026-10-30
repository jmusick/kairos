-- A WoW API stub for unit tests (D22). Install() resets every global the addon touches.
-- Stub.Secret() returns a value that raises on comparison, arithmetic, indexing, length,
-- concatenation and tostring, the way Midnight's secret values do.
local Stub = {}

local SecretMT = {}
local function secretError() error("attempt to use a secret value", 2) end
for _, event in ipairs({ "__index", "__newindex", "__eq", "__lt", "__le", "__add", "__sub", "__mul",
    "__div", "__mod", "__pow", "__unm", "__concat", "__len", "__call", "__tostring" }) do
    SecretMT[event] = secretError
end

function Stub.Secret()
    return setmetatable({}, SecretMT)
end

function Stub.IsSecret(value)
    return type(value) == "table" and rawequal(getmetatable(value), SecretMT)
end

local noop = function() end

local function newRegion(kind)
    -- Unknown keys resolve to a no-op method, so every field a test reads is preset here.
    local region = { kind = kind, shown = true, points = {}, text = "", texture = false, color = false }
    function region:SetText(text) self.text = text end
    function region:GetText() return self.text end
    function region:SetTexture(texture) self.texture = texture end
    function region:SetVertexColor(r, g, b) self.color = { r, g, b } end
    function region:SetTextColor(r, g, b) self.textColor = { r, g, b } end
    function region:Show() self.shown = true end
    function region:Hide() self.shown = false end
    function region:SetShown(shown) self.shown = not not shown end
    function region:IsShown() return self.shown end
    return setmetatable(region, { __index = function() return noop end })
end

local function newFrame(name)
    local frame = newRegion("Frame")
    frame.name = name
    frame.scripts = {}
    frame.events = {}
    frame.unitEvents = {}
    function frame:SetScript(script, fn) self.scripts[script] = fn end
    function frame:GetScript(script) return self.scripts[script] end
    function frame:RegisterEvent(event) self.events[event] = true end
    function frame:RegisterUnitEvent(event, unit) self.unitEvents[event] = unit end
    function frame:CreateTexture() return newRegion("Texture") end
    function frame:CreateFontString() return newRegion("FontString") end
    function frame:SetPoint(...) self.points = { ... } end
    function frame:GetPoint() return self.points[1], nil, self.points[3], self.points[4], self.points[5] end
    function frame:SetScale(scale) self.scale = scale end
    function frame:EnableMouse(on) self.mouse = on end
    Stub.frames[#Stub.frames + 1] = frame
    if name then _G[name] = frame end
    return frame
end

--- Dispatches a client event to every frame registered for it. Unit events reach a
--- frame only when the unit matches its RegisterUnitEvent filter.
function Stub.Fire(event, ...)
    local unit = ...
    for _, frame in ipairs(Stub.frames) do
        local handler = frame.scripts.OnEvent
        if handler then
            if frame.events[event] then
                handler(frame, event, ...)
            elseif frame.unitEvents[event] and frame.unitEvents[event] == unit then
                handler(frame, event, ...)
            end
        end
    end
end

--- Runs every OnUpdate script once with the given elapsed time.
function Stub.Tick(elapsed)
    for _, frame in ipairs(Stub.frames) do
        local handler = frame.scripts.OnUpdate
        if handler then handler(frame, elapsed or 1) end
    end
end

function Stub.Install()
    Stub.frames = {}
    Stub.chat = {}
    Stub.now = 100
    Stub.timers = {}
    Stub.bindings = {}      -- [command] = key
    Stub.actions = {}       -- [slot] = { type, id, subType }
    Stub.macros = {}        -- [macroIndex] = spellID
    Stub.spellNames = {}    -- [spellID] = name
    Stub.acSpell = nil
    Stub.specIndex = 1
    Stub.specs = { [1] = 62, [2] = 63, [3] = 64 }
    Stub.page = 1
    Stub.bonusOffset = 0

    _G.KairosDB = nil
    _G.Kairos = nil
    _G.issecretvalue = Stub.IsSecret
    _G.securecallfunction = function(fn, ...) return fn(...) end
    _G.GetTime = function() return Stub.now end
    _G.time = os.time
    _G.tinsert = table.insert
    _G.UISpecialFrames = {}
    _G.SlashCmdList = {}
    _G.CreateFrame = function(_, name) return newFrame(name) end
    _G.UIParent = newFrame("UIParent")
    _G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) Stub.chat[#Stub.chat + 1] = msg end }
    _G.Settings = nil
    _G.C_Timer = { After = function(delay, fn) Stub.timers[#Stub.timers + 1] = { delay = delay, fn = fn } end }

    _G.Enum = {
        AddOnRestrictionType = { Combat = 0, Encounter = 1, ChallengeMode = 2, PvPMatch = 3, Map = 4, Chat = 5 },
        AddOnRestrictionState = { Inactive = 0, Activating = 1, Active = 2 },
        PowerType = { Mana = 0, Rage = 1, Energy = 3, ArcaneCharges = 16 },
    }
    Stub.restrictions = {}
    _G.C_RestrictedActions = {
        IsAddOnRestrictionActive = function(id) return Stub.restrictions[id] == true end,
    }
    _G.C_Secrets = {
        HasSecretRestrictions = function() return true end,
        ShouldCooldownsBeSecret = function() return false end,
        ShouldAurasBeSecret = function() return false end,
        GetSpellCooldownSecrecy = function() return 2 end,
    }
    _G.C_AddOns = { GetAddOnMetadata = function() return "0.1.0-test" end }
    _G.GetBuildInfo = function() return "12.1.5", "70575", "Oct 1 2026", 120105 end

    _G.UnitName = function() return "Tester" end
    _G.GetNormalizedRealmName = function() return "Realm" end
    _G.GetSpecialization = function() return Stub.specIndex end
    _G.GetSpecializationInfo = function(index) return Stub.specs[index] end
    _G.C_SpecializationInfo = nil
    _G.UnitAffectingCombat = function() return false end
    _G.UnitCanAttack = function() return true end
    _G.InCombatLockdown = function() return false end
    _G.IsInInstance = function() return false, "none" end
    _G.GetInstanceInfo = function() return "Dornogal", "none", 0 end
    _G.GetUnitSpeed = function() return 0 end
    _G.UnitCastingInfo = function() return nil end
    _G.UnitChannelInfo = function() return nil end
    _G.UnitPower = function() return 50 end
    _G.UnitPowerMax = function() return 100 end
    _G.UnitPowerType = function() return 0, "MANA" end
    _G.UnitHealth = function() return 1000 end
    _G.UnitHealthMax = function() return 1000 end
    _G.UnitExists = function() return true end
    _G.UnitGUID = function() return "Creature-0" end
    _G.UnitSpellHaste = function() return 20 end
    _G.GetCVar = function() return "400" end

    _G.GetBindingKey = function(command) return Stub.bindings[command] end
    _G.GetActionInfo = function(slot)
        local action = Stub.actions[slot]
        if action then return action[1], action[2], action[3] end
    end
    _G.GetMacroSpell = function(index) return Stub.macros[index] end
    _G.GetActionBarPage = function() return Stub.page end
    _G.GetBonusBarOffset = function() return Stub.bonusOffset end
    _G.C_ActionBar = nil

    _G.C_Spell = {
        GetSpellName = function(id) return Stub.spellNames[id] end,
        GetSpellTexture = function(id) return 1000 + id end,
        IsSpellUsable = function() return true, false end,
        GetSpellIDForSpellIdentifier = function(name)
            for id, spellName in pairs(Stub.spellNames) do
                if spellName == name then return id end
            end
        end,
        GetSpellCooldown = function() return { startTime = 0, duration = 0, isEnabled = true, modRate = 1 } end,
        GetSpellCharges = function() return nil end,
        IsSpellInRange = function() return true end,
        GetSpellQueueWindow = function() return 400 end,
    }
    _G.C_AssistedCombat = {
        GetNextCastSpell = function() return Stub.acSpell end,
        IsAvailable = function() return true, "" end,
        GetRotationSpells = function() return {} end,
    }
    _G.C_UnitAuras = { GetAuraDataBySpellName = function() return nil end }
    _G.C_SpellActivationOverlay = { IsSpellOverlayed = function() return false end }
    _G.C_ChallengeMode = { IsChallengeModeActive = function() return false end }
end

--- Reads the TOC's file list, loads each file with the addon vararg, and runs the
--- ADDON_LOADED and PLAYER_LOGIN lifecycle. Returns the addon namespace.
function Stub.LoadAddon(options)
    options = options or {}
    local files = {}
    for line in io.lines("Kairos/Kairos.toc") do
        if line:match("%.lua%s*$") then files[#files + 1] = line:match("^%s*(.-)%s*$") end
    end
    local ns = {}
    for _, file in ipairs(files) do
        local chunk = assert(loadfile("Kairos/" .. file))
        chunk("Kairos", ns)
    end
    if options.beforeLoad then options.beforeLoad(ns) end
    Stub.Fire("ADDON_LOADED", "Kairos")
    if options.login ~= false then Stub.Fire("PLAYER_LOGIN") end
    return ns
end

return Stub
