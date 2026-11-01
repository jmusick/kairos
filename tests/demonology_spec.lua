local Stub = require("tests.wow_stub")

describe("Demonology live module", function()
    local K, A, S
    local function fight() Stub.Fire("PLAYER_REGEN_DISABLED") end
    local function hold(id, untilTime) A.cooldowns[id] = { finish = untilTime or 160, base = A.COOLDOWNS[id] } end
    local function hiddenCore()
        C_Secrets.ShouldSpellAuraBeSecret = function(id) return id == 264173 end
        Stub.overlays[S.DEMONBOLT] = true
    end
    before_each(function()
        Stub.Install()
        Stub.specs[1] = 266
        Stub.shards = 2
        UnitPower = function(_, power)
            if power == 7 then return Stub.shards end
            return 0
        end
        for _, id in ipairs({ 686, 105174, 264178, 104316, 265187, 196277, 426115, 30146, 688, 428514 }) do
            Stub.knownSpells[id] = true
        end
        K = Stub.LoadAddon()
        A, S = K.DemonologyState, K.DemonologyAPL.SPELLS
    end)

    it("registers spec 266 independently of Arcane", function()
        assert.are.equal(A, K.APL:ModuleFor(266))
        assert.are.equal(K.ArcaneState, K.APL:ModuleFor(62))
        assert.are.equal("WarlockDemonology", K:CurrentSpec().key)
        assert.is_true(A:Build(100).talent.diabolic_ritual)
        assert.is_false(A:Build(100).known[S.RUINATION])
        assert.is_false(A:Build(100).known[S.IMP_LORD])
    end)

    it("uses Dreadstalkers without spending shards and gates unlearned spells", function()
        Stub.shards = 0
        assert.are.equal(S.DOGS, K.APL:Recommend().spellID)
        Stub.knownSpells[S.DOGS] = false
        Stub.Fire("SPELLS_CHANGED")
        assert.are.equal(S.SHADOW, K.APL:Recommend().spellID)
    end)

    it("uses the shared SimC leveling entry before hero talents unlock", function()
        Stub.knownSpells[428514] = false
        Stub.knownSpells[S.DOGS] = false
        Stub.knownSpells[S.TYRANT] = false
        Stub.shards = 3
        Stub.Fire("SPELLS_CHANGED")
        local rec = K.APL:Recommend()
        assert.are.equal("apl", rec.source)
        assert.are.equal(S.HAND, rec.spellID)
        assert.matches("soulharvest:hand_of_guldan", rec.label)
    end)

    it("aligns the Diabolist spender and Tyrant with the pinned priorities", function()
        hold(S.DOGS)
        Stub.shards = 5
        assert.are.equal(S.TYRANT, K.APL:Recommend().spellID)
        hold(S.TYRANT)
        Stub.shards = 3
        assert.are.equal(S.HAND, K.APL:Recommend().spellID)
        Stub.shards = 1
        assert.are.equal(S.SHADOW, K.APL:Recommend().spellID)
    end)

    it("applies Cooldowns off to major summons and leaves Dogs/Siphon rotational", function()
        for _, id in ipairs({ S.IMP_LORD, S.RAVAGER, S.DOOMGUARD, S.SIPHON }) do Stub.knownSpells[id] = true end
        Stub.Fire("SPELLS_CHANGED")
        K.Toggles:Set("cooldowns", false)
        local s = A:Build(100)
        assert.is_false(s.ready[S.TYRANT])
        assert.are.equal(60, s.remains[S.TYRANT])
        for _, id in ipairs({ S.IMP_LORD, S.RAVAGER, S.DOOMGUARD }) do
            assert.is_false(s.ready[id])
            assert.are.equal(120, s.remains[id])
        end
        assert.is_true(s.ready[S.DOGS])
        assert.is_true(s.ready[S.SIPHON])
        K.DemonologyDemons:Spawn(100, 3, 0)
        assert.are.equal(S.SIPHON, K.APL:Recommend().spellID)
    end)

    it("runs cooldown estimates during combat and reanchors when readable", function()
        fight()
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "dogs", S.DOGS)
        C_Spell.GetSpellCooldown = function(id)
            if id == 61304 then return { startTime = 0, duration = 0, modRate = 1 } end
            return Stub.Secret()
        end
        assert.are.equal(15, A:Build(105).remains[S.DOGS])
        assert.is_true(A:Build(120).ready[S.DOGS])
        K.State.inCombat = false
        C_Spell.GetSpellCooldown = function(id)
            if id == S.DOGS then return { startTime = 99, duration = 20, modRate = 1 } end
            return { startTime = 0, duration = 0, modRate = 1 }
        end
        A:Refresh(100)
        assert.are.equal(19, A:Build(100).remains[S.DOGS])
    end)

    it("keeps a just-cast Grimoire on cooldown when the client still reads it idle", function()
        Stub.knownSpells[S.IMP_LORD] = true
        Stub.shards = 3
        A:Refresh(99)
        assert.are.equal(S.IMP_LORD, K.APL:Recommend().spellID)
        -- 12.1.5: the cast replaces the spellbook entry (the in-combat probe resolves the
        -- name to 132411) and SPELLS_CHANGED refreshes before PLAYER_REGEN_DISABLED.
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "grimoire", S.IMP_LORD)
        Stub.overrides[S.IMP_LORD] = 132411
        Stub.Fire("SPELLS_CHANGED")
        fight()
        assert.is_false(A:Build(Stub.now).ready[S.IMP_LORD])
        assert.is_false(K.APL:Recommend().spellID == S.IMP_LORD)
        -- After combat, a lagging read still can't cancel it; a deferred cooldown that
        -- hasn't started (isEnabled false) counts as a full cooldown from now.
        K.State.inCombat = false
        A:Refresh(Stub.now + 3)
        assert.is_false(A:Build(Stub.now + 3).ready[S.IMP_LORD])
        Stub.overrides[S.IMP_LORD] = nil
        Stub.cooldowns[S.IMP_LORD] = { startTime = 0, duration = 0, isEnabled = false, modRate = 1 }
        A:Refresh(Stub.now + 130)
        assert.are.equal(120, A:Build(Stub.now + 130).remains[S.IMP_LORD])
        -- Once the client agrees it is idle, the cast no longer holds it.
        Stub.cooldowns[S.IMP_LORD] = nil
        A:Refresh(Stub.now + 131)
        assert.is_true(A:Build(Stub.now + 131).ready[S.IMP_LORD])
    end)

    it("requires the actual Diabolist replacement proc for Infernal Bolt and free Ruination", function()
        for _, id in ipairs({ 428518, 428522 }) do Stub.knownSpells[id] = true end
        Stub.Fire("SPELLS_CHANGED")
        hold(S.DOGS); hold(S.TYRANT)
        Stub.overrides[S.SHADOW] = S.INFERNAL
        assert.are.equal(S.INFERNAL, K.APL:Recommend().spellID)
        Stub.overrides[S.HAND] = S.RUINATION
        Stub.shards = 0
        assert.are.equal(S.RUINATION, K.APL:Recommend().spellID)
        Stub.overrides[S.HAND] = nil
        Stub.overrides[S.SHADOW] = nil
        assert.are.equal(S.SHADOW, K.APL:Recommend().spellID)
    end)

    it("uses Core presence for Demonbolt without inventing hidden stacks", function()
        hold(S.DOGS); hold(S.TYRANT)
        hiddenCore()
        local s = A:Build(100)
        assert.is_true(s.coreUp)
        assert.is_true(s.unknown.coreStacks)
        assert.are.equal(S.DEMONBOLT, K.APL:Recommend().spellID)
        assert.are.equal("apl", K.APL:Recommend().source)
    end)

    it("falls back when an unknown Core count changes the Power Siphon choice", function()
        Stub.knownSpells[S.SIPHON] = true
        Stub.Fire("SPELLS_CHANGED")
        hold(S.DOGS); hold(S.TYRANT)
        K.DemonologyDemons:Spawn(100, 3, 0)
        hiddenCore()
        Stub.acSpell = S.DEMONBOLT
        assert.are.equal("uncertain", K.APL:Recommend().reason)
        assert.is_nil(K.APL.lastError)
    end)

    it("accepts a Soul Harvester spell shared by all hidden Core counts", function()
        Stub.knownSpells[428514], Stub.knownSpells[449614] = false, true
        Stub.Fire("SPELLS_CHANGED")
        hold(S.DOGS); hold(S.TYRANT)
        hiddenCore()
        local rec = K.APL:Recommend()
        assert.are.equal("apl", rec.source)
        assert.are.equal(S.DEMONBOLT, rec.spellID)
        assert.matches("core stack independent", rec.label)
    end)

    it("prefers instant Demonbolt while moving and never shows a cast-time guess", function()
        hold(S.DOGS); hold(S.TYRANT)
        hiddenCore()
        GetUnitSpeed = function() return 7 end
        Stub.shards = 3
        assert.are.equal(S.DEMONBOLT, K.APL:Recommend().spellID)
        Stub.overlays[S.DEMONBOLT] = false
        Stub.acSpell = S.DEMONBOLT
        assert.are.equal("ac", K.APL:Recommend().source)
    end)

    it("counts hostile dummies even when their combat flag is false", function()
        for n = 1, 3 do Stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate" .. n) end
        hold(S.DOGS); hold(S.TYRANT)
        K.DemonologyDemons:Spawn(100, 6, 0)
        assert.are.equal(3, A:Build(100).enemies)
        assert.are.equal(S.IMPLOSION, K.APL:Recommend().spellID)
    end)

    it("holds Implosion for 15 seconds even when new imps are available", function()
        fight()
        for n = 1, 3 do Stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate" .. n) end
        hold(S.DOGS); hold(S.TYRANT)
        K.DemonologyDemons:Spawn(100, 6, 0)
        assert.are.equal(S.IMPLOSION, K.APL:Recommend().spellID)
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "implosion", S.IMPLOSION)
        Stub.now = 101
        K.DemonologyDemons:Spawn(101, 6, 0)
        local s = A:Build(101)
        assert.is_false(s.ready[S.IMPLOSION])
        assert.are.equal(14, s.remains[S.IMPLOSION])
        assert.is_false(K.APL:Recommend().spellID == S.IMPLOSION)
        -- Fresh imps near expiry keep the priority eligible; only readiness changes.
        Stub.now = 114.9
        K.DemonologyDemons:Spawn(114.9, 6, 0)
        assert.is_false(K.APL:Recommend().spellID == S.IMPLOSION)
        Stub.now = 115
        assert.are.equal(S.IMPLOSION, K.APL:Recommend().spellID)
        assert.is_nil(A.TAGS[S.IMPLOSION]) -- rotational; the CD toggle does not hold it
    end)

    it("reanchors Implosion's cooldown out of combat and evaluates at GCD end", function()
        for n = 1, 3 do Stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate" .. n) end
        Stub.cooldowns[S.IMPLOSION] = { startTime = 95, duration = 15, modRate = 1 }
        A:Refresh(100)
        fight()
        hold(S.DOGS); hold(S.TYRANT)
        K.DemonologyDemons:Spawn(100, 6, 0)
        assert.are.equal(10, A:Build(100).remains[S.IMPLOSION])
        assert.is_false(K.APL:Recommend().spellID == S.IMPLOSION)
        Stub.now = 109
        K.DemonologyDemons:Spawn(109, 6, 0)
        Stub.cooldowns[61304] = { startTime = 109, duration = 1, modRate = 1 }
        assert.are.equal(110, A:Build(109).t)
        assert.are.equal(S.IMPLOSION, K.APL:Recommend().spellID)
    end)

    it("predicts shards, imps and cooldowns at the cast/GCD boundary without mutating the model", function()
        fight()
        Stub.shards = 3
        K.State.cast = { spellID = S.HAND, endsAt = 102 }
        local s = A:Build(100)
        assert.are.equal(102, s.t)
        assert.are.equal(0, s.shards)
        assert.are.equal(3, s.imps)
        assert.are.equal(0, K.DemonologyDemons:Count(102))
        K.State.cast.spellID = S.DOGS
        s = A:Build(100)
        assert.are.equal(3, s.shards) -- free in 12.1.5
        assert.is_false(s.ready[S.DOGS])
        K.State.cast.spellID = S.INFERNAL
        assert.are.equal(5, A:Build(100).shards)
        K.State.cast = nil
        Stub.cooldowns[61304] = { startTime = 100, duration = 1.5, modRate = 1 }
        assert.are.equal(101.5, A:Build(100).t)
    end)

    it("queues the follow-up one lookahead step past the main pick", function()
        hold(S.TYRANT)
        Stub.shards = 3
        local rec = K.APL:Recommend()
        assert.are.equal(S.DOGS, rec.spellID)
        -- Free Dreadstalkers leave 3 shards, and Hand outranks any Core that could arrive.
        assert.are.equal(S.HAND, rec.queuedID)
        assert.matches("hand_of_guldan#2", rec.queuedLabel)
    end)

    it("hides the queued pick when a random Core or Diabolist art could change it", function()
        hold(S.DOGS); hold(S.TYRANT)
        Stub.shards = 1
        local rec = K.APL:Recommend()
        assert.are.equal("apl", rec.source)
        assert.are.equal(S.SHADOW, rec.spellID)
        assert.is_nil(rec.queuedID) -- a Core arriving mid-cast would make it Demonbolt
        -- Without Demoniac no Core can arrive, and a Diabolist proc needs a Hand first.
        Stub.knownSpells[426115] = false
        Stub.knownSpells[428518], Stub.knownSpells[428522] = true, true
        Stub.Fire("SPELLS_CHANGED")
        hold(S.DOGS); hold(S.TYRANT) -- the out-of-combat refresh reread them as idle
        assert.are.equal(S.SHADOW, K.APL:Recommend().queuedID)
        -- A Hand that just landed may still grant its Demonic Art's Infernal Bolt.
        A:OnCast(S.HAND, Stub.now)
        assert.are.equal(S.SHADOW, K.APL:Recommend().spellID)
        assert.is_nil(K.APL:Recommend().queuedID)
        Stub.now = Stub.now + A.ART_LAG
        assert.are.equal(S.SHADOW, K.APL:Recommend().queuedID)
        -- So may a Hand recommended now: Ruination could follow it.
        Stub.shards = 3
        local hand = K.APL:Recommend()
        assert.are.equal(S.HAND, hand.spellID)
        assert.is_nil(hand.queuedID)
    end)

    it("advances cooldowns, imp expiry and the main pick's own effects", function()
        fight()
        hold(S.DOGS, 101); hold(S.TYRANT)
        A.cooldowns[S.IMPLOSION] = { finish = 100, base = 15 }
        K.DemonologyDemons:Spawn(89, 3, 0)  -- runs out at 101
        K.DemonologyDemons:Spawn(100, 3, 0)
        local moving = K.State:Moving()
        local s = A:Build(100)
        assert.are.equal(6, s.imps)
        local q = A:Advance(s, S.IMPLOSION, moving)
        assert.are.equal(0, q.imps)
        assert.are.equal(15 - s.gcdMax, q.remains[S.IMPLOSION])
        assert.is_true(s.gcdMax >= 1 and q.ready[S.DOGS])
        assert.are.equal(6, s.imps) -- the evaluated state is untouched
        q = A:Advance(s, S.HAND, moving)
        assert.are.equal(100 + math.max(A:CastTime(S.HAND), s.gcdMax), q.t)
        assert.are.equal(6, q.imps) -- three expired, three summoned
        assert.are.equal(0, q.shards)
        assert.are.equal(S.HAND, q.prevGcd)
    end)

    it("counts free Ruination's imps only once they land", function()
        Stub.knownSpells[428522] = true
        Stub.Fire("SPELLS_CHANGED")
        fight()
        K.State.cast = { spellID = S.RUINATION, endsAt = 102 }
        assert.are.equal(0, A:Build(100).imps)
        Stub.cooldowns[61304] = { startTime = 101, duration = 1.5, modRate = 1 }
        assert.are.equal(3, A:Build(100).imps)
    end)

    it("times Dominion of Argus from Tyrant by its rank, without Hand refreshes", function()
        Stub.knownSpells[1276163] = true
        Stub.talentRanks[A.ARGUS.node] = 1
        Stub.Fire("SPELLS_CHANGED")
        fight()
        A:OnCast(S.TYRANT, 100)
        assert.is_true(A:Build(110).argusUp)
        A:OnCast(S.HAND, 110)
        A:OnCast(S.HAND, 114)
        local s = A:Build(116)
        assert.is_false(s.argusUp)
        assert.is_nil(s.unknown.argusUp)
    end)

    it("adds five seconds of Argus for each extra rank", function()
        Stub.knownSpells[1276163] = true
        for rank, duration in pairs({ [2] = 20, [3] = 25, [4] = 25 }) do
            Stub.talentRanks[A.ARGUS.node] = rank
            K.State.inCombat = false
            A:Refresh(100)
            fight()
            A:OnCast(S.TYRANT, 100)
            assert.is_true(A:Build(100 + duration - 0.1).argusUp)
            assert.is_false(A:Build(100 + duration + 0.1).argusUp)
        end
    end)

    it("prefers a readable Argus aura's duration and hides only the span an unknown rank decides", function()
        Stub.knownSpells[1276163] = true
        C_ClassTalents.GetActiveConfigID = function() return Stub.Secret() end
        A:Reset()
        Stub.Fire("SPELLS_CHANGED")
        fight()
        A:OnCast(S.TYRANT, 100)
        assert.is_true(A:Build(114).argusUp)
        assert.is_nil(A:Build(114).unknown.argusUp)
        assert.is_true(A:Build(120).unknown.argusUp)
        assert.is_false(A:Build(126).argusUp)
        assert.is_nil(A:Build(126).unknown.argusUp)
        Stub.auras[A.ARGUS.aura] = { spellId = A.ARGUS.aura, applications = 1, duration = 20 }
        K.State.inCombat = false
        A:Refresh(121)
        assert.is_true(A:Build(119.9).argusUp)
        assert.is_nil(A:Build(119.9).unknown.argusUp)
        assert.is_false(A:Build(120.1).argusUp)
    end)

    it("projects a fresh Tyrant's Argus into the queue state", function()
        Stub.knownSpells[1276163] = true
        Stub.talentRanks[A.ARGUS.node] = 2
        Stub.Fire("SPELLS_CHANGED")
        fight()
        local s = A:Build(100)
        assert.is_false(s.argusUp)
        local q = A:Advance(s, S.TYRANT, K.State:Moving())
        assert.is_true(q.argusUp)
        assert.is_nil(q.unknown.argusUp)
        assert.are.equal(100 + A:CastTime(S.TYRANT) + 20, q.argusUntil)
    end)

    it("survives secret resources, procs, cooldown fields and cached context", function()
        Stub.knownSpells[428518], Stub.knownSpells[428522] = true, true
        Stub.Fire("SPELLS_CHANGED")
        fight()
        UnitPower = function() return Stub.Secret() end
        C_Spell.GetOverrideSpell = function() return Stub.Secret() end
        C_SpellActivationOverlay.IsSpellOverlayed = function() return Stub.Secret() end
        C_Secrets.ShouldSpellAuraBeSecret = function() return true end
        UnitCanAttack = function() return Stub.Secret() end
        Stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        Stub.acSpell = S.SHADOW
        assert.has_no_error(function() assert.are.equal("uncertain", K.APL:Recommend().reason) end)
        assert.is_nil(K.APL.lastError)
        K.State.inCombat = false
        UnitSpellHaste = function() return Stub.Secret() end
        C_SpellBook.IsSpellKnown = function() return Stub.Secret() end
        C_Spell.GetSpellInfo = function() return { castTime = Stub.Secret() } end
        C_Spell.GetSpellCooldown = function() return { startTime = Stub.Secret(), duration = Stub.Secret() } end
        assert.has_no_error(function() A:Refresh(100) end)
        assert.is_true(A.cache.known[S.SHADOW].value)
    end)

    it("recommends a learned pet summon outside combat and records own picks", function()
        UnitExists = function(unit) return unit ~= "pet" end
        local rec = K.APL:Recommend()
        assert.are.equal(A.FELGUARD, rec.spellID)
        assert.are.equal("precombat:summon_pet", rec.label)
        K.Recorder:Clear()
        K.Recorder:NoteRecommendation(rec)
        assert.are.equal("kairos", K.Recorder:Entries()[1].src)
        assert.are.equal("precombat:summon_pet", K.Recorder:Entries()[1].label)
    end)

    it("stays inert on another spec and clears character-specific estimates on switching", function()
        A:OnCast(S.HAND, 100)
        Stub.specIndex = 2
        Stub.Fire("PLAYER_SPECIALIZATION_CHANGED", "player")
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "other", S.HAND)
        assert.are.equal(0, K.DemonologyDemons:Count(100))
        assert.is_nil(A.cache)
    end)

    it("records the spec's Soul Shards and skips secret power values", function()
        K.Recorder:Clear()
        fight()
        local recorded = K.Recorder:Entries()
        assert.are.equal(2, recorded[1].shards)
        Stub.shards = 3
        Stub.Fire("UNIT_POWER_UPDATE", "player", "SOUL_SHARDS")
        recorded = K.Recorder:Entries()
        assert.are.equal("shards", recorded[#recorded].k)
        assert.are.equal(3, recorded[#recorded].n)
        local n = #recorded
        UnitPower = function() return Stub.Secret() end
        Stub.Fire("UNIT_POWER_UPDATE", "player", "SOUL_SHARDS")
        Stub.Fire("UNIT_POWER_UPDATE", "player", Stub.Secret())
        assert.are.equal(n, #K.Recorder:Entries())
    end)

    it("captures its projected inputs for offline reproduction, and only while recording", function()
        fight()
        Stub.shards = 3
        K.State.cast = { spellID = S.HAND, endsAt = 102 }
        local rec = K.APL:Recommend()
        assert.are.equal(102, rec.diagnostic.projected.t)
        assert.are.equal(0, rec.diagnostic.projected.shards)
        assert.are.equal(S.HAND, rec.diagnostic.cast.spellID)
        K.Recorder:Clear()
        K.Recorder:NoteRecommendation(rec)
        K.Recorder:Commit("cast", S.HAND)
        local saved = K.Recorder:Entries()[2].recommendation.diagnostic
        assert.are.equal(3, saved.projected.imps)
        local again = A:Pick(saved.projected)
        assert.are.equal(rec.spellID, again.spellID)
        K.db.global.recorder = false
        assert.is_nil(K.APL:Recommend().diagnostic)
    end)
end)

describe("Demonology Wild Imp estimate", function()
    local K, D
    before_each(function()
        Stub.Install()
        K = Stub.LoadAddon()
        D = K.DemonologyDemons
    end)
    it("models Hand, delayed free Ruination, Siphon, Implosion and expiry with explicit times", function()
        D:OnCast(105174, 100, 0)
        D:OnCast(434635, 101, 0)
        assert.are.equal(3, D:Count(101))
        assert.are.equal(6, D:Count(101.5))
        D:OnCast(264130, 102, 0)
        assert.are.equal(4, D:Count(102))
        assert.are.equal(4, D:Count(111.5))
        assert.are.equal(3, D:Count(112))
        assert.are.equal(0, D:Count(113.5))
        D:OnCast(105174, 120, 0)
        D:OnCast(196277, 121, 0)
        assert.are.equal(0, D:Count(121))
        D:OnCast(105174, 130, 0)
        D:OnCast(196277, 131, 0, true) -- To Hell and Back
        assert.are.equal(3, D:Count(131))
        assert.are.equal(0, D:Count(143))
    end)
    it("pauses imp lifetimes out of combat, keeping whole casts and re-engaging", function()
        D:OnCast(105174, 100, 0) -- 6 Firebolts, one every 2 s
        D:SetCombat(false, 105)  -- 2 casts done; the third was in progress
        assert.are.equal(3, D:Count(130)) -- idle imps keep their energy between pulls
        D:SetCombat(true, 130)
        -- 4 casts left (8 s), after 3 s to find a target.
        assert.are.equal(3, D:Count(140.9))
        assert.are.equal(0, D:Count(141))
    end)
    it("pauses imp lifetimes in combat without a live hostile target", function()
        D:SetCombat(true, 99)
        D:OnCast(105174, 100, 0)
        D:SetTarget(false, 103)  -- 1 cast done; the second was in progress
        D:SetCombat(false, 110)
        D:SetCombat(true, 120)   -- back in combat, still nothing to hit
        assert.are.equal(3, D:Count(140))
        D:SetTarget(true, 140)
        -- 5 casts left (10 s), after 3 s to re-engage.
        assert.are.equal(3, D:Count(152.9))
        assert.are.equal(0, D:Count(153))
    end)
    it("anchors to a readable imp count, adding missed imps and dropping extras", function()
        D:OnCast(105174, 100, 0)
        D:Anchor(101, 5, 0)
        assert.are.equal(5, D:Count(101))
        D:Anchor(102, 1, 0)
        assert.are.equal(1, D:Count(102))
        assert.are.equal(0, D:Count(113.1)) -- the anchored imp is fresh at 101, gone 12 s later
    end)
    it("reads Implosion's cast count as the imp count only where it isn't secret", function()
        Stub.specs[1] = 266
        Stub.knownSpells[196277] = true
        K = Stub.LoadAddon()
        D = K.DemonologyDemons
        Stub.castCounts[196277] = 7
        assert.are.equal(7, K.DemonologyState:Build(Stub.now).imps)
        Stub.castCounts[196277] = Stub.Secret()
        D:OnCast(196277, Stub.now, 0)
        assert.are.equal(0, K.DemonologyState:Build(Stub.now).imps)
    end)
    it("follows the player's combat state from the adapter", function()
        Stub.specs[1] = 266
        K = Stub.LoadAddon()
        D = K.DemonologyDemons
        Stub.Fire("PLAYER_REGEN_DISABLED")
        D:OnCast(105174, 100, 0)
        Stub.now = 105
        Stub.Fire("PLAYER_REGEN_ENABLED")
        assert.are.equal(3, D:Count(200))
    end)
    it("follows the player's target from the adapter", function()
        Stub.specs[1] = 266
        K = Stub.LoadAddon()
        D = K.DemonologyDemons
        Stub.Fire("PLAYER_REGEN_DISABLED")
        D:OnCast(105174, 100, 0)
        Stub.now = 105
        UnitIsDeadOrGhost = function() return true end
        Stub.Fire("UNIT_HEALTH", "target")
        assert.are.equal(3, D:Count(200))
    end)
    it("scales the six Firebolt lifetime estimate by haste and does not invent extra summons", function()
        D:Spawn(100, 3, 100)
        assert.are.equal("estimated", D:Read(104).state)
        assert.are.equal(3, D:Read(104).value)
        D:OnCast(265187, 104, 0)
        assert.are.equal(0, D:Count(106))
    end)
end)
