-- Display (SPEC §7.4, D7, D28): a large current-spell icon, a smaller queued icon,
-- a separate interrupt icon (D19), an "AC" badge when the pick is Blizzard's (D17)
-- and a CD pip for the Cooldowns toggle. Always visible, movable, scalable, lockable.
local _, Kairos = ...
local Display = Kairos:NewModule("Display")
local Signal = Kairos.Signal

Display.MAIN_SIZE = 52
Display.QUEUED_SIZE = 36
Display.INTERRUPT_SIZE = 28
Display.UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
Display.DEFAULT_POINT = { "CENTER", "CENTER", 0, -180 }

local function createIcon(parent, size, fontObject)
    local button = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    button:SetSize(size, size)
    button:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    button:SetBackdropBorderColor(0, 0, 0, 1)

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetPoint("TOPLEFT", 1, -1)
    button.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    button.keybind = button:CreateFontString(nil, "OVERLAY", fontObject)
    button.keybind:SetPoint("TOPRIGHT", -2, -3)
    button.keybind:SetJustifyH("RIGHT")
    return button
end

function Display:Create()
    if self.frame then return end
    local frame = CreateFrame("Frame", "KairosDisplay", UIParent, "BackdropTemplate")
    frame:SetSize(self.MAIN_SIZE + 4 + self.QUEUED_SIZE, self.MAIN_SIZE)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(f) f:StartMoving() end)
    frame:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        local point, _, relativePoint, x, y = f:GetPoint()
        Kairos.profile.display.point = { point, relativePoint, x, y }
    end)

    frame.unlockedLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.unlockedLabel:SetPoint("BOTTOM", frame, "TOP", 0, 2)
    frame.unlockedLabel:SetText("Kairos: drag to move, /kairos lock")

    local main = createIcon(frame, self.MAIN_SIZE, "NumberFontNormal")
    main:SetPoint("TOPLEFT")

    main.badge = main:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    main.badge:SetPoint("BOTTOMLEFT", 3, 3)
    main.badge:SetText("AC")
    main.badge:SetTextColor(1, 0.82, 0)

    local queued = createIcon(frame, self.QUEUED_SIZE, "NumberFontNormalSmall")
    queued:SetPoint("BOTTOMLEFT", main, "BOTTOMRIGHT", 4, 0)

    local interrupt = createIcon(frame, self.INTERRUPT_SIZE, "NumberFontNormalSmall")
    interrupt:SetPoint("BOTTOMLEFT", main, "TOPLEFT", 0, 4)
    interrupt:SetBackdropBorderColor(0.9, 0.2, 0.2, 1)

    local pip = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pip:SetPoint("TOPLEFT", main, "BOTTOMLEFT", 1, -3)
    pip:SetText("CD")

    frame.main, frame.queued, frame.interrupt, frame.pip = main, queued, interrupt, pip
    self.frame = frame

    local elapsed = 0
    frame:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed >= (Kairos.db.global.updateInterval or 0.1) then
            elapsed = 0
            self:Refresh()
        end
    end)

    self:ApplyLayout()
    frame:Show()
end

function Display:ApplyLayout()
    local frame = self.frame
    if not frame then return end
    local settings = Kairos.profile.display
    local point = settings.point or self.DEFAULT_POINT
    frame:ClearAllPoints()
    frame:SetPoint(point[1], UIParent, point[2], point[3], point[4])
    frame:SetScale(settings.scale or 1)

    local unlocked = not settings.locked
    frame:EnableMouse(unlocked)
    if unlocked then
        frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
        frame:SetBackdropColor(0.2, 0.6, 1, 0.25)
        frame.unlockedLabel:Show()
    else
        frame:SetBackdrop(nil)
        frame.unlockedLabel:Hide()
    end
    self:Refresh()
end

local function setUsableTint(texture, spellID)
    local ok, usable, noMana = pcall(C_Spell.IsSpellUsable, spellID)
    if not ok or Signal.IsSecret(usable) or Signal.IsSecret(noMana) or usable then
        texture:SetVertexColor(1, 1, 1)
    elseif noMana then
        texture:SetVertexColor(0.5, 0.5, 1)
    else
        texture:SetVertexColor(0.45, 0.45, 0.45)
    end
end

local function showSpell(button, spellID, showKeybind)
    if not spellID then
        button:Hide()
        return
    end
    local texture = C_Spell.GetSpellTexture(spellID)
    button.icon:SetTexture(texture or Display.UNKNOWN_ICON)
    setUsableTint(button.icon, spellID)
    button.keybind:SetText(showKeybind and Kairos.Keybinds:Lookup(spellID) or "")
    button:Show()
end

function Display:Refresh()
    local frame = self.frame
    if not frame then return end
    local settings = Kairos.profile.display
    local rec = Kairos.APL:Recommend()
    self.current = rec
    Kairos.Recorder:NoteRecommendation(rec)

    local main = frame.main
    if rec.spellID then
        showSpell(main, rec.spellID, settings.showKeybinds)
    else
        -- Never blank (D17): no pick from Kairos or Blizzard shows a question mark.
        main.icon:SetTexture(self.UNKNOWN_ICON)
        main.icon:SetVertexColor(1, 1, 1)
        main.keybind:SetText("")
        main:Show()
    end
    main.badge:SetShown(rec.source ~= "apl")

    showSpell(frame.queued, settings.showQueued and rec.queuedID or nil, settings.showKeybinds)
    showSpell(frame.interrupt, settings.showInterrupt and rec.interruptID or nil, settings.showKeybinds)

    local pip = frame.pip
    pip:SetShown(settings.showToggles)
    if Kairos.Toggles:Get("cooldowns") then
        pip:SetTextColor(0.25, 1, 0.25)
    else
        pip:SetTextColor(0.5, 0.5, 0.5)
    end
end

function Display:OnLogin()
    self:Create()
    local function refresh() self:Refresh() end
    Kairos:On("KAIROS_PROFILE_CHANGED", function() self:ApplyLayout() end)
    Kairos:On("KAIROS_TOGGLE_CHANGED", refresh)
    Kairos:On("KAIROS_PLAYER_CAST", refresh)
    Kairos:On("PLAYER_TARGET_CHANGED", refresh)
end
