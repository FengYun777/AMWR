local DATA_FILE = "helper_data.txt"
local DEFAULT_DATA = "return {\n}\n"

-- The script keeps lineups in a separate Lua table so recorded spots survive
-- script reloads and can still be edited by hand when needed.
local window = gui.Window("helper10_window", "helper 1.0", 120, 120, 612, 648)
local col_w = 288
local gap = 24
local left_x = 8
local right_x = left_x + col_w + gap

local playback_h = 188
local visuals_h = 296
local record_h = 372
local manage_h = 88

local settings = gui.Groupbox(window, "Playback", left_x, 8, col_w, playback_h)
local enabled = gui.Checkbox(settings, "helper10_enabled", "Enabled", true)
local execute_key = gui.Keybox(settings, "helper10_execute_key", "Execute key (default LMB)", 1)
local smooth = gui.Slider(settings, "helper10_smooth", "Aim smoothness", 8, 1, 50)
local position_radius = gui.Slider(settings, "helper10_position_radius", "Spot radius", 8, 2, 20)
local show_distance = gui.Slider(settings, "helper10_show_distance", "Show distance", 1800, 100, 5000)

local visuals = gui.Groupbox(window, "Visuals", right_x, 8, col_w, visuals_h)
local show_points = gui.Checkbox(visuals, "helper10_show_points", "Show world labels", true)
local show_spot_ring = gui.Checkbox(visuals, "helper10_show_spot_ring", "Show spot ring", true)
local show_fov = gui.Checkbox(visuals, "helper10_show_fov", "Show FOV ring", false)
local show_status = gui.Checkbox(visuals, "helper10_show_status", "Show playback state", false)
local bg_color = gui.ColorPicker(visuals, "helper10_bg", "Label background", 18, 20, 28, 195)
local glow_color = gui.ColorPicker(visuals, "helper10_glow", "Label glow", 255, 120, 70, 200)
local red = gui.ColorPicker(visuals, "helper10_red", "Aim dot (idle)", 245, 70, 70, 255)
local green = gui.ColorPicker(visuals, "helper10_green", "Aim dot (ready/playing)", 80, 230, 120, 255)

local record_y = 8 + playback_h + gap
local record_box = gui.Groupbox(window, "Record", left_x, record_y, col_w, record_h)
local rec_name = gui.Editbox(record_box, "helper10_rec_name", "Spot name")
local rec_jump = gui.Checkbox(record_box, "helper10_rec_jump", "Jump throw", false)
local rec_walk = gui.Checkbox(record_box, "helper10_rec_walk", "Walk throw", false)
local rec_walk_ticks = gui.Slider(record_box, "helper10_rec_walk_ticks", "Walk ticks", 30, 5, 250)
local rec_walk_dir = gui.Combobox(record_box, "helper10_rec_walk_dir", "Walk direction", "Forward", "Back", "Left", "Right")
local rec_crouch = gui.Checkbox(record_box, "helper10_rec_crouch", "Crouch", false)
local rec_throw = gui.Combobox(record_box, "helper10_rec_throw", "Throw mode", "Left click", "Both buttons", "Right click")
local rec_fov = gui.Slider(record_box, "helper10_rec_fov", "FOV range (deg)", 5, 1, 45)
local rec_save = gui.Checkbox(record_box, "helper10_rec_save", "Save current spot (toggle)", false)

local manage_y = 8 + visuals_h + gap
local manage_box = gui.Groupbox(window, "Manage", right_x, manage_y, col_w, manage_h)
local del_save = gui.Checkbox(manage_box, "helper10_del_save", "Delete aimed spot (toggle)", false)

local rec_save_prev = false
local del_save_prev = false

local weapon_names = {
    [43] = "flashbang",
    [44] = "hegrenade",
    [45] = "smokegrenade",
    [46] = "molotov",
    [48] = "incgrenade"
}

local function normalize_yaw(yaw)
    while yaw > 180 do yaw = yaw - 360 end
    while yaw < -180 do yaw = yaw + 360 end
    return yaw
end

local function point_lock_deg(point)
    if type(point.range) == "number" and point.range > 0 then
        return point.range
    end
    return 5
end

local function angle_delta_to_point(view, point)
    local tp = math.max(-89, math.min(89, point.ang.pitch))
    local ty = normalize_yaw(point.ang.yaw)
    local vp = math.max(-89, math.min(89, view.pitch))
    local vy = normalize_yaw(view.yaw)
    local dp = tp - vp
    local dy = normalize_yaw(ty - vy)
    while dp > 180 do dp = dp - 360 end
    while dp < -180 do dp = dp + 360 end
    return dp, dy
