local Stub = require("tests.wow_stub")

local MISSILES, BLAST, BOLT, BARRAGE = 5143, 30451, 1295924, 44425

describe("Cumulative Power estimator", function()
    local Kairos, Power

    before_each(function()
        Stub.Install()
        Kairos = Stub.LoadAddon()
        Power = Kairos.ArcaneCumulativePower
        Power:ResetState()
    end)

    it("reaches 8 over a full Missiles channel, 1 at the start", function()
        Power:OnCast(MISSILES, 10)
        assert.are.equal(1, Power:Estimate(10))
        assert.are.equal(5, Power:Estimate(10 + Power.CHANNEL / 2))
        Power:OnChannelStop(10 + Power.CHANNEL * 0.97) -- stopped at the last tick
        assert.are.equal(8, Power:Estimate(12))
    end)

    it("counts only the channelled part of a clipped Missiles, and caps at 8", function()
        Power:OnCast(MISSILES, 0)
        Power:OnChannelStop(Power.CHANNEL / 2)
        assert.are.equal(5, Power:Estimate(2))
        Power:OnCast(MISSILES, 3)
        Power:OnChannelStop(3 + Power.CHANNEL)
        assert.are.equal(8, Power:Estimate(6))
    end)

    it("is consumed at 8 by Arcane Blast or Prismatic Bolt, not below 8", function()
        Power:OnCast(MISSILES, 0)
        Power:OnChannelStop(Power.CHANNEL / 2)
        Power:OnCast(BLAST, 2)
        assert.are.equal(5, Power:Estimate(2))
        Power:OnCast(MISSILES, 3)
        Power:OnChannelStop(3 + Power.CHANNEL)
        Power:OnCast(BOLT, 6)
        local reading = Power:Read(6)
        assert.are.equal(0, reading.value)
        assert.are.equal("known", reading.state)
    end)

    it("ignores other casts", function()
        Power:OnCast(MISSILES, 0)
        Power:OnChannelStop(Power.CHANNEL)
        Power:OnCast(BARRAGE, 2)
        assert.are.equal(8, Power:Estimate(2))
    end)

    it("expires 12 s after the last gain", function()
        Power:OnCast(MISSILES, 0)
        Power:OnChannelStop(Power.CHANNEL)
        assert.are.equal(8, Power:Estimate(Power.CHANNEL + 11.9))
        assert.are.equal(0, Power:Estimate(Power.CHANNEL + 12.1))
        Power:OnCast(MISSILES, 20)
        assert.are.equal(1, Power:Estimate(20))
    end)

    it("takes a readable stack count as truth", function()
        Power:OnTruth(6, 0)
        local reading = Power:Read(1)
        assert.are.equal("known", reading.state)
        assert.are.equal(6, reading.value)
    end)
end)

describe("Cumulative Power estimator in game", function()
    local Kairos, Power, aura

    before_each(function()
        Stub.Install()
        aura = { applications = 3, spellId = 1296930, auraInstanceID = 9 }
        C_UnitAuras.GetAuraDataBySpellName = function(_, name)
            if name == "Cumulative Power" then return aura end
        end
        Kairos = Stub.LoadAddon()
        Power = Kairos.ArcaneCumulativePower
    end)

    it("starts from the out-of-combat read and follows casts and channels", function()
        assert.are.equal(3, Power:Read(GetTime()).value)
        Stub.Fire("PLAYER_REGEN_DISABLED")
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c1", MISSILES)
        Stub.now = Stub.now + Power.CHANNEL
        Stub.Fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "c1", MISSILES)
        assert.are.equal(8, Power:Read(GetTime()).value)
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c2", BLAST)
        assert.are.equal(0, Power:Read(GetTime()).value)

        local values = {}
        for _, entry in ipairs(Kairos.Recorder:Entries()) do
            if entry.k == "cp" then values[#values + 1] = entry.n end
        end
        assert.are.same({ 3, 4, 8, 0 }, values) -- 4: the stack gained as the channel starts
    end)
end)
