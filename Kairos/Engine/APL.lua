-- APL runtime (SPEC §7.3), 0.1.0 shell. Translated spec modules (D4, D21) register here;
-- with no module, or an unsure one, the pick falls back to Assisted Combat (D17, D33).
--
-- Module contract:
--   Kairos.APL:Register(specID, {
--       name = "mage_arcane",
--       Evaluate = function(module, state) return result end,
--   })
--   result = {
--       spellID = n,            -- main pick (what to press when the current cast or GCD ends)
--       line = "actions.x+=/…", -- the APL line that produced it, for /kairos why
--       label = "x:spell (i/k)", -- optional short form: list, action, which top-level clause
--       uncertain = bool,       -- the main pick read unknown fields -> fall back to AC
--       queuedID = n,           -- one-step lookahead pick
--       queuedUncertain = bool, -- the queued pick read unknown fields -> hide it
--       interruptID = n,        -- interrupt available (D19), shown as its own icon
--       offGcdID = n,           -- optional immediate off-GCD cue, separate from the queue
--       offGcdUncertain = bool, -- hide only the off-GCD cue when uncertain
--       pairedID = n,          -- off-GCD follow-up bundled with main, shown overlapping it
--       pairedLabel = string,  -- the follow-up's APL rule; never carried into AC fallback
--       unknownFields = string,-- safe diagnostic names for an uncertain priority path
--   }
local _, Kairos = ...
local APL = Kairos:NewModule("APL")

APL.modules = {}
APL.lastError = nil

function APL:Register(specID, module)
    assert(type(specID) == "number", "APL:Register expects a spec ID")
    assert(type(module) == "table" and type(module.Evaluate) == "function", "APL module needs Evaluate")
    self.modules[specID] = module
end

function APL:ModuleFor(specID)
    return specID and self.modules[specID] or nil
end

local function fallback(reason, rec)
    local spellID = Kairos.Assisted:NextSpell()
    if spellID then
        return {
            source = "ac",
            spellID = spellID,
            interruptID = type(rec) == "table" and rec.interruptID or nil,
            reason = reason,
            unknownFields = type(rec) == "table" and rec.unknownFields or nil,
            offGcdID = type(rec) == "table" and not rec.offGcdUncertain and rec.offGcdID or nil,
            offGcdLabel = type(rec) == "table" and rec.offGcdLabel or nil,
        }
    end
    local available = Kairos.Assisted:IsAvailable()
    return {
        source = "none",
        reason = (available.state == "known" and not available.value and available.failureReason) or reason,
        offGcdID = type(rec) == "table" and not rec.offGcdUncertain and rec.offGcdID or nil,
        offGcdLabel = type(rec) == "table" and rec.offGcdLabel or nil,
        unknownFields = type(rec) == "table" and rec.unknownFields or nil,
    }
end

--- Returns { source = "apl"|"ac"|"none", spellID, queuedID, interruptID, reason, line }.
function APL:Recommend()
    local module = self:ModuleFor(Kairos.specID)
    if not module then return fallback("no-apl") end

    local ok, result = pcall(module.Evaluate, module, Kairos.State)
    if not ok then
        self.lastError = Kairos.Signal.IsSecret(result) and "secret APL error" or tostring(result)
        return fallback("error")
    end
    if type(result) == "table" and result.uncertain then
        return fallback("uncertain", result)
    end
    if type(result) ~= "table" or not result.spellID then
        return fallback("empty", result)
    end
    return {
        source = "apl",
        spellID = result.spellID,
        queuedID = not result.queuedUncertain and result.queuedID or nil,
        interruptID = result.interruptID,
        line = result.line,
        label = result.label,
        offGcdID = not result.offGcdUncertain and result.offGcdID or nil,
        offGcdLabel = result.offGcdLabel,
        unknownFields = result.unknownFields,
        immediate = result.immediate,
        queuedLabel = result.queuedLabel,
        pairedID = result.pairedID,
        pairedLabel = result.pairedLabel,
    }
end
