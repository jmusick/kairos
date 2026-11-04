local Stub = require("tests.wow_stub")

describe("Display", function()
    local Kairos, frame

    before_each(function()
        Stub.Install()
        Kairos = Stub.LoadAddon()
        frame = Kairos.Display.frame
        Stub.acSpell = 30451
        Stub.actions[1] = { "spell", 30451 }
        Stub.bindings.ACTIONBUTTON1 = "SHIFT-Q"
    end)

    it("shows Assisted Combat's pick with the AC badge and keybind", function()
        Stub.Tick(1)
        assert.are.equal(1000 + 30451, frame.main.icon.texture)
        assert.are.equal("SQ", frame.main.keybind.text)
        assert.is_true(frame.main.badge.shown)
        assert.is_false(frame.queued.shown)
        assert.is_false(frame.interrupt.shown)
    end)

    it("drops the badge and shows the queue for an APL pick", function()
        Kairos.APL:Register(62, { Evaluate = function() return { spellID = 30451, queuedID = 44425, interruptID = 2139 } end })
        Stub.Tick(1)
        assert.is_false(frame.main.badge.shown)
        assert.is_true(frame.queued.shown)
        assert.are.equal(1000 + 44425, frame.queued.icon.texture)
        assert.is_true(frame.interrupt.shown)
    end)

    it("never goes blank (D17)", function()
        Stub.acSpell = nil
        Stub.Tick(1)
        assert.is_true(frame.main.shown)
        assert.are.equal(Kairos.Display.UNKNOWN_ICON, frame.main.icon.texture)
    end)

    it("shows a separate use-now cue with a keybind and respects its setting", function()
        Kairos.APL:Register(62, { Evaluate = function()
            return { spellID = 30451, offGcdID = 321507, offGcdLabel = "touch" }
        end })
        Stub.Tick(1)
        assert.is_true(frame.offGcd.shown)
        assert.are.equal(1000 + 321507, frame.offGcd.icon.texture)
        assert.are.equal("NOW", frame.offGcd.caption.text)
        assert.are.equal(1000 + 30451, frame.main.icon.texture)
        Kairos.db.global.display.showOffGcd = false
        Stub.Tick(1)
        assert.is_false(frame.offGcd.shown)
    end)

    it("dims the CD pip when cooldowns are held", function()
        Stub.Tick(1)
        assert.are.equal(1, frame.pip.textColor[2])
        Kairos.ToggleCooldowns()
        assert.are.equal(0.5, frame.pip.textColor[2])
    end)

    it("tints spells that aren't usable", function()
        C_Spell.IsSpellUsable = function() return false, true end
        Stub.Tick(1)
        assert.are.same({ 0.5, 0.5, 1 }, frame.main.icon.color)
    end)

    it("ignores a secret usability read", function()
        C_Spell.IsSpellUsable = function() return Stub.Secret(), Stub.Secret() end
        Stub.Tick(1)
        assert.are.same({ 1, 1, 1 }, frame.main.icon.color)
    end)

    it("shows the exact APL spell's artwork while AC can still show an active override", function()
        C_Spell.GetSpellTexture = function(id)
            if id == 30451 then return 1295924, 30451 end
            return id, id
        end
        Kairos.APL:Register(62, { Evaluate = function() return { spellID = 30451 } end })
        Stub.Tick(1)
        assert.are.equal(30451, frame.main.icon.texture)
        Kairos.APL.modules[62] = nil
        Stub.Tick(1)
        assert.are.equal(1295924, frame.main.icon.texture)
    end)

    it("guards both texture returns and supports an API returning only one icon", function()
        Kairos.APL:Register(62, { Evaluate = function() return { spellID = 30451 } end })
        C_Spell.GetSpellTexture = function() return Stub.Secret(), 42 end
        assert.has_no_error(function() Stub.Tick(1) end)
        assert.are.equal(42, frame.main.icon.texture)
        C_Spell.GetSpellTexture = function() return 42, Stub.Secret() end
        assert.has_no_error(function() Stub.Tick(1) end)
        assert.are.equal(Kairos.Display.UNKNOWN_ICON, frame.main.icon.texture)
        C_Spell.GetSpellTexture = function() return 43 end
        Stub.Tick(1)
        assert.are.equal(43, frame.main.icon.texture)
    end)

    it("applies lock and scale from the profile", function()
        SlashCmdList.KAIROS("lock")
        assert.is_false(frame.mouse)
        SlashCmdList.KAIROS("scale 1.5")
        assert.are.equal(1.5, frame.scale)
        SlashCmdList.KAIROS("unlock")
        assert.is_true(frame.mouse)
    end)

    it("sets exact screen-center coordinates and rejects invalid values", function()
        SlashCmdList.KAIROS("position 125.5 -240")
        assert.are.same({ "CENTER", "CENTER", 125.5, -240 }, Kairos.db.global.display.point)
        SlashCmdList.KAIROS("pos nope 10")
        assert.are.same({ "CENTER", "CENTER", 125.5, -240 }, Kairos.db.global.display.point)
        SlashCmdList.KAIROS("position 1e999 0")
        assert.are.same({ "CENTER", "CENTER", 125.5, -240 }, Kairos.db.global.display.point)
        SlashCmdList.KAIROS("reset")
        assert.are.same({ "CENTER", UIParent, "CENTER", 0, -180 }, frame.points)
    end)

    it("disables display and evaluations, then resumes through the command", function()
        local calls = 0
        Kairos.APL:Register(62, { Evaluate = function()
            calls = calls + 1
            return { spellID = 30451 }
        end })
        SlashCmdList.KAIROS("disable")
        Stub.Tick(1)
        Stub.Fire("PLAYER_TARGET_CHANGED")
        assert.is_false(frame.shown)
        assert.are.equal(0, calls)
        assert.is_false(Kairos.db.global.enabled)
        SlashCmdList.KAIROS("enable")
        assert.is_true(frame.shown)
        assert.are.equal(1, calls)
        assert.is_true(Kairos.db.global.enabled)
    end)

    it("labels immediate Touch in the main icon and keeps its on-GCD follow-up visible", function()
        Kairos.APL:Register(62, { Evaluate = function()
            return { spellID = 321507, immediate = true, queuedID = 30451 }
        end })
        Stub.Tick(1)
        assert.are.equal(1000 + 321507, frame.main.icon.texture)
        assert.are.equal("NOW", frame.main.badge.text)
        assert.is_true(frame.main.badge.shown)
        assert.are.equal(1000 + 30451, frame.queued.icon.texture)
    end)

    it("overlaps the paired spell on the main icon independently of the queued setting", function()
        local pairedID = 321507
        Kairos.Keybinds:SetOverride(pairedID, "M4")
        Kairos.db.global.display.showQueued = false
        Kairos.db.global.display.showOffGcd = false
        Kairos.APL:Register(62, { Evaluate = function()
            return { spellID = 44425, pairedID = pairedID, pairedLabel = "touch" }
        end })
        Stub.Tick(1)
        assert.are.equal(1000 + 44425, frame.main.icon.texture)
        assert.are.equal(1000 + 321507, frame.paired.icon.texture)
        assert.are.equal("M4", frame.paired.keybind.text)
        assert.are.equal("+", frame.paired.caption.text)
        assert.are.same({ "TOPRIGHT", frame.main, "TOPRIGHT", 8, 8 }, frame.paired.points)
        assert.is_true(frame.paired.shown)
        assert.is_false(frame.queued.shown)
        pairedID = nil
        Stub.Tick(1)
        assert.is_false(frame.paired.shown)
    end)

    it("converts dragged anchors to screen-center coordinates at the frame's scale", function()
        Kairos.db.global.display.point = { "TOPLEFT", "TOPLEFT", 120, -200 }
        frame.GetCenter = function() return 600, 350 end
        frame.GetEffectiveScale = function() return 2 end
        UIParent.GetCenter = function() return 1000, 600 end
        UIParent.GetEffectiveScale = function() return 1 end
        local x, y = Kairos.Display:GetPosition()
        assert.are.equal(100, x)
        assert.are.equal(50, y)
        frame:GetScript("OnDragStop")(frame)
        assert.are.same({ "CENTER", "CENTER", 100, 50 }, Kairos.db.global.display.point)
        Kairos.Display:SetPosition(0, 50)
        assert.are.same({ "CENTER", UIParent, "CENTER", 0, 50 }, frame.points)
    end)

    it("provides coordinate edit boxes, centers X=0 from an old anchor and handles recycled rows", function()
        local settings, initializers = {}, {}
        MinimalSliderWithSteppersMixin = { Label = { Right = "right" } }
        Settings = {
            RegisterVerticalLayoutCategory = function() return {} end,
            RegisterProxySetting = function(_, key, _, _, _, get, set)
                local setting = {}
                function setting:GetValue() return get() end
                function setting:SetValue(value)
                    set(value)
                    if self.changed then self.changed(self, value) end
                end
                function setting:SetValueChangedCallback(fn) self.changed = fn end
                settings[key] = setting
                return setting
            end,
            CreateSliderOptions = function()
                return { SetLabelFormatter = function(self, _, formatter) self.formatter = formatter end }
            end,
            CreateSlider = function(_, setting, options)
                local initializer = { InitFrame = function() end, Resetter = function() end }
                initializer.options = options
                initializers[setting] = initializer
                return initializer
            end,
            CreateCheckbox = function() end,
            RegisterAddOnCategory = function() end,
        }
        Kairos.SettingsPanel:OnLogin()
        Kairos.db.global.display.point = { "TOPLEFT", "TOPLEFT", 999, -999 }
        frame.GetCenter = function() return 1200, 550 end
        frame.GetEffectiveScale = function() return 1 end
        UIParent.GetCenter = function() return 1000, 600 end
        UIParent.GetEffectiveScale = function() return 1 end
        local x, y = settings.KAIROS_POSITION_X, settings.KAIROS_POSITION_Y
        assert.are.equal("", initializers[x].options.formatter(200))
        assert.are.equal("", initializers[y].options.formatter(-50))
        assert.are.equal("1.00", initializers[settings.KAIROS_SCALE].options.formatter(1))
        assert.are.equal(200, x:GetValue())
        local row = CreateFrame("Frame")
        initializers[x]:InitFrame(row)
        local edit = row.KairosCoordinateEdit
        edit:SetText("0")
        edit:GetScript("OnEnterPressed")(edit)
        assert.are.same({ "CENTER", "CENTER", 0, -50 }, Kairos.db.global.display.point)
        initializers[x]:Resetter(row)
        assert.is_false(edit.shown)
        initializers[y]:InitFrame(row)
        edit:SetText("-200.5")
        edit:GetScript("OnEnterPressed")(edit)
        assert.are.same({ "CENTER", "CENTER", 0, -200.5 }, Kairos.db.global.display.point)
        x:SetValue(25) -- the old X callback cannot write into the reused Y editor
        assert.are.equal("-200.50", edit.text)
        edit:SetText("invalid")
        edit:GetScript("OnEnterPressed")(edit)
        assert.are.equal(-200.5, y:GetValue())
        edit:SetText("999")
        edit:GetScript("OnEscapePressed")(edit)
        assert.are.equal("-200.50", edit.text)
    end)
end)

