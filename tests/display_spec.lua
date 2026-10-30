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

    it("applies lock and scale from the profile", function()
        SlashCmdList.KAIROS("lock")
        assert.is_false(frame.mouse)
        SlashCmdList.KAIROS("scale 1.5")
        assert.are.equal(1.5, frame.scale)
        SlashCmdList.KAIROS("unlock")
        assert.is_true(frame.mouse)
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
end)
