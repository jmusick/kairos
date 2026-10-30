-- Own-cast Wild Imp estimate. Explicit times allow offline replay later. These are
-- estimates, not observed guardians: five 2 s Firebolts (100 energy / 20 per cast),
-- scaled by cached haste. SimC 515f4a3fe9, sc_warlock_pets.cpp and sc_spell_data.inc.
-- Travel, target downtime, extra imp talents/procs and haste changes can cause drift.
local _, Kairos = ...
local Demons = Kairos:NewModule("DemonologyDemons")

function Demons:Reset() self.batches = {} end
Demons:Reset()

function Demons:Count(t)
    local n = 0
    for _, batch in ipairs(self.batches) do
        if batch.born <= t and batch.finish > t then n = n + batch.n end
    end
    return n
end

function Demons:Prune(t)
    for i = #self.batches, 1, -1 do
        if self.batches[i].finish <= t or self.batches[i].n <= 0 then table.remove(self.batches, i) end
    end
end

function Demons:Spawn(t, n, haste)
    self.batches[#self.batches + 1] = { born = t, finish = t + 10 / (1 + haste / 100), n = n }
end

function Demons:Consume(t, n)
    self:Prune(t)
    for _, batch in ipairs(self.batches) do
        if batch.born <= t then
            local spent = math.min(batch.n, n)
            batch.n, n = batch.n - spent, n - spent
            if n <= 0 then break end
        end
    end
    self:Prune(t)
end

function Demons:OnCast(id, t, haste)
    self:Prune(t)
    if id == 105174 then self:Spawn(t, 3, haste)
    elseif id == 434635 then self:Spawn(t + 0.4, 3, haste) -- free Ruination summons three imps
    elseif id == 196277 then self.batches = {}
    elseif id == 264130 then self:Consume(t, 2)
    end
end

function Demons:Read(t) return Kairos.Signal.Estimated(self:Count(t)) end
