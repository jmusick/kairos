-- Display (SPEC §7.4, D7, D28): a large current-spell icon, a smaller queued icon,
-- a separate interrupt icon (D19), an "AC" badge when the pick is Blizzard's (D17)
-- and a CD pip for the Cooldowns toggle. Always visible, movable, scalable, lockable.
local _, Kairos = ...
local Display = Kairos:NewModule("Display")
local Signal = Kairos.Signal

Display.MAIN_SIZE = Kairos.DB.globalDefaults.display.mainSize
Display.QUEUED_SIZE = 36
Display.INTERRUPT_SIZE = 28
Display.PAIRED_SIZE = 26
Display.UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
Display.DEFAULT_POINT = Kairos.DB.globalDefaults.display.point

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
    -- The main icon is the drag handle. Optional icons extend outside this frame,
    -- as the interrupt already does; don't reserve a blue strip for a hidden queue.
    frame:SetSize(self.MAIN_SIZE, self.MAIN_SIZE)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(f) f:StartMoving() end)
    frame:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        local x, y = self:GetPosition(true)
        self:SetPosition(x, y)
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

    -- A child of main draws above it, without growing the drag/position frame.
    local paired = createIcon(main, self.PAIRED_SIZE, "NumberFontNormalSmall")
    paired:SetPoint("TOPRIGHT", main, "TOPRIGHT", 8, 8)
    paired:SetBackdropBorderColor(0.2, 0.65, 1, 1)
    paired.caption = paired:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    paired.caption:SetPoint("BOTTOMLEFT", 2, 2)
    paired.caption:SetText("+")

    local queued = createIcon(frame, self.QUEUED_SIZE, "NumberFontNormalSmall")
    queued:SetPoint("BOTTOMLEFT", main, "BOTTOMRIGHT", 4, 0)

    local interrupt = createIcon(frame, self.INTERRUPT_SIZE, "NumberFontNormalSmall")
    interrupt:SetPoint("BOTTOMLEFT", main, "TOPLEFT", 0, 4)
    interrupt:SetBackdropBorderColor(0.9, 0.2, 0.2, 1)

    local offGcd = createIcon(frame, self.QUEUED_SIZE, "NumberFontNormalSmall")
    offGcd:SetPoint("BOTTOMLEFT", main, "TOPRIGHT", 4, 4)
    offGcd:SetBackdropBorderColor(0.2, 0.65, 1, 1)
    offGcd.caption = offGcd:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    offGcd.caption:SetPoint("BOTTOMLEFT", 2, 2)
    offGcd.caption:SetText("NOW")

    local pip = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pip:SetPoint("BOTTOMRIGHT", main, "BOTTOMLEFT", -6, 0)
    pip:SetText("CD")

    frame.main, frame.queued, frame.interrupt, frame.pip = main, queued, interrupt, pip
    frame.offGcd = offGcd
    frame.paired = paired
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
end

function Display:SetEnabled(enabled)
    Kairos.db.global.enabled = enabled
    if self.frame then self.frame:SetShown(enabled) end
    if enabled then self:Refresh() end
end

function Display:SetPosition(x, y)
    Kairos.db.global.display.point = { "CENTER", "CENTER", x, y }
    self:ApplyLayout()
end

function Display:GetPosition(fromFrame)
    local point = Kairos.db.global.display.point or self.DEFAULT_POINT
    if not fromFrame and point[1] == "CENTER" and point[2] == "CENTER" then return point[3], point[4] end
    -- Dragging can leave a TOPLEFT/BOTTOMLEFT anchor. Convert the actual main-frame
    -- center into the same CENTER offsets the command and both controls write.
    local function read(fn)
        local r = Signal.Read(fn)
        return r.state == "known" and type(r.value) == "number" and r.value or nil
    end
    local frame = self.frame
    if frame then
        local x = read(function() return (frame:GetCenter()) end)
        local y = read(function() return (select(2, frame:GetCenter())) end)
        local px = read(function() return (UIParent:GetCenter()) end)
        local py = read(function() return (select(2, UIParent:GetCenter())) end)
        local scale = read(function() return frame:GetEffectiveScale() end)
        local parentScale = read(function() return UIParent:GetEffectiveScale() end)
        if x and y and px and py and scale and parentScale and scale > 0 then
            return x - px * parentScale / scale, y - py * parentScale / scale
        end
    end
    return point[3], point[4]
