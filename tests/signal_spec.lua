local Stub = require("tests.wow_stub")

describe("Signal", function()
    local Kairos, Signal

    before_each(function()
        Stub.Install()
        Kairos = Stub.LoadAddon()
        Signal = Kairos.Signal
    end)

    it("stub secrets raise on comparison and arithmetic", function()
        local secret = Stub.Secret()
        assert.has_error(function() return secret < 1 end)
        assert.has_error(function() return secret + 1 end)
        assert.has_error(function() return #secret end)
        assert.has_error(function() return secret.field end)
    end)

    it("wraps a readable value as known", function()
        local reading = Signal.Read(function(a, b) return a + b end, 2, 3)
        assert.are.equal("known", reading.state)
        assert.are.equal(5, reading.value)
    end)

    it("turns a secret into unknown instead of throwing", function()
        local reading = Signal.Read(function() return Stub.Secret() end)
        assert.are.equal("unknown", reading.state)
        assert.are.equal("secret", reading.reason)
    end)

    it("turns an erroring API into unknown", function()
        local reading = Signal.Read(function() error("boom") end)
        assert.are.equal("error", reading.reason)
    end)

    it("treats a missing API as unknown", function()
        assert.are.equal("missing", Signal.Read(nil).reason)
    end)

    it("reads info-table fields one at a time", function()
        local info = { startTime = 10, duration = Stub.Secret() }
        assert.are.equal(10, Signal.ReadField(info, "startTime").value)
        assert.are.equal("secret", Signal.ReadField(info, "duration").reason)
        assert.are.equal("secret", Signal.ReadField(Stub.Secret(), "duration").reason)
    end)

    it("tracks restriction state from the event payload", function()
        assert.is_false(Signal:IsRestricted())
        Stub.Fire("ADDON_RESTRICTION_STATE_CHANGED", 0, 1)
        assert.is_true(Signal.restrictions.Combat)
        assert.are.equal("Combat", Signal:DescribeRestrictions())
        Stub.Fire("ADDON_RESTRICTION_STATE_CHANGED", 0, 0)
        assert.is_false(Signal:IsRestricted())
    end)

    it("refreshes from the API when the payload itself is secret", function()
        Stub.restrictions[1] = true
        Stub.Fire("ADDON_RESTRICTION_STATE_CHANGED", Stub.Secret(), Stub.Secret())
        assert.is_true(Signal.restrictions.Encounter)
    end)
end)
