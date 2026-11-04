-- Affliction: IDs and base mechanics from SimC midnight 515f4a3fe9's Warlock
-- module and spell database (12.1.0.69587). Verify in-client with this spec's probe.
local _, Kairos = ...
Kairos:NewSpec(265, {
    key = "WarlockAffliction", name = "Affliction Warlock",
    resource = { power = "SoulShards", token = "SOUL_SHARDS", key = "shards" },
    onGcd = { [686] = true, [980] = true, [172] = true, [445468] = true, [1259790] = true,
        [27243] = true, [48181] = true, [1257052] = true, [205180] = true, [442726] = true,
        [1261153] = true, [198590] = true, [688] = true, [108503] = true },
    probe = {
        spells = { "Shadow Bolt", "Drain Soul", "Malefic Grasp", "Agony", "Corruption", "Wither",
            "Unstable Affliction", "Seed of Corruption", "Haunt", "Dark Harvest", "Summon Darkglare",
            "Malevolence", "Summon Imp", "Grimoire of Sacrifice" },
        buffs = { "Nightfall", "Shard Instability", "Cascading Calamity", "Unstable Empowerment",
            "Malevolence", "Grimoire of Sacrifice" },
        debuffs = { "Agony", "Corruption", "Wither", "Unstable Affliction", "Seed of Corruption", "Haunt" },
        powers = { "SoulShards", "Mana" },
    },
    auraIDs = { ["Nightfall"] = 264571, ["Shard Instability"] = 1260269, ["Cascading Calamity"] = 1261125,
        ["Unstable Empowerment"] = 1305774, ["Malevolence"] = 442726, ["Grimoire of Sacrifice"] = 196099,
        ["Agony"] = 980, ["Corruption"] = 146739, ["Wither"] = 445474, ["Unstable Affliction"] = 1259790,
        ["Seed of Corruption"] = 27243, ["Haunt"] = 48181 },
})