end

local function is_view_in_point_fov(view, point)
    local lock = point_lock_deg(point)
    local pitch_delta, yaw_delta = angle_delta_to_point(view, point)
    return math.abs(pitch_delta) < lock and math.abs(yaw_delta) < lock
end

local function distance_xy(a, b)
    local dx = a.x - b.x
    local dy = a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function point_position(point)
    return Vector3(point.pos.x, point.pos.y, point.pos.z)
end

local function map_name()
    local name = engine.GetMapName()
    return name:match("maps/(.+)%.vpk") or name
end

local function is_fire_grenade(name)
    return name == "molotov" or name == "incgrenade" or name == "firebomb"
end

local function weapon_matches(point_weapon, held_weapon)
    if point_weapon == nil then return true end
    if point_weapon == held_weapon then return true end
    return is_fire_grenade(point_weapon) and is_fire_grenade(held_weapon)
end

local function get_player()
    local player = entities.GetLocalPlayer()
    if player == nil or not player:IsAlive() then return nil end
    return player
end

local function get_grenade(player)
    if player:GetWeaponType() ~= 9 then return nil end
    return weapon_names[player:GetWeaponID()]
end

local function is_execute_down()
    return input.IsButtonDown(execute_key:GetValue())
end

local function load_lineups()
    local ok, raw = pcall(function() return file.Read(DATA_FILE) end)
    if not ok or type(raw) ~= "string" or raw == "" then
        pcall(function() file.Write(DATA_FILE, DEFAULT_DATA) end)
        raw = DEFAULT_DATA
    end
    local chunk, err = load(raw)
    if chunk == nil then
        print("[helper 1.0] failed to parse helper_data.txt: " .. tostring(err))
        return {}
    end
    local success, data = pcall(chunk)
    if not success or type(data) ~= "table" then
        print("[helper 1.0] helper_data.txt must return a table")
        return {}
    end
    return data
end

local lineups = load_lineups()
local loaded_map = ""
local label_alphas = {}

local state = "idle"
local active = nil
local candidate = nil
local aim_pitch = 0
local aim_yaw = 0
local stable_ticks = 0
local playback_tick = 0
local await_key_release = false

local function valid_point(point)
    if type(point) ~= "table" then return false end
    local p, a = point.pos, point.ang
    return type(p) == "table" and type(a) == "table" and
        type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number" and
        type(a.pitch) == "number" and type(a.yaw) == "number"
end

local function reset_playback()
    state = "idle"
    active = nil
    stable_ticks = 0
    playback_tick = 0
end

local function escape_lua_string(value)
    return tostring(value):gsub("\\", "\\\\"):gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\"", "\\\"")
end

local function read_data_file()
    local ok, raw = pcall(function() return file.Read(DATA_FILE) end)
    if ok and type(raw) == "string" and raw ~= "" then return raw end
    return DEFAULT_DATA
end

local function write_data_file(text)
    pcall(function() file.Write(DATA_FILE, text) end)
end

local function build_point_entry(ctx, name)
    return "        {\n" ..
        "            name   = \"" .. escape_lua_string(name) .. "\",\n" ..
        "            pos    = {x=" .. string.format("%.1f", ctx.pos.x) ..
        ", y=" .. string.format("%.1f", ctx.pos.y) ..
        ",  z=" .. string.format("%.1f", ctx.pos.z) .. "},\n" ..
        "            ang    = {pitch=" .. string.format("%.2f", ctx.ang.pitch) ..
        ", yaw=" .. string.format("%.2f", ctx.ang.yaw) .. "},\n" ..
        "            jump   = " .. tostring(rec_jump:GetValue()) .. ",\n" ..
        "            walk   = " .. tostring(rec_walk:GetValue()) .. ",\n" ..
        "            walk_ticks = " .. tostring(math.floor(rec_walk_ticks:GetValue())) .. ",\n" ..
        "            walk_dir   = " .. tostring(rec_walk_dir:GetValue()) .. ",\n" ..
        "            crouch = " .. tostring(rec_crouch:GetValue()) .. ",\n" ..
        "            throw_mode = " .. tostring(rec_throw:GetValue()) .. ",\n" ..
        "            weapon = \"" .. escape_lua_string(ctx.weapon) .. "\",\n" ..
        "            range  = " .. tostring(math.floor(rec_fov:GetValue())) .. ",\n" ..
        "        },\n"
end

