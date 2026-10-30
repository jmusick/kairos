local Stub = require("tests.wow_stub")

describe("Probe", function()
    local Kairos, Probe

    local function find(run, key)
        for _, result in ipairs(run.results) do
            if result.key == key then return result end
        end
    end

    before_each(function()
        Stub.Install()
        Stub.spellNames = { [30451] = "Arcane Blast", [44425] = "Arcane Barrage", [61304] = "Global Cooldown" }
        Kairos = Stub.LoadAddon()
        Probe = Kairos.Probe
    end)

    it("classifies ok, secret, nil and error results", function()
        assert.are.equal("ok", (Probe.Classify(pcall(function() return 4 end))))
        assert.are.equal("secret", (Probe.Classify(pcall(function() return 1, Stub.Secret() end))))
        assert.are.equal("nil", (Probe.Classify(pcall(function() return nil end))))
        local status, detail = Probe.Classify(pcall(function() error("nope") end))
        assert.are.equal("error", status)
        assert.matches("nope", detail)
    end)

    it("records context and per-field results", function()
        UnitPower = function(_, powerType)
            if powerType == 0 then return Stub.Secret() end
            return 3
        end
        C_Spell.GetSpellCooldown = function(id)
            if id == 30451 then return { startTime = Stub.Secret(), duration = Stub.Secret(), isEnabled = true, modRate = 1 } end
            return { startTime = 0, duration = 0, isEnabled = true, modRate = 1 }
        end
        local run = Probe:Run("test")
        assert.are.equal("12.1.5 (70575)", run.client)
        assert.are.equal(62, run.spec)
        assert.are.equal("none", run.context.restrictions)
        assert.are.equal("secret", find(run, "power Mana (0) current").status)
        assert.are.equal("3", find(run, "power ArcaneCharges (16) current").value)
        assert.are.equal("secret", find(run, "spell Arcane Blast (30451) cooldown.startTime").status)
        assert.are.equal("true", find(run, "spell Arcane Blast (30451) cooldown.isEnabled").value)
        assert.are.equal("missing", find(run, "spell Arcane Orb").status)
        assert.are.equal("missing", find(run, "actionbar GetSpell(1)").status)
        assert.are.equal(1, #KairosDB.probes)
    end)

    it("includes Assisted Combat's rotation spells", function()
        C_AssistedCombat.GetRotationSpells = function() return { 12345 } end
        local run = Probe:Run("test")
        assert.is_not_nil(find(run, "spell spell 12345 (12345) usable"))
    end)

    it("keeps at most MAX_RUNS runs", function()
        Probe.MAX_RUNS = 2
        for i = 1, 3 do Probe:Run("run " .. i) end
        assert.are.equal(2, #KairosDB.probes)
        assert.are.equal("run 2", KairosDB.probes[1].label)
    end)

    it("renders a Markdown matrix with one column per run", function()
        Probe:Run("world")
        UnitHealth = function() return Stub.Secret() end
        Probe:Run("dungeon")
        local report = Probe.Report(KairosDB.probes)
        assert.matches("| Check | #1 | #2 |", report)
        assert.matches("| unit target health | 1000 | %*%*SECRET%*%* |", report)
    end)

    it("auto-probes on combat only when enabled, throttled", function()
        Stub.Fire("PLAYER_REGEN_DISABLED")
        assert.are.equal(0, #Stub.timers)
        KairosDB.global.autoProbe = true
        Stub.Fire("PLAYER_REGEN_ENABLED")
        Stub.Fire("PLAYER_REGEN_DISABLED")
        assert.are.equal(1, #Stub.timers)
        Stub.timers[1].fn()
        assert.are.equal("auto combat", KairosDB.probes[1].label)
        Stub.Fire("PLAYER_REGEN_ENABLED")
        Stub.Fire("PLAYER_REGEN_DISABLED")
        assert.are.equal(1, #Stub.timers)
    end)

    it("runs from the slash command", function()
        SlashCmdList.KAIROS("probe")
        assert.are.equal(1, #KairosDB.probes)
        assert.matches("Probe #1 %(manual%)", Stub.chat[#Stub.chat])
    end)
end)
