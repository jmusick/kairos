-- Settings panel (D27): the native Blizzard Settings API, no libraries. Proxy settings
-- read and write through Kairos.profile, so they follow spec and character swaps.
local _, Kairos = ...
local SettingsPanel = Kairos:NewModule("SettingsPanel")

local function varType(default)
    if Settings.VarType then
        return type(default) == "boolean" and Settings.VarType.Boolean or Settings.VarType.Number
    end
    return type(default)
end

function SettingsPanel:AddCheckbox(key, name, tooltip, default, get, set)
    local setting = Settings.RegisterProxySetting(self.category, "KAIROS_" .. key, varType(default), name,
        default, get, set)
    Settings.CreateCheckbox(self.category, setting, tooltip)
    return setting
end

function SettingsPanel:AddSlider(key, name, tooltip, default, min, max, step, get, set)
    local setting = Settings.RegisterProxySetting(self.category, "KAIROS_" .. key, varType(default), name,
        default, get, set)
    local options = Settings.CreateSliderOptions(min, max, step)
    if MinimalSliderWithSteppersMixin and options.SetLabelFormatter then
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
            return ("%.2f"):format(value)
        end)
    end
    Settings.CreateSlider(self.category, setting, options, tooltip)
    return setting
end

local function displayOption(field)
    return function() return Kairos.profile.display[field] end, function(value)
        Kairos.profile.display[field] = value
        Kairos.Display:ApplyLayout()
    end
end

function SettingsPanel:OnLogin()
    if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterProxySetting) then return end
    self.category = Settings.RegisterVerticalLayoutCategory("Kairos")

    self:AddCheckbox("LOCKED", "Lock display", "Locked displays ignore the mouse. Unlock to drag.",
        false, displayOption("locked"))
    self:AddSlider("SCALE", "Scale", "Size of the display.", 1, 0.5, 2, 0.05, displayOption("scale"))
    self:AddCheckbox("SHOW_QUEUED", "Show queued spell", "The smaller icon: what comes after the main pick.",
        true, displayOption("showQueued"))
    self:AddCheckbox("SHOW_KEYBINDS", "Show keybinds", "Keybind text on each icon. Override with /kairos bind.",
        true, displayOption("showKeybinds"))
    self:AddCheckbox("SHOW_INTERRUPT", "Show interrupt icon", "A separate small icon when an interrupt is available.",
        true, displayOption("showInterrupt"))
    self:AddCheckbox("SHOW_TOGGLES", "Show CD indicator", "The CD pip: lit while the Cooldowns toggle is on.",
        true, displayOption("showToggles"))

    self:AddCheckbox("COOLDOWNS", "Cooldowns toggle",
        "Off holds major cooldowns, racials, on-use trinkets and potions. Bind it under Key Bindings > AddOns.",
        true, function() return Kairos.Toggles:Get("cooldowns") end,
        function(value) Kairos.Toggles:Set("cooldowns", value) end)

    self:AddCheckbox("RECORDER", "Flight recorder",
        "Saves picks and casts to KairosDB for the offline replay harness. Account-wide.",
        true, function() return Kairos.db.global.recorder end,
        function(value) Kairos.db.global.recorder = value end)
    self:AddCheckbox("AUTO_PROBE", "Auto-probe",
        "Runs the secrecy probe on entering combat, encounters and keystones. Account-wide.",
        false, function() return Kairos.db.global.autoProbe end,
        function(value) Kairos.db.global.autoProbe = value end)

    Settings.RegisterAddOnCategory(self.category)
end

function SettingsPanel:Open()
    if self.category and Settings.OpenToCategory then
        Settings.OpenToCategory(self.category:GetID())
    else
        Kairos:Print("The settings panel isn't available. Use /kairos help.")
    end
end