local function insert_point_entry(text, map, entry)
    local map_key = '    ["' .. map .. '"] = {'
    local mpos = text:find(map_key, 1, true)
    if mpos then
        local block_start = mpos + #map_key
        local depth = 1
        local ci = block_start
        while ci <= #text and depth > 0 do
            local ch = text:sub(ci, ci)
            if ch == "{" then depth = depth + 1
            elseif ch == "}" then depth = depth - 1 end
            if depth > 0 then ci = ci + 1 end
        end
        return text:sub(1, ci - 1) .. "\n" .. entry .. "    " .. text:sub(ci)
    end
    local new_map = '    ["' .. map .. '"] = {\n' .. entry .. "    },\n"
    return text:gsub("return%s*%{", "return {\n" .. new_map, 1)
end

local function find_entry_bounds(text, point)
    local px_str = string.format("%.1f", point.pos.x)
    local py_str = string.format("%.1f", point.pos.y)
    local search_from = 1
    local found_at = nil
    while true do
        local pos_x = text:find("x=" .. px_str, search_from, true)
        if not pos_x then break end
        local line_end = text:find("\n", pos_x, true) or #text
        local line_str = text:sub(pos_x, line_end)
        if line_str:find("y=" .. py_str, 1, true) then
            found_at = pos_x
            break
        end
        search_from = pos_x + 1
    end
    if not found_at then return nil, nil end

    local entry_start = found_at
    while entry_start > 1 do
        entry_start = entry_start - 1
        if text:sub(entry_start, entry_start + 8) == "        {" then break end
    end

    local depth = 0
    local ci = entry_start
    local entry_end = nil
    while ci <= #text do
        local ch = text:sub(ci, ci)
        if ch == "{" then depth = depth + 1
        elseif ch == "}" then
            depth = depth - 1
            if depth == 0 then
                entry_end = ci + 1
                if text:sub(entry_end, entry_end) == "," then entry_end = entry_end + 1 end
                if text:sub(entry_end, entry_end) == "\n" then entry_end = entry_end + 1 end
                break
            end
        end
        ci = ci + 1
    end
    return entry_start, entry_end
end

local function reload_lineups()
    lineups = load_lineups()
    label_alphas = {}
end

local function get_record_context()
    local player = get_player()
    if player == nil then return nil end
    local weapon = get_grenade(player)
    if weapon == nil then return nil end
    return {
        pos = player:GetAbsOrigin(),
        ang = engine.GetViewAngles(),
        map = map_name(),
        weapon = weapon,
    }
end

local function frame_time()
    local ok, ft = pcall(function() return globals.FrameTime() end)
    if ok and type(ft) == "number" and ft > 0 then return ft end
    return 0.016
end

local function point_key(point)
    return string.format("%d,%d,%d", math.floor(point.pos.x + 0.5), math.floor(point.pos.y + 0.5), math.floor(point.pos.z + 0.5))
end

local function point_label_key(point)
    return point_key(point) .. "|" .. tostring(point.ang.pitch) .. "|" .. tostring(point.ang.yaw)
end

local function update_label_alpha(key, distance, fade_start, fade_end, ft)
    if label_alphas[key] == nil then label_alphas[key] = 0 end
    local target = 255
    if distance <= fade_start then
        target = 255
    elseif distance >= fade_end then
        target = 0
    else
        local t = (distance - fade_start) / (fade_end - fade_start)
        t = math.min(1, math.max(0, t))
        target = math.floor(255 * (1 - t) * (1 - t) * (1 - t))
    end
    local speed = target > label_alphas[key] and (255 / 0.18) or (255 / 0.30)
    local delta = target - label_alphas[key]
    local max_d = speed * ft
    if delta > max_d then delta = max_d elseif delta < -max_d then delta = -max_d end
    label_alphas[key] = label_alphas[key] + delta
    return math.floor(math.max(0, math.min(255, label_alphas[key])))
end

local function find_candidate(player, map, weapon, view)
    local points = lineups[map]
    if type(points) ~= "table" then return nil end
    local origin = player:GetAbsOrigin()
    local best, best_angle = nil, math.huge
    for _, point in ipairs(points) do
        if valid_point(point) and weapon_matches(point.weapon, weapon) then
            local target = point_position(point)
            if distance_xy(origin, target) <= position_radius:GetValue() and math.abs(origin.z - target.z) <= 12 then
                if is_view_in_point_fov(view, point) then
                    local pitch_delta, yaw_delta = angle_delta_to_point(view, point)
                    local angle_distance = math.abs(pitch_delta) + math.abs(yaw_delta)
                    if angle_distance < best_angle then
                        best = point
                        best_angle = angle_distance
                    end
                end
            end
        end
    end
    return best
