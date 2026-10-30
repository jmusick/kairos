-- Cumulative Power estimator (Midnight Season 2 Arcane 4-piece). The aura is secret in
-- combat, and the Sunfury APL casts Prismatic Bolt early at exactly 8 stacks. From the
-- 12.1.5 combat logs (docs/probe/12.1.5-70575-cumulative-power.md):
--   * Only Arcane Missiles builds it: +1 as the channel starts, then about +1 per tick,
--     reaching 8 in a full channel (29 of 31 channels from 0).
--   * At 8, the next Arcane Blast or Prismatic Bolt consumes it (every removal was at 8).
--   * It lasts 12 s after the last gain or refresh.
-- Like the Salvo estimator, every method takes an explicit time so the replay can drive it.
local _, Kairos = ...
local CumulativePower = Kairos:NewModule("ArcaneCumulativePower")
local Signal = Kairos.Signal

CumulativePower.SPEC = 62
CumulativePower.MAX = 8
CumulativePower.DURATION = 12
CumulativePower.CHANNEL = 1.7 -- typical full Missiles channel when the client doesn't give the end time
CumulativePower.CHAIN_GAP = 0.1 -- a channel opened this recently belongs to the cast event at hand

CumulativePower.MISSILES = 5143
CumulativePower.CONSUMERS = { [30451] = true, [1295924] = true } -- Arcane Blast, Prismatic Bolt

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

function CumulativePower:ResetState()
    self.stacks = 0
    self.refreshedAt = nil
    self.channel = nil
    self.exact = false
end
CumulativePower:ResetState()

--- Stacks gained by a channel that has run for `fraction` of its length: 1 at the start,
--- the rest spread over the ticks.
local function channelGain(fraction)
    return 1 + (CumulativePower.MAX - 1) * fraction
end

local function channelFraction(channel, t)
    local length = channel.finish - channel.start
    if length <= 0 then return 1 end
    return clamp((t - channel.start) / length, 0, 1)
end

function CumulativePower:Expire(t)
    if self.stacks > 0 and not self.channel and self.refreshedAt and t - self.refreshedAt > self.DURATION then
        self.stacks = 0
        self.exact = true
    end
end

function CumulativePower:CommitChannel(t)
    local channel = self.channel
    if not channel then return end
    self.stacks = math.min(self.MAX, self.stacks + channelGain(channelFraction(channel, t)))
    self.refreshedAt = t
    self.channel = nil
end

--- Whether a Missiles channel was opened (by its CHANNEL_START) within CHAIN_GAP of t.
function CumulativePower:FreshChannel(t)
    return self.channel ~= nil and t - self.channel.start <= self.CHAIN_GAP
end

function CumulativePower:OnCast(spellID, t)
    self:Expire(t)
    -- The channel this Missiles cast belongs to may already be open (CHANNEL_START can
    -- arrive first); don't close it at zero length.
    if spellID == self.MISSILES and self:FreshChannel(t) then return end
    self:CommitChannel(t)
    if self.CONSUMERS[spellID] then
        if self.stacks >= self.MAX - 0.5 then
            self.stacks = 0
            self.exact = true
        end
    elseif spellID == self.MISSILES then
        self.channel = { start = t, finish = t + self.CHANNEL }
        self.exact = false
    end
end

--- A chained Missiles fires its CHANNEL_START before its cast event, while the old
--- channel is still open: close the old one first (see Salvo.lua).
function CumulativePower:OnChannelStart(spellID, t, finish)
    if spellID ~= self.MISSILES then return end
    if self.channel and not self:FreshChannel(t) then self:CommitChannel(t) end
    if not self.channel then
        self.channel = { start = t }
        self.exact = false
    end
    self.channel.finish = finish or (self.channel.start + self.CHANNEL)
end

function CumulativePower:OnChannelStop(t)
    self:CommitChannel(t)
end

--- A readable stack count (out of combat) replaces the estimate.
function CumulativePower:OnTruth(stacks, t)
    self.stacks, self.refreshedAt, self.channel, self.exact = stacks, t, nil, true
end

--- Whole stacks at time t, including the channel in progress and expiry. Rounded: stacks
--- come per tick, and a channel ended at its last tick has run just short of its length.
function CumulativePower:Estimate(t)
    local stacks = self.stacks
    if self.channel then
        stacks = math.min(self.MAX, stacks + channelGain(channelFraction(self.channel, t)))
    elseif stacks > 0 and self.refreshedAt and t - self.refreshedAt > self.DURATION then
        stacks = 0
    end
    return math.floor(stacks + 0.5)
end

function CumulativePower:Read(t)
    local stacks = self:Estimate(t)
    if self.exact and not self.channel then return Signal.Known(stacks) end
    return Signal.Estimated(stacks, 1)
end

-- In game -------------------------------------------------------------------------

function CumulativePower:Active()
    return Kairos.specID == self.SPEC
end

function CumulativePower:Record(why)
    local stacks = self:Estimate(GetTime())
    if stacks == self.lastRecorded then return end
    self.lastRecorded = stacks
    Kairos.Recorder:Push({ k = "cp", n = stacks, why = why })
end

function CumulativePower:OnInit()
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
    Kairos:On("KAIROS_AURA_KNOWN", function(_, name, stacks)
        if not self:Active() or name ~= "Cumulative Power" then return end
        self:OnTruth(stacks, GetTime())
        self:Record("read")
    end)
    Kairos:On("KAIROS_PROFILE_CHANGED", function() self:ResetState() end)
end
