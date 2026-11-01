-- Own-cast Wild Imp estimate. Explicit times allow offline replay. These are estimates,
-- not observed guardians: six 2 s Firebolts, scaled by cached haste. SimC 515f4a3fe9
-- implies five (100 energy / 20 per cast), but the 12.1.5 log shows six in 59 of 87 Hand
-- imps (the rest were consumed early), living a median 9.5 s at 29% haste.
-- Implosion with To Hell and Back summons three imps (8 of 8 casts in that log; the talent
-- link is inferred, as the only one taken that matches). Inner Demons adds one imp every
-- 12 s on a timer whose phase isn't visible (it runs out of combat and can shift), so it
-- stays unmodeled. Imps spend energy only while they have a target: in The Everbloom
-- they stopped casting for exactly the 18 s the player was out of combat between pulls
-- and lived on, so the lifetime clock pauses out of combat. Travel, target downtime in
-- combat and haste changes can still cause drift.
local _, Kairos = ...
local Demons = Kairos:NewModule("DemonologyDemons")

-- idle holds out-of-combat spans { from, to }; an open span (no `to`) is ongoing.
function Demons:Reset() self.batches, self.idle = {}, {} end
Demons:Reset()

function Demons:SetCombat(on, t)
    local last = self.idle[#self.idle]
    if on then
        if last and not last.to then last.to = t end
    elseif not last or last.to then
        self.idle[#self.idle + 1] = { from = t }
    end
    while #self.idle > 32 do table.remove(self.idle, 1) end
end

-- Seconds of energy a batch has spent by t: its age minus the time out of combat.
function Demons:Spent(batch, t)
    local idle = 0
    for _, span in ipairs(self.idle) do
        local from, to = math.max(batch.born, span.from), math.min(t, span.to or t)
        if to > from then idle = idle + to - from end
    end
    return t - batch.born - idle
end

function Demons:Count(t)
    local n = 0
    for _, batch in ipairs(self.batches) do
        if batch.born <= t and self:Spent(batch, t) < batch.life then n = n + batch.n end
    end
    return n
end

function Demons:Prune(t)
    for i = #self.batches, 1, -1 do
        local batch = self.batches[i]
        if batch.n <= 0 or (batch.born <= t and self:Spent(batch, t) >= batch.life) then
            table.remove(self.batches, i)
        end
    end
end

function Demons:Spawn(t, n, haste)
    self.batches[#self.batches + 1] = { born = t, life = 12 / (1 + haste / 100), n = n }
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

function Demons:OnCast(id, t, haste, toHellAndBack)
    self:Prune(t)
    if id == 105174 then self:Spawn(t, 3, haste)
    elseif id == 434635 then self:Spawn(t + 0.4, 3, haste) -- free Ruination summons three imps
    elseif id == 196277 then
        self.batches = {}
        if toHellAndBack then self:Spawn(t, 3, haste) end
    elseif id == 264130 then self:Consume(t, 2)
    end
end

function Demons:Read(t) return Kairos.Signal.Estimated(self:Count(t)) end
