
-- Manual Fire Defensive Siege Weapons: campaign-to-battle bridge
--
-- Rome II's ordinary campaign Lua state loads lua_scripts/all_scripted.lua but
-- does not expose empire_battle there. add_custom_battlefield() is the supported
-- route for attaching a battle.lua to campaign battles. The enormous radius
-- covers the campaign map; blank loading-screen and battlefield override paths
-- preserve the settlement and armies Rome II already generated. Only the
-- battle script path is supplied.
--
-- Packaging note: this file is an append fragment. Build a complete
-- lua_scripts/all_scripted.lua by copying the current vanilla file byte for
-- byte and appending this fragment. Replacing the vanilla loader with only this
-- fragment will prevent the game's standard campaign scripts from loading.

local MFD_CAMPAIGN_LOG = "manual_fire_defensive_siege_weapons_campaign.log"
local mfd_campaign_load = tostring({})
local mfd_registered = false

-- Direct file logging works even before CA's normal logging helpers are ready.
-- Every operation is protected so a read-only game folder cannot break setup.
local function mfd_campaign_log(message)
    local line = "MFD_CAMPAIGN load=" ..
        mfd_campaign_load .. " " .. tostring(message)
    pcall(function()
        local file = io.open(MFD_CAMPAIGN_LOG, "a")
        if file ~= nil then
            file:write(line)
            file:write("\n")
            file:flush()
            file:close()
        end
    end)
    pcall(function() print(line) end)
end

-- Different Rome II campaign loaders publish game_interface in different
-- places. Check the direct global first, then both observed package names.
local function mfd_game_interface()
    local direct = rawget(_G, "scripting")
    if direct ~= nil and direct.game_interface ~= nil then
        return direct.game_interface
    end
    local episodic = package.loaded["lua_scripts.EpisodicScripting"]
    if episodic ~= nil and episodic.game_interface ~= nil then
        return episodic.game_interface
    end
    local episodic_lower = package.loaded["lua_scripts.episodicscripting"]
    if episodic_lower ~= nil and episodic_lower.game_interface ~= nil then
        return episodic_lower.game_interface
    end
    return nil
end

local function mfd_register_battle_script()
    if mfd_registered then
        return
    end
    local ok, error_message = pcall(function()
        local game = mfd_game_interface()
        if game == nil then
            error("campaign game_interface unavailable")
        end

        -- These are the exact cleanup calls used by the successful Test 18.
        -- They remove registrations left by the preceding experiments before
        -- the proven Test-11 bridge key is registered again. Keeping this list
        -- unchanged avoids introducing another untested loader variation.
        pcall(function() game:remove_custom_battlefield("ian_bastion_test06") end)
        pcall(function() game:remove_custom_battlefield("ian_bastion_test07") end)
        pcall(function() game:remove_custom_battlefield("ian_bastion_test08") end)
        pcall(function() game:remove_custom_battlefield("ian_bastion_test09") end)
        pcall(function() game:remove_custom_battlefield("ian_bastion_test10") end)
        pcall(function() game:remove_custom_battlefield("ian_bastion_test11") end)
        pcall(function() game:remove_custom_battlefield("ian_bastion_test12") end)
        pcall(function() game:remove_custom_battlefield("ian_bastion_test18") end)

        -- Parameters: key, map X, map Z, radius, is_siege, loading screen,
        -- battle script, battlefield override, and battle time limit. The key
        -- and internal script path must match the paths packed below.
        game:add_custom_battlefield(
            "ian_bastion_test11",
            0,
            0,
            1000000,
            false,
            "",
            "ian_bastion_test11/battle.lua",
            "",
            0
        )
        mfd_registered = true
    end)
    if ok then
        mfd_campaign_log("CUSTOM_BATTLEFIELD_READY")
    else
        mfd_campaign_log(
            "CUSTOM_BATTLEFIELD_ERROR detail=" .. tostring(error_message)
        )
    end
end

-- UICreated fires after campaign UI/game_interface initialization. Registering
-- earlier produced a valid loader but no usable bridge during investigation.
mfd_campaign_log("LOADER_START")
if events ~= nil and events.UICreated ~= nil then
    table.insert(events.UICreated, mfd_register_battle_script)
    mfd_campaign_log("UICREATED_HANDLER_READY")
else
    mfd_campaign_log("NO_UICREATED_EVENT")
end