end

local function clear_controlled_buttons(buttons)
    buttons = bit.band(buttons, bit.bnot(1))
    buttons = bit.band(buttons, bit.bnot(2048))
    buttons = bit.band(buttons, bit.bnot(2))
    buttons = bit.band(buttons, bit.bnot(4))
    buttons = bit.band(buttons, bit.bnot(8))
    buttons = bit.band(buttons, bit.bnot(16))
    buttons = bit.band(buttons, bit.bnot(512))
    buttons = bit.band(buttons, bit.bnot(1024))
    return buttons
end

local function throw_buttons(point, base)
    local mode = point.throw_mode or 0
    if mode == 0 then base = bit.bor(base, 1) end
    if mode == 1 then base = bit.bor(base, bit.bor(1, 2048)) end
    if mode == 2 then base = bit.bor(base, 2048) end
    return base
end

local function charge_ticks_for(point)
    local weapon = point.weapon
    if weapon == "flashbang" then return 4 end
    if weapon == "hegrenade" then return 14 end
    return 8
end

local function weapon_label(weapon)
    if weapon == "flashbang" then return "Flash" end
    if weapon == "hegrenade" then return "HE" end
    if weapon == "smokegrenade" then return "Smoke" end
    if is_fire_grenade(weapon) then return "Molly" end
    return "Nade"
end

local function apply_view(cmd, pitch, yaw)
    pitch = math.max(-89, math.min(89, pitch))
    yaw = normalize_yaw(yaw)
    local ang = EulerAngles(pitch, yaw, 0)
    ang:Normalize()
    ang:Clamp()
    engine.SetViewAngles(ang)
    cmd:SetViewAngles(ang)
    return ang.pitch, ang.yaw
end

local function write_aim(cmd)
    aim_pitch, aim_yaw = apply_view(cmd, aim_pitch, aim_yaw)
    cmd:SetForwardMove(0)
    cmd:SetSideMove(0)
    cmd:SetUpMove(0)
    cmd:SetButtons(clear_controlled_buttons(math.floor(cmd:GetButtons())))
end

local function write_charge(cmd, point)
    aim_pitch, aim_yaw = apply_view(cmd, aim_pitch, aim_yaw)
    cmd:SetForwardMove(0)
    cmd:SetSideMove(0)
    cmd:SetUpMove(0)
    local buttons = throw_buttons(point, clear_controlled_buttons(math.floor(cmd:GetButtons())))
    if point.crouch then buttons = bit.bor(buttons, 4) end
    cmd:SetButtons(buttons)
end

local function write_legacy_run(cmd, point)
    aim_pitch, aim_yaw = apply_view(cmd, aim_pitch, aim_yaw)
    cmd:SetUpMove(0)
    local direction = point.walk_dir or 0
    local buttons = throw_buttons(point, clear_controlled_buttons(math.floor(cmd:GetButtons())))
    if direction == 0 then
        cmd:SetForwardMove(450); cmd:SetSideMove(0); buttons = bit.bor(buttons, 8)
    elseif direction == 1 then
        cmd:SetForwardMove(-450); cmd:SetSideMove(0); buttons = bit.bor(buttons, 16)
    elseif direction == 2 then
        cmd:SetForwardMove(0); cmd:SetSideMove(450); buttons = bit.bor(buttons, 512)
    else
        cmd:SetForwardMove(0); cmd:SetSideMove(-450); buttons = bit.bor(buttons, 1024)
    end
    if point.crouch then buttons = bit.bor(buttons, 4) end
    cmd:SetButtons(buttons)
end

local function write_release(cmd, point, jumping)
    aim_pitch, aim_yaw = apply_view(cmd, aim_pitch, aim_yaw)
    cmd:SetForwardMove(0)
    cmd:SetSideMove(0)
    cmd:SetUpMove(0)
    local buttons = clear_controlled_buttons(math.floor(cmd:GetButtons()))
    if point.crouch and not jumping then buttons = bit.bor(buttons, 4) end
    if jumping then buttons = bit.bor(buttons, 2) end
    cmd:SetButtons(buttons)
end

local function write_current_command(cmd)
    if active == nil then return end
    if state == "aim" then write_aim(cmd) end
    if state == "charge" then write_charge(cmd, active) end
    if state == "legacy_run" then write_legacy_run(cmd, active) end
    if state == "release" then write_release(cmd, active, false) end
    if state == "jump" then write_release(cmd, active, true) end
end

