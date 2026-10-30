-- Offline only. Load the reference without changing any addon/test source file.
local scratch = assert(arg[1], "verification output directory required")
dofile(scratch .. "/expressions.lua")
local reference = assert(loadfile("translator/Kairos.Translator.Tests/reference/mage_arcane_sunfury.lua"))("Kairos", {})
local generated = assert(loadfile(scratch .. "/mage_arcane.lua"))("Kairos", {})
local control = assert(loadfile(scratch .. "/control.lua"))("Kairos", {})
local SURGE, TOUCH, ORB, PULSE = 365350, 321507, 153626, 1241462
local MISSILES, BLAST, BARRAGE, BOLT = 5143, 30451, 44425, 1295924
local count = 0
local function state(overrides)
    local s = {
        salvo = 0, clearcasting = 0, charges = 2, cumulativePower = 0, lustrousGleam = 0,
        soul = false, surgeUp = false, surgeRemains = 0, boltReady = false,
        enemies = 1, gcdMax = 1.2, prevGcd = nil,
        ready = {}, remains = { [SURGE] = 60 }, chargesFractional = { [ORB] = 0.5 },
        known = { [PULSE] = false }, talent = { spellfire_spheres = true }, setS2_4pc = true,
    }
    for k,v in pairs(overrides or {}) do s[k] = v end
    return s
end
local function compare(s, expected, label)
    local actual = generated:Evaluate(s)
    local baseline = reference:Evaluate(s)
    assert(actual.spellID == baseline.spellID, (label or "parity") .. ": main pick differs, generated line=" .. actual.line)
    if expected then assert(actual.spellID == expected, label or "expected pick") end
    assert(actual.line:match("^actions"), "diagnostic must retain the original SimC line")
    local a, b = generated:OffGcd(s), reference:OffGcd(s)
    assert((a and a.spellID) == (b and b.spellID), "off-GCD pick differs")
    count = count + 1
    return actual
end

-- The reference spec's boundary cases, including ordering between competing picks.
compare(state(), BLAST, "fallback")
compare(state({ ready = { [SURGE] = true, [TOUCH] = true }, clearcasting = 1 }), SURGE, "Surge and Touch ready")
compare(state({ ready = { [SURGE] = true, [TOUCH] = true }, clearcasting = 1, lustrousGleam = 1 }), MISSILES, "hold Surge at one Gleam")
compare(state({ ready = { [SURGE] = true, [TOUCH] = false }, clearcasting = 1 }), MISSILES, "hold Surge for Touch")
compare(state({ ready = { [SURGE] = true, [TOUCH] = true }, clearcasting = 1,
    known = { [TOUCH] = false } }), MISSILES, "hold Surge without learned Touch")
