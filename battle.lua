-- Manual Fire Defensive Siege Weapons
--
-- Rome II's mountable defensive artillery can aim and finish loading but then
-- refuse to release a shot at a live unit. First-person fire and Alt-click
-- ground fire still work. Testing showed that scripted attack_unit() reaches
-- the same broken live-target authorization path, while attack_location()
-- bypasses it and fires normally.
--
-- This script therefore watches the local player's "Attack Unit" commands,
-- identifies which wall-mounted weapon card issued the order, and replaces
-- that rejected unit order with a native attack-location order. It remembers
-- a separate target for every emplacement and periodically moves the ground
-- aim point as that target moves.
--
-- The code deliberately does not inspect weapon type. Anything exposed by the
-- engine through units:mountable_artillery_item() is eligible. In vanilla
-- Rome II this covers the culture variants of Bastion Ballista, Onager,
-- Scorpion and Polybolos.

-- This marker uses only base Lua facilities and executes before the CA battle
-- libraries are required. Its presence distinguishes file handoff from a
-- subsequent library/API failure.
pcall(function()
    local file = io.open("manual_fire_defensive_siege_weapons_boot.log", "a")
    if file ~= nil then
        file:write("MFD_BOOT BATTLE_FILE_ENTERED\n")
        file:flush()
        file:close()
    end
end)

require "lua_scripts.Battle_Script_Header"

-- Proven Test-18 tuning. Reissuing controller orders too frequently interrupts
-- aiming/reloading and makes selection unstable. A two-second/one-metre test
-- failed for exactly that reason, so change these values cautiously.
local MFD_LOG_FILE = "manual_fire_defensive_siege_weapons_battle.log"
local MFD_TRACK_INTERVAL_MS = 4000
local MFD_TRACK_INTERVAL_SECONDS = MFD_TRACK_INTERVAL_MS / 1000
local MFD_TRACK_DISTANCE_SQ = 225 -- 15 metres
local MFD_RELEASE_DELAY_MS = 500

-- One prediction interval means: extrapolate one more four-second movement
-- sample along the target's current course. The cap protects against extreme
-- samples caused by very fast units, sharp state changes or bad coordinates.
local MFD_PREDICTION_INTERVALS = 1.0
local MFD_MAX_LEAD_DISTANCE = 30

-- Runtime interfaces and counters.
local mfd_load_id = tostring({})
local mfd_battle = nil
local mfd_bm = nil
local mfd_release_serial = 0
local mfd_discovery_serial = 0

-- UI/source-identification state. Rome II does not emit the normal unit
-- selection callback for mountable artillery, so the script maps visible
-- cards in the Mountable Artillery filter to the engine's mount ordinals.
local mfd_mount_filter_active = false
local mfd_card_panel_x = nil
local mfd_mount_card_map = {}
local mfd_selected_mount_ordinal = nil
local mfd_selected_card_id = nil

-- Per-mount tracking state, indexed by the flattened mount ordinal. Each
-- emplacement can therefore retain a different enemy target.
local mfd_assignments = {}

-- File logging was retained from the diagnostic build because it is valuable
-- when another mod or an unusual settlement breaks the bridge. The pcall
-- wrappers ensure that an unwritable log path cannot stop the battle script.
local function mfd_log(message)
    local line = "MFD_BATTLE load=" .. mfd_load_id ..
        " " .. tostring(message)
    pcall(function()
        local file = io.open(MFD_LOG_FILE, "a")
        if file ~= nil then
            file:write(line)
            file:write("\n")
            file:flush()
            file:close()
        end
    end)
    pcall(function() print(line) end)
end

-- API calls differ slightly across Rome II script contexts. These small safe
-- wrappers keep a missing method or transient UI component from aborting the
-- entire command handler.
local function mfd_unit_type(unit)
    if unit == nil then
        return "nil"
    end
    local ok, value = pcall(function() return unit:type() end)
    if ok then
        return tostring(value)
    end
    return "unavailable"
end

local function mfd_component_text(component, method_name)
    local ok, value = pcall(function()
        return component[method_name](component)
    end)
    if ok and value ~= nil then
        return tostring(value)
    end
    return ""
