local Stub = require("tests.wow_stub")

describe("APL runtime", function()
    local Kairos, APL

    before_each(function()
        Stub.Install()
        Kairos = Stub.LoadAddon()
        APL = Kairos.APL
        APL.modules[62] = nil -- exercise the generic runtime without the live Arcane registration
        Stub.acSpell = 30451
    end)

    it("falls back to Assisted Combat when the spec has no APL", function()
        local rec = APL:Recommend()
        assert.are.equal("ac", rec.source)
        assert.are.equal(30451, rec.spellID)
        assert.are.equal("no-apl", rec.reason)
        assert.is_nil(rec.queuedID)
    end)

    it("uses the module's pick and queue", function()
        APL:Register(62, { name = "test", Evaluate = function()
            return { spellID = 44425, queuedID = 30451, line = "actions+=/arcane_barrage" }
        end })
        local rec = APL:Recommend()
        assert.are.equal("apl", rec.source)
        assert.are.equal(44425, rec.spellID)
        assert.are.equal(30451, rec.queuedID)
        assert.are.equal("actions+=/arcane_barrage", rec.line)
    end)

    it("hides only the queued icon when the lookahead is uncertain", function()
        APL:Register(62, { Evaluate = function()
            return { spellID = 44425, queuedID = 30451, queuedUncertain = true }
        end })
        local rec = APL:Recommend()
        assert.are.equal(44425, rec.spellID)
        assert.is_nil(rec.queuedID)
    end)

    it("shows Blizzard's pick when the main pick is uncertain (D17)", function()
        APL:Register(62, { Evaluate = function()
            return { spellID = 44425, uncertain = true, interruptID = 2139, pairedID = 321507 }
        end })
        local rec = APL:Recommend()
        assert.are.equal("ac", rec.source)
        assert.are.equal(30451, rec.spellID)
        assert.are.equal("uncertain", rec.reason)
        assert.are.equal(2139, rec.interruptID)
        assert.is_nil(rec.pairedID)
    end)

    it("survives a module error", function()
        APL:Register(62, { Evaluate = function() error("bad binding") end })
        local rec = APL:Recommend()
        assert.are.equal("ac", rec.source)
        assert.are.equal("error", rec.reason)
        assert.matches("bad binding", APL.lastError)
    end)

    it("keeps a known off-GCD cue separate when only the main pick is uncertain", function()
        APL:Register(62, { Evaluate = function()
            return { spellID = 44425, uncertain = true, unknownFields = "salvo", offGcdID = 321507 }
        end })
        local rec = APL:Recommend()
        assert.are.equal("ac", rec.source)
        assert.are.equal(321507, rec.offGcdID)
        assert.are.equal("salvo", rec.unknownFields)
    end)

    it("survives a secret error payload", function()
        APL:Register(62, { Evaluate = function() error(Stub.Secret()) end })
        assert.are.equal("error", APL:Recommend().reason)
        assert.are.equal("secret APL error", APL.lastError)
    end)

    it("survives a module that reads a secret", function()
        APL:Register(62, { Evaluate = function()
            local stacks = Stub.Secret()
            if stacks >= 4 then return { spellID = 44425 } end
        end })
        assert.are.equal("error", APL:Recommend().reason)
    end)

    it("reports no pick when Assisted Combat has none", function()
        Stub.acSpell = nil
        C_AssistedCombat.IsAvailable = function() return false, "No rotation for this spec" end
        local rec = APL:Recommend()
        assert.are.equal("none", rec.source)
        assert.are.equal("No rotation for this spec", rec.reason)
    end)

    it("treats a secret Assisted Combat pick as no pick", function()
        Stub.acSpell = Stub.Secret()
        assert.are.equal("none", APL:Recommend().source)
    end)
end)

describe("Toggles", function()
    local Kairos, Toggles

    before_each(function()
        Stub.Install()
        Kairos = Stub.LoadAddon()
        Toggles = Kairos.Toggles
    end)

    it("starts with cooldowns on and flips from the binding", function()
        assert.is_true(Toggles:Get("cooldowns"))
        Kairos.ToggleCooldowns()
        assert.is_false(Toggles:Get("cooldowns"))
        assert.matches("OFF", Stub.chat[#Stub.chat])
    end)

    it("holds tagged abilities as just used when off (D15)", function()
        assert.is_false(Toggles:IsHeld("cooldowns"))
        Toggles:Set("cooldowns", false)
        assert.is_true(Toggles:IsHeld("cooldowns"))
        assert.is_false(Toggles:IsHeld(nil))
        local ready, remains = Toggles:ApplyToCooldown("cooldowns", true, 0, 90)
        assert.is_false(ready)
        assert.are.equal(90, remains)
        ready, remains = Toggles:ApplyToCooldown(nil, true, 0, 90)
        assert.is_true(ready)
        assert.are.equal(0, remains)
    end)

    it("stores the toggle per spec profile", function()
        Toggles:Set("cooldowns", false)
        Stub.specIndex = 2
        Stub.Fire("PLAYER_SPECIALIZATION_CHANGED", "player")
        assert.is_true(Toggles:Get("cooldowns"))
    end)
end)
