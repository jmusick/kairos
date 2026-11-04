-- Own-cast Wild Imp estimate. Explicit times allow offline replay. These are estimates,
-- not observed guardians: six 2 s Firebolts, scaled by cached haste. SimC 515f4a3fe9
-- implies five (100 energy / 20 per cast), but the 12.1.5 log shows six in 59 of 87 Hand
-- imps (the rest were consumed early), living a median 9.5 s at 29% haste.
-- Implosion with To Hell and Back summons three imps (8 of 8 casts in that log; the talent
-- link is inferred, as the only one taken that matches). Inner Demons adds one imp every
-- 12.0 s (see Inner below). Imps spend energy only while they have a target: in The Everbloom
-- they stopped casting for exactly the 18 s the player was out of combat between pulls
-- and lived on, and in Bloodmaul Slag Mines they stopped in combat while the player had
-- no live hostile target, so the lifetime clock pauses in both cases. Travel and haste
-- changes can still cause drift.
local _, Kairos = ...
local Demons = Kairos:NewModule("DemonologyDemons")

-- idle holds spans { from, to } without combat or a live hostile target; an open span
-- (no `to`) is ongoing. combat and target are nil until known, which counts as engaged.
function Demons:Reset()
    self.batches, self.idle, self.combat, self.target = {}, {}, nil, nil
    self:Zone()
end

-- Inner Demons summons one imp every 12.0 s. In the 12.1.5 logs its phase held through
-- whole keys (29 minutes in a +10) and moved only at loading screens and reloads; 110 of
-- that key's imps came from it. Its imps can't be seen in combat, but out of combat each
-- one ticks Implosion's readable cast count up by one, on the log's grid to 0.01 s. Two
-- such ticks a whole number of periods apart (with no Hand, Ruination or Implosion just
-- cast) fix the phase, and the estimate then adds an imp every period, in combat too.
-- innerTalent is false when the talent isn't taken, nil when unknown (the replay).
Demons.INNER_PERIOD, Demons.INNER_SLACK, Demons.INNER_SPAN, Demons.SUMMON_QUIET = 12, 0.3, 5, 1

--- A loading screen: the phase may move, and the next readable count starts afresh.
function Demons:Zone()
    self.inner, self.nextInner, self.candidates, self.lastCount = nil, nil, {}, nil
end

local function onGrid(t, phase, period, slack)
    local d = (t - phase) % period
    return math.min(d, period - d) <= slack
end

--- An out-of-combat count tick at t: it fits the known phase, confirms an earlier
--- candidate a whole number of periods back, or becomes a candidate itself.
function Demons:Tick(t)
    if self.innerTalent == false then return end
    local P, slack = self.INNER_PERIOD, self.INNER_SLACK
    if self.inner and onGrid(t, self.inner, P, slack) then return end
    for _, c in ipairs(self.candidates) do
        if t - c > slack and t - c <= self.INNER_SPAN * P + slack and onGrid(t, c, P, slack) then
            self.inner, self.nextInner, self.candidates = t, t + P, {}
            return true
        end
    end
    table.insert(self.candidates, t)
    if #self.candidates > 4 then table.remove(self.candidates, 1) end
end

