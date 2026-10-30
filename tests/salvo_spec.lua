local Stub = require("tests.wow_stub")

local BARRAGE, MISSILES, BLAST, BOLT, SURGE = 44425, 5143, 30451, 1295924, 365350

describe("Salvo estimator", function()
    local Kairos, Salvo

    before_each(function()
        Stub.Install()
        Kairos = Stub.LoadAddon()
        Salvo = Kairos.ArcaneSalvo
        Salvo:ResetState()
    end)

    it("is exact at 0 after Barrage", function()
        Salvo:OnCast(BLAST, 1)
        Salvo:OnCast(BARRAGE, 2)
        local reading = Salvo:Read(2)
        assert.are.equal("known", reading.state)
        assert.are.equal(0, reading.value)
    end)

    it("adds fixed gains for Blast and Prismatic Bolt", function()
        Salvo:OnCast(BARRAGE, 0)
        Salvo:OnCast(BLAST, 1)
        Salvo:OnCast(BOLT, 2)
        local value, low, high = Salvo:Estimate(2)
        assert.are.equal(8, value)
        assert.are.equal(6, low)
        assert.are.equal(9, high)
        assert.are.equal("estimated", Salvo:Read(2).state)
    end)

    local function rounded(x) return math.floor(x + 0.5) end

    it("builds through a Missiles channel in proportion to time", function()
        local gain = Salvo.GAINS[MISSILES][1]
        Salvo:OnCast(BARRAGE, 0)
        Salvo:OnCast(MISSILES, 10)
        assert.are.equal(0, (Salvo:Estimate(10)))
        assert.are.equal(rounded(gain / 2), (Salvo:Estimate(10 + Salvo.CHANNEL / 2)))
        assert.are.equal(gain, (Salvo:Estimate(10 + Salvo.CHANNEL)))
        assert.are.equal(gain, (Salvo:Estimate(20)))
    end)

    it("handles a chained Missiles whose CHANNEL_START arrives before its cast", function()
        local gain = Salvo.GAINS[MISSILES][1]
        Salvo:OnCast(BARRAGE, 0)
        -- First channel: start, then cast event (either order is possible).
        Salvo:OnChannelStart(MISSILES, 10, 10 + Salvo.CHANNEL)
        Salvo:OnCast(MISSILES, 10.01)
        -- Chained recast at the channel's end: the new CHANNEL_START comes first.
        local chain = 10 + Salvo.CHANNEL
        Salvo:OnChannelStart(MISSILES, chain, chain + Salvo.CHANNEL)
        assert.are.equal(gain, (Salvo:Estimate(chain)))
        Salvo:OnCast(MISSILES, chain + 0.01)
        assert.are.equal(gain, (Salvo:Estimate(chain + 0.01)))
        Salvo:OnChannelStop(chain + Salvo.CHANNEL)
        assert.are.equal(2 * gain, (Salvo:Estimate(chain + Salvo.CHANNEL)))
    end)

    it("counts only the channelled part of a clipped Missiles", function()
        Salvo:OnCast(BARRAGE, 0)
        Salvo:OnCast(MISSILES, 10)
        Salvo:OnChannelStop(10 + Salvo.CHANNEL / 4)
        assert.are.equal(rounded(Salvo.GAINS[MISSILES][1] / 4), (Salvo:Estimate(30)))
    end)

    it("uses the client's channel end time when given", function()
        Salvo:OnCast(BARRAGE, 0)
        Salvo:OnCast(MISSILES, 10)
        Salvo:OnChannelStart(MISSILES, 10, 14)
        assert.are.equal(rounded(Salvo.GAINS[MISSILES][1] / 2), (Salvo:Estimate(12)))
    end)

    it("anchors at 25 when Barrage lights up, and caps at 24 while it's dark", function()
        Salvo:OnCast(BARRAGE, 0)
        for start = 1, 7, 3 do
            Salvo:OnCast(MISSILES, start)
            Salvo:OnChannelStop(start + 2)
        end
        assert.are.equal(24, (Salvo:Estimate(9)))
        Salvo:OnGlow(BARRAGE, true, 6.5)
        local reading = Salvo:Read(6.5)
        assert.are.equal("known", reading.state)
        assert.are.equal(25, reading.value)
    end)

    it("ignores the glow during Arcane Soul after Surge", function()
        Salvo:OnCast(BARRAGE, 0)
        Salvo:OnCast(SURGE, 1)
        Salvo:OnCast(BLAST, 2)
        Salvo:OnGlow(BARRAGE, true, 1 + 17.4)
        assert.are.equal(2, (Salvo:Estimate(19)))
        Salvo:OnGlow(BARRAGE, false, 1 + 21.5)
        Salvo:OnGlow(BARRAGE, true, 60)
        assert.are.equal(25, (Salvo:Estimate(60)))
    end)

    it("adds instead of resetting for Barrage during Arcane Soul", function()
        Salvo:OnCast(BARRAGE, 0)
        Salvo:OnCast(SURGE, 1)
        Salvo:OnGlow(BARRAGE, true, 18.3)
        Salvo:OnCast(BLAST, 18.5)
        Salvo:OnCast(BARRAGE, 19)
        Salvo:OnCast(BARRAGE, 20)
        assert.are.equal(12, (Salvo:Estimate(20)))
        Salvo:OnGlow(BARRAGE, false, 22.4)
        Salvo:OnCast(BARRAGE, 22.8)
        assert.are.equal(0, (Salvo:Estimate(23)))
    end)

    it("ends Soul on time even when Salvo reached 25 during it and the glow stayed lit", function()
        Salvo:OnCast(SURGE, 0)
        Salvo:OnCast(BARRAGE, 0.5)
        Salvo:OnGlow(BARRAGE, true, 17.4)
        for t = 18, 21, 1 do Salvo:OnCast(BARRAGE, t) end
        assert.are.equal(20, (Salvo:Estimate(21)))
        Salvo:OnCast(BLAST, 22) -- Soul is over and the glow is still lit: Salvo is 25
        assert.are.equal(25, (Salvo:Estimate(22)))
        Salvo:OnCast(BARRAGE, 23) -- a real Barrage again: consumes
        assert.are.equal(0, Salvo:Read(23).value)
        assert.are.equal("known", Salvo:Read(23).state)
    end)

    it("ends Soul when the glow goes dark inside the timed window", function()
        Salvo:OnCast(SURGE, 0)
        Salvo:OnGlow(BARRAGE, true, 17.4)
        Salvo:OnCast(BARRAGE, 18)
        Salvo:OnCast(BARRAGE, 19)
        -- Soul ended at 21.40 with Salvo at 25 (glow still lit); a Barrage 5 ms later
        -- consumed it, and its glow went dark at the same instant.
        Salvo:OnCast(BARRAGE, 21.405)
        Salvo:OnGlow(BARRAGE, false, 21.405)
        assert.are.equal(0, Salvo:Read(21.41).value)
        assert.are.equal("known", Salvo:Read(21.41).state)
        Salvo:OnCast(BLAST, 21.45)
        Salvo:OnCast(BARRAGE, 21.48) -- still inside the window, but Soul is over: consumes
        assert.are.equal(0, (Salvo:Estimate(21.48)))
    end)

    it("ends Soul early on a dark glow without anchoring when no Barrage caused it", function()
        Salvo:OnCast(SURGE, 0)
        Salvo:OnGlow(BARRAGE, true, 17.4)
        Salvo:OnCast(BLAST, 18)
        Salvo:OnGlow(BARRAGE, false, 21.35)
        assert.are.equal(2, (Salvo:Estimate(21.4)))
        assert.are.equal("estimated", Salvo:Read(21.4).state)
    end)

    it("treats a glow already lit for Salvo as Soul once Soul is due", function()
        Salvo:OnCast(SURGE, 0)
        Salvo:OnGlow(BARRAGE, true, 10)
        Salvo:OnCast(BARRAGE, 18)
        assert.are.equal(25, (Salvo:Estimate(18)))
    end)

    it("answers threshold checks with certainty from the bounds", function()
        Salvo:OnCast(BARRAGE, 0)
        Salvo:OnCast(BOLT, 1)
        Salvo:OnCast(BLAST, 2)
        local atLeast, sure = Salvo:AtLeast(8, 2)
        assert.is_true(atLeast)
        assert.is_false(sure)
        atLeast, sure = Salvo:AtLeast(12, 2)
        assert.is_false(atLeast)
        assert.is_true(sure)
    end)

    it("takes a readable stack count as truth", function()
        Salvo:OnCast(MISSILES, 0)
        Salvo:OnTruth(17)
        local reading = Salvo:Read(1)
        assert.are.equal("known", reading.state)
        assert.are.equal(17, reading.value)
    end)
end)

