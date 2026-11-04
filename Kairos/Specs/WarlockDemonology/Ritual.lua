-- Diabolic Ritual (Diabolist), from own casts. Explicit times allow offline replay.
-- SimC 515f4a3fe9 and the 12.1.5 log agree: a shard spender (Hand of Gul'dan,
-- Call Dreadstalkers, the Grimoires, Summon Doomguard; free Dreadstalkers too) starts the
-- next ritual if none is running, and every such cast takes 1 s per shard off it, plus
-- 1 s with Infernal Machine while a Demonic Tyrant is out. A ritual lasts 20 s before
-- that; a cast that takes more than is left ends it right after (END_LAG). When it ends, its Demonic
-- Art appears 0.2 s later (replacing any older Art) and the cycle moves on: Overlord,
-- Mother of Chaos, Pit Lord. A Hand consumes the Art only
-- if one was up when its cast began; Mother of Chaos then grants Infernal Bolt and Pit
-- Lord Ruination. A Ruination consumes any Art up at its success. The auras are secret in combat, so readable ones anchor the model and
-- an observed proc names the Art a Hand consumed.
local _, Kairos = ...
local Ritual = Kairos:NewModule("DemonologyRitual")

Ritual.DURATION = 20
Ritual.PER_SHARD = 1
Ritual.MACHINE = 1
-- A Tyrant lives 15 s plus a random extra cast (SimC: 380 ± 220 ms; this takes the mean),
-- and Reign of Tyranny adds 5 s (12.1.5 log: last casts 19.2-20.4 s after 9 summons).
Ritual.TYRANT, Ritual.REIGN = 15.38, 5
Ritual.ART_DELAY = 0.2
-- A ritual a cast overruns ends just after it (12.1.5: 6-31 ms), so a cast inside that gap
-- (Dreadstalkers or a Grimoire pressed with the Hand: 2-6 ms after it in five logs) still
-- counts toward it. One 49 ms after it began the next ritual (Nov. 4), so 0.05 was too long.
Ritual.END_LAG = 0.03
Ritual.ART_LIFE = 60
Ritual.KINDS = { "overlord", "mother", "pit_lord" }
Ritual.AURAS = { overlord = { ritual = 431944, art = 428524 }, mother = { ritual = 432815, art = 432794 },
    pit_lord = { ritual = 432816, art = 432795 } }
Ritual.PROCS = { mother = "infernalReady", pit_lord = "ruinationReady" }

local function after(kind)
    for i, k in ipairs(Ritual.KINDS) do
        if k == kind then return Ritual.KINDS[i % #Ritual.KINDS + 1] end
    end
end

-- ritual = { kind, ends } while one runs; art = { kind, at } once one appears. A nil kind
-- is a ritual or Art whose place in the cycle isn't known yet. known is false until an
-- aura read or a proc says whether anything is running at all.
function Ritual:Reset()
    self.ritual, self.art, self.nextKind, self.known = nil, nil, nil, false
end
Ritual:Reset()

-- What is running at t, without changing the model: the ritual if it hasn't ended, and
-- the newest Art (from a ritual that ended by t, or the one already there). An Art is up
-- once t reaches its `at`; a newer one replaces it.
function Ritual:At(t)
    local ritual, art, nextKind = self.ritual, self.art, self.nextKind
    if ritual and ritual.ends <= t then
        art = { kind = ritual.kind, at = ritual.ends + self.ART_DELAY }
        nextKind = ritual.kind and after(ritual.kind) or nil
        ritual = nil
    end
    if art and art.at + self.ART_LIFE <= t then art = nil end
    return ritual, art, nextKind
end

function Ritual:Resolve(t)
    self.ritual, self.art, self.nextKind = self:At(t)
end

--- The Art up at t: its kind, or false for none. nil when unknown: before an aura read
--- has anchored the model, or for an Art whose place in the cycle isn't known.
function Ritual:ArtAt(t)
    if not self.known then return nil end
    local _, art = self:At(t)
    if not art or art.at > t then return false end
    return art.kind
end

function Ritual:Spend(t, shards, machine)
    self:Resolve(t)
    if not self.ritual then
        self.ritual = { kind = self.nextKind, ends = t + self.DURATION }
        self.nextKind = nil
    end
    local ends = self.ritual.ends - shards * self.PER_SHARD - (machine and self.MACHINE or 0)
    self.ritual.ends = ends > t + self.END_LAG and ends or math.min(self.ritual.ends, t + self.END_LAG)
end

--- A Hand of Gul'dan's success at t, its cast begun at start. Returns the kind of Art it
--- consumed, false for none, or nil when unknown. Only an Art up when the cast began
--- counts, but a newer one that has replaced it by the success is the one consumed.
function Ritual:Hand(t, start, shards, machine)
    local kind = self:ArtAt(start)
    self:Resolve(t)
    local consumed = kind
    if kind ~= false and self.art and self.art.at <= t then
        consumed = self.art.kind
        self.art = nil
    end
    self:Spend(t, shards, machine)
    return consumed
end

--- A Ruination's success at t consumes the Art up then, even one that appeared mid-cast
--- (12.1.5 logs: 9 of 9, every one an Overlord, which grants no proc). It spends nothing.
function Ritual:Ruination(t)
    self:Resolve(t)
    if self.art and self.art.at <= t then self.art = nil end
end

--- A proc that only a consumed Art grants: that Art was `kind`, so the cycle has moved
--- past it. Fixes a cycle position the model had wrong or didn't know.
function Ritual:Learn(kind)
    if self.ritual then self.ritual.kind = after(kind) else self.nextKind = after(kind) end
end

--- Readable auras: each present ritual or Art with its expiration (0 when absent).
--- readings = { [kind] = { ritual = expiresAt or false, art = expiresAt or false } }.
function Ritual:Anchor(t, readings)
    local ritual, art
    for _, kind in ipairs(self.KINDS) do
        local r = readings[kind]
        if r.ritual then ritual = { kind = kind, ends = r.ritual } end
        if r.art then art = { kind = kind, at = r.art - self.ART_LIFE } end
    end
    -- A running ritual is the newest step; with none, the last Art's successor comes next.
    if ritual then self.nextKind = nil
    elseif art then self.nextKind = after(art.kind)
    elseif self.ritual and self.ritual.kind then self.nextKind = after(self.ritual.kind) end
    self.ritual, self.art, self.known = ritual, art, true
    self:Resolve(t)
end
