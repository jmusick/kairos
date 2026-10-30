-- Slash commands (/kairos, /kai) and the copy-text window used by reports.
local _, Kairos = ...
local Commands = Kairos:NewModule("Commands")

local HELP = {
    "/kairos lock | unlock - lock or unlock the display",
    "/kairos reset - move the display back to the default spot",
    "/kairos scale <0.5-2> - set the display scale",
    "/kairos cd [on|off] - flip or set the Cooldowns toggle",
    "/kairos bind <spell> <text> - override a spell's keybind text",
    "/kairos unbind <spell> - remove an override",
    "/kairos binds - list keybind overrides",
    "/kairos why - explain the current pick",
    "/kairos status - version, spec, profile and restrictions",
    "/kairos probe - run the secrecy probe now",
    "/kairos probe report [n] - copyable matrix of the last n runs",
    "/kairos probe auto on|off - probe on combat, encounters and keystones",
    "/kairos probe clear - delete stored probe runs",
    "/kairos recorder on|off|clear - flight recorder",
    "/kairos config - open the settings panel",
}

function Kairos:ShowText(title, text)
    local frame = Commands.textFrame
    if not frame then
        frame = CreateFrame("Frame", "KairosTextFrame", UIParent, "BasicFrameTemplateWithInset")
        frame:SetSize(720, 480)
        frame:SetPoint("CENTER")
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", frame.StartMoving)
        frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
        frame:SetFrameStrata("DIALOG")
        tinsert(UISpecialFrames, "KairosTextFrame")

        frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        frame.title:SetPoint("TOP", 0, -5)

        local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 12, -32)
        scroll:SetPoint("BOTTOMRIGHT", -32, 12)

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(660)
        edit:SetScript("OnEscapePressed", function() frame:Hide() end)
        scroll:SetScrollChild(edit)
        frame.edit = edit
        Commands.textFrame = frame
    end
    frame.title:SetText(title)
    frame.edit:SetText(text)
    frame:Show()
    frame.edit:SetFocus()
    frame.edit:HighlightText()
end

local function setLocked(locked)
    Kairos.profile.display.locked = locked
    Kairos.Display:ApplyLayout()
    Kairos:Print("Display %s.", locked and "locked" or "unlocked")
end

local REASONS = {
    ["no-apl"] = "Kairos has no APL for this spec yet, so this is Assisted Combat's pick",
    uncertain = "the APL's pick read state Kairos can't know, so this is Assisted Combat's pick",
    error = "the APL raised an error, so this is Assisted Combat's pick",
    empty = "the APL had no pick, so this is Assisted Combat's pick",
}

function Commands:Why()
    local rec = Kairos.Display.current or Kairos.APL:Recommend()
    if rec.source == "apl" then
        Kairos:Print("%s, from %s", Kairos.SpellName(rec.spellID), rec.line or "an unnamed APL line")
    elseif rec.source == "ac" then
        Kairos:Print("%s: %s.", Kairos.SpellName(rec.spellID), REASONS[rec.reason] or tostring(rec.reason))
    else
        Kairos:Print("No pick. Assisted Combat returned nothing (%s).", tostring(rec.reason))
    end
    if rec.reason == "error" and Kairos.APL.lastError then
        Kairos:Print("APL error: %s", Kairos.APL.lastError)
    end
end

function Commands:Status()
    local module = Kairos.APL:ModuleFor(Kairos.specID)
    Kairos:Print("v%s, profile %s / spec %s, APL: %s, restrictions: %s, cooldowns %s.", Kairos.version,
        tostring(Kairos.DB.activeChar), tostring(Kairos.specID), module and (module.name or "loaded") or "none",
        Kairos.Signal:DescribeRestrictions(), Kairos.Toggles:Get("cooldowns") and "on" or "off")
end

function Commands:Probe(rest)
    local sub, arg = rest:match("^(%S*)%s*(.-)$")
    sub = sub:lower()
    if sub == "" then
        Kairos.Probe:RunAndReport("manual")
    elseif sub == "report" then
        Kairos:ShowText("Kairos probe report (Ctrl+C to copy)", Kairos.Probe.Report(Kairos.db.probes, tonumber(arg)))
    elseif sub == "auto" then
        if arg == "on" or arg == "off" then Kairos.db.global.autoProbe = arg == "on" end
        Kairos:Print("Auto-probe is %s.", Kairos.db.global.autoProbe and "on" or "off")
    elseif sub == "clear" then
        Kairos.db.probes = {}
        Kairos:Print("Probe runs cleared.")
    else
        Kairos.Probe:RunAndReport(rest)
    end
end

function Commands:Bind(rest)
    local spellText, text = rest:match("^(.-)%s+(%S+)$")
    local spellID = Kairos.ResolveSpell(spellText)
    if not spellID then
        Kairos:Print("Usage: /kairos bind <spell name or ID> <text>")
        return
    end
    Kairos.Keybinds:SetOverride(spellID, text)
    Kairos:Print("%s shows %q.", Kairos.SpellName(spellID), text)
end

function Commands:Handle(input)
    local command, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    command = command:lower()

    if command == "" or command == "help" then
        Kairos:Print("v%s commands:", Kairos.version)
        for _, line in ipairs(HELP) do DEFAULT_CHAT_FRAME:AddMessage("  " .. line) end
    elseif command == "lock" then
        setLocked(true)
    elseif command == "unlock" then
        setLocked(false)
    elseif command == "reset" then
        Kairos.profile.display.point = nil
        Kairos.Display:ApplyLayout()
    elseif command == "scale" then
        local scale = tonumber(rest)
        if not scale or scale < 0.5 or scale > 2 then
            Kairos:Print("Usage: /kairos scale <0.5-2>")
            return
        end
        Kairos.profile.display.scale = scale
        Kairos.Display:ApplyLayout()
    elseif command == "cd" or command == "cooldowns" then
        if rest == "on" or rest == "off" then
            Kairos.Toggles:Set("cooldowns", rest == "on")
            Kairos:Print("Cooldowns %s.", rest)
        else
            Kairos.ToggleCooldowns()
        end
    elseif command == "bind" then
        self:Bind(rest)
    elseif command == "unbind" then
        local spellID = Kairos.ResolveSpell(rest)
        if spellID then
            Kairos.Keybinds:SetOverride(spellID, nil)
            Kairos:Print("Removed the override for %s.", Kairos.SpellName(spellID))
        end
    elseif command == "binds" then
        local any = false
        for spellID, text in pairs(Kairos.profile.keybindOverrides) do
            any = true
            Kairos:Print("%s (%d): %s", Kairos.SpellName(spellID), spellID, text)
        end
        if not any then Kairos:Print("No keybind overrides for this spec.") end
    elseif command == "why" then
        self:Why()
    elseif command == "status" then
        self:Status()
    elseif command == "probe" then
        self:Probe(rest)
    elseif command == "recorder" then
        if rest == "clear" then
            Kairos.Recorder:Clear()
        elseif rest == "on" or rest == "off" then
            Kairos.db.global.recorder = rest == "on"
        end
        Kairos:Print("Flight recorder is %s, %d entries.", Kairos.db.global.recorder and "on" or "off",
            #Kairos.Recorder:Entries())
    elseif command == "config" or command == "settings" then
        Kairos.SettingsPanel:Open()
    else
        Kairos:Print("Unknown command %q. /kairos help", command)
    end
end

function Commands:OnInit()
    SLASH_KAIROS1 = "/kairos"
    SLASH_KAIROS2 = "/kai"
    SlashCmdList.KAIROS = function(input) self:Handle(input) end
end
