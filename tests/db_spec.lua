local Stub = require("tests.wow_stub")

describe("DB profiles", function()
    before_each(function()
        Stub.Install()
    end)

    it("creates a profile per character and spec with defaults", function()
        local Kairos = Stub.LoadAddon()
        assert.are.equal(62, Kairos.specID)
        assert.are.equal("Tester-Realm", Kairos.DB.activeChar)
        assert.are.equal(Kairos.profile, KairosDB.profiles["Tester-Realm"][62])
        assert.is_true(Kairos.profile.toggles.cooldowns)
        assert.is_nil(Kairos.profile.display)
        assert.are.equal(1, KairosDB.global.display.scale)
    end)

    it("switches profiles on a spec change and keeps the display for every spec", function()
        local Kairos = Stub.LoadAddon()
        Kairos.profile.toggles.cooldowns = false
        KairosDB.global.display.scale = 1.5
        Stub.specIndex = 2
        Stub.Fire("PLAYER_SPECIALIZATION_CHANGED", "player")
        assert.are.equal(63, Kairos.specID)
        assert.is_true(Kairos.profile.toggles.cooldowns)
        assert.are.equal(1.5, KairosDB.global.display.scale)
        Stub.specIndex = 1
        Stub.Fire("PLAYER_SPECIALIZATION_CHANGED", "player")
        assert.is_false(Kairos.profile.toggles.cooldowns)
    end)

    it("shares the display between characters", function()
        Stub.LoadAddon()
        KairosDB.global.display.point = { "CENTER", "CENTER", 40, -60 }
        local saved = KairosDB
        Stub.Install()
        UnitName = function() return "Alt" end
        local Kairos = Stub.LoadAddon({ beforeLoad = function() KairosDB = saved end })
        assert.are.equal("Alt-Realm", Kairos.DB.activeChar)
        assert.are.same({ "CENTER", "CENTER", 40, -60 }, KairosDB.global.display.point)
    end)

    it("ignores spec events for other units", function()
        local Kairos = Stub.LoadAddon()
        Stub.specIndex = 2
        Stub.Fire("PLAYER_SPECIALIZATION_CHANGED", "party1")
        assert.are.equal(62, Kairos.specID)
    end)

    it("migrates schema 1 data: auto-probe turns on once", function()
        Stub.LoadAddon({
            beforeLoad = function() KairosDB = { schema = 1, global = { autoProbe = false } } end,
        })
        assert.is_true(KairosDB.global.autoProbe)
        assert.are.equal(4, KairosDB.schema)
    end)

    it("migrates schema 2 data: the old 32-pull recorder limit rises, a custom one stays", function()
        Stub.LoadAddon({
            beforeLoad = function() KairosDB = { schema = 2, global = { recorderPulls = 32 } } end,
        })
        assert.are.equal(300, KairosDB.global.recorderPulls)
        Stub.LoadAddon({
            beforeLoad = function() KairosDB = { schema = 2, global = { recorderPulls = 64 } } end,
        })
        assert.are.equal(64, KairosDB.global.recorderPulls)
    end)

    it("migrates schema 3 data: this character's display becomes everyone's", function()
        Stub.LoadAddon({
            beforeLoad = function()
                KairosDB = { schema = 3, global = {}, profiles = {
                    ["Alt-Realm"] = { [62] = { display = { scale = 2 } } },
                    ["Tester-Realm"] = { [63] = { display = { scale = 1.2 } },
                        [62] = { display = { scale = 0.8, point = { "CENTER", "CENTER", 5, 6 } } } },
                } }
            end,
        })
        assert.are.equal(4, KairosDB.schema)
        assert.are.equal(0.8, KairosDB.global.display.scale)
        assert.are.same({ "CENTER", "CENTER", 5, 6 }, KairosDB.global.display.point)
        assert.is_true(KairosDB.global.display.showQueued)
        assert.is_nil(KairosDB.profiles["Alt-Realm"][62].display)
        assert.is_nil(KairosDB.profiles["Tester-Realm"][63].display)
    end)

    it("migrates another character's display when this one has none", function()
        Stub.LoadAddon({
            beforeLoad = function()
                KairosDB = { schema = 3, global = {}, profiles = {
                    ["Zed-Realm"] = { [64] = { display = { scale = 0.6 } } },
                    ["Alt-Realm"] = { [63] = { toggles = {} }, [62] = { display = { scale = 2 } } },
                } }
            end,
        })
        assert.are.equal(2, KairosDB.global.display.scale)
    end)

    it("leaves a choice made after the migration alone", function()
        Stub.LoadAddon({
            beforeLoad = function() KairosDB = { schema = 2, global = { autoProbe = false } } end,
        })
        assert.is_false(KairosDB.global.autoProbe)
    end)

    it("fills new defaults into saved data without overwriting it", function()
        Stub.LoadAddon({
            beforeLoad = function()
                KairosDB = {
                    global = { recorder = false, display = { scale = 0.8 } },
                    profiles = { ["Tester-Realm"] = { [62] = { toggles = {} } } },
                }
            end,
        })
        assert.is_false(KairosDB.global.recorder)
        assert.are.equal(0.1, KairosDB.global.updateInterval)
        assert.are.equal(0.8, KairosDB.global.display.scale)
        assert.is_true(KairosDB.global.display.showQueued)
        assert.is_true(KairosDB.profiles["Tester-Realm"][62].toggles.cooldowns)
    end)
end)