--- A phase known from elsewhere (the recorder's pull-start note in a replay).
function Demons:SetPhase(t, phase)
    local P = self.INNER_PERIOD
    self.inner, self.nextInner = phase, phase + P * (math.floor((t - phase) / P) + 1)
end

--- Adds the Inner Demons imps due by t once the phase is known.
function Demons:Inner(t)
    while self.inner and self.nextInner <= t do
        self:Spawn(self.nextInner, 1, self.haste or 0)
        self.nextInner = self.nextInner + self.INNER_PERIOD
    end
end

-- A count read after combat (secret during it) is a new baseline, not a tick.
function Demons:SetCombat(on, t) self.combat = on; self.lastCount = nil; self:Engage(t) end
function Demons:SetTarget(on, t) self.target = on; self:Engage(t) end

function Demons:Engage(t)
    local last = self.idle[#self.idle]
    local open = last and not last.to
    local function close()
        -- A pause that hasn't begun (a target back within the grace) never happened.
        if last.from >= t then table.remove(self.idle) else last.to = t end
        open = false
    end
    if self.combat ~= false and self.target ~= false then
        if open then close() end
    elseif self.combat == false then
        -- Leaving combat pauses them at once.
        if not open then self.idle[#self.idle + 1] = { from = t, combat = true }
        else last.from, last.combat = math.min(last.from, t), true end
    else
        -- In combat without a live target: a pull that began targetless ends the combat
        -- pause, and the target pause starts only after the grace (see Engaged).
        if open and last.combat then close() end
        if not open then self.idle[#self.idle + 1] = { from = t + self.TARGET_GRACE } end
    end
    while #self.idle > 32 do table.remove(self.idle, 1) end
end

-- Seconds of energy a batch has spent by t. While idle it spends none and keeps only
-- whole Firebolts (a cast in progress when the pack dies isn't finished); re-engaged it
-- waits REENGAGE seconds before spending again. Carried imps' first cast came a median
-- 2.1-2.3 s after combat start (about 0.7 s plus one cast) in two dungeons; 3 s scored best
-- across the dummy and both dungeons (imp-estimate picks 109/109, 234/246, 187/196 vs
-- 109, 223, 178 without these rules). Treating a lost target like leaving combat, with
-- the same 3 s, took Bloodmaul Slag Mines from 185/200 to 197/200 (0, 1 and 2 s scored
-- 194-195). Fitted on that log; in fresh Skyreach data imps idled and re-engaged as
-- modeled, but the pause changed only 1 of 20 Implosion picks there.
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
    self:Inner(t)
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

Demons.CASTS, Demons.REENGAGE, Demons.RUINATION_DELAY = 6, 3, 0.4
-- Without a hard target the player may still be fighting on a soft (action) target: in three
-- 12.1.5 Mythic+ keys "no target" lasted many seconds while they cast and the imps fought.
-- So the target pause begins only TARGET_GRACE after the later of losing the target and
-- the player's last cast; a cast inside a pause ends it. 4 s took exact imp counts in those
-- keys from 55/104/223 to 121/175/240 and kept Bloodmaul's pause (191/196 picks vs 182
-- with none); 2-3 s left most of the keys' gain behind.
Demons.TARGET_GRACE = 4

function Demons:Spawn(t, n, haste)
    self.batches[#self.batches + 1] = { born = t, life = 12 / (1 + haste / 100), n = n }
end

-- 12.1.5: Implosion's cast count is the Wild Imp count wherever it's readable (out of
-- combat; secret in combat). Imps the estimate missed (Inner Demons, idle carried imps)
-- join as a fresh batch; extras are dropped oldest first. Replaying the traced counts in
-- Shadowmoon Burial Grounds put the estimate within one imp at 77/196 decisions, from 52.
function Demons:Anchor(t, n, haste)
    self.haste = haste
    local quiet = not (self.summonAt and t - self.summonAt < self.SUMMON_QUIET)
    if self.lastCount and n == self.lastCount + 1 and quiet and self:Tick(t) then
        -- A newly confirmed phase: the imp at t is already in the count.
        self.nextInner = t + self.INNER_PERIOD
    end
    self.lastCount = n
    self:Inner(t)
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

-- The player's own cast proves they're fighting, target or not (see TARGET_GRACE).
function Demons:Engaged(t)
    local last = self.idle[#self.idle]
    if self.combat == false or self.target ~= false or not last or last.to or last.combat then return end
    if last.from > t then last.from = t + self.TARGET_GRACE
    else
        last.to = t
        self.idle[#self.idle + 1] = { from = t + self.TARGET_GRACE }
    end
end

function Demons:OnCast(id, t, haste, toHellAndBack)
    self.haste = haste
    self:Engaged(t)
    self:Inner(t)
    self:Prune(t)
    if id == 105174 or id == 434635 or id == 196277 then self.summonAt = t + (id == 434635 and self.RUINATION_DELAY or 0) end
    if id == 105174 then self:Spawn(t, 3, haste)
    elseif id == 434635 then self:Spawn(t + self.RUINATION_DELAY, 3, haste) -- free Ruination summons three imps
    elseif id == 196277 then
        self.batches = {}
        if toHellAndBack then self:Spawn(t, 3, haste) end
    elseif id == 264130 then self:Consume(t, 2)
    end
end

function Demons:Read(t) return Kairos.Signal.Estimated(self:Count(t)) end

-- When each batch alive at t runs out of energy if it stays engaged, as plain data the
-- lookahead (and offline replay) can use. Idle batches spend nothing and aren't listed.
function Demons:Expiries(t)
    self:Inner(t)
    local out, last = {}, self.idle[#self.idle]
    if last and not last.to and last.from <= t then return out end
    for _, batch in ipairs(self.batches) do
        local spent = batch.born <= t and self:Spent(batch, t) or 0
        if spent < batch.life then
            out[#out + 1] = { at = math.max(t, batch.born) + batch.life - spent, n = batch.n }
        end
    end
    return out
end
