-- Flight recorder (SPEC §7.6): a ring buffer of picks and own casts in KairosDB.flight,
-- for the offline replay harness. Picks are logged only when they change.
local _, Kairos = ...
local Recorder = Kairos:NewModule("Recorder")
local Signal = Kairos.Signal

-- Fight traces add a few hundred entries per pull, so keep several pulls' worth.
Recorder.SIZE = 5000
Recorder.HISTORY = 20       -- recent evaluations kept (by reference) for OnScreen
Recorder.PRESS_LOOKBACK = 1 -- seconds after a GCD start that a commit still predates it
Recorder.history = {}

local function buffer()
    local flight = Kairos.db.flight
    flight.entries = flight.entries or {}
    flight.pos = flight.pos or 0
    return flight
end

function Recorder:Enabled()
    return Kairos.db and Kairos.db.global.recorder
end

function Recorder:Push(entry)
    if not self:Enabled() then return end
    local flight = buffer()
    flight.sequence = (flight.sequence or 0) + 1
    entry.seq = flight.sequence
    entry.context = self.context
    flight.pos = flight.pos % self.SIZE + 1
    entry.t = entry.t or GetTime()
    flight.entries[flight.pos] = entry
    local pull = self.pull
    if pull and (entry.k == "sent" or entry.k == "commit" or entry.k == "cast") then
        if #pull.entries < Kairos.db.global.recorderPullEntries then
            pull.entries[#pull.entries + 1] = entry
        else
            pull.dropped = (pull.dropped or 0) + 1
        end
    end
end

--- Entries oldest first.
function Recorder:Entries()
    local flight = buffer()
    local out, count = {}, #flight.entries
    for i = 1, count do
        out[i] = flight.entries[(flight.pos + i - 1) % count + 1]
    end
    return out
end

function Recorder:Clear()
    Kairos.db.flight = {}
    self.last, self.latest, self.pull, self.context, self.history = nil, nil, nil, nil, {}
    self.lastAC = nil
    self:Context()
end

-- Do not persist a secret, even if a future adapter accidentally includes one in
-- its diagnostics. Keys are checked before indexing the output; depth bounds cycles.
local function copy(value, depth)
    if Signal.IsSecret(value) then return nil end
    local kind = type(value)
    if kind == "number" or kind == "string" or kind == "boolean" then return value end
    if kind ~= "table" or (depth or 0) >= 8 then return nil end
    local out = {}
    for key, child in pairs(value) do
        if not Signal.IsSecret(key) and (type(key) == "number" or type(key) == "string") then
            out[key] = copy(child, (depth or 0) + 1)
        end
    end
    return out
end

function Recorder:Context(newSession)
    local db = Kairos.DB
    if not db.activeChar then return end
    local flight = buffer()
    if newSession or not self.context then
        flight.session = (flight.session or 0) + 1
    end
    local _, build = GetBuildInfo()
    -- Contexts are immutable, so old entries preserve the toggle state they saw.
    self.context = { session = flight.session, char = db.activeChar, spec = Kairos.specID,
        build = build, ver = Kairos.version, cooldowns = Kairos.Toggles:Get("cooldowns") }
end

function Recorder:BeginPull()
    if not self:Enabled() or self.pull then return end
    local flight = buffer()
    flight.pulls = flight.pulls or {}
    while #flight.pulls >= Kairos.db.global.recorderPulls do
        table.remove(flight.pulls, 1)
        flight.retiredPulls = (flight.retiredPulls or 0) + 1
    end
    self.pull = { t = GetTime(), at = time(), context = self.context, entries = {} }
    flight.pulls[#flight.pulls + 1] = self.pull
end

function Recorder:EndPull(reason)
    if self.pull then self.pull.finish, self.pull.reason = GetTime(), reason end
    self.pull = nil
end

-- The client starts the GCD at the keypress, and the throttled refresh can evaluate
-- the next GCD before SENT/START/SUCCEEDED arrive (12.1.5: 119 of 224 keypress
-- snapshots in a dungeon). The instruction on screen at the press is the latest
-- evaluation from before the GCD began; the later one is kept only as a forecast.
function Recorder:OnScreen()
    local latest = self.latest
    local now = Signal.Read(GetTime)
    local gcd = Signal.Read(C_Spell and C_Spell.GetSpellCooldown, 61304)
    local start = Signal.ReadField(gcd.state == "known" and gcd.value or nil, "startTime")
    if not latest or now.state ~= "known" or start.state ~= "known" or type(start.value) ~= "number"
        or start.value <= 0 or now.value - start.value > self.PRESS_LOOKBACK or latest.t < start.value then
        return latest
    end
    for i = #self.history, 1, -1 do
        if self.history[i].t < start.value then return self.history[i], latest end
    end
    return latest
end

function Recorder:Commit(kind, spellID, channel)
    if not self:Enabled() then return end
    if Kairos.State.inCombat and not self.pull then self:BeginPull() end
    local shown, forecast = self:OnScreen()
    local enabled = Kairos.db.global.enabled
    self:Push({ k = kind, spell = spellID, channel = channel,
        recommendation = enabled and copy(shown) or nil,
        forecast = enabled and forecast and forecast.spell ~= (shown and shown.spell) and forecast.spell or nil,
        combat = Kairos.State.inCombat or nil })
end

function Recorder:NoteRecommendation(rec)
    if not self:Enabled() then self.latest, self.last, self.history = nil, nil, {}; return end
    if not self.context then self:Context() end
    -- Retain the most recent evaluation even when the visible pick is unchanged.
    -- Copy only when persisted, rather than on every throttled display refresh.
    self.latest = { t = GetTime(), src = rec.source == "apl" and "kairos" or rec.source,
        spell = rec.spellID, queued = rec.queuedID, label = rec.label, immediate = rec.immediate,
        paired = rec.pairedID, fields = rec.unknownFields, why = rec.reason,
        diagnostic = rec.diagnostic, ac = Kairos.Assisted:NextSpell() }
    -- References only (no copies): enough refreshes to reach back past a GCD start.
    local history = self.history
    history[#history + 1] = self.latest
    if #history > self.HISTORY then table.remove(history, 1) end
    -- Preserve the AC baseline while Kairos supplies the displayed recommendation.
    -- observed entries never replace the displayed pick in the offline scorer.
    if rec.source == "apl" then
        local ac = self.latest.ac
        if ac ~= self.lastAC then
            self.lastAC = ac
            self:Push({ k = "pick", src = "ac", spell = ac, observed = true,
                combat = Kairos.State.inCombat or nil })
        end
    elseif rec.source == "ac" then
        self.lastAC = rec.spellID
    else
        self.lastAC = nil
    end
    local last = self.last
    if last and last.source == rec.source and last.spellID == rec.spellID
        and last.queuedID == rec.queuedID and last.reason == rec.reason and last.label == rec.label
        and last.offGcdID == rec.offGcdID and last.offGcdLabel == rec.offGcdLabel
        and last.unknownFields == rec.unknownFields and last.immediate == rec.immediate
        and last.queuedLabel == rec.queuedLabel
        and last.pairedID == rec.pairedID and last.pairedLabel == rec.pairedLabel then
        return
    end
    self.last = rec
    self:Push({
        k = "pick",
        src = rec.source == "apl" and "kairos" or rec.source,
        spell = rec.spellID,
        queued = rec.queuedID,
        why = rec.reason,
        label = rec.label,
        offGcd = rec.offGcdID,
        offGcdLabel = rec.offGcdLabel,
        fields = rec.unknownFields,
        immediate = rec.immediate,
        queuedLabel = rec.queuedLabel,
        paired = rec.pairedID,
        pairedLabel = rec.pairedLabel,
        combat = Kairos.State.inCombat or nil,
        diagnostic = copy(rec.diagnostic),
    })
end

function Recorder:OnInit()
    Kairos:On("KAIROS_PLAYER_CAST", function(_, spellID)
        self:Commit("cast", spellID)
    end)
    -- OnInit registers these before Display's OnLogin refresh handlers. Capture
    -- the instruction visible BEFORE the new cast/channel's lookahead replaces it.
    for _, event in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START" }) do
        local channel = event == "UNIT_SPELLCAST_CHANNEL_START"
        Kairos:OnUnit(event, "player", function(_, _, _, spellID)
            if not Signal.IsSecret(spellID) and type(spellID) == "number" then
                self:Commit("commit", spellID, channel)
            end
        end)
    end
    -- The client starts the GCD at the keypress, and a display refresh often lands
    -- before START/SUCCEEDED (81 of 104 Demo snapshots in 12.1.5 already projected past
    -- the press). SENT fires at the press itself, so it holds the instruction on screen.
    Kairos:OnUnit("UNIT_SPELLCAST_SENT", "player", function(_, _, _, _, spellID)
        if not Signal.IsSecret(spellID) and type(spellID) == "number" then self:Commit("sent", spellID) end
    end)
    Kairos:On("KAIROS_PROFILE_CHANGED", function(_, charKey, specID)
        self:EndPull("profile")
        self.latest = nil
        self:Context(true)
        local _, build = GetBuildInfo()
        self:Push({ k = "session", char = charKey, spec = specID, build = build, ver = Kairos.version, at = time() })
        self.last = nil
        self.lastAC = nil
    end)
    Kairos:On("KAIROS_TOGGLE_CHANGED", function(_, key, on)
        self:Context()
        self:Push({ k = "toggle", key = key, on = on })
    end)
    Kairos:On("KAIROS_COMBAT_CHANGED", function(_, on)
        if on then self:BeginPull() else self:EndPull("combat") end
    end)
end
