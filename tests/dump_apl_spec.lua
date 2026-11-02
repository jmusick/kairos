-- Exercise the command end to end with a small offline log and an interleaved
-- recorder stream. In particular, AC observations must never displace live picks.
describe("APL dump live scoring", function()
    local function report(recorded, logOverride, flightOverride)
        local output = {}
        local log = logOverride or {
            '10/30/2026 10:00:00.000-4  SPELL_AURA_APPLIED,Player-1,"Tester",0,0,Player-1,"Tester",0,0,1242974,"Arcane Salvo",64,BUFF',
            '10/30/2026 10:00:01.000-4  SPELL_CAST_SUCCESS,Player-1,"Tester",0,0,Creature-1,"Dummy",0,0,365350,"Arcane Surge",64',
            '10/30/2026 10:00:03.000-4  SPELL_CAST_SUCCESS,Player-1,"Tester",0,0,Creature-1,"Dummy",0,0,153626,"Arcane Orb",64',
            '10/30/2026 10:00:05.000-4  SPELL_CAST_SUCCESS,Player-1,"Tester",0,0,Creature-1,"Dummy",0,0,30451,"Arcane Blast",64',
        }
        local env = setmetatable({
            arg = { [0] = "tools/kairos-dump.lua", "apl", "fixture.log", "fixture.sv", "Tester", "10:00:00", "10:00:06" },
            print = function(text) output[#output + 1] = text end,
            io = { open = function(path)
                assert.are.equal("fixture.log", path)
                return { close = function() end, lines = function()
                    local i = 0
                    return function() i = i + 1; return log[i] end
                end }
            end },
        }, { __index = _G })
        env.loadfile = function(path)
            if path == "fixture.sv" then
                return function()
                    env.KairosDB = { flight = flightOverride or { entries = recorded, pos = #recorded } }
                end
            end
            return loadfile(path)
        end
        local chunk
        if setfenv then
            chunk = assert(loadfile("tools/kairos-dump.lua"))
            setfenv(chunk, env)
        else
            local file = assert(io.open("tools/kairos-dump.lua"))
            local source = file:read("*a")
            file:close()
            chunk = assert(load(source, "@tools/kairos-dump.lua", "t", env))
        end
        chunk()
        return table.concat(output, "\n")
    end

    local function diagnostic(t, surgeReady)
        local function state()
            return { t = t, unknown = {}, known = { unknown = {}, [1241462] = false },
                talent = { unknown = {}, slipstream = true },
                ready = { [365350] = surgeReady, [321507] = surgeReady },
                remains = { [365350] = surgeReady and 0 or 90, [321507] = surgeReady and 0 or 45 },
                chargesFractional = { [153626] = 2 }, charges = 0, salvo = 0, clearcasting = 0,
                boltReady = false, cumulativePower = 0, lustrousGleam = 0, setS2_4pc = false,
                soul = false, surgeUp = false, surgeRemains = 0, enemies = 1, gcdMax = 1.2 }
        end
        return { v = 1, now = t, projected = state(), current = state(),
            movement = { state = "known", value = false } }
    end

    local function context(cooldowns)
        return { session = 1, char = "Tester-Realm", spec = 62, cooldowns = cooldowns }
    end

    it("aligns live and AC streams and scores only their actual coverage", function()
        local output = report({
            { k = "pick", src = "ac", observed = true, spell = 321507, t = 100 },
            { k = "pick", src = "kairos", spell = 365350, label = "surge", t = 100 },
            { k = "cast", spell = 365350, t = 101 },
            { k = "pick", src = "ac", spell = 153626, t = 102 },
            { k = "cast", spell = 153626, t = 103 },
            { k = "pick", src = "kairos", spell = 30451, label = "filler", t = 104 },
            { k = "pick", src = "ac", observed = true, spell = 153626, t = 104.5 },
            { k = "cast", spell = 30451, t = 105 },
        })
        assert.matches("recorder aligned: 3/3", output)
        assert.matches("Kairos in game%s+= APL on true state: 1/2 %(50%%%)", output)
        assert.matches("Display including AC fallback:%s+2/3", output)
        assert.matches("AC fallback share of recorded decisions:%s+1/3", output)
        assert.matches("Assisted Combat%s+= APL on true state: 2/3", output)
        assert.matches("In game agrees", output)
    end)

    it("keeps legacy AC-only recordings readable without inventing live scores", function()
        local output = report({
            { k = "pick", src = "ac", spell = 365350, t = 100 },
            { k = "cast", spell = 365350, t = 101 },
            { k = "pick", src = "ac", spell = 153626, t = 102 },
            { k = "cast", spell = 153626, t = 103 },
            { k = "cast", spell = 30451, t = 105 },
        })
        assert.is_nil(output:find("Kairos in game", 1, true))
        assert.matches("Assisted Combat%s+= APL on true state: 3/3", output)
    end)

    it("never grades the post-cast pick against a success whose clock lands a few ms later", function()
        local output = report({
            { k = "pick", src = "kairos", spell = 365350, t = 100.9 },
            { k = "cast", spell = 365350, t = 101.006 },
            { k = "pick", src = "kairos", spell = 153626, t = 101.006 },
            { k = "cast", spell = 153626, t = 102.994 },
            { k = "pick", src = "kairos", spell = 153626, label = "second Orb charge", t = 102.994 },
            { k = "cast", spell = 30451, t = 105.001 },
            { k = "pick", src = "kairos", spell = 5143, t = 105.001 },
        })
        assert.matches("recorder aligned: 3/3", output)
        assert.matches("Kairos in game%s+= APL on true state: 3/3", output)
    end)

    it("scores Barrage before its own Bolt proc, then preserves that proc for the next cast", function()
        local log = {
            '10/30/2026 10:00:00.000-4  SPELL_AURA_APPLIED,Player-1,"Tester",0,0,Player-1,"Tester",0,0,1242974,"Arcane Salvo",64,BUFF',
            '10/30/2026 10:00:01.000-4  SPELL_CAST_SUCCESS,Player-1,"Tester",0,0,Creature-1,"Dummy",0,0,365350,"Arcane Surge",64',
            '10/30/2026 10:00:02.000-4  SPELL_AURA_APPLIED_DOSE,Player-1,"Tester",0,0,Player-1,"Tester",0,0,1242974,"Arcane Salvo",64,BUFF,10',
            '10/30/2026 10:00:02.996-4  SPELL_AURA_APPLIED,Player-1,"Tester",0,0,Player-1,"Tester",0,0,1295942,"Prismatic Bolt!",64,BUFF',
            '10/30/2026 10:00:03.000-4  SPELL_CAST_SUCCESS,Player-1,"Tester",0,0,Creature-1,"Dummy",0,0,44425,"Arcane Barrage",64',
            '10/30/2026 10:00:04.000-4  SPELL_CAST_SUCCESS,Player-1,"Tester",0,0,Creature-1,"Dummy",0,0,1295924,"Prismatic Bolt",64',
        }
        local recorded = {
            { k = "pick", src = "kairos", spell = 365350, t = 100 },
            { k = "cast", spell = 365350, t = 101 },
            { k = "pick", src = "kairos", spell = 44425, t = 102 },
            { k = "cast", spell = 44425, t = 103 },
            { k = "pick", src = "kairos", spell = 1295924, t = 103.1 },
            { k = "cast", spell = 1295924, t = 104 },
        }
        local output = report(recorded, log)
        assert.matches("Bolt procs excluded from pre%-press state: 1", output)
        assert.matches("Kairos in game%s+= APL on true state: 3/3", output)
        -- A proc that was already available must still take priority over Barrage.
        log[4] = log[4]:gsub("02.996", "02.000")
        recorded[3].spell = 1295924
        output = report(recorded, log)
        assert.is_nil(output:find("Bolt procs excluded", 1, true))
        assert.matches("Kairos in game%s+= APL on true state: 3/3", output)
    end)

    it("still scores a cast-time spell at START instead of using picks shown during that cast", function()
        local log = {
            '10/30/2026 10:00:00.000-4  SPELL_AURA_APPLIED,Player-1,"Tester",0,0,Player-1,"Tester",0,0,1242974,"Arcane Salvo",64,BUFF',
            '10/30/2026 10:00:01.000-4  SPELL_CAST_SUCCESS,Player-1,"Tester",0,0,Creature-1,"Dummy",0,0,365350,"Arcane Surge",64',
            '10/30/2026 10:00:03.000-4  SPELL_CAST_SUCCESS,Player-1,"Tester",0,0,Creature-1,"Dummy",0,0,153626,"Arcane Orb",64',
            '10/30/2026 10:00:04.000-4  SPELL_CAST_START,Player-1,"Tester",0,0,Creature-1,"Dummy",0,0,30451,"Arcane Blast",64',
            '10/30/2026 10:00:05.000-4  SPELL_CAST_SUCCESS,Player-1,"Tester",0,0,Creature-1,"Dummy",0,0,30451,"Arcane Blast",64',
        }
        local output = report({
            { k = "pick", src = "kairos", spell = 365350, t = 100 },
            { k = "cast", spell = 365350, t = 101 },
            { k = "pick", src = "kairos", spell = 153626, t = 102 },
            { k = "cast", spell = 153626, t = 103 },
            { k = "pick", src = "kairos", spell = 5143, t = 104.2 },
            { k = "cast", spell = 30451, t = 105 },
        }, log)
        assert.matches("Kairos in game%s+= APL on true state: 3/3", output)
    end)

    it("ignores another character's later picks and casts when aligning Arcane", function()
        local output = report({
            { k = "session", char = "Tester-Realm", spec = 62, t = 99 },
            { k = "pick", src = "kairos", spell = 365350, t = 100 },
            { k = "cast", spell = 365350, t = 101 },
            { k = "pick", src = "kairos", spell = 153626, t = 102 },
            { k = "cast", spell = 153626, t = 103 },
            { k = "cast", spell = 30451, t = 105 },
            { k = "session", char = "Warlock-Realm", spec = 266, t = 120 },
            { k = "pick", src = "kairos", spell = 264178, t = 120 },
            { k = "cast", spell = 264178, t = 121 },
        })
        assert.matches("recorder aligned: 3/3", output)
        assert.matches("Kairos in game%s+= APL on true state: 3/3", output)
    end)

    it("aligns from an earlier cast when the last cast wasn't logged", function()
        local output = report({
            { k = "pick", src = "ac", spell = 365350, t = 100 },
            { k = "cast", spell = 365350, t = 101 },
            { k = "pick", src = "ac", spell = 153626, t = 102 },
            { k = "cast", spell = 153626, t = 103 },
            { k = "cast", spell = 30451, t = 105 },
            { k = "cast", spell = 1459, t = 110 },
        })
        assert.matches("recorder aligned: 3/4", output)
        assert.matches("Assisted Combat%s+= APL on true state: 3/3", output)
    end)

    it("uses archived commitment snapshots after rollover and deduplicates their casts", function()
        local casts = {}
        for i, spell in ipairs({ 365350, 153626, 30451 }) do
            casts[i] = { k = "cast", spell = spell, t = 99 + 2 * i, seq = i, context = context(false),
                recommendation = { t = 98 + 2 * i, src = "kairos", spell = 153626,
                    label = "sunfury:arcane_orb", diagnostic = diagnostic(98 + 2 * i, false) } }
        end
        local output = report({}, nil, { entries = { casts[3] }, pos = 1, pulls = { { entries = casts } } })
        assert.matches("recorder aligned: 3/3", output)
        assert.matches("commitment context: 3 captured, 0 unscored, 0 legacy", output)
        assert.matches("Kairos in game%s+= APL on true state: 3/3", output)
        assert.matches("Captured evaluation reproduced:%s+3/3", output)
    end)

    it("reproduces a real adapter snapshot persisted by the recorder", function()
        local Stub = require("tests.wow_stub")
        Stub.Install()
        for _, id in ipairs({ 5143, 30451, 44425, 153626, 365350, 321507 }) do Stub.knownSpells[id] = true end
        Stub.charges[153626] = { currentCharges = 2, maxCharges = 2,
            cooldownStartTime = 0, cooldownDuration = 20, chargeModRate = 1 }
        UnitPower = function() return 0 end
        local K = Stub.LoadAddon()
        K.Recorder:Clear()
        K.Toggles:Set("cooldowns", false)
        Stub.Fire("PLAYER_REGEN_DISABLED")
        K.Display:Refresh()
        Stub.now = 101
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "surge", 365350)
        local output = report({}, nil, { pulls = K.db.flight.pulls })
        assert.matches("commitment context: 1 captured, 0 unscored", output)
        assert.matches("Captured evaluation reproduced:%s+1/1", output)
        assert.matches("Kairos in game%s+= APL on true state: 1/1", output)
    end)

    it("reads a cast snapshot saved as a reference to the press's keypress copy", function()
        local Stub = require("tests.wow_stub")
        Stub.Install()
        for _, id in ipairs({ 5143, 30451, 44425, 153626, 365350, 321507 }) do Stub.knownSpells[id] = true end
        Stub.charges[153626] = { currentCharges = 2, maxCharges = 2,
            cooldownStartTime = 0, cooldownDuration = 20, chargeModRate = 1 }
        UnitPower = function() return 0 end
        local K = Stub.LoadAddon()
        K.Recorder:Clear()
        K.Toggles:Set("cooldowns", false)
        Stub.Fire("PLAYER_REGEN_DISABLED")
        K.Display:Refresh()
        Stub.now = 101
        Stub.Fire("UNIT_SPELLCAST_SENT", "player", "Dummy", "surge", 365350)
        Stub.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "surge", 365350)
        local cast
        for _, e in ipairs(K.db.flight.pulls[1].entries) do if e.k == "cast" then cast = e end end
        assert.is_not_nil(cast.sameAs)
        local output = report({}, nil, { pulls = K.db.flight.pulls })
        assert.matches("commitment context: 1 captured, 0 unscored", output)
        assert.matches("Captured evaluation reproduced:%s+1/1", output)
        assert.matches("Kairos in game%s+= APL on true state: 1/1", output)
    end)

    it("leaves missing toggle or evaluation history explicitly unscored", function()
        local output = report({
            { k = "cast", spell = 365350, t = 101, context = context(nil),
                recommendation = { src = "kairos", spell = 365350, diagnostic = diagnostic(100, true) } },
            { k = "cast", spell = 153626, t = 103, context = context(true),
                recommendation = { src = "kairos", spell = 153626 } },
            { k = "cast", spell = 30451, t = 105, context = context(true) },
        })
        assert.matches("commitment context: 3 captured, 3 unscored", output)
        assert.matches("unscored 1: missing cooldown history", output)
        assert.matches("unscored 1: missing evaluation state", output)
        assert.matches("unscored 1: no commitment snapshot", output)
        assert.is_nil(output:find("Display including AC fallback:", 1, true))
    end)

    it("separates exact adapter reproduction from agreement with log truth", function()
        local recorded = {}
        for i, spell in ipairs({ 365350, 153626, 30451 }) do
            recorded[i] = { k = "cast", spell = spell, t = 99 + 2 * i, context = context(true),
                recommendation = { src = "kairos", spell = 365350, label = "cooldowns:arcane_surge (2/2)",
                    diagnostic = diagnostic(98 + 2 * i, true) } }
        end
        local output = report(recorded)
        assert.matches("Captured evaluation reproduced:%s+3/3", output)
        assert.matches("Kairos in game%s+= APL on true state: 1/3", output)
    end)

    it("samples the pre-channel commitment instead of the new channel's forecast", function()
        local log = {
            '10/30/2026 10:00:00.000-4  SPELL_AURA_APPLIED,Player-1,"Tester",0,0,Player-1,"Tester",0,0,1242974,"Arcane Salvo",64,BUFF',
            '10/30/2026 10:00:01.000-4  SPELL_CAST_SUCCESS,Player-1,"Tester",0,0,Creature-1,"Dummy",0,0,365350,"Arcane Surge",64',
            '10/30/2026 10:00:02.000-4  SPELL_AURA_APPLIED,Player-1,"Tester",0,0,Player-1,"Tester",0,0,263725,"Clearcasting",64,BUFF',
            '10/30/2026 10:00:03.000-4  SPELL_CAST_SUCCESS,Player-1,"Tester",0,0,Creature-1,"Dummy",0,0,5143,"Arcane Missiles",64',
        }
        local pre = { src = "kairos", spell = 5143, diagnostic = diagnostic(102.9, false) }
        pre.diagnostic.projected.clearcasting = 1
        local post = { src = "kairos", spell = 44425, diagnostic = diagnostic(103, false) }
        post.diagnostic.cast = { spellID = 5143, channel = true, startsAt = 103, endsAt = 105 }
        local recorded = {
            { k = "cast", spell = 365350, t = 101 },
            { k = "commit", spell = 5143, t = 103, context = context(true), recommendation = pre },
            { k = "pick", src = "kairos", spell = 44425, t = 103, diagnostic = post.diagnostic },
            { k = "cast", spell = 5143, t = 103, context = context(true), recommendation = post },
        }
        local output = report(recorded, log)
        assert.matches("Kairos in game%s+= APL on true state: 1/1", output)
        table.remove(recorded, 2)
        output = report(recorded, log)
        assert.matches("commitment context: 1 captured, 1 unscored", output)
    end)

    it("uses captured movement to filter stationary reference actions", function()
        local d = diagnostic(100, false)
        d.movement.value = true
        local output = report({
            { k = "cast", spell = 365350, t = 101, context = context(true),
                recommendation = { src = "kairos", spell = 153626, diagnostic = d } },
        })
        assert.matches("Kairos in game%s+= APL on true state: 1/1", output)
    end)

    it("leaves an unavailable reference unscored rather than inventing a spell", function()
        local d = diagnostic(100, false)
        d.movement.value = true
        d.projected.orbInFlight = true
        local output = report({
            { k = "cast", spell = 365350, t = 101, context = context(true),
                recommendation = { src = "kairos", spell = 30451, diagnostic = d } },
        })
        assert.matches("no reference action under captured availability", output)
        assert.matches("Player cast%s+= APL on true state: 1/2", output)
    end)

    it("requires a start commitment for a new-format cast-time decision", function()
        local log = {
            '10/30/2026 10:00:00.000-4  SPELL_AURA_APPLIED,Player-1,"Tester",0,0,Player-1,"Tester",0,0,1242974,"Arcane Salvo",64,BUFF',
            '10/30/2026 10:00:01.000-4  SPELL_CAST_START,Player-1,"Tester",0,0,Creature-1,"Dummy",0,0,30451,"Arcane Blast",64',
            '10/30/2026 10:00:03.000-4  SPELL_CAST_SUCCESS,Player-1,"Tester",0,0,Creature-1,"Dummy",0,0,30451,"Arcane Blast",64',
        }
        local output = report({
            { k = "cast", spell = 30451, t = 103, context = context(true),
                recommendation = { src = "kairos", spell = 153626, diagnostic = diagnostic(102, false) } },
        }, log)
        assert.matches("unscored 1: missing cast%-start snapshot", output)
    end)

    it("scores a NOW Touch separately and uses its queued slot for GCD agreement", function()
        local log = {
            '10/30/2026 10:00:00.000-4  SPELL_AURA_APPLIED,Player-1,"Tester",0,0,Player-1,"Tester",0,0,1242974,"Arcane Salvo",64,BUFF',
            '10/30/2026 10:00:01.000-4  SPELL_CAST_SUCCESS,Player-1,"Tester",0,0,Creature-1,"Dummy",0,0,365350,"Arcane Surge",64',
            '10/30/2026 10:00:02.000-4  SPELL_CAST_SUCCESS,Player-1,"Tester",0,0,Creature-1,"Dummy",0,0,44425,"Arcane Barrage",64',
            '10/30/2026 10:00:03.000-4  SPELL_CAST_SUCCESS,Player-1,"Tester",0,0,Creature-1,"Dummy",0,0,153626,"Arcane Orb",64',
        }
        local output = report({
            { k = "cast", spell = 365350, t = 101 },
            { k = "cast", spell = 44425, t = 102 },
            { k = "pick", src = "kairos", spell = 321507, immediate = true, queued = 153626, t = 102.5 },
            { k = "cast", spell = 153626, t = 103 },
        }, log)
        assert.matches("Display including AC fallback:%s+0/1", output)
        assert.matches("GCD slot %(queued behind NOW cues%):%s+1/1", output)
        assert.matches("Immediate cue = off%-GCD reference:%s+1/1", output)
    end)
    it("replays Demonology from log truth and scores captured live and AC picks", function()
        local me, dummy = 'Player-1,"Tester",0,0,', 'Creature-1,"Dummy",0,0,'
        local function line(time, event, dest, rest)
            return ('10/30/2026 10:00:%s-4  %s,%s%s%s'):format(time, event, me, dest, rest)
        end
        local log = {
            line("00.000", "SPELL_ENERGIZE", me, '686,"Shadow Bolt",32,3.0000,0.0000,7,5'),
            line("00.100", "SPELL_AURA_APPLIED", 'Creature-0-1-1-1-55659-1,"Wild Imp",0,0,', '1,"x",1,BUFF'),
            line("00.200", "SPELL_AURA_APPLIED", me, '264173,"Demonic Core",32,BUFF'),
            line("00.300", "SPELL_AURA_APPLIED_DOSE", me, '264173,"Demonic Core",32,BUFF,2'),
            line("02.000", "SPELL_CAST_SUCCESS", dummy, '264178,"Demonbolt",32'),
            line("02.010", "SPELL_AURA_REMOVED_DOSE", me, '264173,"Demonic Core",32,BUFF,1'),
            line("03.000", "SPELL_CAST_START", dummy, '686,"Shadow Bolt",32'),
            line("05.000", "SPELL_CAST_SUCCESS", dummy, '686,"Shadow Bolt",32'),
        }
        local ctx = { session = 1, char = "Tester-Realm", spec = 266, cooldowns = true }
        local function projected()
            return { t = 102, unknown = {}, known = { unknown = {}, [264178] = true, [686] = true },
                talent = { unknown = {} }, ready = {}, remains = {}, castable = { [264178] = true, [686] = true },
                chargesFractional = {}, shards = 3, coreStacks = 2, coreUp = true, imps = 0, enemies = 1,
                gcdMax = 1.25, fightRemains = 300, infernalReady = false, ruinationReady = false, argusUp = false }
        end
        local output = report({
            { k = "shards", n = 3, t = 100.5, context = ctx },
            { k = "cast", spell = 264178, t = 102, combat = true, context = ctx, recommendation = { src = "kairos",
                spell = 264178, label = "soulharvest:demonbolt#2", ac = 686,
                diagnostic = { v = 1, now = 102, projected = projected(), movement = { state = "known", value = false } } } },
            { k = "commit", spell = 686, t = 103, combat = true, context = ctx,
                recommendation = { src = "ac", spell = 686, ac = 686 } },
            { k = "cast", spell = 686, t = 105, combat = true, context = ctx },
        }, log)
        assert.matches("warlock_demonology", output)
        assert.matches("recorder aligned: 2/2", output)
        assert.matches("Talents and learned spells: captured", output)
        assert.matches("Log shard model = client reading:%s+1/1", output)
        assert.matches("Kairos in game%s+= APL on true state: 1/1", output)
        assert.matches("Display including AC fallback:%s+1/2", output)
        assert.matches("AC fallback share of recorded decisions:%s+1/2", output)
        assert.matches("Assisted Combat%s+= APL on true state: 0/2", output)
        assert.matches("Captured evaluation reproduced:%s+1/1", output)
        assert.matches("Hidden Core count would force AC:%s+0/2", output)
    end)

    it("grades the pick on screen before the GCD when a snapshot already forecasts the next one", function()
        local me, dummy = 'Player-1,"Tester",0,0,', 'Creature-1,"Dummy",0,0,'
        local function line(time, event, dest, rest)
            return ('10/30/2026 10:00:%s-4  %s,%s%s%s'):format(time, event, me, dest, rest)
        end
        local log = {
            line("00.000", "SPELL_ENERGIZE", me, '686,"Shadow Bolt",32,1.0000,0.0000,7,50'),
            line("03.000", "SPELL_CAST_START", dummy, '686,"Shadow Bolt",32'),
            line("05.000", "SPELL_CAST_SUCCESS", dummy, '686,"Shadow Bolt",32'),
        }
        local ctx = { session = 1, char = "Tester-Realm", spec = 266, cooldowns = true }
        local forecast = { v = 1, now = 103.01, movement = { state = "known", value = false },
            projected = { t = 104.2, gcdMax = 1.2, unknown = {}, known = { unknown = {}, [686] = true },
                talent = { unknown = {} }, ready = {}, remains = {}, castable = { [686] = true },
                chargesFractional = {}, shards = 1, coreStacks = 0, coreUp = false, imps = 0, enemies = 1,
                fightRemains = 300, infernalReady = false, ruinationReady = false, argusUp = false } }
        local output = report({
            { k = "pick", src = "kairos", spell = 686, t = 102.5, context = ctx },
            -- The client started the GCD at 103.0; the refresh after it forecast Hand.
            { k = "pick", src = "kairos", spell = 105174, t = 103.01, context = ctx },
            { k = "sent", spell = 686, t = 103.02, combat = true, context = ctx,
                recommendation = { src = "kairos", spell = 105174, diagnostic = forecast } },
            { k = "cast", spell = 686, t = 105, combat = true, context = ctx },
        }, log)
        assert.matches("post%-press snapshots replaced by the pick shown before the GCD: 1", output)
        assert.matches("Kairos in game%s+= APL on true state: 1/1", output)
    end)

    it("keeps a cast-time decision at START when a repeat press is rejected mid-cast", function()
        local me, dummy = 'Player-1,"Tester",0,0,', 'Creature-1,"Dummy",0,0,'
        local function line(time, event, dest, rest)
            return ('10/30/2026 10:00:%s-4  %s,%s%s%s'):format(time, event, me, dest, rest)
        end
        local log = {
            line("00.000", "SPELL_ENERGIZE", me, '686,"Shadow Bolt",32,1.0000,0.0000,7,50'),
            line("03.000", "SPELL_CAST_START", dummy, '686,"Shadow Bolt",32'),
            line("03.020", "SPELL_CAST_FAILED", dummy, '686,"Shadow Bolt",32,"Another action is in progress"'),
            line("05.000", "SPELL_CAST_SUCCESS", dummy, '686,"Shadow Bolt",32'),
        }
        local ctx = { session = 1, char = "Tester-Realm", spec = 266, cooldowns = true }
        local output = report({
            { k = "sent", spell = 686, t = 102.9, combat = true, context = ctx,
                recommendation = { src = "kairos", spell = 686, ac = 686 } },
            { k = "cast", spell = 686, t = 105, combat = true, context = ctx },
        }, log)
        assert.matches("Kairos in game%s+= APL on true state: 1/1", output)
        assert.matches("Player cast%s+= APL on true state: 1/1", output)
        -- An interruption still ends the cast; the later success is its own decision.
        log[3] = log[3]:gsub("Another action is in progress", "Interrupted")
        output = report({
            { k = "cast", spell = 686, t = 105, combat = true, context = ctx },
        }, log)
        assert.matches("Player cast%s+= APL on true state: 2/2", output)
    end)

    it("grades the keypress snapshot over a later start commitment in Demonology", function()
        local me, dummy = 'Player-1,"Tester",0,0,', 'Creature-1,"Dummy",0,0,'
        local function line(time, event, dest, rest)
            return ('10/30/2026 10:00:%s-4  %s,%s%s%s'):format(time, event, me, dest, rest)
        end
        local log = {
            line("00.000", "SPELL_ENERGIZE", me, '686,"Shadow Bolt",32,1.0000,0.0000,7,50'),
            line("00.200", "SPELL_AURA_APPLIED", me, '264173,"Demonic Core",32,BUFF'),
            line("03.000", "SPELL_CAST_START", dummy, '686,"Shadow Bolt",32'),
            line("05.000", "SPELL_CAST_SUCCESS", dummy, '686,"Shadow Bolt",32'),
        }
        local ctx = { session = 1, char = "Tester-Realm", spec = 266, cooldowns = true }
        local output = report({
            { k = "sent", spell = 686, t = 102.9, combat = true, context = ctx,
                recommendation = { src = "kairos", spell = 686, ac = 686 } },
            { k = "commit", spell = 686, t = 103, combat = true, context = ctx,
                recommendation = { src = "kairos", spell = 264178, ac = 686 } },
            { k = "cast", spell = 686, t = 105, combat = true, context = ctx },
        }, log)
        -- Demonbolt is never cast in this log, so the reference is Shadow Bolt: what the
        -- keypress showed, not the later start commitment.
        assert.matches("Kairos in game%s+= APL on true state: 1/1", output)
        assert.matches("snapshots at the keypress: 1 of 1", output)
    end)
end)
