local Stub = require("tests.wow_stub")

describe("Keybinds", function()
    local Kairos, Keybinds

    before_each(function()
        Stub.Install()
        Kairos = Stub.LoadAddon()
        Keybinds = Kairos.Keybinds
    end)

    it("abbreviates modifiers, mouse buttons and the numpad", function()
        assert.are.equal("S4", Keybinds.Format("SHIFT-4"))
        assert.are.equal("CM4", Keybinds.Format("CTRL-BUTTON4"))
        assert.are.equal("AM3", Keybinds.Format("ALT-MIDDLEBUTTON"))
        assert.are.equal("N5", Keybinds.Format("NUMPAD5"))
        assert.are.equal("SMwU", Keybinds.Format("SHIFT-MOUSEWHEELUP"))
        assert.are.equal("BkSp", Keybinds.Format("BACKSPACE"))
        assert.are.equal("Q", Keybinds.Format("q"))
        assert.is_nil(Keybinds.Format(nil))
    end)

    it("finds a spell on the main bar", function()
        Stub.actions[3] = { "spell", 30451 }
        Stub.bindings.ACTIONBUTTON3 = "3"
        assert.are.equal("3", Keybinds:Lookup(30451))
    end)

    it("finds a spell on a multi-action bar", function()
        Stub.actions[61] = { "spell", 44425 }
        Stub.bindings.MULTIACTIONBAR1BUTTON1 = "SHIFT-1"
        assert.are.equal("S1", Keybinds:Lookup(44425))
    end)

    it("resolves macros to their spell", function()
        Stub.actions[5] = { "macro", 7 }
        Stub.macros[7] = 2139
        Stub.bindings.ACTIONBUTTON5 = "E"
        assert.are.equal("E", Keybinds:Lookup(2139))
    end)

    it("follows bonus bars for the main bar buttons", function()
        Stub.bonusOffset = 1
        Stub.actions[73] = { "spell", 100 }
        Stub.bindings.ACTIONBUTTON1 = "1"
        assert.are.equal(73, Keybinds.MainBarSlot(1))
        assert.are.equal("1", Keybinds:Lookup(100))
    end)

    it("prefers a manual override", function()
        Stub.actions[1] = { "spell", 30451 }
        Stub.bindings.ACTIONBUTTON1 = "1"
        Keybinds:SetOverride(30451, "F")
        assert.are.equal("F", Keybinds:Lookup(30451))
        Keybinds:SetOverride(30451, nil)
        Keybinds.dirty = true
        assert.are.equal("1", Keybinds:Lookup(30451))
    end)

    it("rebuilds after a slot change", function()
        Stub.bindings.ACTIONBUTTON2 = "2"
        assert.is_nil(Keybinds:Lookup(5143))
        Stub.actions[2] = { "spell", 5143 }
        Stub.Fire("ACTIONBAR_SLOT_CHANGED", 2)
        assert.are.equal("2", Keybinds:Lookup(5143))
    end)

    it("keeps the last full map when a rebuild hits a secret", function()
        Stub.actions[1] = { "spell", 30451 }
        Stub.bindings.ACTIONBUTTON1 = "1"
        assert.are.equal("1", Keybinds:Lookup(30451))
        Stub.actions[1] = { Stub.Secret(), Stub.Secret() }
        Stub.Fire("ACTIONBAR_SLOT_CHANGED", 1)
        assert.are.equal("1", Keybinds:Lookup(30451))
        assert.is_true(Keybinds.dirty)
    end)
end)