local function start_aim(cmd, point)
    active = point
    state = "aim"
    stable_ticks = 0
    playback_tick = 0
    local view = engine.GetViewAngles()
    aim_pitch = view.pitch
    aim_yaw = normalize_yaw(view.yaw)
end

local function update_playback(cmd, player, map, weapon)
    if map ~= loaded_map then
        lineups = load_lineups()
        loaded_map = map
        reset_playback()
        candidate = nil
        await_key_release = false
        label_alphas = {}
    end

    if await_key_release then
        if not is_execute_down() then await_key_release = false end
        return
    end

    candidate = find_candidate(player, map, weapon, engine.GetViewAngles())
    if state == "idle" then
        if candidate and is_execute_down() then start_aim(cmd, candidate) end
        return
    end

    if not is_execute_down() or active == nil or not weapon_matches(active.weapon, weapon) then
        reset_playback()
        return
    end

    if state == "aim" then
        local view = engine.GetViewAngles()
        if not is_view_in_point_fov(view, active) then
            reset_playback()
            return
        end

        local target_pitch = math.max(-89, math.min(89, active.ang.pitch))
        local target_yaw = normalize_yaw(active.ang.yaw)
        local pitch_delta = target_pitch - aim_pitch
        local yaw_delta = normalize_yaw(target_yaw - aim_yaw)
        local total = math.abs(pitch_delta) + math.abs(yaw_delta)

        local s = math.max(2, smooth:GetValue())
        local max_step = math.min(6, math.max(0.35, 32 / s))
        local step_p = pitch_delta / s
        local step_y = yaw_delta / s

        if math.abs(step_p) > max_step then
            step_p = max_step * (pitch_delta > 0 and 1 or -1)
        end
        if math.abs(step_y) > max_step then
            step_y = max_step * (yaw_delta > 0 and 1 or -1)
        end
        if total > 0.3 then
            if math.abs(step_p) >= math.abs(pitch_delta) then step_p = pitch_delta * 0.5 end
            if math.abs(step_y) >= math.abs(yaw_delta) then step_y = yaw_delta * 0.5 end
        else
            if math.abs(step_p) > math.abs(pitch_delta) then step_p = pitch_delta end
            if math.abs(step_y) > math.abs(yaw_delta) then step_y = yaw_delta end
        end

        aim_pitch = math.max(-89, math.min(89, aim_pitch + step_p))
        aim_yaw = normalize_yaw(aim_yaw + step_y)

        if math.abs(pitch_delta) < 0.15 and math.abs(yaw_delta) < 0.15 then
            stable_ticks = stable_ticks + 1
            if stable_ticks >= 4 then
                aim_pitch = target_pitch
                aim_yaw = target_yaw
                if active.walk then
                    state = "legacy_run"
                    playback_tick = 0
                else
                    state = "charge"
                    playback_tick = 0
                end
            end
        else
            stable_ticks = 0
        end
        return
    end

    if state == "charge" then
        playback_tick = playback_tick + 1
        if playback_tick > charge_ticks_for(active) then state = "release"; playback_tick = 0 end
    elseif state == "legacy_run" then
        playback_tick = playback_tick + 1
        local ticks = active.walk_ticks or 30
        if active.crouch then ticks = ticks * 3 end
        if playback_tick > ticks then state = "release"; playback_tick = 0 end
    elseif state == "release" then
        playback_tick = playback_tick + 1
        if playback_tick > 1 then
            if active.jump then state = "jump"; playback_tick = 0
            else reset_playback(); await_key_release = true end
        end
    elseif state == "jump" then
        playback_tick = playback_tick + 1
        if playback_tick > 5 then reset_playback(); await_key_release = true end
    end
end

callbacks.Register("CreateMove", "helper10_createmove", function(cmd)
    if not enabled:GetValue() then reset_playback(); return end
    local player = get_player()
    if player == nil then reset_playback(); return end
    local weapon = get_grenade(player)
    if weapon == nil then reset_playback(); return end
    update_playback(cmd, player, map_name(), weapon)
    write_current_command(cmd)
end)

callbacks.Register("PreMove", "helper10_premove", function(cmd)
    if enabled:GetValue() and active and is_execute_down() then write_current_command(cmd) end
end)

callbacks.Register("PostMove", "helper10_postmove", function(cmd)
    if enabled:GetValue() and active and is_execute_down() then write_current_command(cmd) end
end)

local function draw_ring(point, radius, r, g, b, a)
    local last_x, last_y = nil, nil
    for i = 0, 48 do
        local angle = i / 48 * math.pi * 2
        local world = Vector3(point.pos.x + math.cos(angle) * radius, point.pos.y + math.sin(angle) * radius, point.pos.z + 5)
        local x, y = client.WorldToScreen(world)
        if x and y and last_x and last_y then
            draw.Color(r, g, b, a)
            draw.Line(last_x, last_y, x, y)
        end
        last_x, last_y = x, y
    end
