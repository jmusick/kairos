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

-- Seconds of energy a batch has spent by t. Out of combat it spends none and keeps only
-- whole Firebolts (a cast in progress when the pack dies isn't finished); back in combat
-- it waits REENGAGE seconds before spending again. Carried imps' first cast came a median
-- 2.1-2.3 s after combat start (about 0.7 s plus one cast) in two dungeons; 3 s scored best
-- across the dummy and both dungeons (imp-estimate picks 109/109, 234/246, 187/196 vs
-- 109, 223, 178 without these rules), so it also absorbs target gaps. Fitted, not validated.
function Demons:Spent(batch, t)
    local spent, cursor, interval = 0, batch.born, batch.life / self.CASTS
    for _, span in ipairs(self.idle) do
        if span.from >= t then break end
        local to = span.to or t
        if to + self.REENGAGE > cursor then
            if span.from > cursor then
                spent = spent + span.from - cursor
                spent = math.floor(spent / interval + 1e-9) * interval
            end
            cursor = math.max(cursor, to + (span.to and self.REENGAGE or 0))
            if cursor >= t then return spent end
        end
    end
    return spent + math.max(0, t - cursor)
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

Demons.CASTS, Demons.REENGAGE = 6, 3

function Demons:Spawn(t, n, haste)
    self.batches[#self.batches + 1] = { born = t, life = 12 / (1 + haste / 100), n = n }
end

-- 12.1.5: Implosion's cast count is the Wild Imp count wherever it's readable (out of
-- combat; secret in combat). Imps the estimate missed (Inner Demons, idle carried imps)
-- join as a fresh batch; extras are dropped oldest first. Replaying the traced counts in
-- Shadowmoon Burial Grounds put the estimate within one imp at 77/196 decisions, from 52.
function Demons:Anchor(t, n, haste)
    self:Prune(t)
    local missing = n - self:Count(t)
    if missing > 0 then
        self:Spawn(t, missing, haste)
    elseif missing < 0 then
        self:Consume(t, -missing)
    end
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
