-- Settings panel (D27): the native Blizzard Settings API, no libraries. Proxy settings
-- read and write the account-wide display settings (D41).
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

function SettingsPanel:AddSlider(key, name, tooltip, default, min, max, step, get, set, editable)
    local setting = Settings.RegisterProxySetting(self.category, "KAIROS_" .. key, varType(default), name,
        default, get, set)
    local options = Settings.CreateSliderOptions(min, max, step)
    if MinimalSliderWithSteppersMixin and options.SetLabelFormatter then
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
            -- The numeric editor occupies this space instead of the native value label.
            if editable then return "" end
            return ("%.2f"):format(value)
        end)
    end
    local initializer = Settings.CreateSlider(self.category, setting, options, tooltip)
    if editable and initializer and initializer.InitFrame then
        local activeEdit
        local originalInit, originalReset = initializer.InitFrame, initializer.Resetter
        function initializer:InitFrame(control)
            originalInit(self, control)
            local edit = control.KairosCoordinateEdit
            if not edit then
                edit = CreateFrame("EditBox", nil, control, "InputBoxTemplate")
                edit:SetSize(92, 24)
                edit:SetPoint("LEFT", control, "CENTER", 190, 3)
                edit:SetAutoFocus(false)
                edit:SetMaxLetters(24)
                control.KairosCoordinateEdit = edit
            end
            activeEdit = edit
            edit.setting = setting
            edit:SetText(("%.2f"):format(setting:GetValue()))
            edit:Show()
            edit:SetScript("OnEnterPressed", function(box)
                local value = tonumber(box:GetText())
                if value and value == value and value >= min and value <= max then setting:SetValue(value) end
                box:SetText(("%.2f"):format(setting:GetValue()))
                box:ClearFocus()
            end)
            edit:SetScript("OnEscapePressed", function(box)
                box:SetText(("%.2f"):format(setting:GetValue()))
                box:ClearFocus()
            end)
        end
        function initializer:Resetter(control)
            if control.KairosCoordinateEdit then
                control.KairosCoordinateEdit.setting = nil
                control.KairosCoordinateEdit:Hide()
            end
            activeEdit = nil
            if originalReset then originalReset(self, control) end
        end
        if setting.SetValueChangedCallback then
            setting:SetValueChangedCallback(function(_, value)
                if activeEdit and activeEdit.setting == setting then activeEdit:SetText(("%.2f"):format(value)) end
            end)
        end
    end
    return setting
end

local function displayOption(field)
    return function() return Kairos.db.global.display[field] end, function(value)
        Kairos.db.global.display[field] = value
        Kairos.Display:ApplyLayout()
    end
end

function SettingsPanel:OnLogin()
    if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterProxySetting) then return end
    self.category = Settings.RegisterVerticalLayoutCategory("Kairos")
    self:AddCheckbox("ENABLED", "Enable Kairos", "Show the display and run recommendations. Account-wide.",
        true, function() return Kairos.db.global.enabled end, function(value) Kairos.Display:SetEnabled(value) end)

    self:AddCheckbox("LOCKED", "Lock display", "Locked displays ignore the mouse. Unlock to drag.",
        false, displayOption("locked"))
    self:AddSlider("SCALE", "Scale", "Size of the display.", 1, 0.5, 2, 0.05, displayOption("scale"))
    local getSize, setSize = displayOption("mainSize")
    self:AddSlider("MAIN_SIZE", "Main icon size", "Width and height before display scale (32-128). Type a value and press Enter.",
        Kairos.DB.globalDefaults.display.mainSize, 32, 128, 1, getSize, setSize, true)
    local function coordinate(index)
        return function()
            local x, y = Kairos.Display:GetPosition()
            return index == 3 and x or y
        end, function(value)
            local x, y = Kairos.Display:GetPosition()
            Kairos.Display:SetPosition(index == 3 and value or x, index == 4 and value or y)
        end
    end
    local getX, setX = coordinate(3)
    local getY, setY = coordinate(4)
    self:AddSlider("POSITION_X", "X coordinate", "Main icon offset from screen center (right positive). Type a value and press Enter.",
        Kairos.DB.globalDefaults.display.point[3], -2000, 2000, 1, getX, setX, true)
    self:AddSlider("POSITION_Y", "Y coordinate", "Main icon offset from screen center (up positive). Type a value and press Enter.",
        Kairos.DB.globalDefaults.display.point[4], -1200, 1200, 1, getY, setY, true)
    self:AddCheckbox("SHOW_QUEUED", "Show queued spell", "The smaller icon: what comes after the main pick.",
        true, displayOption("showQueued"))
    self:AddCheckbox("SHOW_KEYBINDS", "Show keybinds", "Keybind text on each icon. Override with /kairos bind.",
        true, displayOption("showKeybinds"))
    self:AddCheckbox("SHOW_INTERRUPT", "Show interrupt icon", "A separate small icon when an interrupt is available.",
        true, displayOption("showInterrupt"))
    self:AddCheckbox("SHOW_OFF_GCD", "Show extra cooldown cue", "Show additional cooldown suggestions beside the main icon.",
        true, displayOption("showOffGcd"))
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
        "Runs the secrecy probe at login, early in and right after each fight, and at encounter and keystone "
            .. "starts. Account-wide.",
        true, function() return Kairos.db.global.autoProbe end,
        function(value) Kairos.db.global.autoProbe = value end)
    self:AddCheckbox("COMBAT_LOG", "Combat logging",
        "Turns on combat logging (with advanced logging) at login, writing to _retail_\\Logs. Account-wide.",
        true, function() return Kairos.db.global.combatLog end,
        function(value)
            Kairos.db.global.combatLog = value
            Kairos.CombatLog:Ensure()
        end)

    Settings.RegisterAddOnCategory(self.category)
end

function SettingsPanel:Open()
    if self.category and Settings.OpenToCategory then
        Settings.OpenToCategory(self.category:GetID())
    else
        Kairos:Print("The settings panel isn't available. Use /kairos help.")
    end
end