end

local function draw_ui_panel(x1, y1, x2, y2, alpha, accent_r, accent_g, accent_b)
    local round = 7
    local gr, gg, gb, ga = glow_color:GetValue()
    local br, bg_g, bg_b, bg_a = bg_color:GetValue()
    local scale = alpha / 255

    draw.Color(gr, gg, gb, math.floor(ga * scale * 0.50))
    draw.ShadowRect(x1, y1, x2, y2, 16)

    draw.Color(br, bg_g, bg_b, math.floor(bg_a * scale * 0.55))
    draw.ShadowRect(x1, y1, x2, y2, 8)

    draw.Color(br, bg_g, bg_b, math.floor(bg_a * scale * 0.88))
    draw.RoundedRectFill(x1, y1, x2, y2, round, 1, 1, 1, 1)

    draw.Color(accent_r, accent_g, accent_b, math.floor(90 * scale))
    draw.ShadowRect(x1 + 1, y1 + 1, x2 - 1, y2 - 1, 5)

    draw.Color(accent_r, accent_g, accent_b, math.floor(210 * scale))
    draw.RoundedRect(x1, y1, x2, y2, round, 1, 1, 1, 1)
end

local function measure_label(title, subtitle)
    local tw1, th1 = draw.GetTextSize(title)
    local tw2, th2 = 0, 0
    if subtitle ~= "" then tw2, th2 = draw.GetTextSize(subtitle) end
    local pad_x, pad_y = 11, 7
    local w = math.max(tw1, tw2) + pad_x * 2
    local h = th1 + pad_y * 2
    if subtitle ~= "" then h = h + th2 + 3 end
    return w, h, pad_x, pad_y, th1
end

local function draw_world_label(cx, cy, title, subtitle, alpha, accent_r, accent_g, accent_b)
    local w, h, pad_x, pad_y, th1 = measure_label(title, subtitle)
    local x1 = math.floor(cx - w / 2)
    local y1 = math.floor(cy - h / 2)
    local x2 = x1 + w
    local y2 = y1 + h
    draw_ui_panel(x1, y1, x2, y2, alpha, accent_r, accent_g, accent_b)
    draw.Color(255, 255, 255, alpha)
    draw.Text(x1 + pad_x, y1 + pad_y, title)
    if subtitle ~= "" then
        draw.Color(190, 196, 210, math.floor(alpha * 0.88))
        draw.Text(x1 + pad_x, y1 + pad_y + th1 + 3, subtitle)
    end
    return h
end

local function draw_fov_ring(point, in_range, alpha)
    if not show_fov:GetValue() then return end
    local sw, sh = draw.GetScreenSize()
    local cx = math.floor(sw / 2)
    local cy = math.floor(sh / 2)
    local lock = point_lock_deg(point)
    local scale = (sw / 2) / 45
    local rpx = math.floor(lock * scale)
    local r, g, b, a
    if in_range then
        r, g, b, a = green:GetValue()
        a = math.min(a, math.floor(150 * alpha / 255))
    else
        r, g, b, a = red:GetValue()
        a = math.min(a, math.floor(95 * alpha / 255))
    end
    local prev_x, prev_y = nil, nil
    for i = 0, 64 do
        local angle = i / 64 * math.pi * 2
        local px = cx + math.floor(math.cos(angle) * rpx)
        local py = cy + math.floor(math.sin(angle) * rpx)
        if prev_x and prev_y then
            draw.Color(r, g, b, a)
            draw.Line(prev_x, prev_y, px, py)
        end
        prev_x, prev_y = px, py
    end
end

local function lineup_dot_screen_xy(player, point, view)
    local origin = player:GetAbsOrigin()
    local pitch_rad = math.rad(point.ang.pitch)
    local yaw_rad = math.rad(point.ang.yaw)
    local lx = math.cos(pitch_rad) * math.cos(yaw_rad)
    local ly = math.cos(pitch_rad) * math.sin(yaw_rad)
    local lz = -math.sin(pitch_rad)
    local eye_z = origin.z + 64

    for _, dist in ipairs({500, 350, 800, 200}) do
        local tip = Vector3(origin.x + lx * dist, origin.y + ly * dist, eye_z + lz * dist)
        local tx, ty = client.WorldToScreen(tip)
        if tx and ty then return tx, ty end
    end

    local sw, sh = draw.GetScreenSize()
    local cx = math.floor(sw / 2)
    local cy = math.floor(sh / 2)
    local dpitch, dyaw = angle_delta_to_point(view, point)
    local scale = (sw / 2) / 45
    local tx = cx + math.floor(dyaw * scale)
    local ty = cy + math.floor(dpitch * scale)
    tx = math.max(12, math.min(sw - 12, tx))
    ty = math.max(12, math.min(sh - 12, ty))
    return tx, ty
