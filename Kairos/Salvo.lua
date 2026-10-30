-- Arcane Salvo estimator (SPEC §7.2, §10.2). Salvo stacks are secret in combat, so this
-- rebuilds them from what stays readable: the player's own casts and channels, and the
-- Arcane Barrage proc glow, which lights exactly when Salvo reaches 25 (or during Arcane
-- Soul). The estimate re-anchors often: 0 after every Barrage, 25 when the glow lights,
-- and the true value from out-of-combat reads. Numbers come from the 12.1.5 combat log
-- in docs/probe/12.1.5-70575-salvo.md.
--
-- Every method takes an explicit time, so tools/kairos-dump.lua can replay a combat log
-- through this file outside the game.
local _, Kairos = ...
local Salvo = Kairos:NewModule("Salvo")
local Signal = Kairos.Signal

Salvo.SPEC = 62
Salvo.MAX = 25

Salvo.BARRAGE = 44425
Salvo.MISSILES = 5143
Salvo.SURGE = 365350

-- Gain per cast: { expected, low, high }. Missiles is per full channel; its high end
-- covers Overpowered Missiles, which is secret and only ever underestimated.
Salvo.GAINS = {
    [30451] = { 2, 2, 3 },     -- Arcane Blast
    [1295924] = { 6, 4, 6 },   -- Prismatic Bolt
    [5143] = { 11, 8, 21 },    -- Arcane Missiles, full channel
}
-- During Arcane Soul, Barrage adds Salvo instead of consuming it.
Salvo.SOUL_BARRAGE = { 5, 5, 6 }
Salvo.CHANNEL = 1.7 -- typical full Missiles channel when the client doesn't give the end time

-- Arcane Soul starts when Arcane Surge's buff ends, 17.3-17.5 s after the Surge cast, and
-- lasts 4.0-4.1 s (three cycles in the 12.1.5 logs). It's timed from the cast, with a
-- small margin. Inside it, a Barrage glow means Soul, not Salvo at 25.
Salvo.SOUL = { 17.1, 21.5 }

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

--- Sets an exact value (Barrage, the glow, or a readable aura).
function Salvo:Anchor(stacks)
    self.value, self.low, self.high = stacks, stacks, stacks
    self.exact = true
    self.channel = nil
end

function Salvo:ResetState()
    self:Anchor(0)
    self.exact = false -- unknown until the first anchor
    self.lit = false
    self.surgeAt = nil
    self.soulPending = false
end
Salvo:ResetState()

local function channelFraction(channel, t)
    local length = channel.finish - channel.start
    if length <= 0 then return 1 end
    return clamp((t - channel.start) / length, 0, 1)
end

--- Folds the in-progress Missiles channel into the estimate, up to time t.
function Salvo:CommitChannel(t)
    local channel = self.channel
    if not channel then return end
    local gain, fraction = self.GAINS[self.MISSILES], channelFraction(channel, t)
    self.value = self.value + gain[1] * fraction
    self.low = self.low + gain[2] * fraction
    self.high = self.high + gain[3] * fraction
    self.channel = nil
end

--- Whether Arcane Soul is up at time t, timed from the last Arcane Surge cast.
function Salvo:InSoul(t)
    local since = self.surgeAt and (t - self.surgeAt)
    return since ~= nil and since >= self.SOUL[1] and since <= self.SOUL[2]
end

--- Once Soul is over, a glow that's still lit means Salvo reached 25 during Soul (no new
--- glow event arrives in that case, since the glow never went dark).
function Salvo:Settle(t)
    if not self.soulPending or t - self.surgeAt <= self.SOUL[2] then return end
    self.soulPending = false
    if self.lit then self:Anchor(self.MAX) end
end

local function add(self, gain)
    self.value, self.low, self.high = self.value + gain[1], self.low + gain[2], self.high + gain[3]
    self.exact = false
end

function Salvo:OnCast(spellID, t)
    self:Settle(t)
    self:CommitChannel(t)
    if spellID == self.BARRAGE then
        if self:InSoul(t) then
            add(self, self.SOUL_BARRAGE)
        else
            self:Anchor(0)
        end
    elseif spellID == self.SURGE then
        self.surgeAt = t
        self.soulPending = true
    elseif spellID == self.MISSILES then
        self.channel = { start = t, finish = t + self.CHANNEL }
        self.exact = false
    elseif self.GAINS[spellID] then
        add(self, self.GAINS[spellID])
    end