describe("Flight recorder", function()
    local Kairos

    before_each(function()
        Stub.Install()
        Kairos = Stub.LoadAddon()
        Stub.acSpell = 30451
    end)

    it("logs picks only when they change, plus own casts", function()
        -- Login already logged a "none" pick (no Assisted Combat spell yet).
        Stub.Tick(1)
        Stub.Tick(1)
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 30451)
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "target", "Cast-2", 999)
        local kinds, sources = {}, {}
        for _, entry in ipairs(Kairos.Recorder:Entries()) do
            if entry.k == "session" or entry.k == "pick" or entry.k == "cast" then kinds[#kinds + 1] = entry.k end
            if entry.k == "pick" then sources[#sources + 1] = entry.src end
        end
        assert.are.same({ "session", "pick", "pick", "cast" }, kinds)
        assert.are.same({ "none", "ac" }, sources)
        assert.are.equal(30451, Kairos.State:PrevCast(1))
    end)

    it("wraps around at its size, oldest first", function()
        Kairos.Recorder.SIZE = 3
        Kairos.Recorder:Clear()
        for i = 1, 5 do Kairos.Recorder:Push({ k = "n", n = i }) end
        local entries = Kairos.Recorder:Entries()
        assert.are.equal(3, #entries)
        assert.are.equal(3, entries[1].n)
        assert.are.equal(5, entries[3].n)
    end)

    it("records changes to the paired cue even while the main spell stays the same", function()
        Kairos.Recorder:Clear()
        Kairos.Recorder:NoteRecommendation({ source = "apl", spellID = 44425 })
        Kairos.Recorder:NoteRecommendation({ source = "apl", spellID = 44425,
            pairedID = 321507, pairedLabel = "touch" })
        Kairos.Recorder:NoteRecommendation({ source = "apl", spellID = 44425,
            pairedID = 321507, pairedLabel = "touch" })
        Kairos.Recorder:NoteRecommendation({ source = "apl", spellID = 44425 })
        local picks = {}
        for _, entry in ipairs(Kairos.Recorder:Entries()) do
            if entry.src == "kairos" then picks[#picks + 1] = entry end
        end
        assert.are.equal(3, #picks)
        assert.is_nil(picks[1].paired)
        assert.are.equal(321507, picks[2].paired)
        assert.are.equal("touch", picks[2].pairedLabel)
        assert.is_nil(picks[3].paired)
    end)
end)