compare(state({ clearcasting = 1, salvo = 11 }), MISSILES, "Missiles below 12")
compare(state({ clearcasting = 1, salvo = 12, charges = 3 }), BLAST, "Missiles boundary")
compare(state({ clearcasting = 1, salvo = 12, charges = 4 }), BARRAGE, "Barrage at 12")
compare(state({ clearcasting = 0, salvo = 12, charges = 4 }), BLAST, "Barrage needs a trigger")
compare(state({ salvo = 12, charges = 4, chargesFractional = { [ORB] = 1.5 } }), BLAST, "AoE threshold below")
compare(state({ salvo = 12, charges = 4, chargesFractional = { [ORB] = 1.5 }, enemies = 5 }), BARRAGE, "AoE threshold met")
compare(state({ salvo = 25, charges = 4 }), BARRAGE, "25 Salvo")
compare(state({ salvo = 25, charges = 4, surgeUp = true, surgeRemains = 5 }), BARRAGE, "25 Salvo in Surge")
compare(state({ salvo = 25, charges = 4, surgeUp = true, surgeRemains = 1 }), BLAST, "Surge expiry")
compare(state({ soul = true }), BARRAGE, "Soul")
compare(state({ soul = true, clearcasting = 1 }), MISSILES, "Missiles before Soul")
compare(state({ salvo = 9, ready = { [TOUCH] = true } }), BARRAGE, "Touch setup")
compare(state({ salvo = 8, ready = { [TOUCH] = true } }), BLAST, "Touch boundary")
local firstBolt = compare(state({ boltReady = true, cumulativePower = 8 }), BOLT, "tier Bolt")
local lastBolt = compare(state({ boltReady = true, cumulativePower = 7 }), BOLT, "fallback Bolt")
assert(firstBolt.line ~= lastBolt.line, "keep the two Bolt rules distinct")
compare(state({ boltReady = true, cumulativePower = 8, soul = true }), BARRAGE, "Soul before Bolt")
compare(state({ boltReady = true, cumulativePower = 3, setS2_4pc = false }), BOLT, "no tier")
compare(state({ chargesFractional = { [ORB] = 1 } }), ORB, "Orb")
compare(state({ chargesFractional = { [ORB] = 1 }, charges = 3 }), BLAST, "Orb charge cap")
compare(state({ charges = 0, chargesFractional = { [PULSE] = 1 } }), BLAST, "unlearned Pulse")
compare(state({ charges = 0, chargesFractional = { [PULSE] = 1 }, known = {} }), PULSE, "Pulse")
local touchState = state({ ready = { [TOUCH] = true }, prevGcd = BARRAGE, remains = { [SURGE] = 45 } })
assert(generated:OffGcd(touchState).spellID == TOUCH)
compare(touchState)
touchState.remains[SURGE] = 20
assert(generated:OffGcd(touchState) == nil)
compare(touchState)
touchState.surgeUp, touchState.surgeRemains, touchState.prevGcd = true, 10, BLAST
assert(generated:OffGcd(touchState).spellID == TOUCH)
compare(touchState)
touchState.ready[TOUCH] = false
assert(generated:OffGcd(touchState) == nil)
compare(touchState)

-- Deterministic combinations exercise interactions beyond the targeted boundaries.
-- Use a small PRNG so this sequence also matches on Lua 5.1 and LuaLS's newer Lua.
local seed = 515
local function random(n)
    seed = (seed * 16807) % 2147483647
    return seed % n
end
local function boolean() return random(2) == 1 end
for _ = 1, 20000 do
    local s = state({
        salvo = random(26), clearcasting = random(4), charges = random(5),
        cumulativePower = random(9), lustrousGleam = random(4),
        soul = boolean(), surgeUp = boolean(), surgeRemains = random(30) * 0.5,
        boltReady = boolean(), enemies = 1 + random(10), gcdMax = 0.75 + random(5) * 0.25,
        prevGcd = ({BLAST, BARRAGE, BOLT, SURGE})[1 + random(4)],
        ready = { [SURGE] = boolean(), [TOUCH] = boolean() }, remains = { [SURGE] = random(90) },
        chargesFractional = { [ORB] = random(201) / 100, [PULSE] = random(201) / 100 },
        known = { [SURGE] = boolean(), [TOUCH] = boolean(), [ORB] = boolean(), [PULSE] = boolean() },
        talent = { spellfire_spheres = boolean() }, setS2_4pc = boolean(),
    })
    compare(s)
end

-- Control fixture: conditional variable set, call priority, call fallthrough,
-- per-evaluation variable reset, and traversing calls in the off-GCD pass.
local s = state({ enemies = 5, charges = 4 })
assert(control:Evaluate(s).spellID == BARRAGE)
s.enemies = 4
assert(control:Evaluate(s).spellID == BLAST)
s.enemies = 11
assert(control:Evaluate(s).spellID == BARRAGE)
s.enemies = 4
assert(control:Evaluate(s).spellID == BLAST, "variable state must not leak")
s.talent.spellfire_spheres = false
assert(control:Evaluate(s).spellID == BARRAGE)
s.talent.spellfire_spheres = 2
assert(control:Evaluate(s).spellID == BLAST, "numeric talent ranks must be preserved")
s.charges = 2
s.chargesFractional[ORB] = 1
assert(control:Evaluate(s).spellID == ORB, "call must fall through")
s.prevGcd, s.ready[TOUCH] = BARRAGE, true
assert(control:OffGcd(s).spellID == TOUCH)
assert(control:Evaluate(s).spellID == ORB, "off-GCD action must not displace main pick")
print("Lua: expression semantics, " .. count .. " reference comparisons, and control-flow checks passed")
assert(loadfile("translator/Kairos.Translator.Tests/verify_demonology.lua"))(scratch)
