-- Independent spell-choice reference for the supported pinned Demonology lists.
-- Labels/coverage are golden checked in C#; this exercises actual Lua decisions.
local scratch = ...
local APL = assert(loadfile(scratch .. "/warlock_demonology.lua"))("Kairos", {})
local S = APL.SPELLS
local function referenceList(s, diabolist)
    local function usable(id) return s.known[id] ~= false and s.castable[id] end
    local function ready(id) return usable(id) and s.ready[id] end
    local function hand() return usable(S.HAND) and s.shards >= 3 and not s.ruinationReady end
    if ready(S.SIPHON) and s.imps > 0 and (s.coreStacks <= 1 or s.fightRemains < 10) then return S.SIPHON end
    if hand() and s.argusUp then return S.HAND end
    for _, id in ipairs({ S.IMP_LORD, S.RAVAGER, S.DOOMGUARD }) do
        if ready(id) and s.shards >= 1 then return id end
    end
    local tyrantRemains = s.remains[S.TYRANT] or 0
    if ready(S.DOGS) and s.shards >= 2 and (not diabolist or not s.talent.reign_of_tyranny
        or tyrantRemains >= 20 + s.gcdMax or tyrantRemains <= 12 - s.gcdMax) then return S.DOGS end
    if ready(S.TYRANT) and (not diabolist or s.shards == 5) then return S.TYRANT end
    if ready(S.IMPLOSION) and s.imps >= 6 and (s.enemies > 2 or s.talent.to_hell_and_back) then return S.IMPLOSION end
    if diabolist and usable(S.RUINATION) and s.ruinationReady then return S.RUINATION end
    if hand() and (not diabolist or tyrantRemains > 5 or s.shards == 5) then return S.HAND end
    if usable(S.INFERNAL) and s.infernalReady and s.shards < 3 then return S.INFERNAL end
    if usable(S.DEMONBOLT) and s.coreUp and s.shards < 4 then return S.DEMONBOLT end
    if usable(S.SHADOW) and not s.infernalReady then return S.SHADOW end
    if diabolist and usable(S.INFERNAL) and s.infernalReady then return S.INFERNAL end
end
local function reference(s)
    local id
    if s.talent.diabolic_ritual then id = referenceList(s, true) end
    if not id and s.talent.demonic_soul then id = referenceList(s, false) end
    return id
end
local seed = 266
local function random(n) seed = (seed * 48271) % 2147483647; return seed % n end
local function bit() return random(2) == 1 end
for i = 1, 5000 do
    local stacks = random(5)
    local s = { known = {}, ready = {}, remains = {}, castable = {}, chargesFractional = {},
        shards = random(6), coreStacks = stacks, coreUp = stacks > 0, imps = random(13),
        enemies = random(6), fightRemains = random(320), gcdMax = 0.75 + random(76) / 100,
        argusUp = bit(), ruinationReady = bit(), infernalReady = bit(),
        talent = { diabolic_ritual = bit(), demonic_soul = bit(), reign_of_tyranny = bit(),
            to_hell_and_back = bit(), doom = bit() } }
    for _, id in pairs(S) do
        s.known[id], s.ready[id], s.castable[id], s.remains[id] = bit(), bit(), bit(), random(121)
    end
    local pick = APL:Evaluate(s)
    assert((pick and pick.spellID) == reference(s), "Demonology hero-route mismatch " .. i)
    pick = APL:Leveling(s)
    assert((pick and pick.spellID) == referenceList(s, false), "Demonology leveling mismatch " .. i)
end
assert(APL:OffGcd({ talent = { diabolic_ritual = true } }) == nil, "no supported off-GCD Demo actions")
print("Lua: 10000 Demonology hero-route and leveling reference comparisons passed")
