local Stub = require("tests.wow_stub")

describe("Probe", function()
    local Kairos, Probe

    local function find(run, key)
        return Probe.Results(run)[key]
    end

    before_each(function()
        Stub.Install()
        Stub.spellNames = { [30451] = "Arcane Blast", [44425] = "Arcane Barrage", [61304] = "Global Cooldown" }
        Kairos = Stub.LoadAddon()
        Probe = Kairos.Probe
        Stub.timers = {} -- drop the login auto-probe timer
    end)

    it("classifies ok, secret, nil and error results", function()
        assert.are.equal("ok", (Probe.Classify(pcall(function() return 4 end))))
        assert.are.equal("secret", (Probe.Classify(pcall(function() return 1, Stub.Secret() end))))
        assert.are.equal("nil", (Probe.Classify(pcall(function() return nil end))))
        local status, detail = Probe.Classify(pcall(function() error("nope") end))
        assert.are.equal("error", status)
        assert.matches("nope", detail)
    end)

    it("stores results as compact strings and decodes both formats", function()
        assert.are.equal("a b\tok\t1 2", Probe.Encode("a b", "ok", "1\t2"))
        assert.are.equal("a\tsecret", Probe.Encode("a", "secret"))
        local key, status, value = Probe.Decode("a b\tok\t1 2")
        assert.are.equal("a b", key)
        assert.are.equal("ok", status)
        assert.are.equal("1 2", value)
        key, status, value = Probe.Decode("a\tsecret")
        assert.are.equal("secret", status)
        assert.is_nil(value)
        key, status = Probe.Decode({ key = "old", status = "nil" })
        assert.are.equal("old", key)
        assert.are.equal("nil", status)
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
        assert.are.equal("string", type(run.results[1]))
        assert.are.equal("secret", find(run, "power Mana (0) current").status)
        assert.are.equal("3", find(run, "power ArcaneCharges (16) current").value)
        assert.are.equal("secret", find(run, "spell Arcane Blast (30451) cooldown.startTime").status)
        assert.are.equal("true", find(run, "spell Arcane Blast (30451) cooldown.isEnabled").value)
        assert.are.equal("unresolved", find(run, "spell Arcane Orb").status)
        assert.are.equal("missing", find(run, "actionbar GetSpell(1)").status)
        assert.are.equal(1, #KairosDB.probes)
    end)

    it("includes Assisted Combat's rotation spells", function()
        C_AssistedCombat.GetRotationSpells = function() return { 12345 } end
        local run = Probe:Run("test")
        assert.is_not_nil(find(run, "spell spell 12345 (12345) usable"))
    end)

    it("matches extras against rotation spell names before name lookup", function()
        Stub.spellNames[12051] = "Evocation"
        C_AssistedCombat.GetRotationSpells = function() return { 12051 } end
        C_Spell.GetSpellIDForSpellIdentifier = function() return nil end
        local run = Probe:Run("test")
        assert.is_nil(find(run, "spell Evocation"))
        assert.is_not_nil(find(run, "spell Evocation (12051) usable"))
    end)

    it("checks aura secrecy against the aura's own ID, not the spell's", function()
        C_Secrets.GetSpellAuraSecrecy = function(id) return id == 365362 and 2 or 99 end
        local run = Probe:Run("test")
        assert.are.equal("365362 table", find(run, "aura Arcane Surge on player auraID").value)
        assert.are.equal("2", find(run, "aura Arcane Surge on player auraSecrecy").value)
        assert.are.equal("unresolved", find(run, "aura Arcane Salvo on player auraID").status)
    end)

    it("prefers aura IDs learned in game", function()
        C_UnitAuras.GetAuraDataBySpellName = function(_, name)
            if name == "Arcane Salvo" then return { applications = 12, spellId = 1234567, auraInstanceID = 77 } end
        end
        local run = Probe:Run("test")
        assert.are.equal("1234567 seen", find(run, "aura Arcane Salvo on player auraID").value)
        assert.are.equal("77", find(run, "aura Arcane Salvo on player instanceID").value)
    end)

    it("reports the trace's aura event counts", function()
        C_UnitAuras.GetAuraDataBySpellName = function(_, name)
            if name == "Arcane Salvo" then return { applications = 12, spellId = 1242974, auraInstanceID = 77 } end
        end
        Stub.Fire("UNIT_AURA", "player")
        Stub.Fire("PLAYER_REGEN_DISABLED")
        Stub.Fire("UNIT_AURA", "player", { updatedAuraInstanceIDs = { 77, 78 } })
        Stub.Fire("UNIT_AURA", "player", { updatedAuraInstanceIDs = { 77 }, addedAuras = { { spellId = Stub.Secret() } } })
        local run = Probe:Run("test")
        assert.are.equal("2", find(run, "auraEvents since combat start").value)
        assert.are.equal("2", find(run, "auraEvents Arcane Salvo updated").value)
        assert.are.equal("1", find(run, "auraEvents added with secret spellId").value)
    end)

    it("keeps at most MAX_RUNS runs", function()
        Probe.MAX_RUNS = 2
        for i = 1, 3 do Probe:Run("run " .. i) end
        assert.are.equal(2, #KairosDB.probes)
        assert.are.equal("run 2", KairosDB.probes[1].label)
    end)

    it("renders a Markdown matrix with one column per run, old and new formats", function()
        KairosDB.probes[1] = { label = "old", client = "x", context = {}, results = {
            { key = "unit target health", status = "ok", value = "999" } } }
        Probe:Run("world")
        UnitHealth = function() return Stub.Secret() end
        Probe:Run("dungeon")
        local report = Probe.Report(KairosDB.probes)
        assert.matches("| Check | #1 | #2 | #3 |", report)
        assert.matches("| unit target health | 999 | 1000 | %*%*SECRET%*%* |", report)
    end)

    it("auto-probes silently at login, early in each fight and after it, throttled", function()
        Stub.Install()
        Kairos = Stub.LoadAddon()
        Probe = Kairos.Probe
        assert.are.equal(1, #Stub.timers)
        assert.are.equal(Probe.LOGIN_DELAY, Stub.timers[1].delay)

        Stub.Fire("PLAYER_REGEN_DISABLED")
        Stub.Fire("PLAYER_REGEN_ENABLED")
        local chatBefore = #Stub.chat
        for _, timer in ipairs(Stub.timers) do timer.fn() end
        local labels = {}
        for _, run in ipairs(KairosDB.probes) do labels[#labels + 1] = run.label end
        table.sort(labels)
        assert.are.same({ "auto after", "auto combat", "auto login" }, labels)
        assert.are.equal(chatBefore, #Stub.chat)

        local timers = #Stub.timers
        Stub.Fire("PLAYER_REGEN_DISABLED")
        Stub.Fire("PLAYER_REGEN_ENABLED")
        -- Throttled probes add no timers; the trace's fight-end read still schedules one.
        assert.are.equal(timers + 1, #Stub.timers)
    end)

    it("doesn't auto-probe when turned off", function()
        KairosDB.global.autoProbe = false
        Stub.Fire("PLAYER_REGEN_DISABLED")
        Stub.Fire("PLAYER_REGEN_ENABLED")
        for _, timer in ipairs(Stub.timers) do timer.fn() end
        assert.are.equal(0, #KairosDB.probes)
    end)

    it("runs from the slash command and says whether it was in combat", function()
        SlashCmdList.KAIROS("probe")
        assert.are.equal(1, #KairosDB.probes)
        assert.matches("Probe #1 %(manual, .-out of combat", Stub.chat[#Stub.chat])
        InCombatLockdown = function() return true end
        SlashCmdList.KAIROS("probe")
        assert.matches("in combat", Stub.chat[#Stub.chat])
    end)

    it("schedules a delayed probe", function()
        SlashCmdList.KAIROS("probe in 20 salvo-combat")
        assert.are.equal(1, #Stub.timers)
        assert.are.equal(20, Stub.timers[1].delay)
        assert.are.equal(0, #KairosDB.probes)
        Stub.timers[1].fn()
        assert.are.equal("salvo-combat", KairosDB.probes[1].label)

        SlashCmdList.KAIROS("probe in 5")
        Stub.timers[2].fn()
        assert.are.equal("in 5s", KairosDB.probes[2].label)

        SlashCmdList.KAIROS("probe in 0")
        assert.are.equal(2, #Stub.timers)
        assert.matches("Usage", Stub.chat[#Stub.chat])
    end)

    it("records the probe revision and reports it per run", function()
        local run = Probe:Run("test")
        assert.are.equal(Probe.REVISION, run.rev)
        KairosDB.probes[1].rev = nil
        local report = Probe.Report(KairosDB.probes)
        assert.matches("| Kairos | Probe | Spec |", report)
        assert.matches("| 0.1.0%-test | 1 | 62 |", report)
    end)
end)
