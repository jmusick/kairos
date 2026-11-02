-- Turns on combat logging (with advanced logging) so every session leaves a
-- WoWCombatLog file in _retail_\Logs for the offline replay harness (D9). Kairos never
-- reads the log in game. Toggle with the "Combat logging" setting.
local _, Kairos = ...
local CombatLog = Kairos:NewModule("CombatLog")
local Signal = Kairos.Signal

CombatLog.DELAY = 3
-- Logging managers act on these zone events: one turns logging off 1 s after the last
-- of them outside Mythic content, which once left the log off for a minute after a reload
-- mid-pull. Recheck DELAY after each, so the check lands after theirs.
CombatLog.ZONE_EVENTS = { "PLAYER_ENTERING_WORLD", "LOADING_SCREEN_DISABLED", "ZONE_CHANGED_NEW_AREA",
    "UPDATE_INSTANCE_INFO", "PLAYER_DIFFICULTY_CHANGED" }

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
    for _, event in ipairs(self.ZONE_EVENTS) do
        Kairos:On(event, function()
            C_Timer.After(self.DELAY, function() self:Ensure() end)
        end)
    end
end
