-- Arcane Mage (spec 62): metadata. Everything that applies to Arcane alone lives in this
-- folder: this file (IDs and what to probe and trace), Salvo.lua (the Arcane Salvo state
-- model) and APL.lua (the rotation). Generic modules read this through
-- Kairos:CurrentSpec() and never name Arcane spells themselves.
local _, Kairos = ...

Kairos:NewSpec(62, {
    key = "MageArcane",
    name = "Arcane Mage",

    -- What the probe checks and Trace tracks, on top of Assisted Combat's rotation
    -- spells. Names, not IDs: several Midnight spells are new, and the client resolves
    -- names for known spells and auras.
    probe = {
        spells = { "Arcane Blast", "Arcane Barrage", "Arcane Missiles", "Arcane Orb", "Arcane Pulse",
            "Arcane Explosion", "Arcane Surge", "Touch of the Magi", "Evocation", "Presence of Mind",
            "Counterspell", "Arcane Intellect" },
        buffs = { "Clearcasting", "Arcane Salvo", "Arcane Soul", "Intuition", "Arcane Surge", "Presence of Mind",
            "Prismatic Bolt!", "Overpowered Missiles", "Lustrous Gleam", "Cumulative Power", "Arcane Intellect" },
        debuffs = { "Touch of the Magi" },
        powers = { "Mana", "ArcaneCharges" },
    },

    -- Aura spell IDs, which often differ from the spell that applies them (Arcane Surge
    -- casts 365350, its buff is 365362). IDs learned in game win over these.
    auraIDs = {
        ["Clearcasting"] = 263725,
        ["Arcane Salvo"] = 1242974,
        ["Arcane Surge"] = 365362,
        ["Touch of the Magi"] = 210824,
        ["Presence of Mind"] = 205025,
        ["Arcane Intellect"] = 1459,
        ["Overpowered Missiles"] = 1277009,
        ["Cumulative Power"] = 1296930,
        -- From the 12.1.5 combat logs: both make Arcane Barrage glow, as does Salvo at 25.
        ["Arcane Soul"] = 451038,
        ["Intuition"] = 1223797,
        -- The proc that turns Arcane Blast into Prismatic Bolt (1295924).
        ["Prismatic Bolt!"] = 1295942,
    },
})