end

local function draw_aim_glow(x, y, r, g, b, alpha)
    local dot_r = 3
    local layers = {
        { r = dot_r + 4, a = 0.05 },
        { r = dot_r + 3, a = 0.12 },
        { r = dot_r + 2, a = 0.28 },
        { r = dot_r + 1, a = 0.55 },
        { r = dot_r,     a = 1.00 },
    }
    for _, layer in ipairs(layers) do
        draw.Color(r, g, b, math.floor(alpha * layer.a))
        draw.FilledCircle(x, y, layer.r)
    end
end

local function draw_aim_target(player, point, is_playing, in_fov, alpha, view)
    local x, y = lineup_dot_screen_xy(player, point, view)

    local ar, ag, ab = red:GetValue()
    if is_playing or in_fov then ar, ag, ab = green:GetValue() end

    local title = point.name or "Lineup"
    local _, label_h = measure_label(title, "")
    local label_cy = y - 10 - math.floor(label_h / 2)
    draw_world_label(x, label_cy, title, "", alpha, ar, ag, ab)

    draw_aim_glow(x, y, ar, ag, ab, alpha)
    draw.Color(0, 0, 0, math.floor(140 * alpha / 255))
    draw.FilledCircle(x, y, 4)
    draw.Color(ar, ag, ab, alpha)
    draw.OutlinedCircle(x, y, 4)
    draw.FilledCircle(x, y, 2)
end

local function save_current_spot()
    local ctx = get_record_context()
    if ctx == nil then
        print("[helper 1.0] record failed: hold a grenade before saving")
        return
    end
    local name = rec_name:GetString()
    if name == nil or name == "" then name = "New spot" end
    local entry = build_point_entry(ctx, name)
    local text = insert_point_entry(read_data_file(), ctx.map, entry)
    write_data_file(text)
    reload_lineups()
    rec_save:SetValue(false)
    rec_save_prev = false
    print(string.format("[helper 1.0] saved spot \"%s\" on %s", name, ctx.map))
end

local function delete_nearest_spot()
    local player = get_player()
    if player == nil then return end
    local weapon = get_grenade(player)
    if weapon == nil then
        print("[helper 1.0] delete failed: hold a matching grenade first")
        return
    end
    local map = map_name()
    local list = lineups[map]
    if type(list) ~= "table" or #list == 0 then
        print("[helper 1.0] delete failed: no spots on this map")
        return
    end
    local origin = player:GetAbsOrigin()
    local view = engine.GetViewAngles()
    local delete_radius = 8
    local target = nil
    local target_d = nil
    local best_angle = math.huge
    for _, point in ipairs(list) do
        if valid_point(point) and weapon_matches(point.weapon, weapon) then
            local pos = point_position(point)
            local d = distance_xy(origin, pos)
            if d <= delete_radius and math.abs(origin.z - pos.z) <= 12 and is_view_in_point_fov(view, point) then
                local pitch_delta, yaw_delta = angle_delta_to_point(view, point)
                local angle_distance = math.abs(pitch_delta) + math.abs(yaw_delta)
                if angle_distance < best_angle then
                    target = point
                    target_d = d
                    best_angle = angle_distance
                end
            end
        end
    end
    if target == nil then
        print("[helper 1.0] delete failed: stand within 8u and aim at spot (green)")
        return
    end
    local text = read_data_file()
    local entry_start, entry_end = find_entry_bounds(text, target)
    if entry_start == nil or entry_end == nil then
        print("[helper 1.0] delete failed: could not locate spot in file")
        return
    end
    write_data_file(text:sub(1, entry_start - 1) .. text:sub(entry_end))
    if active == target then reset_playback() end
    reload_lineups()
    del_save:SetValue(false)
    del_save_prev = false
    print(string.format("[helper 1.0] deleted spot \"%s\" (%.1fu)", target.name or "Lineup", target_d))
end

local function handle_record_toggle()
    local cur = rec_save:GetValue()
    if cur and not rec_save_prev then save_current_spot() end
    rec_save_prev = cur
end

