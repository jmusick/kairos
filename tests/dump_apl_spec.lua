-- Exercise the command end to end with a small offline log and an interleaved
-- recorder stream. In particular, AC observations must never displace live picks.
describe("APL dump live scoring", function()
    local function report(recorded, logOverride)
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
                return function() env.KairosDB = { flight = { entries = recorded, pos = #recorded } } end
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
end)
