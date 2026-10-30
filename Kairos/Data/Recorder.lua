-- Flight recorder (SPEC §7.6): a ring buffer of picks and own casts in KairosDB.flight,
-- for the offline replay harness. Picks are logged only when they change.
local _, Kairos = ...
local Recorder = Kairos:NewModule("Recorder")

-- Fight traces add a few hundred entries per pull, so keep several pulls' worth.
Recorder.SIZE = 5000

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
    flight.pos = flight.pos % self.SIZE + 1
    entry.t = entry.t or GetTime()
    flight.entries[flight.pos] = entry
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
    self.last = nil
    self.lastAC = nil
end

function Recorder:NoteRecommendation(rec)
    -- Preserve the AC baseline while Kairos supplies the displayed recommendation.
    -- observed entries never replace the displayed pick in the offline scorer.
    if rec.source == "apl" then
        local ac = Kairos.Assisted:NextSpell()
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
    })
end

function Recorder:OnInit()
    Kairos:On("KAIROS_PLAYER_CAST", function(_, spellID)
        self:Push({ k = "cast", spell = spellID, combat = Kairos.State.inCombat or nil })
    end)
    Kairos:On("KAIROS_PROFILE_CHANGED", function(_, charKey, specID)
        local _, build = GetBuildInfo()
        self:Push({ k = "session", char = charKey, spec = specID, build = build, ver = Kairos.version, at = time() })
        self.last = nil
        self.lastAC = nil
    end)
end