end

local function mfd_component_position(component)
    local ok, x, y = pcall(function() return component:Position() end)
    if ok and type(x) == "number" and type(y) == "number" then
        return x, y
    end
    return nil, nil
end

-- Walk upward from the clicked filter component to find the left edge of the
-- unit-card panel. This supports a positional fallback if card IDs have not
-- yet been captured when the user clicks a mount card.
local function mfd_find_cards_panel_x(component)
    local current = component
    for depth = 0, 12 do
        if current == nil then
            break
        end
        if mfd_component_text(current, "Id") == "cards_panel" then
            local x = mfd_component_position(current)
            if x ~= nil then
                mfd_card_panel_x = x
                mfd_log("CARD_PANEL_ORIGIN x=" .. tostring(x))
                return x
            end
        end
        local parent_ok, parent_address = pcall(function()
            return current:Parent()
        end)
        if not parent_ok or parent_address == nil then
            break
        end
        local wrap_ok, wrapped = pcall(function()
            return UIComponent(parent_address)
        end)
        if not wrap_ok then
            break
        end
        current = wrapped
    end
    return nil
end

-- Discover the visible unit cards after selecting the Mountable Artillery
-- filter (UI id "cf_buildings"). Sorting by row then X position gives the
-- same ordinal order as mountable_artillery_item() in the tested battle UI.
-- The 150 ms delayed call in the click handler allows the filter redraw to
-- finish before this scan runs.
local function mfd_discover_mount_cards()
    local ok, error_message = pcall(function()
        local address = mfd_battle:ui_component("review_DY")
        if address == nil then
            error("review_DY unavailable")
        end
        local panel = UIComponent(address)
        local cards = {}
        for child_index = 0, panel:ChildCount() - 1 do
            local child_address = panel:Find(child_index)
            if child_address ~= nil then
                local child = UIComponent(child_address)
                if mfd_component_text(child, "CallbackId") == "UnitCard" then
                    local visible_ok, visible = pcall(function()
                        return child:Visible()
                    end)
                    local x, y = mfd_component_position(child)
                    if visible_ok and visible and x ~= nil then
                        cards[#cards + 1] = {
                            id = mfd_component_text(child, "Id"),
                            x = x,
                            y = y or 0,
                        }
                    end
                end
            end
        end
        table.sort(cards, function(left, right)
            if math.abs(left.y - right.y) > 2 then
                return left.y < right.y
            end
            return left.x < right.x
        end)
        mfd_mount_card_map = {}
        for ordinal, card in ipairs(cards) do
            mfd_mount_card_map[card.id] = ordinal
            mfd_log("MOUNT_CARD_MAP id=" .. card.id ..
                " ordinal=" .. tostring(ordinal) ..
                " position=" .. tostring(card.x) .. "," .. tostring(card.y))
        end
        mfd_log("MOUNT_CARD_DISCOVERY count=" .. tostring(#cards))
    end)
    if not ok then
        mfd_log("MOUNT_CARD_DISCOVERY_ERROR detail=" .. tostring(error_message))
    end
end

-- Fallback ordinal calculation for a newly drawn card that is not yet in the
-- ID map. Unit cards have uniform width, so their X offset from cards_panel
-- identifies the one-based slot.
local function mfd_card_position_ordinal(component)
    local x = mfd_component_position(component)
    local width_ok, width = pcall(function() return component:Width() end)
    if x == nil or not width_ok or type(width) ~= "number" or width <= 0 then
        return nil
    end
    if mfd_card_panel_x == nil then
        local panel_ok, panel_address = pcall(function()
            return mfd_battle:ui_component("cards_panel")
        end)
        if panel_ok and panel_address ~= nil then
            local panel = UIComponent(panel_address)
            mfd_card_panel_x = mfd_component_position(panel)
        end
    end
    if mfd_card_panel_x == nil then
        return nil
    end
    local ordinal = math.floor((x - mfd_card_panel_x) / width) + 1
    if ordinal < 1 or ordinal > 32 then
        return nil
    end
    return ordinal
end

-- Global UI click hook installed into events.ComponentLClickUp below.
-- Selecting another card filter or a normal unit clears the remembered mount;
-- this is essential because otherwise an infantry right-click could redirect
-- the last selected wall engine.
function mfd_ui_click(context)
    local ok, error_message = pcall(function()
        local raw_component = context.component
        if raw_component == nil then
            local context_ok, context_component = pcall(function()
                return context:component()
            end)
            if context_ok then
                raw_component = context_component
            end
        end
        if raw_component == nil then
            return
        end
        local component = UIComponent(raw_component)
        local id = mfd_component_text(component, "Id")
        local callback_id = mfd_component_text(component, "CallbackId")

        if id == "cf_buildings" then
            mfd_mount_filter_active = true
            mfd_selected_mount_ordinal = nil
            mfd_selected_card_id = nil
            mfd_find_cards_panel_x(component)
            mfd_discovery_serial = mfd_discovery_serial + 1
            local discovery_name = "mfd_card_discovery_" ..
                tostring(mfd_discovery_serial)
            mfd_bm:callback(mfd_discover_mount_cards, 150, discovery_name)
            mfd_log("MOUNT_FILTER_SELECTED")
            return
        end

        if string.sub(id, 1, 3) == "cf_" then
            mfd_mount_filter_active = false
            mfd_selected_mount_ordinal = nil
            mfd_selected_card_id = nil
            mfd_log("NON_MOUNT_FILTER_SELECTED id=" .. id)
            return
        end

        if callback_id ~= "UnitCard" then
            return
        end

        local ordinal = mfd_mount_card_map[id]
        local source = "map"
        if ordinal == nil and mfd_mount_filter_active then
            ordinal = mfd_card_position_ordinal(component)
            source = "position"
        end

        if ordinal ~= nil then
            mfd_selected_mount_ordinal = ordinal
            mfd_selected_card_id = id
            mfd_log("MOUNT_CARD_SELECTED id=" .. id ..
                " ordinal=" .. tostring(ordinal) .. " source=" .. source)
        else
            -- A normal unit card was selected. Clearing the remembered mount
            -- prevents infantry attack commands from redirecting artillery.
            mfd_selected_mount_ordinal = nil
            mfd_selected_card_id = nil
            mfd_log("NON_MOUNT_CARD_SELECTED id=" .. id)
        end
    end)
    if not ok then
        mfd_log("UI_CLICK_ERROR detail=" .. tostring(error_message))
    end
end

-- Flatten mountable artillery from every army in the local alliance into the
-- same one-based order used by the visible card map. The upper bound is only a
-- defensive guard; enumeration stops as soon as the engine returns nil.
--
-- Restricting this to local_alliance() is intentional: AI defenders have no
-- player card click to identify a source mount, and this mod does not attempt
-- to replace AI target selection.
local function mfd_flat_mounts()
    local records = {}
    local alliances = mfd_battle:alliances()
    local alliance_index = mfd_battle:local_alliance()
    local alliance = alliances:item(alliance_index)
    if alliance == nil then
        return records
    end
    local armies = alliance:armies()
    for army_index = 1, armies:count() do
        local army = armies:item(army_index)
        if army ~= nil then
            local units = army:units()
            if units ~= nil then
                for mount_index = 1, 32 do
                    local mount_ok, mount = pcall(function()
                        return units:mountable_artillery_item(mount_index)
                    end)
                    if not mount_ok or mount == nil then
                        break
                    end
                    records[#records + 1] = {
                        ordinal = #records + 1,
                        army = army,
                        army_index = army_index,
                        mount = mount,
                        mount_index = mount_index,
                        type = mfd_unit_type(mount),
                    }
                end
            end
        end
    end
    return records
end

-- Immediately after the player gives a selected mount an attack order, Rome II
-- reports that mount as non-idle even though the live-unit shot will later be
-- rejected. Combining that state with the clicked card ordinal prevents a
-- stale card selection from controlling the wrong emplacement.
local function mfd_is_non_idle(record)
    local ok, idle = pcall(function() return record.mount:is_idle() end)
    return ok and idle == false
end

-- Resolve exactly one source mount. Earlier experiments safely proved that
-- broadcasting attack_location to all mounts fires them, but it also prevents
-- independent targeting. This card-and-state gate is what makes assignments
-- per emplacement.
local function mfd_resolve_source(records)
    local non_idle = {}
    for _, record in ipairs(records) do
        if mfd_is_non_idle(record) then
            non_idle[#non_idle + 1] = record
        end
    end

    local mapped = nil
    if mfd_selected_mount_ordinal ~= nil then
        mapped = records[mfd_selected_mount_ordinal]
    end

    if mapped ~= nil and mfd_is_non_idle(mapped) then
        mfd_log("SOURCE_RESOLVED method=card_and_state ordinal=" ..
            tostring(mapped.ordinal) .. " card=" ..
            tostring(mfd_selected_card_id) .. " type=" .. mapped.type ..
            " non_idle_count=" .. tostring(#non_idle))
        return mapped
    end

    local candidates = ""
    for _, record in ipairs(non_idle) do
        if candidates ~= "" then
            candidates = candidates .. ","
        end
        candidates = candidates .. tostring(record.ordinal)
    end
    mfd_log("SOURCE_UNRESOLVED selected=" ..
        tostring(mfd_selected_mount_ordinal) .. " non_idle=" .. candidates)
    return nil
end

function mfd_unit_selection_handler(unit, is_selected)
    -- Rome II emits this callback for ordinary army units but not for
    -- mountable defensive artillery. A normal selection therefore proves
    -- that a remembered artillery card must no longer be used as the source.
    if is_selected then
        mfd_selected_mount_ordinal = nil
        mfd_selected_card_id = nil
        mfd_log("NORMAL_UNIT_SELECTED type=" .. mfd_unit_type(unit) ..
            " remembered_mount_cleared=true")
    end
end

local function mfd_release_controller(controller, record, reason)
    -- A script-created unit controller owns every unit added to it. Leaving it
    -- alive made the emplacement unselectable for the rest of the battle.
    -- Releasing after 500 ms gives Rome II enough time to accept the location
    -- order while promptly returning the weapon to player control.
    mfd_release_serial = mfd_release_serial + 1
    local release_name = "mfd_release_" .. tostring(mfd_release_serial)
    mfd_bm:callback(function()
        local ok, error_message = pcall(function()
            controller:release_control()
        end)
        if ok then
            mfd_log("CONTROL_RELEASED ordinal=" .. tostring(record.ordinal) ..
                " reason=" .. reason)
        else
            mfd_log("CONTROL_RELEASE_ERROR ordinal=" ..
                tostring(record.ordinal) .. " detail=" ..
                tostring(error_message))
        end
    end, MFD_RELEASE_DELAY_MS, release_name)
end

-- Submit the one operation that bypasses the bug. Do not replace this with
-- controller:attack_unit(): that call was tested and still failed to release a
-- shot. A fresh one-mount controller is used for each order and then released.
local function mfd_issue_location(record, position, reason)
    local ok, error_message = pcall(function()
        local controller = record.army:create_unit_controller()
        if controller == nil then
            error("create_unit_controller returned nil")
        end
        controller:add_units(record.mount)
        controller:attack_location(position)
        mfd_release_controller(controller, record, reason)
    end)
    if ok then
        mfd_log("ATTACK_LOCATION_ISSUED ordinal=" ..
            tostring(record.ordinal) .. " army=" ..
            tostring(record.army_index) .. " mount_index=" ..
            tostring(record.mount_index) .. " type=" .. record.type ..
            " reason=" .. reason)
        return true
    end
    mfd_log("ATTACK_LOCATION_ERROR ordinal=" .. tostring(record.ordinal) ..
        " reason=" .. reason .. " detail=" .. tostring(error_message))
    return false
end

-- Read a target's current battle vector and cache its horizontal coordinates.
-- The vector itself is used for the first order; X/Z are used by prediction.
local function mfd_target_position(target)
    local ok, position = pcall(function() return target:position() end)
    if not ok or position == nil then
        return nil, nil, nil
    end
    local coordinate_ok, x, z = pcall(function()
        return position:get_x(), position:get_z()
    end)
    if not coordinate_ok then
        return nil, nil, nil
    end
    return position, x, z
end

-- Constant-velocity prediction:
--
--   movement = current_position - previous_sample
--   aim      = current_position + movement * prediction_intervals
--
-- Samples are four seconds apart, so the default predicts four seconds ahead.
-- This is an empirical lead rather than an exact ballistic solution: vanilla
-- bastion projectiles use muzzle_velocity = -1, leaving final launch velocity
-- and flight time to the engine. The predicted vector retains the target's Y
-- coordinate and caps horizontal lead at MFD_MAX_LEAD_DISTANCE.
local function mfd_project_position(position, last_x, last_z, x, z)
    local step_x = x - last_x
    local step_z = z - last_z
    local step_distance = math.sqrt(step_x * step_x + step_z * step_z)
    local lead_x = step_x * MFD_PREDICTION_INTERVALS
    local lead_z = step_z * MFD_PREDICTION_INTERVALS
    local lead_distance = math.sqrt(lead_x * lead_x + lead_z * lead_z)

    if lead_distance > MFD_MAX_LEAD_DISTANCE and lead_distance > 0 then
        local scale = MFD_MAX_LEAD_DISTANCE / lead_distance
        lead_x = lead_x * scale
        lead_z = lead_z * scale
        lead_distance = MFD_MAX_LEAD_DISTANCE
    end

    local predicted_x = x + lead_x
    local predicted_z = z + lead_z
    local predicted = v(0, 0)
    predicted:set_x(predicted_x)
    predicted:set_y(position:get_y())
    predicted:set_z(predicted_z)
    return predicted, predicted_x, predicted_z, step_x, step_z,
        step_distance, lead_distance
end

-- Stop following destroyed, routed-off-map or otherwise invalid targets.
local function mfd_target_is_alive(target)
    local ok, men = pcall(function() return target:number_of_men_alive() end)
    if not ok or type(men) ~= "number" or men <= 0 then
        return false
    end
    local leaving_ok, leaving = pcall(function()
        return target:is_leaving_battle()
    end)
    if leaving_ok and leaving then
        return false
    end
    return true
end

-- Periodic tracker shared by all assignments. It always refreshes the motion
-- sample, but only creates a controller when the target has moved at least 15
-- metres from the actual position used for the preceding order. Separating
-- sample_x/sample_z from last_order_x/last_order_z is important: prediction
-- needs recent velocity while throttling needs cumulative movement.
local function mfd_track_targets()
    local battle_over_ok, battle_over = pcall(function()
        return mfd_battle:is_battle_over()
    end)
    if battle_over_ok and battle_over then
        return
    end

    for ordinal, assignment in pairs(mfd_assignments) do
        if not mfd_target_is_alive(assignment.target) then
            mfd_assignments[ordinal] = nil
            mfd_log("TRACK_STOP ordinal=" .. tostring(ordinal) ..
                " reason=target_invalid")
        else
            local position, x, z = mfd_target_position(assignment.target)
            if position == nil then
                mfd_assignments[ordinal] = nil
                mfd_log("TRACK_STOP ordinal=" .. tostring(ordinal) ..
                    " reason=position_invalid")
            else
                local order_dx = x - assignment.last_order_x
                local order_dz = z - assignment.last_order_z
                local distance_sq = order_dx * order_dx + order_dz * order_dz
                local predicted, predicted_x, predicted_z, step_x, step_z,
                    step_distance, lead_distance = mfd_project_position(
                        position,
                        assignment.sample_x,
                        assignment.sample_z,
                        x,
                        z
                    )
                if distance_sq >= MFD_TRACK_DISTANCE_SQ then
                    if mfd_issue_location(
                        assignment.record, predicted, "TRACK_PREDICTED"
                    ) then
                        assignment.last_order_x = x
                        assignment.last_order_z = z
                        mfd_log("TRACK_PREDICTION ordinal=" ..
                            tostring(ordinal) ..
                            " previous=" .. tostring(assignment.sample_x) ..
                            "," .. tostring(assignment.sample_z) ..
                            " current=" .. tostring(x) .. "," .. tostring(z) ..
                            " projected=" .. tostring(predicted_x) ..
                            "," .. tostring(predicted_z) ..
                            " sample_move=" .. tostring(step_distance) ..
                            " velocity=" ..
                            tostring(step_x / MFD_TRACK_INTERVAL_SECONDS) ..
                            "," ..
                            tostring(step_z / MFD_TRACK_INTERVAL_SECONDS) ..
                            " horizon_s=" ..
                            tostring(MFD_TRACK_INTERVAL_SECONDS *
                                MFD_PREDICTION_INTERVALS) ..
                            " since_order=" ..
                            tostring(math.sqrt(distance_sq)) ..
                            " lead=" .. tostring(lead_distance))
                    end
                end
                assignment.sample_x = x
                assignment.sample_z = z
            end
        end
    end
end

-- Raw battle command hook. Rome II still raises "Attack Unit" even though its
-- built-in authorization later refuses to fire the mounted engine. We capture
-- the target from that event, resolve the selected mount, issue an initial
-- attack_location at the target's current point, and create its tracking state.
-- The first shot cannot be led because only one position sample exists.
function mfd_command_handler(event)
    local ok, error_message = pcall(function()
        if event:get_name() ~= "Attack Unit" then
            return
        end
        local target = event:get_unit()
        if target == nil then
            return
        end
        local position, x, z = mfd_target_position(target)
        if position == nil then
            return
        end

        local records = mfd_flat_mounts()
        local source = mfd_resolve_source(records)
        if source == nil then
            return
        end

        if mfd_issue_location(source, position, "PLAYER") then
            mfd_assignments[source.ordinal] = {
                record = source,
                target = target,
                last_order_x = x,
                last_order_z = z,
                sample_x = x,
                sample_z = z,
            }
            mfd_log("TARGET_ASSIGNED ordinal=" .. tostring(source.ordinal) ..
                " source_type=" .. source.type ..
                " target_type=" .. mfd_unit_type(target) ..
                " current=" .. tostring(x) .. "," .. tostring(z) ..
                " projected=unavailable reason=first_sample")
        end
    end)
    if not ok then
        mfd_log("COMMAND_ERROR detail=" .. tostring(error_message))
    end
end

-- empire_battle is supplied by the campaign custom-battlefield bridge in the
-- loader append. battle_manager supplies safe named callbacks/repeat callbacks;
-- the raw battle interface supplies armies, command hooks and UI access.
mfd_log("SCRIPT_START empire_battle=" .. tostring(empire_battle))
local mfd_init_ok, mfd_init_error = pcall(function()
    if empire_battle == nil then
        error("empire_battle unavailable")
    end
    mfd_battle = empire_battle:new()
    if mfd_battle == nil then
        error("empire_battle:new returned nil")
    end
    mfd_bm = battle_manager:new(mfd_battle)
    if mfd_bm == nil then
        error("battle_manager:new returned nil")
    end
    mfd_battle:register_command_handler(
        "mfd_command_handler"
    )
    mfd_battle:register_unit_selection_handler(
        "mfd_unit_selection_handler"
    )
    if events ~= nil and events.ComponentLClickUp ~= nil then
        table.insert(events.ComponentLClickUp, mfd_ui_click)
    else
        error("ComponentLClickUp unavailable")
    end
    mfd_bm:repeat_callback(
        mfd_track_targets,
        MFD_TRACK_INTERVAL_MS,
        "mfd_target_tracker"
    )
end)

if mfd_init_ok then
    mfd_log("HANDLERS_READY track_interval_ms=" ..
        tostring(MFD_TRACK_INTERVAL_MS) .. " move_threshold=" ..
        tostring(math.sqrt(MFD_TRACK_DISTANCE_SQ)) ..
        " prediction_intervals=" .. tostring(MFD_PREDICTION_INTERVALS) ..
        " max_lead=" .. tostring(MFD_MAX_LEAD_DISTANCE))
else
    mfd_log("INIT_ERROR detail=" .. tostring(mfd_init_error))
end

