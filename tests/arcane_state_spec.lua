local Stub = require("tests.wow_stub")

describe("Arcane live state", function()
    local K, A, S
    local function refresh()
        A.refreshedAt = nil
        A:Refresh(Stub.now)
    end
    local function fight()
        Stub.Fire("PLAYER_REGEN_DISABLED")
        -- Assert the adapter never needs the secret client cooldown in combat.
        C_Spell.GetSpellCooldown = function(id)
            if id == 61304 then return { startTime = 0, duration = 0 } end
            return Stub.Secret()
        end
    end
    before_each(function()
        Stub.Install()
        Stub.spellNames[448601] = "Spellfire Spheres"
        Stub.spellNames[443739] = "Splintering Sorcery"
        for _, id in ipairs({ 5143, 30451, 44425, 153626, 365350, 321507, 448601 }) do
            Stub.knownSpells[id] = true
        end
        Stub.charges[153626] = { currentCharges = 2, maxCharges = 2, cooldownStartTime = 0,
            cooldownDuration = 20, chargeModRate = 1 }
        K = Stub.LoadAddon()
        A, S = K.ArcaneState, K.ArcaneAPL.SPELLS
    end)

    it("builds every contract field from readable inputs and caches static context", function()
        UnitPower = function(_, power) assert.are.equal(16, power); return 4 end
        Stub.overlays[S.MISSILES], Stub.overlays[S.BOLT] = true, true
        Stub.knownSpells[A.SET_BONUS] = true
        Stub.auras["Lustrous Gleam"] = { applications = 2 }
        UnitSpellHaste = function() return 25 end
        refresh()
        K.ArcaneSalvo:OnTruth(14)
        K.ArcaneCumulativePower:OnTruth(8, Stub.now)
        K.State:RecordCast(S.BARRAGE, Stub.now)
        fight()
        UnitSpellHaste = function() error("must use cached haste") end
        local s = A:Build(Stub.now)
        assert.are.equal(4, s.charges)
        assert.are.equal(1, s.clearcasting)
        assert.is_true(s.boltReady)
        assert.are.equal(14, s.salvo)
        assert.are.equal(8, s.cumulativePower)
        assert.are.equal(2, s.lustrousGleam)
        assert.is_true(s.setS2_4pc)
        assert.is_false(s.soul)
        assert.is_false(s.surgeUp)
        assert.are.equal(0, s.surgeRemains)
        assert.are.equal(1.2, s.gcdMax)
        assert.are.equal(S.BARRAGE, s.prevGcd)
        assert.is_true(s.talent.spellfire_spheres)
        assert.is_false(s.talent.splintering_sorcery)
        assert.is_true(s.known[S.BOLT]) -- cached from Blast even before the proc
        assert.is_false(s.known[S.PULSE])
        assert.is_true(s.ready[S.SURGE])
        assert.are.equal(0, s.remains[S.TOUCH])
        assert.are.equal(2, s.chargesFractional[S.ORB])
    end)

    it("uses zero for dark glows and never infers Clearcasting stacks", function()
        local s = A:Build(100)
        assert.are.equal(0, s.clearcasting)
        assert.is_false(s.boltReady)
    end)

    it("times Surge, Soul and cooldowns from successful casts", function()
        fight()
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "surge", S.SURGE)
        Stub.now = 102
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "touch", S.TOUCH)
        local s = A:Build(110)
        assert.are.equal(80, s.remains[S.SURGE])
        assert.are.equal(37, s.remains[S.TOUCH])
        assert.is_false(s.ready[S.SURGE])
        assert.is_true(s.surgeUp)
        assert.is_true(math.abs(s.surgeRemains - 7.4) < 0.00001)
        assert.are.equal(S.SURGE, s.prevGcd) -- off-GCD Touch did not replace it
        s = A:Build(118)
        assert.is_true(s.soul)
        assert.is_false(s.surgeUp)
        assert.is_true(A:Build(192).ready[S.SURGE])
    end)

    it("selects Missiles after Surge below 12 Salvo, and Barrage into Touch with carried stacks", function()
        UnitPower = function() return 0 end
        Stub.overlays[S.MISSILES] = true
        fight()
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "surge", S.SURGE)
        for _, stacks in ipairs({ 0, 11, 12, 25 }) do
            K.ArcaneSalvo:OnTruth(stacks)
            local rec = A:Evaluate()
            assert.is_false(rec.uncertain or false)
            assert.are.equal(stacks < 12 and S.MISSILES or S.BARRAGE, rec.spellID)
            assert.are.equal(stacks >= 12 and S.TOUCH or nil, rec.pairedID)
        end
        -- Salvo persists between pulls; Surge must not reset a readable 25 to zero.
        assert.are.equal(25, A:Build(Stub.now).salvo)
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "barrage", S.BARRAGE)
        local rec = A:Evaluate()
        assert.are.equal(S.TOUCH, rec.spellID)
        assert.is_true(rec.immediate)
        assert.is_nil(rec.pairedID)
    end)

    it("withholds the Barrage pairing when Touch is spent, held, unknown or outside its window", function()
        UnitPower = function() return 4 end
        Stub.overlays[S.MISSILES] = true
        K.ArcaneSalvo:OnTruth(25)
        fight()
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "surge", S.SURGE)
        local rec = K.APL:Recommend()
        assert.are.equal(S.BARRAGE, rec.spellID)
        assert.are.equal(S.TOUCH, rec.pairedID)
        assert.matches("touch_of_the_magi", rec.pairedLabel)
        A:OnCast(S.TOUCH, Stub.now)
        assert.is_nil(K.APL:Recommend().pairedID)
        A.cooldowns[S.TOUCH] = { finish = Stub.now }
        K.Toggles:Set("cooldowns", false)
        assert.is_nil(K.APL:Recommend().pairedID)
        K.Toggles:Set("cooldowns", true)
        A.cooldowns[S.TOUCH] = nil
        assert.is_nil(K.APL:Recommend().pairedID)
        A.cooldowns[S.TOUCH] = { finish = Stub.now }
        A.surgeAt = nil
        A.cooldowns[S.SURGE] = { finish = Stub.now + 20 }
        assert.is_nil(K.APL:Recommend().pairedID)
    end)

    it("models sequential Orb recharge and spending during a recharge", function()
        fight()
        A:OnCast(S.ORB, 100)
        assert.is_true(A:Build(101).ready[S.ORB])
        assert.are.equal(0, A:Build(101).remains[S.ORB])
        A:OnCast(S.ORB, 105)
        assert.are.equal(0.5, A:Build(110).chargesFractional[S.ORB])
        assert.is_false(A:Build(110).ready[S.ORB])
        assert.are.equal(10, A:Build(110).remains[S.ORB])
        assert.are.equal(1.5, A:Build(130).chargesFractional[S.ORB])
        A:OnCast(S.ORB, 130)
        assert.are.equal(0.75, A:Build(135).chargesFractional[S.ORB])
        assert.are.equal(2, A:Build(200).chargesFractional[S.ORB])
    end)

    it("advances past a successful Orb while its charges are still arriving", function()
        fight()
        UnitPower = function() return 1 end
        A.cooldowns[S.SURGE] = { finish = 190 }
        K.ArcaneSalvo:OnTruth(0)
        assert.are.equal(S.ORB, K.APL:Recommend().spellID)
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "orb", S.ORB)
        local s = A:Build(100)
        assert.is_true(s.orbInFlight)
        assert.are.equal(1, s.charges)
        assert.is_true(s.known[S.ORB])
        assert.is_true(s.ready[S.ORB])
        assert.are.equal(1, s.chargesFractional[S.ORB]) -- second charge is real, just not needed yet
        assert.are.equal(S.BLAST, K.APL:Recommend().spellID)
        -- A projected GCD end beyond the guard must not make Orb stick now.
        C_Spell.GetSpellCooldown = function(id)
            if id == 61304 then return { startTime = 100, duration = 2 } end
            return Stub.Secret()
        end
        assert.are.equal(S.BLAST, K.APL:Recommend().spellID)
        Stub.now = 101.499
        assert.are.equal(S.BLAST, K.APL:Recommend().spellID)
        C_Spell.GetSpellCooldown = function(id)
            if id == 61304 then return { startTime = 0, duration = 0 } end
            return Stub.Secret()
        end
        Stub.now = 101.5 -- no hits: guard expires so a missed Orb cannot block forever
        assert.are.equal(S.ORB, K.APL:Recommend().spellID)
    end)

    it("allows higher priority picks during Orb flight and a second Orb after Barrage", function()
        fight()
        UnitPower = function() return 1 end
        A.cooldowns[S.SURGE] = { finish = 190 }
        A.cooldowns[S.TOUCH] = { finish = 145 }
        K.ArcaneSalvo:OnTruth(0)
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "orb", S.ORB)
        Stub.overlays[S.MISSILES] = true
        assert.are.equal(S.MISSILES, K.APL:Recommend().spellID)
        Stub.overlays[S.MISSILES] = false
        Stub.now = 100.5
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "barrage", S.BARRAGE)
        assert.is_false(A:Build(100.5).orbInFlight)
        assert.are.equal(S.ORB, K.APL:Recommend().spellID)
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "orb2", S.ORB)
        UnitPower = function() return Stub.Secret() end
        assert.has_no_error(function() K.APL:Recommend() end)
        assert.are.equal("uncertain", K.APL:Recommend().reason)
        A:Reset()
        assert.is_false(A:Build(100.5).orbInFlight)
    end)

    it("corrects cooldown and fractional charge anchors out of combat", function()
        Stub.cooldowns[S.SURGE] = { startTime = 90, duration = 90, modRate = 2 }
        Stub.cooldowns[S.TOUCH] = { startTime = 95, duration = 45, modRate = 1 }
        Stub.charges[S.ORB] = { currentCharges = 1, maxCharges = 2, cooldownStartTime = 95,
            cooldownDuration = 20, chargeModRate = 1 }
        refresh()
        fight()
        local s = A:Build(105)
        assert.are.equal(30, s.remains[S.SURGE])
        assert.are.equal(35, s.remains[S.TOUCH])
        assert.are.equal(1.5, s.chargesFractional[S.ORB])
    end)

    it("holds ready Surge until a delayed Touch is ready without falsifying its cooldown", function()
        fight()
        Stub.overlays[S.MISSILES] = true
        K.ArcaneSalvo:OnTruth(0)
        A:OnCast(S.TOUCH, 65) -- ten seconds remain at t=100
        for _, t in ipairs({ 100, 109.999, 110 }) do
            Stub.now = t
            local state, rec = A:Build(t), K.APL:Recommend()
            assert.is_true(state.ready[S.SURGE])
            assert.are.equal(0, state.remains[S.SURGE])
            assert.are.equal(t < 110 and S.MISSILES or S.SURGE, rec.spellID)
            assert.are.equal("apl", rec.source)
        end
        A.cooldowns[S.TOUCH] = nil
        Stub.acSpell = S.BLAST
        local rec = K.APL:Recommend()
        assert.are.equal("uncertain", rec.reason)
        assert.matches("ready:" .. S.TOUCH, rec.unknownFields)
        assert.is_nil(K.APL.lastError)
    end)

    it("checks Surge/Touch alignment at the end of the current cast", function()
        fight()
        K.ArcaneSalvo:OnTruth(0)
        Stub.overlays[S.MISSILES] = true
        A:OnCast(S.TOUCH, 57) -- ready at t=102
        K.State.cast = { spellID = S.BLAST, endsAt = 101.999 }
        assert.are.equal(S.MISSILES, K.APL:Recommend().spellID)
        K.State.cast.endsAt = 102
        assert.are.equal(S.SURGE, K.APL:Recommend().spellID)
    end)

    it("holds exactly the metadata cooldown tags as just used (D15, D25)", function()
        K.Toggles:Set("cooldowns", false)
        local s = A:Build(100)
        assert.is_false(s.ready[S.SURGE])
        assert.is_false(s.ready[S.TOUCH])
        assert.are.equal(90, s.remains[S.SURGE])
        assert.are.equal(45, s.remains[S.TOUCH])
        assert.are.equal(2, s.chargesFractional[S.ORB])
        assert.is_nil(A.TAGS[12051])
        local file = assert(io.open("translator/metadata/mage_arcane.json"))
        local metadata = file:read("*a")
        file:close()
        for _, name in ipairs({ "arcane_surge", "touch_of_the_magi" }) do
            assert.matches('"' .. name .. '"[^\n]+"toggle": "cooldowns"', metadata)
        end
    end)

    it("counts hostile nameplates even when dummies report no combat", function()
        UnitCanAttack = function(_, unit) return unit ~= "nameplate3" end
        for i = 1, 3 do Stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate" .. i) end
        assert.are.equal(2, A:Build(100).enemies)
        UnitCanAttack = function() return Stub.Secret() end
        assert.is_true(A:Build(100).unknown.enemies)
    end)

    it("advances to the later of cast and GCD end and applies Blast's effects once", function()
        fight()
        C_Spell.GetSpellCooldown = function(id)
            if id == 61304 then return { startTime = 100, duration = 1.5 } end
        end
        UnitPower = function() return 2 end
        K.ArcaneSalvo:OnTruth(10)
        K.ArcaneCumulativePower:OnTruth(8, 100)
        K.State.cast = { spellID = S.BLAST, endsAt = 102, channel = false }
        local s = A:Build(100)
        assert.are.equal(102, s.t)
        assert.are.equal(3, s.charges)
        assert.are.equal(12, s.salvo)
        assert.are.equal(0, s.cumulativePower)
        assert.are.equal(S.BLAST, s.prevGcd)
        assert.are.equal(10, K.ArcaneSalvo:Read(100).value)
        assert.are.equal(8, K.ArcaneCumulativePower:Read(100).value)
        assert.are.equal(12, A:Build(100).salvo)
        K.State.cast.endsAt = 101
        assert.are.equal(101.5, A:Build(100).t)
    end)

    it("projects Bolt's four charges and consumption, and Surge's buff", function()
        fight()
        UnitPower = function() return 0 end
        Stub.overlays[S.BOLT] = true
        K.State.cast = { spellID = S.BOLT, endsAt = 102 }
        local s = A:Build(100)
        assert.are.equal(4, s.charges)
        assert.is_false(s.boltReady)
        K.State.cast.spellID = S.SURGE
        s = A:Build(100)
        assert.is_true(s.surgeUp)
        assert.are.equal(17.4, s.surgeRemains)
        assert.is_false(s.ready[S.SURGE])
    end)

    it("visibly advances during a Bolt cast while its proc is lit, and restores on interruption", function()
        fight()
        A.cooldowns[S.SURGE] = { finish = 190 }
        A.cooldowns[S.TOUCH] = { finish = 145 }
        UnitPower = function() return 0 end
        Stub.overlays[S.BOLT] = true
        K.ArcaneSalvo:OnTruth(0)
        K.ArcaneCumulativePower:OnTruth(8, 100)
        C_Spell.GetSpellTexture = function(id)
            if id == S.BLAST then return S.BOLT, S.BLAST end
            return id, id
        end
        K.Display:Refresh()
        assert.are.equal(S.BOLT, K.Display.frame.main.icon.texture)
        UnitCastingInfo = function() return "Bolt", nil, nil, 100000, 102000, nil, nil, nil, S.BOLT end
        Stub.Fire("UNIT_SPELLCAST_START", "player", "bolt", S.BOLT)
        assert.is_true(Stub.overlays[S.BOLT]) -- proc remains observed until cast completion
        assert.are.equal(S.BLAST, K.Display.current.spellID)
        assert.are.equal(S.BLAST, K.Display.frame.main.icon.texture)
        local state = A:Build(100)
        assert.is_false(state.boltReady)
        assert.are.equal(4, state.charges)
        assert.are.equal(0, state.cumulativePower)
        assert.are.equal(8, K.ArcaneCumulativePower:Read(100).value)
        UnitCastingInfo = function() return nil end
        Stub.Fire("UNIT_SPELLCAST_INTERRUPTED", "player", "bolt", S.BOLT)
        assert.are.equal(S.BOLT, K.Display.frame.main.icon.texture)
        UnitCastingInfo = function() return "Bolt", nil, nil, 100000, Stub.Secret(), nil, nil, nil, S.BOLT end
        assert.has_no_error(function() Stub.Fire("UNIT_SPELLCAST_START", "player", "bolt", S.BOLT) end)
        assert.are.equal("uncertain", K.Display.current.reason)
    end)

    it("reads active channels at their projected end without advancing the live models", function()
        fight()
        K.ArcaneSalvo:OnTruth(0)
        K.ArcaneCumulativePower:OnTruth(0, 100)
        K.ArcaneSalvo:OnChannelStart(S.MISSILES, 100, 102)
        K.ArcaneCumulativePower:OnChannelStart(S.MISSILES, 100, 102)
        K.State.cast = { spellID = S.MISSILES, endsAt = 102, channel = true }
        local s = A:Build(100)
        assert.are.equal(11, s.salvo)
        assert.are.equal(8, s.cumulativePower)
        assert.are.equal(0, K.ArcaneSalvo:Read(100).value)
    end)

    it("keeps secrets out of numeric and boolean fields and preserves good caches", function()
        fight()
        UnitPower = function() return Stub.Secret() end
        C_SpellActivationOverlay.IsSpellOverlayed = function() return Stub.Secret() end
        local s
        assert.has_no_error(function() s = A:Build(100) end)
        assert.is_true(s.unknown.charges)
        assert.is_true(s.unknown.clearcasting)
        assert.is_true(s.unknown.boltReady)
        K.State.inCombat = false
        UnitSpellHaste = function() return Stub.Secret() end
        C_SpellBook.IsSpellKnown = function() return Stub.Secret() end
        C_UnitAuras.GetAuraDataBySpellName = function() return Stub.Secret() end
        C_UnitAuras.GetPlayerAuraBySpellID = function() return Stub.Secret() end
        C_Spell.GetSpellCharges = function() return { currentCharges = Stub.Secret() } end
        assert.has_no_error(function() refresh() end)
        assert.is_true(A.static.known[S.BLAST].value)
        assert.are.equal(1.25, A.static.gcdMax.value)
    end)

    it("falls back when an earlier priority or selected line reads an unknown", function()
        Stub.acSpell = S.BARRAGE
        fight()
        C_SpellActivationOverlay.IsSpellOverlayed = function() return Stub.Secret() end
        A.cooldowns[S.SURGE] = { finish = 190 }
        local rec = K.APL:Recommend()
        assert.are.equal("ac", rec.source)
        assert.are.equal("uncertain", rec.reason)
        assert.is_nil(K.APL.lastError)
    end)

    it("does not fall back for an unknown field the priority path never reads", function()
        fight()
        UnitPower = function() return Stub.Secret() end
        C_SpellActivationOverlay.IsSpellOverlayed = function() return Stub.Secret() end
        local rec = K.APL:Recommend() -- ready Surge does not read the proc or charge fields
        assert.are.equal("apl", rec.source)
        assert.are.equal(S.SURGE, rec.spellID)
        assert.matches("cooldowns:arcane_surge", rec.label)
    end)

    it("accepts estimated stacks for the pick", function()
        fight()
        A.cooldowns[S.SURGE] = { finish = 190 }
        Stub.overlays[S.MISSILES] = true
        K.ArcaneSalvo:OnTruth(0)
        K.ArcaneSalvo:OnCast(S.BLAST, 100)
        assert.are.equal("estimated", K.ArcaneSalvo:Read(100).state)
        local rec = K.APL:Recommend()
        assert.are.equal("apl", rec.source)
        assert.are.equal(S.MISSILES, rec.spellID)
    end)

    it("keeps the unsupported hero tree and unknown timing on AC", function()
        Stub.acSpell = S.BLAST
        Stub.knownSpells[443739] = true
        refresh()
        assert.are.equal("uncertain", K.APL:Recommend().reason)
        Stub.knownSpells[443739] = false
        refresh()
        UnitCastingInfo = function() return nil, nil, nil, nil, Stub.Secret(), nil, nil, nil, S.BLAST end
        Stub.Fire("UNIT_SPELLCAST_START", "player")
        assert.are.equal("uncertain", K.APL:Recommend().reason)
    end)

    it("uses movement events to prefer instants while speed is secret", function()
        Stub.acSpell = S.BARRAGE
        GetUnitSpeed = function() return Stub.Secret() end
        Stub.Fire("PLAYER_STARTED_MOVING")
        assert.are.equal(S.BARRAGE, K.APL:Recommend().spellID)
        Stub.Fire("PLAYER_STOPPED_MOVING")
        assert.are.equal("apl", K.APL:Recommend().source)
    end)

    it("seeds stationary movement at login before speed becomes secret", function()
        GetUnitSpeed = function() return Stub.Secret() end
        fight()
        assert.are.equal("apl", K.APL:Recommend().source)
        assert.is_false(K.State:Moving().value)
    end)

    it("routes around stationary spells to Barrage or Orb while moving", function()
        UnitPower = function() return 4 end
        K.ArcaneSalvo:OnTruth(25)
        Stub.Fire("PLAYER_STARTED_MOVING")
        GetUnitSpeed = function() return Stub.Secret() end
        local rec = K.APL:Recommend()
        assert.are.equal("apl", rec.source)
        assert.are.equal(S.BARRAGE, rec.spellID)
        UnitPower = function() return 0 end
        K.ArcaneSalvo:OnTruth(0)
        assert.are.equal(S.ORB, K.APL:Recommend().spellID)
    end)

    it("allows Clearcasting Missiles during movement when Slipstream is learned", function()
        Stub.knownSpells[236457] = true
        refresh()
        Stub.overlays[S.MISSILES] = true
        K.ArcaneSalvo:OnTruth(0)
        GetUnitSpeed = function() return 7 end
        assert.are.equal(S.MISSILES, K.APL:Recommend().spellID)
    end)

    it("registers only spec 62 and promotes ready Touch with the on-GCD pick queued", function()
        assert.are.equal(A, K.APL:ModuleFor(62))
        assert.is_nil(K.APL:ModuleFor(63))
        A.surgeAt = 90
        K.State:RecordCast(S.BARRAGE, 99)
        fight()
        local touch = A:OffGcd()
        assert.are.equal(S.TOUCH, touch.spellID)
        assert.is_false(touch.uncertain)
        local rec = A:Evaluate()
        assert.are.equal(S.TOUCH, rec.spellID)
        assert.is_true(rec.immediate)
        assert.are.equal(S.SURGE, rec.queuedID)
        Stub.specIndex = 2
        Stub.Fire("PLAYER_SPECIALIZATION_CHANGED", "player")
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "other", S.SURGE)
        assert.is_nil(A.surgeAt)
    end)

    it("records own picks and labels, including label changes on the same spell", function()
        local rec = { source = "apl", spellID = S.BARRAGE, line = "line", label = "clause 1" }
        K.Recorder:Clear()
        K.Recorder:NoteRecommendation(rec)
        K.Recorder:NoteRecommendation(rec)
        K.Recorder:NoteRecommendation({ source = "apl", spellID = S.BARRAGE, label = "clause 2" })
        local entries = K.Recorder:Entries()
        assert.are.equal(2, #entries)
        assert.are.equal("kairos", entries[1].src)
        assert.are.equal("clause 1", entries[1].label)
        assert.are.equal("clause 2", entries[2].label)
    end)

    it("keeps AC observations while the main pick and label stay unchanged", function()
        K.Recorder:Clear()
        local rec = { source = "apl", spellID = S.SURGE, label = "surge" }
        Stub.acSpell = S.TOUCH
        K.Recorder:NoteRecommendation(rec)
        Stub.acSpell = S.BLAST
        K.Recorder:NoteRecommendation(rec)
        Stub.acSpell = Stub.Secret()
        assert.has_no_error(function() K.Recorder:NoteRecommendation(rec) end)
        local entries = K.Recorder:Entries()
        assert.are.equal(4, #entries)
        assert.are.equal("ac", entries[1].src)
        assert.is_true(entries[1].observed)
        assert.are.equal("kairos", entries[2].src)
        assert.are.equal(S.BLAST, entries[3].spell)
        assert.is_nil(entries[4].spell)
    end)

    it("never treats a hidden aura nil as absent at an out-of-combat restriction", function()
        Stub.auras["Lustrous Gleam"] = { applications = 2 }
        refresh()
        Stub.auras["Lustrous Gleam"] = nil
        C_Secrets.ShouldAurasBeSecret = function() return true end
        refresh()
        assert.are.equal(2, A:Build(100).lustrousGleam)
        C_Secrets.ShouldAurasBeSecret = function() return false end
        C_Secrets.ShouldSpellAuraBeSecret = function() return true end
        refresh()
        assert.are.equal(2, A:Build(100).lustrousGleam)
        A.static.lustrousGleam = nil
        refresh()
        assert.is_true(A:Build(100).unknown.lustrousGleam)
    end)

    it("tracks unknown Orb/Pulse cooldowns and cache misses instead of making them ready", function()
        Stub.knownSpells[S.PULSE] = true
        refresh()
        A.orb = nil
        A.cooldowns[S.PULSE] = nil
        fight()
        local s = A:Build(100)
        assert.is_true(s.unknown["chargesFractional:" .. S.ORB])
        assert.is_true(s.unknown["chargesFractional:" .. S.PULSE])
        A:Reset()
        assert.is_true(A:Build(100).talent.unknown.spellfire_spheres)
        assert.is_true(A:Evaluate().uncertain)
    end)

    it("uses the Mage Pulse ID and models its 15-second single-charge cooldown", function()
        assert.are.equal(1241462, S.PULSE)
        Stub.knownSpells[S.PULSE] = true
        refresh()
        fight()
        assert.are.equal(1, A:Build(100).chargesFractional[S.PULSE])
        A:OnCast(S.PULSE, 100)
        local s = A:Build(105)
        assert.are.equal(10, s.remains[S.PULSE])
        assert.is_false(s.ready[S.PULSE])
        assert.is_true(math.abs(s.chargesFractional[S.PULSE] - 1/3) < 0.00001)
        assert.is_true(s.unknown.salvo)
        A:OnCast(S.BARRAGE, 106)
        assert.is_nil(A:Build(106).unknown.salvo)
        assert.is_true(A:Build(115).ready[S.PULSE])
    end)

    it("detects the four-piece from equipment even when the passive isn't in the spellbook", function()
        assert.is_false(Stub.knownSpells[A.SET_BONUS] or false)
        for _, slot in ipairs({ 1, 3, 5, 7 }) do
            Stub.inventory[slot], Stub.itemSets[slot] = slot, A.SET_ID
        end
        Stub.Fire("PLAYER_EQUIPMENT_CHANGED")
        assert.is_true(A:Build(100).setS2_4pc)
        Stub.itemSets[7] = nil
        Stub.Fire("PLAYER_EQUIPMENT_CHANGED")
        assert.is_false(A:Build(100).setS2_4pc)
    end)

    it("keeps missing or secret equipment data uncertain until item data arrives", function()
        for _, slot in ipairs({ 1, 3, 5, 7 }) do
            Stub.inventory[slot], Stub.itemSets[slot] = slot, A.SET_ID
        end
        Stub.itemMissing[7] = true
        Stub.Fire("PLAYER_EQUIPMENT_CHANGED")
        assert.is_true(A:Build(100).unknown.setS2_4pc)
        Stub.itemMissing[7] = nil
        Stub.Fire("GET_ITEM_INFO_RECEIVED", 7, true)
        assert.is_true(A:Build(100).setS2_4pc)
        Stub.itemSets[7] = Stub.Secret()
        assert.has_no_error(function() Stub.Fire("PLAYER_EQUIPMENT_CHANGED") end)
        assert.is_true(A:Build(100).unknown.setS2_4pc)
    end)

    it("shows Touch immediately after its trigger and never before the Bolt has landed", function()
        A.surgeAt = 98
        A.cooldowns[S.SURGE] = { finish = 188 }
        K.State:RecordCast(S.BLAST, 99)
        K.State.cast = { spellID = S.BOLT, endsAt = 102 }
        fight()
        assert.is_nil(K.APL:Recommend().immediate)
        Stub.now = 102
        K.State.cast = nil
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "bolt", S.BOLT)
        local rec = K.APL:Recommend()
        assert.are.equal(S.TOUCH, rec.spellID)
        assert.is_true(rec.immediate)
        assert.matches("touch_of_the_magi", rec.label)
        assert.are.equal(S.BLAST, rec.queuedID)
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "touch", S.TOUCH)
        assert.is_nil(K.APL:Recommend().immediate)
        K.Toggles:Set("cooldowns", false)
        assert.is_nil(K.APL:Recommend().immediate)
    end)

    it("reports the unknown fields actually read instead of silently falling back", function()
        fight()
        A.cooldowns[S.SURGE] = { finish = 190 }
        C_SpellActivationOverlay.IsSpellOverlayed = function() return Stub.Secret() end
        local rec = K.APL:Recommend()
        assert.are.equal("uncertain", rec.reason)
        assert.matches("clearcasting", rec.unknownFields)
        K.Recorder:Clear()
        K.Recorder:NoteRecommendation(rec)
        assert.matches("clearcasting", K.Recorder:Entries()[1].fields)
    end)
end)