describe("Salvo estimator in game", function()
    local Kairos, Salvo, salvoAura

    local function salvoEntries()
        local out = {}
        for _, entry in ipairs(Kairos.Recorder:Entries()) do
            if entry.k == "salvo" then out[#out + 1] = entry end
        end
        return out
    end

    before_each(function()
        Stub.Install()
        salvoAura = { applications = 20, spellId = 1242974, auraInstanceID = 77 }
        C_UnitAuras.GetAuraDataBySpellName = function(_, name)
            if name == "Arcane Salvo" then return salvoAura end
        end
        Kairos = Stub.LoadAddon()
        Salvo = Kairos.ArcaneSalvo
    end)

    it("starts from the out-of-combat read", function()
        assert.are.equal(20, Salvo:Read(GetTime()).value)
    end)

    it("follows casts, glows and channels, and records each change", function()
        Stub.Fire("PLAYER_REGEN_DISABLED")
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c1", BARRAGE)
        assert.are.equal(0, Salvo:Read(GetTime()).value)
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c2", MISSILES)
        Stub.now = Stub.now + Salvo.CHANNEL
        Stub.Fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "c2", MISSILES)
        local gain = Salvo.GAINS[MISSILES][1]
        assert.are.equal(gain, Salvo:Read(GetTime()).value)
        Stub.Fire("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", BARRAGE)
        assert.are.equal(25, Salvo:Read(GetTime()).value)

        local values = {}
        for _, entry in ipairs(salvoEntries()) do values[#values + 1] = entry.v end
        assert.are.same({ 20, 0, gain, 25 }, values)
    end)

    it("ignores casts on other specs", function()
        Stub.specIndex = 2
        Stub.Fire("PLAYER_SPECIALIZATION_CHANGED", "player")
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c1", BLAST)
        assert.are.equal(0, Salvo:Read(GetTime()).value)
    end)
end)
