local Stub = require("tests.wow_stub")

describe("Destruction live module", function()
    local K, A, S
    local function cast(id) Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", id) end
    local function hold(id) A.cooldowns[id] = { finish = 400, base = A.COOLDOWNS[id] } end
    local function learn(ids, on)
        for _, id in ipairs(ids) do Stub.knownSpells[id] = on ~= false end
        K.State.inCombat = false
        Stub.Fire("SPELLS_CHANGED")
        K.State.inCombat = true
    end
    before_each(function()
        Stub.Install()
        Stub.specs[1] = 267
        Stub.fragments = 35
        UnitPower = function(_, power, unmodified)
            if power ~= 7 then return 0 end
            return unmodified and Stub.fragments or math.floor(Stub.fragments / 10)
        end
        -- Single target, no hero tree: Incinerate, Chaos Bolt, Conflagrate (Backdraft), Immolate.
        for _, id in ipairs({ 29722, 116858, 17962, 348, 196406, 688 }) do Stub.knownSpells[id] = true end
        Stub.charges[17962] = { currentCharges = 2, maxCharges = 2, cooldownStartTime = 0, cooldownDuration = 0 }
        -- In combat Backdraft is secret, so its stacks come from the cast model.
        C_Secrets.ShouldSpellAuraBeSecret = function(id) return id == 117828 end
        K = Stub.LoadAddon()
        A, S = K.DestructionState, K.DestructionAPL.SPELLS
        K.State.inCombat = true
    end)

    it("registers spec 267 and reads shards in tenths", function()
        assert.are.equal(A, K.APL:ModuleFor(267))
        assert.are.equal("WarlockDestruction", K:CurrentSpec().key)
        local s = A:Build(100)
        assert.are.equal(3.5, s.shards)
        assert.are.equal(2, s.chargesFractional[S.CONFLAGRATE])
        assert.is_false(s.known[S.WITHER])
    end)

    it("follows the single-target priorities from own casts", function()
        local rec = K.APL:Recommend()
        assert.are.equal(S.CONFLAGRATE, rec.spellID)
        assert.are.equal("default:conflagrate#1", rec.label)
        cast(S.CONFLAGRATE)
        assert.are.equal(1, A:Build(100).backdraft)
        assert.are.equal(S.IMMOLATE, K.APL:Recommend().spellID)
        cast(S.IMMOLATE)
        rec = K.APL:Recommend()
        assert.are.equal(S.INCINERATE, rec.spellID)
        assert.is_nil(rec.queuedID)
        cast(S.INCINERATE)
        assert.are.equal(0, A:Build(100).backdraft)
        -- Immolate under 30% (5.4 s) is refreshable again, after the recharged Conflagrate.
        Stub.now = 113
        assert.is_true(A:Build(113).immolateRefreshable)
        assert.are.equal(S.CONFLAGRATE, K.APL:Recommend().spellID)
        cast(S.CONFLAGRATE)
        assert.are.equal(S.IMMOLATE, K.APL:Recommend().spellID)
    end)

    it("recharges Conflagrate with haste from its last cast", function()
        cast(S.CONFLAGRATE)
        cast(S.CONFLAGRATE)
        assert.are.equal(0, A:Build(100).chargesFractional[S.CONFLAGRATE])
        -- 12.96 s at 20% haste is 10.8 s a charge.
        local function near(expected, actual) assert.is_true(math.abs(expected - actual) < 1e-9) end
        near(0.5, A:Build(105.4).chargesFractional[S.CONFLAGRATE])
        near(1.5, A:Build(116.2).chargesFractional[S.CONFLAGRATE])
        assert.are.equal(2, A:Build(130).chargesFractional[S.CONFLAGRATE])
    end)

    it("spends Chaos Bolt for Hellcaller at four shards and holds tagged cooldowns", function()
        learn({ 445465, 442726, 1122 })
        cast(S.CONFLAGRATE)
        cast(S.CONFLAGRATE)
        cast(S.WITHER)
        Stub.fragments = 45
        assert.are.equal(S.SUMMON_INFERNAL, K.APL:Recommend().spellID)
        K.Toggles:Set("cooldowns", false)
        local s = A:Build(100)
        assert.is_false(s.ready[S.SUMMON_INFERNAL])
        assert.is_false(s.ready[S.MALEVOLENCE])
        assert.is_false(s.known[S.IMMOLATE]) -- Wither replaces it
        local rec = K.APL:Recommend()
        assert.are.equal(S.CHAOS_BOLT, rec.spellID)
        assert.matches("default:chaos_bolt#2", rec.label)
        Stub.fragments = 25
        assert.are.equal(S.INCINERATE, K.APL:Recommend().spellID)
    end)

    it("projects a cast in progress into shards, Backdraft and DoTs", function()
        cast(S.CONFLAGRATE)
        UnitCastingInfo = function() return "Incinerate", nil, nil, 100000, 101500, nil, nil, nil, S.INCINERATE end
        Stub.Fire("UNIT_SPELLCAST_START", "player")
        local s = A:Build(100)
        assert.are.equal(101.5, s.t)
        assert.are.equal(3.7, s.shards)
        assert.are.equal(0, s.backdraft)
    end)

    it("uses Diabolist procs and needs target health for the ritual Chaos Bolt", function()
        learn({ 428514, 428518, 428522 })
        cast(S.CONFLAGRATE)
        cast(S.CONFLAGRATE)
        cast(S.IMMOLATE)
        Stub.auras[432815] = { spellId = 432815, expirationTime = 115 } -- Mother of Chaos ritual
        Stub.fragments = 15
        Stub.overrides[S.INCINERATE] = S.INFERNAL_BOLT
        assert.are.equal(S.INFERNAL_BOLT, K.APL:Recommend().spellID)
        Stub.overrides[S.INCINERATE] = nil
        Stub.overrides[S.CHAOS_BOLT] = S.RUINATION
        assert.are.equal(S.RUINATION, K.APL:Recommend().spellID)
        Stub.overrides[S.CHAOS_BOLT] = nil
        Stub.fragments = 25
        assert.matches("default:chaos_bolt#2", K.APL:Recommend().label)
        -- A Demonic Art makes the ritual Chaos Bolt read target health, which is secret.
        Stub.auras[432794] = { spellId = 432794 }
        assert.matches("default:chaos_bolt#1", K.APL:Recommend().label)
        Stub.acSpell = S.INCINERATE
        UnitHealth = function() return Stub.Secret() end
        assert.are.equal("ac", K.APL:Recommend().source)
    end)

    it("falls back to AC when a hidden target's DoTs can't be known", function()
        cast(S.CONFLAGRATE)
        cast(S.CONFLAGRATE)
        Stub.acSpell = S.INCINERATE
        UnitGUID = function() return Stub.Secret() end
        Stub.Fire("PLAYER_TARGET_CHANGED")
        assert.are.equal("ac", K.APL:Recommend().source)
        cast(S.IMMOLATE)
        assert.are.equal(S.INCINERATE, K.APL:Recommend().spellID)
    end)

    it("summons the Imp out of combat", function()
        K.State.inCombat = false
        UnitExists = function(unit) return unit ~= "pet" end
        assert.are.equal(688, K.APL:Recommend().spellID)
    end)

    it("counts only enemies in combat", function()
        for n = 1, 4 do Stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate" .. n) end
        UnitAffectingCombat = function() return false end
        assert.are.equal(1, A:Build(100).enemies)
        UnitAffectingCombat = function() return true end
        assert.are.equal(4, A:Build(100).enemies)
    end)
end)