end

--- The client's channel end time, when readable, replaces the typical length.
function Salvo:OnChannelStart(spellID, t, finish)
    if spellID ~= self.MISSILES then return end
    if not self.channel then self.channel = { start = t } end
    self.channel.finish = finish or (self.channel.start + self.CHANNEL)
end

function Salvo:OnChannelStop(t)
    self:Settle(t)
    self:CommitChannel(t)
end

function Salvo:OnGlow(spellID, on, t)
    if spellID ~= self.BARRAGE then return end
    self:Settle(t)
    self.lit = on
    if on and not self:InSoul(t) then
        self:Anchor(self.MAX)
    end
end

--- A readable stack count (out of combat) replaces the estimate.
function Salvo:OnTruth(stacks)
    self:Anchor(stacks)
end

--- value, low, high at time t, including the channel in progress. While Barrage is dark,
--- Salvo is at most 24.
function Salvo:Estimate(t)
    local value, low, high = self.value, self.low, self.high
    local channel = self.channel
    if channel then
        local gain, fraction = self.GAINS[self.MISSILES], channelFraction(channel, t)
        value, low, high = value + gain[1] * fraction, low + gain[2] * fraction, high + gain[3] * fraction
    end
    local cap = self.lit and self.MAX or (self.MAX - 1)
    if self.exact and not channel then cap = self.MAX end
    value = clamp(math.floor(value + 0.5), 0, cap)
    return value, clamp(math.floor(low), 0, value), clamp(math.ceil(high), value, cap)
end

--- A Signal reading: known when anchored with nothing added since, else estimated.
function Salvo:Read(t)
    local value, low, high = self:Estimate(t)
    if self.exact and not self.channel then return Signal.Known(value) end
    local reading = Signal.Estimated(value, math.max(value - low, high - value))
    reading.low, reading.high = low, high
    return reading
end

--- Whether Salvo >= threshold at time t, and whether the bounds make that certain.
function Salvo:AtLeast(threshold, t)
    local value, low, high = self:Estimate(t)
    return value >= threshold, low >= threshold or high < threshold
end

-- In game -------------------------------------------------------------------------

function Salvo:Active()
    return Kairos.specID == self.SPEC
end

function Salvo:Record(why)
    local t = GetTime()
    local value, low, high = self:Estimate(t)
    if value == self.lastValue and low == self.lastLow and high == self.lastHigh then return end
    self.lastValue, self.lastLow, self.lastHigh = value, low, high
    Kairos.Recorder:Push({ k = "salvo", v = value, lo = low, hi = high, why = why })
end

function Salvo:OnInit()
    Kairos:On("KAIROS_PLAYER_CAST", function(_, spellID)
        if not self:Active() then return end
        self:OnCast(spellID, GetTime())
        self:Record("cast")
    end)
    Kairos:OnUnit("UNIT_SPELLCAST_CHANNEL_START", "player", function(_, _, _, spellID)
        if not self:Active() or Signal.IsSecret(spellID) then return end
        local finish = Signal.Read(function() return (select(5, UnitChannelInfo("player"))) end)
        self:OnChannelStart(spellID, GetTime(), finish.state == "known" and finish.value and finish.value / 1000 or nil)
    end)
    Kairos:OnUnit("UNIT_SPELLCAST_CHANNEL_STOP", "player", function()
        if not self:Active() then return end
        self:OnChannelStop(GetTime())
        self:Record("channel")
    end)
    Kairos:On("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", function(_, spellID)
        if not self:Active() or Signal.IsSecret(spellID) then return end
        self:OnGlow(spellID, true, GetTime())
        self:Record("glow")
    end)
    Kairos:On("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE", function(_, spellID)
        if not self:Active() or Signal.IsSecret(spellID) then return end
        self:OnGlow(spellID, false, GetTime())
    end)
    Kairos:On("KAIROS_AURA_KNOWN", function(_, name, stacks)
        if not self:Active() or name ~= "Arcane Salvo" then return end
        self:OnTruth(stacks)
        self:Record("read")
    end)
    Kairos:On("KAIROS_PROFILE_CHANGED", function() self:ResetState() end)
end