local function handle_delete_toggle()
    local cur = del_save:GetValue()
    if cur and not del_save_prev then delete_nearest_spot() end
    del_save_prev = cur
end

callbacks.Register("Draw", "helper10_draw", function()
    window:SetActive(gui.Reference("Menu"):IsActive())
    handle_record_toggle()
    handle_delete_toggle()
    if not enabled:GetValue() then return end
    local player = get_player()
    if player == nil then return end
    local weapon = get_grenade(player)
    if weapon == nil then return end
    local map = map_name()
    local points = lineups[map]
    if type(points) ~= "table" then return end

    local origin = player:GetAbsOrigin()
    local view = engine.GetViewAngles()
    local rr, rg, rb = red:GetValue()
    local gr, gg, gb = green:GetValue()
    local show_limit = show_distance:GetValue()
    local fade_start = show_limit * 0.82
    local fade_end = show_limit * 1.06
    local radius = position_radius:GetValue()
    local ft = frame_time()

    local draw_list = {}
    for _, point in ipairs(points) do
        if valid_point(point) and weapon_matches(point.weapon, weapon) then
            local distance = distance_xy(origin, point_position(point))
            if distance <= fade_end + 50 then
                local on_spot = distance <= radius and math.abs(origin.z - point.pos.z) <= 12
                local alpha = 255
                if not on_spot then
                    alpha = update_label_alpha(point_label_key(point), distance, fade_start, fade_end, ft)
                end
                if alpha >= 4 or on_spot then
                    table.insert(draw_list, {
                        point = point,
                        distance = distance,
                        alpha = on_spot and math.max(alpha, 220) or alpha,
                        on_spot = on_spot,
                        is_active = active == point,
                    })
                end
            end
        end
    end

    local stack_groups = {}
    for _, item in ipairs(draw_list) do
        local pk = point_key(item.point)
        if not stack_groups[pk] then stack_groups[pk] = {} end
        table.insert(stack_groups[pk], item)
    end

    for pk, items in pairs(stack_groups) do
        local point0 = items[1].point
        table.sort(items, function(a, b)
            return (a.point.name or "") < (b.point.name or "")
        end)

        local accent_r, accent_g, accent_b = rr, rg, rb
        for _, item in ipairs(items) do
            if item.is_active then accent_r, accent_g, accent_b = gr, gg, gb; break end
        end

        local any_on_spot = false
        for _, item in ipairs(items) do
            if item.on_spot then any_on_spot = true; break end
        end

        if show_spot_ring:GetValue() and any_on_spot then
            local ring_alpha = 255
            for _, item in ipairs(items) do
                if item.on_spot then ring_alpha = math.max(ring_alpha, item.alpha) end
            end
            draw_ring(point0, radius, accent_r, accent_g, accent_b, math.floor(170 * ring_alpha / 255))
        end

        for _, item in ipairs(items) do
            if item.on_spot then
                local point = item.point
                local spot_alpha = math.max(item.alpha, 220)
                local in_fov = is_view_in_point_fov(view, point)
                draw_fov_ring(point, in_fov, spot_alpha)
                local playing = item.is_active and is_execute_down() and state ~= "aim"
                draw_aim_target(player, point, playing, in_fov, spot_alpha, view)
            end
        end

        local sx, sy = client.WorldToScreen(Vector3(point0.pos.x, point0.pos.y, point0.pos.z + 14))
        if sx and sy and show_points:GetValue() then
            local heights, total_h = {}, 0
            for i, item in ipairs(items) do
                local subtitle = string.format("%.0f u · %s", item.distance, weapon_label(item.point.weapon))
                local _, h = measure_label(item.point.name or "Lineup", subtitle)
                heights[i] = h
                total_h = total_h + h + (i < #items and 5 or 0)
            end

            local cur_y = sy - math.floor(total_h / 2)
            for i, item in ipairs(items) do
                local point = item.point
                local item_r, item_g, item_b = rr, rg, rb
                if item.is_active then item_r, item_g, item_b = gr, gg, gb end
                local subtitle = string.format("%.0f u · %s", item.distance, weapon_label(point.weapon))
                local cy = cur_y + math.floor(heights[i] / 2)
                draw_world_label(sx, cy, point.name or "Lineup", subtitle,
                    item.alpha, item_r, item_g, item_b)
                cur_y = cur_y + heights[i] + 5
            end
        end
    end

    if show_status:GetValue() then
        draw.Color(255, 255, 255, 255)
        draw.Text(12, 12, "helper 1.0: " .. state)
        if candidate then draw.Text(12, 28, "point: " .. (candidate.name or "Lineup")) end
    end
end)
