local Stub = require("tests.wow_stub")

describe("Affliction live module", function()
    local K, A, S
    local function cast(id) Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", id) end
    local function hold(id) A.cooldowns[id] = { finish = 400, base = A.COOLDOWNS[id] } end
    before_each(function()
        Stub.Install()
        Stub.specs[1] = 265
        Stub.shards = 0
        UnitPower = function(_, power)
            if power == 7 then return Stub.shards end
            return 0
        end
        -- Soul Harvester with Drain Soul; no Dark Harvest, Darkglare or Malevolence yet.
        for _, id in ipairs({ 686, 980, 172, 1259790, 27243, 48181, 388667, 449614, 688 }) do
            Stub.knownSpells[id] = true
        end
        K = Stub.LoadAddon()
        A, S = K.AfflictionState, K.AfflictionAPL.SPELLS
        K.State.inCombat = true
    end)

    it("registers spec 265 beside the other modules", function()
        assert.are.equal(A, K.APL:ModuleFor(265))
        assert.are.equal(K.DemonologyState, K.APL:ModuleFor(266))
        assert.are.equal("WarlockAffliction", K:CurrentSpec().key)
        local s = A:Build(100)
        assert.is_true(s.talent.demonic_soul)
        assert.is_true(s.known[S.DRAIN])
        assert.is_false(s.known[S.GRASP])
        assert.are.equal(1, s.enemies)
    end)

    it("follows the Soul Harvester single-target priorities from own casts", function()
        local rec = K.APL:Recommend()
        assert.are.equal(S.HAUNT, rec.spellID)
        assert.are.equal("SH_st:haunt", rec.label)
        hold(S.HAUNT)
        assert.are.equal(S.AGONY, K.APL:Recommend().spellID)
        cast(S.AGONY)
        assert.are.equal(S.CORRUPTION, K.APL:Recommend().spellID)
        cast(S.CORRUPTION)
        Stub.shards = 2
        assert.are.equal(S.UA, K.APL:Recommend().spellID)
        Stub.shards = 0
        rec = K.APL:Recommend()
        assert.are.equal(S.DRAIN, rec.spellID)
        assert.are.equal("default:drain_soul", rec.label)
        assert.is_nil(rec.queuedID)
    end)

    it("times DoTs with pandemic refreshes and keeps them per target", function()
        hold(S.HAUNT)
        cast(S.AGONY)
        cast(S.CORRUPTION)
        Stub.now = 115
        assert.are.equal(3, A:Build(115).agonyRemains)
        Stub.now = 116
        assert.are.equal(S.AGONY, K.APL:Recommend().spellID)
        cast(S.AGONY) -- 2 s left carries over: 18 + 2
        assert.are.equal(20, A:Build(116).agonyRemains)
        UnitGUID = function() return "Creature-1" end
        assert.are.equal(0, A:Build(116).agonyRemains)
        assert.are.equal(S.AGONY, K.APL:Recommend().spellID)
        UnitGUID = function() return "Creature-0" end
        assert.are.equal(20, A:Build(116).agonyRemains)
    end)

    it("prefers a readable debuff over its own timers", function()
        Stub.spellNames[980] = "Agony"
        Stub.auras["Agony"] = { spellId = 980, expirationTime = 102 }
        hold(S.HAUNT)
        assert.are.equal(2, A:Build(100).agonyRemains)
        assert.are.equal(S.AGONY, K.APL:Recommend().spellID)
    end)

    it("falls back to AC when a hidden target's DoTs can't be known", function()
        hold(S.HAUNT)
        Stub.acSpell = 686
        UnitGUID = function() return Stub.Secret() end
        Stub.Fire("PLAYER_TARGET_CHANGED")
        local rec = K.APL:Recommend()
        assert.are.equal("ac", rec.source)
        cast(S.AGONY)
        cast(S.CORRUPTION)
        assert.are.equal("apl", K.APL:Recommend().source)
    end)

    it("accepts a hidden Nightfall count only when every count agrees", function()
        hold(S.HAUNT)
        cast(S.AGONY)
        cast(S.CORRUPTION)
        Stub.acSpell = 686
        C_Secrets.ShouldSpellAuraBeSecret = function(id) return id == 264571 end
        Stub.overlays[S.SHADOW] = true
        -- Drain Soul wants two stacks; one would leave UA or the filler.
        Stub.shards = 1
        assert.are.equal("ac", K.APL:Recommend().source)
        -- With no shards both counts end on Drain Soul.
        Stub.shards = 0
        local rec = K.APL:Recommend()
        assert.are.equal("apl", rec.source)
        assert.are.equal(S.DRAIN, rec.spellID)
        Stub.overlays[S.SHADOW] = false
        assert.are.equal(0, A:Build(100).nightfall)
    end)

    it("routes Hellcaller by enemy count and holds tagged cooldowns", function()
        for _, id in ipairs({ 445465, 442726, 205180 }) do Stub.knownSpells[id] = true end
        Stub.knownSpells[449614] = false
        K.State.inCombat = false
        Stub.Fire("SPELLS_CHANGED")
        K.State.inCombat = true
        hold(S.HAUNT)
        cast(S.AGONY)
        cast(S.WITHER)
        assert.are.equal(S.MALEVOLENCE, K.APL:Recommend().spellID)
        K.Toggles:Set("cooldowns", false)
        local s = A:Build(100)
        assert.is_false(s.ready[S.MALEVOLENCE])
        assert.is_false(s.ready[S.DARKGLARE])
        assert.is_false(s.ready[S.HAUNT])
        assert.are.equal(S.DRAIN, K.APL:Recommend().spellID)
        Stub.now = 113 -- Agony and Wither under 5.4 s left are refreshable
        assert.are.equal(S.AGONY, K.APL:Recommend().spellID)
    end)

    it("uses the shared Soul Harvester lists before a hero tree is chosen", function()
        Stub.knownSpells[449614] = false
        K.State.inCombat = false
        Stub.Fire("SPELLS_CHANGED")
        K.State.inCombat = true
        local rec = K.APL:Recommend()
        assert.are.equal("apl", rec.source)
        assert.matches("SH_st:haunt", rec.label)
    end)

    it("summons the Imp out of combat, or sacrifices it when talented", function()
        K.State.inCombat = false
        UnitExists = function(unit) return unit ~= "pet" end
        local rec = K.APL:Recommend()
        assert.are.equal(688, rec.spellID)
        assert.are.equal("precombat:summon_pet", rec.label)
        Stub.knownSpells[108503] = true
        Stub.Fire("SPELLS_CHANGED")
        assert.are.equal(688, K.APL:Recommend().spellID)
        UnitExists = function() return true end
        assert.are.equal(108503, K.APL:Recommend().spellID)
        Stub.auras[196099] = { spellId = 196099 }
        assert.are.equal(S.HAUNT, K.APL:Recommend().spellID)
    end)

    it("counts only enemies in combat, so a dummy area stays single-target", function()
        for n = 1, 3 do Stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate" .. n) end
        UnitAffectingCombat = function() return false end
        assert.are.equal(1, A:Build(100).enemies)
        UnitAffectingCombat = function(unit) return unit ~= "nameplate3" end
        assert.are.equal(2, A:Build(100).enemies)
        UnitAffectingCombat = function(unit) return unit == "nameplate1" and Stub.Secret() or true end
        assert.is_true(A:Build(100).unknown.enemies)
    end)

    it("reads a secret Shard Instability from its glow on Unstable Affliction", function()
        hold(S.HAUNT)
        cast(S.AGONY)
        cast(S.CORRUPTION)
        C_Secrets.ShouldSpellAuraBeSecret = function(id) return id == 1260269 end
        assert.are.equal(S.DRAIN, K.APL:Recommend().spellID)
        Stub.overlays[S.UA] = true
        local rec = K.APL:Recommend()
        assert.are.equal(S.UA, rec.spellID)
        assert.are.equal("SH_st:unstable_affliction (2/2)", rec.label)
        -- Casting it spends one of an unknown number of stacks.
        UnitCastingInfo = function() return "UA", nil, nil, 100000, 101500, nil, nil, nil, S.UA end
        Stub.Fire("UNIT_SPELLCAST_START", "player")
        local s = A:Build(100)
        assert.are.equal(0, s.shards)
        assert.is_true(s.unknown.shardInstability)
    end)

    it("times Cascading Calamity from a UA that lands on a ticking UA", function()
        Stub.knownSpells[1261124] = true
        K.State.inCombat = false
        Stub.Fire("SPELLS_CHANGED")
        K.State.inCombat = true
        C_Secrets.ShouldSpellAuraBeSecret = function(id) return id == 1261125 end
        cast(S.UA)
        assert.are.equal(0, A:Build(100).calamityRemains)
        Stub.now = 104
        cast(S.UA)
        assert.are.equal(9, A:Build(110).calamityRemains)
        assert.is_nil(A:Build(110).unknown.calamityRemains)
        Stub.knownSpells[1260229] = true -- Fatal Echoes can grant it at random
        K.State.inCombat = false
        Stub.Fire("SPELLS_CHANGED")
        assert.is_true(A:Build(125).unknown.calamityRemains)
    end)
end)
