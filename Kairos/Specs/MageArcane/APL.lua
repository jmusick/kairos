-- Arcane Mage, Sunfury: a HAND-WRITTEN stopgap for the SimC APL until the translator
-- generates it (D4, D21). Source: ActionPriorityLists/default/mage_arcane.simc on the
-- SimC midnight branch at 515f4a3fe9 (2026-09-06). Covered: the cooldowns list and the
-- Sunfury list. Left out: Counterspell (its own icon, D19), potions, racials, trinkets,
-- invoke_external_buff, the fight_remains Barrage, Evocation (mana is secret) and
-- Presence of Mind (not talented in the test build). Touch of the Magi is off the GCD
-- (use_off_gcd=1) and is evaluated separately from the main pick.
--
-- Not in the TOC yet: the in-game state model doesn't provide these fields. Today it's
-- loaded by tools/kairos-dump.lua, which builds the state from a combat log.
local _, Kairos = ...

local Arcane = {
    name = "mage_arcane sunfury (hand-written)",
    simc = "515f4a3fe9",
    spec = 62,
}

local MISSILES, BLAST, BARRAGE, ORB, PULSE = 5143, 30451, 44425, 153626, 260364
local BOLT, SURGE, TOUCH = 1295924, 365350, 321507
Arcane.SPELLS = {
    MISSILES = MISSILES, BLAST = BLAST, BARRAGE = BARRAGE, ORB = ORB, PULSE = PULSE,
    BOLT = BOLT, SURGE = SURGE, TOUCH = TOUCH,
}

-- The state is a plain table:
--   salvo, clearcasting, charges (Arcane Charges), cumulativePower, lustrousGleam: stacks
--   soul, surgeUp, boltReady (the "Prismatic Bolt!" proc): booleans
--   surgeRemains, gcdMax: seconds; enemies: active enemy count
--   prevGcd: spell ID of the last spell cast on the GCD
--   ready[spellID], remains[spellID], chargesFractional[spellID]: cooldown state
--   known[spellID] = false for spells the character doesn't have
--   talent.spellfire_spheres, setS2_4pc: booleans
local function has(s, spellID)
    return not (s.known and s.known[spellID] == false)
end

local function pick(spellID, line)
    return { spellID = spellID, line = line }
end

--- Touch of the Magi (cooldowns list, off the GCD), or nil.
function Arcane:OffGcd(s)
    if not (has(s, TOUCH) and s.ready[TOUCH]) then return nil end
    local trigger = s.prevGcd == BOLT or s.prevGcd == BARRAGE or (s.surgeUp and s.surgeRemains < 12)
    if trigger and (s.surgeUp or (s.remains[SURGE] or 0) > 30) then
        return pick(TOUCH, "cooldowns:touch_of_the_magi")
    end
    return nil
end

--- The main (on-GCD) pick.
function Arcane:Evaluate(s)
    local aoeCount = 2 + 3 * (s.talent.spellfire_spheres and 1 or 0)
    local clearcasting = s.clearcasting > 0

    -- cooldowns
    if has(s, SURGE) and s.ready[SURGE] and (s.lustrousGleam >= 2 or s.lustrousGleam == 0) then
        return pick(SURGE, "cooldowns:arcane_surge")
    end

    -- sunfury
    if clearcasting and s.salvo < 12 then
        return pick(MISSILES, "sunfury:arcane_missiles (salvo<12)")
    end
    if s.boltReady and (not s.setS2_4pc or s.cumulativePower == 8) and not s.soul then
        return pick(BOLT, "sunfury:prismatic_bolt (cumulative_power=8)")
    end
    if s.charges == 4 then
        local orbOrPulse = ((s.chargesFractional[ORB] or 0) > 0.95 or (s.chargesFractional[PULSE] or 0) > 0.95)
            and s.enemies >= aoeCount
        if (orbOrPulse or clearcasting) and s.salvo >= 12 then
            return pick(BARRAGE, "sunfury:arcane_barrage (charges=4, salvo>=12)")
        end
        if (s.surgeRemains > s.gcdMax or not s.surgeUp) and s.salvo == 25 then
            return pick(BARRAGE, "sunfury:arcane_barrage (charges=4, salvo=25)")
        end
    end
    if s.soul then
        return pick(BARRAGE, "sunfury:arcane_barrage (arcane_soul)")
    end
    if s.salvo > 8 and has(s, TOUCH) and s.ready[TOUCH] then
        return pick(BARRAGE, "sunfury:arcane_barrage (salvo>8, touch ready)")
    end
    if s.boltReady then
        return pick(BOLT, "sunfury:prismatic_bolt")
    end
    if has(s, ORB) and (s.chargesFractional[ORB] or 0) >= 1 and s.charges < 3 then
        return pick(ORB, "sunfury:arcane_orb (charges<3)")
    end
    if has(s, PULSE) and (s.chargesFractional[PULSE] or 0) >= 1
        and (s.enemies >= aoeCount - 1 or s.charges < 1) then
        return pick(PULSE, "sunfury:arcane_pulse")
    end
    return pick(BLAST, "sunfury:arcane_blast")
end

-- Not registered with the runtime yet (see the header). The replay reads it from here.
Kairos.ArcaneAPL = Arcane
return Arcane
