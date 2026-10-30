-- Turns on combat logging (with advanced logging) so every session leaves a
-- WoWCombatLog file in _retail_\Logs for the offline replay harness (D9). Kairos never
-- reads the log in game. Toggle with the "Combat logging" setting.
local _, Kairos = ...
local CombatLog = Kairos:NewModule("CombatLog")
local Signal = Kairos.Signal

CombatLog.DELAY = 3

function CombatLog:Ensure()
    if not Kairos.db.global.combatLog then return end
    local getCVar = C_CVar and C_CVar.GetCVar
    local setCVar = C_CVar and C_CVar.SetCVar
    local advanced = Signal.Read(getCVar, "advancedCombatLogging")
    if setCVar and advanced.state == "known" and advanced.value ~= "1" then
        Signal.Read(setCVar, "advancedCombatLogging", "1")
    end
    local logging = Signal.Read(LoggingCombat)
    if logging.state == "known" and logging.value == false then
        local enabled = Signal.Read(LoggingCombat, true)
        if enabled.state == "known" and enabled.value == true then
            Kairos.Recorder:Push({ k = "log", on = true, at = time() })
        end
    end
end

function CombatLog:OnLogin()
    -- Logging managers may stop between pulls. Recheck at boundaries, never poll
    -- the log file or fight another addon every frame.
    Kairos:On("PLAYER_REGEN_DISABLED", function() self:Ensure() end)
    Kairos:On("ENCOUNTER_START", function() self:Ensure() end)
    Kairos:On("PLAYER_ENTERING_WORLD", function()
        C_Timer.After(self.DELAY, function() self:Ensure() end)
    end)
end