end

function Display:ApplyLayout()
    local frame = self.frame
    if not frame then return end
    local settings = Kairos.db.global.display
    local point = settings.point or self.DEFAULT_POINT
    local size = settings.mainSize or self.MAIN_SIZE
    frame:SetSize(size, size)
    frame.main:SetSize(size, size)
    frame.paired:SetSize(size / 2, size / 2)
    frame:ClearAllPoints()
    frame:SetPoint(point[1], UIParent, point[2], point[3], point[4])
    frame:SetScale(settings.scale or 1)
    frame:SetShown(Kairos.db.global.enabled)

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

local function showSpell(button, spellID, showKeybind, exact)
    if not spellID then
        button:Hide()
        return
    end
    local texture = Signal.Read(function()
        local icon, original = C_Spell.GetSpellTexture(spellID)
        -- icon can still show an active override after lookahead consumed its proc.
        -- originalIconID (second return) belongs to the exact recommended spell.
        if exact and (Signal.IsSecret(original) or original ~= nil) then return original end
        return icon
    end)
    button.icon:SetTexture(texture.state == "known" and texture.value or Display.UNKNOWN_ICON)
    setUsableTint(button.icon, spellID)
    button.keybind:SetText(showKeybind and Kairos.Keybinds:Lookup(spellID) or "")
    button:Show()
end

function Display:Refresh()
    local frame = self.frame
    if not frame then return end
    if not Kairos.db.global.enabled then frame:Hide(); return end
    local settings = Kairos.db.global.display
    local rec = Kairos.APL:Recommend()
    self.current = rec
    Kairos.Recorder:NoteRecommendation(rec)

    local main = frame.main
    if rec.spellID then
        showSpell(main, rec.spellID, settings.showKeybinds, rec.source == "apl")
    else
        -- Never blank (D17): no pick from Kairos or Blizzard shows a question mark.
        main.icon:SetTexture(self.UNKNOWN_ICON)
        main.icon:SetVertexColor(1, 1, 1)
        main.keybind:SetText("")
        main:Show()
    end
    main.badge:SetText(rec.immediate and "NOW" or "AC")
    main.badge:SetShown(rec.source ~= "apl" or rec.immediate == true)
    -- Keep the main binding clear of the overlapping follow-up icon.
    main.keybind:ClearAllPoints()
    main.keybind:SetPoint(rec.pairedID and "BOTTOMRIGHT" or "TOPRIGHT", -2, rec.pairedID and 3 or -3)

    showSpell(frame.queued, settings.showQueued and rec.queuedID or nil, settings.showKeybinds, true)
    showSpell(frame.interrupt, settings.showInterrupt and rec.interruptID or nil, settings.showKeybinds, true)
    showSpell(frame.offGcd, settings.showOffGcd and rec.offGcdID or nil, settings.showKeybinds, true)
    showSpell(frame.paired, rec.pairedID, settings.showKeybinds, true)

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
    -- These run after the state/estimator handlers registered during OnInit.
    -- Advance lookahead as soon as a cast starts, and restore it on interruption.
    for _, event in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_DELAYED", "UNIT_SPELLCAST_STOP",
        "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_CHANNEL_START",
        "UNIT_SPELLCAST_CHANNEL_UPDATE", "UNIT_SPELLCAST_CHANNEL_STOP" }) do
        Kairos:OnUnit(event, "player", refresh)
    end
end
