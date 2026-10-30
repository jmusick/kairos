local Stub = require("tests.wow_stub")

describe("Trace", function()
    local Kairos, Trace
    local salvo

    local function traced(kind)
        local out = {}
        for _, entry in ipairs(Kairos.Recorder:Entries()) do
            if entry.k == kind then out[#out + 1] = entry end
        end
        return out
    end

    local function runTimers()
        local timers = Stub.timers
        Stub.timers = {}
        for _, timer in ipairs(timers) do timer.fn() end
    end

    before_each(function()
        Stub.Install()
        salvo = { applications = 12, spellId = 1242974, auraInstanceID = 77 }
        C_UnitAuras.GetAuraDataBySpellName = function(_, name)
            if name == "Arcane Salvo" then return salvo end
        end
        Kairos = Stub.LoadAddon()
        Trace = Kairos.Trace
        Stub.timers = {}
    end)

    it("learns aura spell and instance IDs out of combat", function()
        assert.are.equal(1242974, KairosDB.global.auraIDs["Arcane Salvo"])
        assert.are.equal(77, Trace.instanceByName["Arcane Salvo"])
        assert.are.equal("Arcane Salvo", Trace.instances[77])
    end)

    it("records out-of-combat stack changes only when they change", function()
        Stub.Fire("UNIT_AURA", "player")
        salvo.applications = 13
        Stub.Fire("UNIT_AURA", "player")
        salvo = nil
        Stub.Fire("UNIT_AURA", "player")
        local stacks = {}
        for _, entry in ipairs(traced("aura")) do
            if entry.name == "Arcane Salvo" then stacks[#stacks + 1] = entry.n end
        end
        assert.are.same({ 12, 13, 0 }, stacks)
    end)

    it("never reads auras in combat, where secret ones look absent", function()
        Stub.Fire("PLAYER_REGEN_DISABLED")
        salvo = nil
        Trace:Refresh()
        assert.are.equal(12, Trace.known["Arcane Salvo"])
    end)

    it("brackets each fight with the readable stacks before and after", function()
        Stub.Fire("PLAYER_REGEN_DISABLED")
        salvo.applications = 20
        Stub.now = Stub.now + 5
        Stub.Fire("PLAYER_REGEN_ENABLED")
        runTimers()
        local fights = traced("fight")
        assert.are.equal("start", fights[1].phase)
        assert.are.equal(12, fights[1].auras["Arcane Salvo"])
        assert.is_not_nil(fights[1].at)
        assert.are.equal("end", fights[2].phase)
        assert.are.equal(5, fights[2].length)
        assert.are.equal("after", fights[3].phase)
        assert.are.equal(20, fights[3].auras["Arcane Salvo"])
    end)

    it("marks the end at once and skips the after read if combat restarts first", function()
        Stub.Fire("PLAYER_REGEN_DISABLED")
        Stub.Fire("PLAYER_REGEN_ENABLED")
        Stub.Fire("PLAYER_REGEN_DISABLED")
        runTimers()
        local phases = {}
        for _, entry in ipairs(traced("fight")) do phases[#phases + 1] = entry.phase end
        assert.are.same({ "start", "end", "start" }, phases)
    end)

    it("traces in-combat updates to known aura instances", function()
        Stub.Fire("PLAYER_REGEN_DISABLED")
        Stub.Fire("UNIT_AURA", "player", { updatedAuraInstanceIDs = { 77, 78 } })
        Stub.Fire("UNIT_AURA", "player", { removedAuraInstanceIDs = { 77 }, addedAuras = { { spellId = 5 }, { spellId = Stub.Secret() } } })
        Stub.Fire("UNIT_AURA", "player", { updatedAuraInstanceIDs = Stub.Secret() })
        Stub.Fire("UNIT_AURA", "player", Stub.Secret())
        local ops = {}
        for _, entry in ipairs(traced("aura")) do
            if entry.op then ops[#ops + 1] = (entry.name or "?") .. " " .. entry.op .. " " .. tostring(entry.spell) end
        end
        assert.are.same({ "Arcane Salvo upd nil", "Arcane Salvo rem nil", "? add 5", "? add nil" }, ops)
        assert.are.equal(4, Trace.events.events)
        assert.are.equal(2, Trace.events.secret)
        assert.are.equal(1, Trace.events.addedSecretSpell)
        assert.are.equal(0, Trace.events.errors)
    end)

    it("records the watched spell's visible state only when it changes", function()
        local override = 5143
        C_Spell.GetOverrideSpell = function() return override end
        C_Spell.GetSpellCastCount = function() return Stub.Secret() end
        Kairos.Trace.watched = {}
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c1", 5143)
        Stub.Fire("UNIT_AURA", "player", Stub.Secret())
        override = 9999
        Stub.Fire("UNIT_AURA", "player", Stub.Secret())
        local watches = traced("watch")
        assert.are.equal(2, #watches)
        assert.matches("ov=5143", watches[1].sig)
        assert.matches("cc=S", watches[1].sig)
        assert.matches("ov=9999", watches[2].sig)
    end)

    it("traces glows and Arcane Charges changes", function()
        Stub.Fire("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", 44425)
        Stub.Fire("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE", 44425)
        Stub.Fire("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", Stub.Secret())
        UnitPower = function() return 2 end
        Stub.Fire("UNIT_POWER_UPDATE", "player", "ARCANE_CHARGES")
        Stub.Fire("UNIT_POWER_UPDATE", "player", "ARCANE_CHARGES")
        Stub.Fire("UNIT_POWER_UPDATE", "player", "MANA")
        local glows = traced("glow")
        assert.are.equal(2, #glows)
        assert.is_true(glows[1].on)
        assert.is_false(glows[2].on)
        local charges = traced("ac")
        assert.are.equal(1, #charges)
        assert.are.equal(2, charges[1].n)
    end)
end)

describe("CombatLog", function()
    local Kairos, logging, cvars

    before_each(function()
        Stub.Install()
        logging, cvars = false, {}
        LoggingCombat = function(on)
            if on ~= nil then logging = on end
            return logging
        end
        C_CVar = {
            GetCVar = function(name) return cvars[name] end,
            SetCVar = function(name, value) cvars[name] = value return true end,
        }
        Kairos = Stub.LoadAddon()
    end)

    it("turns on advanced combat logging after entering the world", function()
        Stub.timers = {}
        Stub.Fire("PLAYER_ENTERING_WORLD")
        for _, timer in ipairs(Stub.timers) do timer.fn() end
        assert.is_true(logging)
        assert.are.equal("1", cvars.advancedCombatLogging)
    end)

    it("leaves logging alone when the setting is off", function()
        KairosDB.global.combatLog = false
        Kairos.CombatLog:Ensure()
        assert.is_false(logging)
    end)

    it("re-enables logging at the next pull or encounter when another addon stopped it", function()
        Stub.Fire("PLAYER_REGEN_DISABLED")
        assert.is_true(logging)
        logging = false
        Stub.Fire("ENCOUNTER_START", 1, "Boss")
        assert.is_true(logging)
        logging = false
        KairosDB.global.combatLog = false
        Stub.Fire("ENCOUNTER_START", 1, "Boss")
        assert.is_false(logging)
    end)

    it("does not compare secret logging or CVar reads", function()
        LoggingCombat = function() return Stub.Secret() end
        C_CVar.GetCVar = function() return Stub.Secret() end
        assert.has_no_error(function() Kairos.CombatLog:Ensure() end)
    end)
end)
