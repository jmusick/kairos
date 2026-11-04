-- Destruction: IDs and base mechanics from SimC midnight 515f4a3fe9's Warlock
-- module and spell database (12.1.0.69587). Verify in-client with this spec's probe.
local _, Kairos = ...
Kairos:NewSpec(267, {
    key = "WarlockDestruction", name = "Destruction Warlock",
    resource = { power = "SoulShards", token = "SOUL_SHARDS", key = "shards" },
    onGcd = { [29722] = true, [116858] = true, [17962] = true, [348] = true, [445468] = true,
        [6353] = true, [17877] = true, [1122] = true, [442726] = true, [152108] = true, [5740] = true,
        [1214467] = true, [80240] = true, [434506] = true, [434635] = true, [688] = true, [108503] = true },
    probe = {
        spells = { "Incinerate", "Chaos Bolt", "Conflagrate", "Immolate", "Wither", "Soul Fire",
            "Shadowburn", "Summon Infernal", "Malevolence", "Cataclysm", "Rain of Fire", "Havoc",
            "Infernal Bolt", "Ruination", "Summon Imp", "Grimoire of Sacrifice" },
        buffs = { "Backdraft", "Fiendish Cruelty", "Malevolence", "Infernal Bolt", "Ruination",
            "Diabolic Ritual: Mother of Chaos", "Diabolic Ritual: Overlord", "Diabolic Ritual: Pit Lord",
            "Demonic Art: Mother of Chaos", "Demonic Art: Overlord", "Demonic Art: Pit Lord",
            "Grimoire of Sacrifice" },
        debuffs = { "Immolate", "Wither", "Havoc" },
        powers = { "SoulShards", "Mana" },
    },
    auraIDs = { ["Backdraft"] = 117828, ["Fiendish Cruelty"] = 1245664, ["Malevolence"] = 442726,
        ["Infernal Bolt"] = 433891, ["Ruination"] = 433885,
        ["Diabolic Ritual: Mother of Chaos"] = 432815, ["Diabolic Ritual: Overlord"] = 431944,
        ["Diabolic Ritual: Pit Lord"] = 432816, ["Demonic Art: Mother of Chaos"] = 432794,
        ["Demonic Art: Overlord"] = 428524, ["Demonic Art: Pit Lord"] = 432795,
        ["Grimoire of Sacrifice"] = 196099, ["Immolate"] = 157736, ["Wither"] = 445474, ["Havoc"] = 80240 },
})
