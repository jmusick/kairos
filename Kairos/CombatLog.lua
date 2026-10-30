-- Turns on combat logging (with advanced logging) so every session leaves a
-- WoWCombatLog file in _retail_\Logs for the offline replay harness (D9). Kairos never
-- reads the log in game. Toggle with the "Combat logging" setting.
local _, Kairos = ...
local CombatLog = Kairos:NewModule("CombatLog")

CombatLog.DELAY = 3

function CombatLog:Ensure()
    if not Kairos.db.global.combatLog then return end
    local getCVar = C_CVar and C_CVar.GetCVar
    local setCVar = C_CVar and C_CVar.SetCVar
    if getCVar and setCVar and getCVar("advancedCombatLogging") ~= "1" then
        setCVar("advancedCombatLogging", "1")
    end
    if LoggingCombat and not LoggingCombat() then
        LoggingCombat(true)
        Kairos.Recorder:Push({ k = "log", on = true, at = time() })
    end
end

function CombatLog:OnLogin()
    Kairos:On("PLAYER_ENTERING_WORLD", function()
        C_Timer.After(self.DELAY, function() self:Ensure() end)
    end)
end
