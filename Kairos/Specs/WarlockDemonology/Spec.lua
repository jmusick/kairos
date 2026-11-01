-- Demonology: IDs and base mechanics from SimC midnight 515f4a3fe9's Warlock
-- module and spell database (12.1.0.69587). Verify in-client with this spec's probe.
local _, Kairos = ...
Kairos:NewSpec(266, {
    key = "WarlockDemonology", name = "Demonology Warlock",
    resource = { power = "SoulShards", token = "SOUL_SHARDS", key = "shards" },
    onGcd = { [686] = true, [105174] = true, [264178] = true, [104316] = true,
        [265187] = true, [264130] = true, [196277] = true, [434506] = true, [434635] = true,
        [1276452] = true, [1276467] = true, [1276672] = true, [30146] = true, [688] = true },
    probe = {
        spells = { "Shadow Bolt", "Hand of Gul'dan", "Demonbolt", "Call Dreadstalkers",
            "Summon Demonic Tyrant", "Power Siphon", "Implosion", "Infernal Bolt", "Ruination",
            "Grimoire: Imp Lord", "Grimoire: Fel Ravager", "Summon Doomguard", "Summon Felguard", "Summon Imp" },
        buffs = { "Demonic Core", "Power Siphon", "Infernal Bolt", "Ruination", "Dominion of Argus" },
        debuffs = { "Doom" }, powers = { "SoulShards", "Mana" },
    },
    -- Implosion: does any count/state field track the Wild Imps the estimate can't see?
    watch = { 264178, 686, 105174, 196277 },
    auraIDs = { ["Demonic Core"] = 264173, ["Power Siphon"] = 334581,
        ["Infernal Bolt"] = 433891, ["Ruination"] = 433885, ["Dominion of Argus"] = 1276166,
        ["Doom"] = 460553 },
})
