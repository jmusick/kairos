local Stub = require("tests.wow_stub")

describe("State", function()
    local Kairos, State

    before_each(function()
        Stub.Install()
        Kairos = Stub.LoadAddon()
        State = Kairos.State
    end)

    it("reads movement from unit speed when it's readable", function()
        GetUnitSpeed = function() return 7 end
        local moving = State:Moving()
        assert.are.equal("known", moving.state)
        assert.is_true(moving.value)
    end)

    it("falls back to movement events when speed is secret", function()
        GetUnitSpeed = function() return Stub.Secret() end
        State.movingByEvent = nil -- exercise a login where no readable speed was available
        assert.are.equal("unknown", State:Moving().state)
        Stub.Fire("PLAYER_STARTED_MOVING")
        local moving = State:Moving()
        assert.are.equal("estimated", moving.state)
        assert.is_true(moving.value)
        Stub.Fire("PLAYER_STOPPED_MOVING")
        assert.is_false(State:Moving().value)
    end)

    it("counts movement events from combat start", function()
        Stub.Fire("PLAYER_STARTED_MOVING")
        Stub.Fire("PLAYER_REGEN_DISABLED")
        assert.are.equal(0, State.moveEvents)
        Stub.Fire("PLAYER_STARTED_MOVING")
        Stub.Fire("PLAYER_STOPPED_MOVING")
        assert.are.equal(2, State.moveEvents)
    end)

    it("keeps the last ten casts, newest first", function()
        for i = 1, 12 do Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast", i) end
        assert.are.equal(12, State:PrevCast(1))
        assert.are.equal(3, State:PrevCast(10))
        assert.is_nil(State:PrevCast(11))
    end)

    it("ignores a secret spell ID in a cast event", function()
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast", Stub.Secret())
        assert.is_nil(State:PrevCast(1))
    end)

    it("omits a secret cast start while retaining readable projection timing", function()
        UnitCastingInfo = function() return "Blast", nil, nil, Stub.Secret(), 102000, nil, nil, nil, 30451 end
        assert.has_no_error(function() Stub.Fire("UNIT_SPELLCAST_START", "player", "cast", 30451) end)
        assert.is_nil(State.cast.startsAt)
        assert.are.equal(102, State.cast.endsAt)
        assert.is_false(State.castUnknown)
    end)

    it("counts hostile in-combat nameplates, unknown if any read is secret", function()
        UnitAffectingCombat = function(unit) return unit ~= "nameplate3" end
        for i = 1, 3 do Stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate" .. i) end
        assert.are.equal(2, State:EnemyCount().value)
        Stub.Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
        assert.are.equal(1, State:EnemyCount().value)
        UnitCanAttack = function() return Stub.Secret() end
        assert.are.equal("unknown", State:EnemyCount().state)
    end)
end)
