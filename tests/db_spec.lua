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
        assert.are.equal(1, Kairos.profile.display.scale)
    end)

    it("switches profiles on a spec change and keeps each spec's settings", function()
        local Kairos = Stub.LoadAddon()
        Kairos.profile.display.scale = 1.5
        Stub.specIndex = 2
        Stub.Fire("PLAYER_SPECIALIZATION_CHANGED", "player")
        assert.are.equal(63, Kairos.specID)
        assert.are.equal(1, Kairos.profile.display.scale)
        Stub.specIndex = 1
        Stub.Fire("PLAYER_SPECIALIZATION_CHANGED", "player")
        assert.are.equal(1.5, Kairos.profile.display.scale)
    end)

    it("ignores spec events for other units", function()
        local Kairos = Stub.LoadAddon()
        Stub.specIndex = 2
        Stub.Fire("PLAYER_SPECIALIZATION_CHANGED", "party1")
        assert.are.equal(62, Kairos.specID)
    end)

    it("fills new defaults into saved data without overwriting it", function()
        Stub.LoadAddon({
            beforeLoad = function()
                KairosDB = {
                    global = { recorder = false },
                    profiles = { ["Tester-Realm"] = { [62] = { display = { scale = 0.8 } } } },
                }
            end,
        })
        assert.is_false(KairosDB.global.recorder)
        assert.are.equal(0.1, KairosDB.global.updateInterval)
        local profile = KairosDB.profiles["Tester-Realm"][62]
        assert.are.equal(0.8, profile.display.scale)
        assert.is_true(profile.display.showQueued)
        assert.is_true(profile.toggles.cooldowns)
    end)
end)
