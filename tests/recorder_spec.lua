local Stub = require("tests.wow_stub")

describe("Recorder commitment context", function()
    local K, R
    before_each(function()
        Stub.Install()
        K = Stub.LoadAddon()
        R = K.Recorder
        R:Clear()
    end)

    it("keeps the latest evaluation when an unchanged icon is committed", function()
        local function rec(stacks)
            return { source = "apl", spellID = 5143, label = "missiles",
                diagnostic = { now = Stub.now, projected = { salvo = stacks } } }
        end
        R:NoteRecommendation(rec(8))
        Stub.now = 100.1
        R:NoteRecommendation(rec(11))
        R:Commit("commit", 5143, true)
        local list = R:Entries()
        assert.are.equal(2, #list)
        assert.are.equal(8, list[1].diagnostic.projected.salvo)
        assert.are.equal(11, list[2].recommendation.diagnostic.projected.salvo)
        assert.are.equal(100.1, list[2].recommendation.t)
    end)

    it("captures the pre-channel instruction before Display refreshes lookahead", function()
        R:NoteRecommendation({ source = "apl", spellID = 5143, label = "before" })
        UnitChannelInfo = function() return "Missiles", nil, nil, 100000, 102000, nil, nil, 5143 end
        Stub.Fire("UNIT_SPELLCAST_CHANNEL_START", "player", "channel", 5143)
        local commit
        for _, e in ipairs(R:Entries()) do if e.k == "commit" then commit = e end end
        assert.are.equal(5143, commit.recommendation.spell)
        assert.are.equal("before", commit.recommendation.label)
        assert.are.equal(100, K.State.cast.startsAt)
        assert.are.equal(102, K.State.cast.endsAt)
    end)

    it("commits the instruction on screen at the keypress, before the cast's GCD refresh", function()
        R:NoteRecommendation({ source = "apl", spellID = 264178, label = "before press" })
        Stub.Fire("UNIT_SPELLCAST_SENT", "player", "target", "guid", 264178)
        R:NoteRecommendation({ source = "apl", spellID = 105174, label = "next GCD" })
        Stub.Fire("UNIT_SPELLCAST_SENT", "player", "target", "guid", Stub.Secret())
        local list = R:Entries()
        assert.are.equal("sent", list[2].k)
        assert.are.equal(264178, list[2].spell)
        assert.are.equal("before press", list[2].recommendation.label)
        assert.are.equal(3, #list)
    end)

    it("commits what was on screen before the press's GCD began, keeping the forecast", function()
        R:NoteRecommendation({ source = "apl", spellID = 104316, label = "on screen" })
        Stub.now = 100.2
        Stub.cooldowns[61304] = { startTime = 100.15, duration = 1.2, modRate = 1 }
        R:NoteRecommendation({ source = "apl", spellID = 686, label = "next GCD" })
        Stub.Fire("UNIT_SPELLCAST_SENT", "player", "target", "guid", 104316)
        local sent = R:Entries()[#R:Entries()]
        assert.are.equal("on screen", sent.recommendation.label)
        assert.are.equal(686, sent.forecast)
        -- Long after the GCD began, the latest evaluation is what's on screen.
        Stub.now = 102
        R:Commit("cast", 686)
        assert.are.equal("next GCD", R:Entries()[#R:Entries()].recommendation.label)
        assert.is_nil(R:Entries()[#R:Entries()].forecast)
    end)

    it("records whether a live hostile target exists, on change and at each commit", function()
        local function kind(k)
            local out = {}
            for _, e in ipairs(R:Entries()) do if e.k == k then out[#out + 1] = e end end
            return out
        end
        local dead = false
        UnitIsDeadOrGhost = function() return dead end
        Stub.Fire("PLAYER_TARGET_CHANGED")
        assert.is_true(kind("target")[1].on)
        Stub.Fire("UNIT_HEALTH", "target")
        assert.are.equal(1, #kind("target")) -- unchanged state isn't repeated
        dead = true
        Stub.Fire("UNIT_HEALTH", "target")
        assert.is_false(kind("target")[2].on)
        R:Commit("cast", 686)
        assert.is_false(kind("cast")[1].target)
        UnitCanAttack = function() return Stub.Secret() end
        dead = false
        Stub.Fire("PLAYER_TARGET_CHANGED")
        assert.are.equal(2, #kind("target")) -- a secret read records nothing
    end)

    it("filters secret keys and values and owns the persisted snapshot", function()
        local secret = Stub.Secret()
        local d = { known = 4, hidden = secret, nested = { [secret] = 7, value = secret, ok = false } }
        local rec = { source = "apl", spellID = 5143, diagnostic = d }
        assert.has_no_error(function() R:NoteRecommendation(rec); R:Commit("cast", 5143) end)
        d.known = 10
        local saved = R:Entries()[1].diagnostic
        assert.are.equal(4, saved.known)
        assert.is_nil(saved.hidden)
        assert.are.same({ ok = false }, saved.nested)
    end)

    it("preserves per-entry toggle and identity context after ring rollover", function()
        R.SIZE = 3
        Stub.Fire("PLAYER_REGEN_DISABLED")
        R:NoteRecommendation({ source = "apl", spellID = 365350 })
        R:Commit("cast", 365350)
        local before = K.db.flight.pulls[1].entries[2]
        K.Toggles:Set("cooldowns", false)
        R:Commit("cast", 44425)
        for i = 1, 5 do R:Push({ k = "noise", n = i }) end
        local after = K.db.flight.pulls[1].entries[3]
        assert.is_true(before.context.cooldowns)
        assert.is_false(after.context.cooldowns)
        assert.are.equal(before.context.session, after.context.session)
        assert.are.equal(62, before.context.spec)
        assert.is_not_nil(before.context.char)
        assert.is_not_nil(before.recommendation)
        assert.are.equal(3, #R:Entries())
    end)

    it("bounds pull count and entries and reports omitted coverage", function()
        K.db.global.recorderPulls, K.db.global.recorderPullEntries = 2, 2
        for _ = 1, 3 do
            Stub.Fire("PLAYER_REGEN_DISABLED")
            for _ = 1, 4 do R:Commit("cast", 30451) end
            Stub.Fire("PLAYER_REGEN_ENABLED")
        end
        assert.are.equal(2, #K.db.flight.pulls)
        assert.are.equal(1, K.db.flight.retiredPulls)
        -- The fight start and one cast fit; three casts and the fight end are omitted.
        assert.are.equal(2, #K.db.flight.pulls[1].entries)
        assert.are.equal(4, K.db.flight.pulls[1].dropped)
        assert.are.equal("combat", K.db.flight.pulls[1].reason)
    end)

    it("saves a press's repeated snapshot once per pull", function()
        R:NoteRecommendation({ source = "apl", spellID = 30451, diagnostic = { now = 100 } })
        R:Commit("sent", 30451)
        R:Commit("cast", 30451)
        local outside = R:Entries()
        assert.is_not_nil(outside[#outside].recommendation)
        Stub.Fire("PLAYER_REGEN_DISABLED")
        R:Commit("sent", 30451)
        R:Commit("cast", 30451)
        local pull = K.db.flight.pulls[1].entries
        local sent, cast = pull[#pull - 1], pull[#pull]
        assert.are.equal(30451, sent.recommendation.spell)
        assert.is_nil(cast.recommendation)
        assert.are.equal(sent.seq, cast.sameAs)
        R:NoteRecommendation({ source = "apl", spellID = 5143, diagnostic = { now = 101 } })
        R:Commit("sent", 5143)
        assert.are.equal(5143, pull[#pull].recommendation.spell)
        assert.is_nil(pull[#pull].sameAs)
    end)

    it("archives a pull's traces and fight end, but not its display picks", function()
        Stub.Fire("PLAYER_REGEN_DISABLED")
        R:Push({ k = "shards", n = 3 })
        R:NoteRecommendation({ source = "apl", spellID = 5143 })
        Stub.Fire("PLAYER_REGEN_ENABLED")
        R:Push({ k = "shards", n = 4 })
        local kinds = {}
        for _, e in ipairs(K.db.flight.pulls[1].entries) do kinds[#kinds + 1] = e.k .. (e.phase or e.n or "") end
        assert.are.same({ "fightstart", "shards3", "fightend" }, kinds)
    end)

    it("clears both archives and starts a new context across a profile switch", function()
        Stub.Fire("PLAYER_REGEN_DISABLED")
        R:NoteRecommendation({ source = "apl", spellID = 5143 })
        R:Commit("cast", 5143)
        local session = R.context.session
        Stub.specIndex = 2
        Stub.Fire("PLAYER_SPECIALIZATION_CHANGED", "player")
        assert.is_true(R.context.session > session)
        assert.are.equal(63, R.context.spec)
        -- Display may refresh at the profile event, but cannot inherit Arcane's pick.
        assert.is_false(R.latest and R.latest.spell == 5143 or false)
        R:Clear()
        assert.is_nil(K.db.flight.pulls)
        assert.are.equal(0, #R:Entries())
    end)

    it("never archives an old instruction while recommendations are disabled", function()
        R:NoteRecommendation({ source = "apl", spellID = 5143 })
        K.db.global.enabled = false
        R:Commit("cast", 5143)
        assert.is_nil(R:Entries()[2].recommendation)
        K.db.global.recorder = false
        R:Commit("cast", 5143)
        assert.are.equal(2, #R:Entries())
    end)
end)
