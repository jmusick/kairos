local Stub = require("tests.wow_stub")

describe("Diabolic Ritual model", function()
    local K, R, A, S
    local none = { ritual = false, art = false }
    local function empty() return { overlord = none, mother = none, pit_lord = none } end
    before_each(function()
        Stub.Install()
        Stub.specs[1] = 266
        Stub.shards = 2
        UnitPower = function(_, power) return power == 7 and Stub.shards or 0 end
        for _, id in ipairs({ 686, 105174, 264178, 426115, 30146, 428514, 428518, 428522 }) do
            Stub.knownSpells[id] = true
        end
        K = Stub.LoadAddon()
        R, A, S = K.DemonologyRitual, K.DemonologyState, K.DemonologyAPL.SPELLS
    end)

    it("starts a ritual on a spend and ends it 1 s sooner per shard", function()
        local readings = empty()
        readings.overlord = { ritual = false, art = 110 } -- an Overlord Art from 50 s ago
        R:Anchor(100, readings)
        assert.are.equal("overlord", R:ArtAt(100))
        R:Spend(101, 0, false) -- free Dreadstalkers still starts the next one
        assert.are.equal("mother", R.ritual.kind)
        assert.are.equal(121, R.ritual.ends)
        R:Spend(102, 3, true) -- a Hand with Infernal Machine: 4 s
        assert.are.equal(117, R.ritual.ends)
        assert.are.equal("overlord", R:ArtAt(109.9))
        assert.is_false(R:ArtAt(110.5)) -- its 60 s ran out at 110
        assert.is_false(R:ArtAt(117.1))
        assert.are.equal("mother", R:ArtAt(117.2))
    end)

    it("ends a ritual just after a spend that takes more than is left", function()
        R:Anchor(100, empty())
        R:Spend(100, 1, false)
        for t = 101, 106 do R:Spend(t, 3, false) end
        -- 119 - 3 a second reaches 104 at the 105 s spend, which ends it END_LAG later.
        local _, art = R:At(106)
        assert.are.equal(105.25, art.at)
        assert.are.equal(126 - 3, R.ritual.ends) -- the 106 s spend began the next one
    end)

    it("counts a cast just after an overrunning Hand toward the ending ritual", function()
        R:Anchor(100, empty())
        R.nextKind = "mother"
        R:Spend(100, 3, false)
        R:Spend(110, 3, false) -- 117 - 3 = 114: still running
        R:Spend(113, 3, false) -- 111 < 113: it ends just after, at 113.05
        R:Spend(113.002, 0, false) -- Dreadstalkers inside that gap starts nothing
        assert.are.equal(113.05, R.ritual.ends)
        assert.are.equal("mother", R.ritual.kind)
        R:Spend(115, 3, false) -- the next spend starts Pit Lord
        assert.are.equal("pit_lord", R.ritual.kind)
        assert.are.equal("mother", R:ArtAt(115))
    end)

    it("lets a Hand consume only an Art that was up when its cast began", function()
        R:Anchor(100, empty())
        R.nextKind = "pit_lord"
        R:Spend(100, 3, false)
        R.ritual.ends = 105 -- the Pit Lord Art appears at 105.2
        assert.is_false(R:Hand(105.8, 104.5, 3, false)) -- began before the Art
        assert.are.equal("pit_lord", R:ArtAt(106))
        assert.are.equal("pit_lord", R:Hand(107.5, 106.2, 3, false))
        assert.is_false(R:ArtAt(108))
        assert.are.equal("overlord", R.ritual.kind) -- the Hand started the next ritual
    end)

    it("is unknown until anchored, and a proc fixes its place in the cycle", function()
        R:Reset()
        assert.is_nil(R:ArtAt(100))
        R:Spend(100, 3, false)
        assert.is_nil(R.ritual.kind)
        R:Learn("mother")
        assert.are.equal("pit_lord", R.ritual.kind)
    end)

    it("anchors from readable auras out of combat", function()
        Stub.auras[432815] = { spellId = 432815, expirationTime = 112 }
        Stub.auras[428524] = { spellId = 428524, expirationTime = 150 }
        A:AnchorRitual(100)
        assert.are.equal("mother", R.ritual.kind)
        assert.are.equal(112, R.ritual.ends)
        assert.are.equal("overlord", R:ArtAt(100))
        -- A secret aura leaves the model alone.
        Stub.auras[432815] = nil
        C_Secrets.ShouldSpellAuraBeSecret = function(id) return id == 432795 end
        A:AnchorRitual(101)
        assert.are.equal("mother", R.ritual.kind)
    end)

    it("shows the proc a casting Hand will bring before it lands", function()
        Stub.auras[432794] = { spellId = 432794, expirationTime = 150 } -- Mother of Chaos Art up
        A:AnchorRitual(Stub.now)
        Stub.Fire("PLAYER_REGEN_DISABLED")
        A.cooldowns[S.DOGS] = { finish = 400, base = 20 }
        A.cooldowns[S.TYRANT] = { finish = 400, base = 60 }
        Stub.shards = 3
        K.State.cast = { spellID = S.HAND, startsAt = 100, endsAt = 101.5 }
        local s = A:Build(100.5)
        assert.is_true(s.infernalReady)
        assert.is_true(s.handArtKnown)
        assert.are.equal(S.INFERNAL, A:Pick(s).spellID)
        -- It landed: the proc counts until the override shows it.
        K.State.cast = nil
        Stub.now = 101.5
        A:OnCast(S.HAND, 101.5)
        assert.are.equal("mother", A.handArt)
        assert.is_true(A:Build(101.6).infernalReady)
        assert.are.equal("pit_lord", R.ritual.kind)
    end)

    it("knows a casting Hand brings nothing when no Art was up", function()
        A:AnchorRitual(Stub.now)
        Stub.Fire("PLAYER_REGEN_DISABLED")
        K.State.cast = { spellID = S.HAND, startsAt = 100, endsAt = 101.5 }
        local s = A:Build(100.5)
        assert.is_false(s.infernalReady)
        assert.is_true(s.pendingArtKnown)
    end)
end)
