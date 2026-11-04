local Stub = require("tests.wow_stub")

describe("Wild Imp estimate", function()
    local D
    before_each(function()
        Stub.Install()
        Stub.specs[1] = 266
        Stub.knownSpells[267216] = true -- Inner Demons
        D = Stub.LoadAddon().DemonologyDemons
        D:Reset()
    end)

    it("learns Inner Demons' phase from two count ticks a whole number of periods apart", function()
        D:SetCombat(false, 99) -- out of combat imps idle
        D:Anchor(100, 0, 0)
        D:Anchor(103, 1, 0) -- one tick: only a candidate
        assert.is_nil(D.inner)
        D:Anchor(115, 2, 0) -- 12 s later: confirmed
        assert.are.equal(115, D.inner)
        D:SetCombat(true, 120) -- the idle two spend from 123 (REENGAGE) and run out at 135
        assert.are.equal(2, D:Count(126.9))
        assert.are.equal(3, D:Count(127)) -- the next imp, unseen in combat
        assert.are.equal(1, D:Count(135))
        assert.are.equal(1, D:Count(139)) -- the 127 imp ran out as the 139 one arrived
    end)

    it("confirms across several periods and keeps a phase a later tick fits", function()
        D:Anchor(100, 0, 0)
        D:Anchor(100.5, 1, 0)
        D:Anchor(136.6, 2, 0) -- three periods later, within the slack
        assert.are.equal(136.6, D.inner)
        D:Anchor(148.5, 3, 0)
        assert.are.equal(136.6, D.inner)
    end)

    it("doesn't take a rise right after its own summon, or across combat, as a tick", function()
        D:Anchor(100, 0, 0)
        D:OnCast(105174, 101, 0) -- Hand: +3 in the estimate
        D:Anchor(101.2, 1, 0)
        D:Anchor(113.2, 2, 0)
        assert.is_nil(D.inner)
        D:SetCombat(true, 114)
        D:SetCombat(false, 120)
        D:Anchor(125.2, 3, 0) -- the first read after combat is a new baseline
        assert.is_nil(D.inner)
    end)

    it("forgets the phase at a loading screen and when the talent isn't taken", function()
        D:Anchor(100, 0, 0)
        D:Anchor(103, 1, 0)
        D:Anchor(115, 2, 0)
        assert.are.equal(115, D.inner)
        D:Zone()
        assert.is_nil(D.inner)
        D.innerTalent = false
        D:Anchor(130, 0, 0)
        D:Anchor(133, 1, 0)
        D:Anchor(145, 2, 0)
        assert.is_nil(D.inner)
    end)

    it("pauses imps only once the target has been gone for the grace", function()
        D.TARGET_GRACE = 3
        D:SetCombat(true, 100)
        D:Spawn(100, 3, 0) -- 12 s of Firebolts at no haste
        D:SetTarget(false, 102)
        D:SetTarget(true, 104) -- back within the grace: no pause
        assert.are.equal(0, D:Count(112))
        D:Spawn(120, 3, 0)
        D:SetTarget(false, 121) -- paused from 124 to 126, then REENGAGE until 129
        D:SetTarget(true, 126)
        assert.are.equal(3, D:Count(136.9))
        assert.are.equal(0, D:Count(137))
        -- A pull that starts with no target ends the out-of-combat pause.
        D:SetTarget(false, 140)
        D:SetCombat(false, 145)
        D:SetCombat(true, 160)
        local closed = D.idle[#D.idle - 1]
        assert.are.equal(160, closed.to)
        assert.are.equal(163, D.idle[#D.idle].from)
    end)

    it("takes a phase given by the replay", function()
        D:SetPhase(130, 103)
        assert.are.equal(139, D.nextInner)
        assert.are.equal(1, D:Count(139))
    end)
end)
