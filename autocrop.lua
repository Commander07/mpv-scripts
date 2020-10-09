--[[
This script uses the lavfi cropdetect filter to automatically insert a crop filter with appropriate parameters for the
currently playing video, the script run continuously by default, base on periodic_timer and detect_seconds timer.

It will automatically crop the video, when playback starts.

Also It registers the key-binding "C" (shift+c). You can manually crop the video by pressing the "C" (shift+c) key.

If the "C" key is pressed again, the crop filter is removed restoring playback to its original state.

The workflow is as follows: First, it inserts the filter vf=lavfi=cropdetect. After <detect_seconds> (default is 1)
seconds, it then inserts the filter vf=crop=w:h:x:y, where w,h,x,y are determined from the vf-metadata gathered by
cropdetect. The cropdetect filter is removed immediately after the crop filter is inserted as it is no longer needed.

Since the crop parameters are determined from the 1 second of video between inserting the cropdetect and crop filters, the "C"
key should be pressed at a position in the video where the crop region is unambiguous (i.e., not a black frame, black background
title card, or dark scene).

The default options can be overridden by adding script-opts-append=autocrop-<parameter>=<value> into mpv.conf

List of available parameters (For default values, see <options>)：

auto: bool - Whether to automatically apply crop periodicly. 
    If you want a single crop at start, set it to false or add "script-opts-append=autocrop-auto=no" into mpv.conf.

periodic_timer: seconds - Delay between crop detect in auto mode.

detect_limit: number[0-255] - Black threshold for cropdetect.
    Smaller values will generally result in less cropping.
    See limit of https://ffmpeg.org/ffmpeg-filters.html#cropdetect

detect_round: number[2^n] -  The value which the width/height should be divisible by 2. Smaller values have better detection
    accuracy. If you have problems with other filters, you can try to set it to 4 or 16.
    See round of https://ffmpeg.org/ffmpeg-filters.html#cropdetect

detect_seconds: seconds - How long to gather cropdetect data.
    Increasing this may be desirable to allow cropdetect more time to collect data.

min/max_aspect_ratio: [21.6/9] or [2.4][2.68] - min_aspect_ratio is used to disable the script if the video is over that ratio (already crop).
    max_aspect_ratio is used to prevent cropping over that ratio.
--]]
require "mp.msg"
require "mp.options"

local options = {
    enable = true,
    auto = true, -- create mode = 0-on-demand, 1-single, 2-auto-start, 3-auto-manual
    periodic_timer = 0,
    start_delay = 0,
    -- crop behavior
    min_aspect_ratio = 21.6 / 9,
    max_aspect_ratio = 21.6 / 9,
    width_pxl_margin = 4,
    height_pxl_margin = 4,
    height_pct_margin = 0.038,
    fixed_width = true,
    -- cropdetect
    detect_limit = 24,
    detect_round = 2,
    detect_seconds = 0.45
}
read_options(options)

if not options.enable then
    mp.msg.info("Disable script.")
    return
end

-- Init variables
local label_prefix = mp.get_script_name()
local labels = {
    crop = string.format("%s-crop", label_prefix),
    cropdetect = string.format("%s-cropdetect", label_prefix)
}
-- option
local min_h
local height_pct_margin_up = options.height_pct_margin / (1 - options.height_pct_margin)
local detect_seconds_adjust = options.detect_seconds
local limit_max = options.detect_limit
local limit_adjust = options.detect_limit
local limit_adjust_by = 1
-- state
local timer = {}
local in_progress, paused, toggled, seeking
-- metadata
local meta, meta_stat = {}, {}
local entity = {"size_origin", "apply_current", "detect_current", "detect_last"}
local unit = {"w", "h", "x", "y"}
for k, v in pairs(entity) do
    meta[v] = {unit}
end

local function meta_copy(from, to)
    for k, v in pairs(unit) do
        to[v] = from[v]
    end
end

local function meta_stats(meta, shape, debug)
    -- Shape Majority
    local symmetric, in_margin = 0, 0
    local is_majority, return_shape
    for k, k1 in pairs(meta_stat) do
        if meta_stat[k].shape_y == "Symmetric" then
            symmetric = symmetric + meta_stat[k].count
        else
            in_margin = in_margin + meta_stat[k].count
        end
    end
    if symmetric > in_margin then
        return_shape = true
        is_majority = "Symmetric"
    else
        return_shape = false
        is_majority = "In Margin"
    end

    -- Debug
    if debug then
        mp.msg.info("Meta Stats:")
        mp.msg.info(string.format("Shape majority is %s, %d > %d", is_majority, symmetric, in_margin))
        for k, k1 in pairs(meta_stat) do
            if type(k) ~= "table" then
                mp.msg.info(string.format("%s count=%s shape_y=%s", k, meta_stat[k].count, meta_stat[k].shape_y))
            end
        end
        return
    end

    local meta_whxy = string.format("w=%s:h=%s:x=%s:y=%s", meta.w, meta.h, meta.x, meta.y)
    if not meta_stat[meta_whxy] then
        meta_stat[meta_whxy] = {unit}
        meta_stat[meta_whxy].count = 0
        meta_stat[meta_whxy].shape_y = shape
        meta_copy(meta, meta_stat[meta_whxy])
    end
    meta_stat[meta_whxy].count = meta_stat[meta_whxy].count + 1

    return return_shape
end

local function init_size()
    local width = mp.get_property_native("width")
    local height = mp.get_property_native("height")
    meta.size_origin = {
        w = width,
        h = height,
        x = 0,
        y = 0
    }
    min_h = math.floor(meta.size_origin.w / options.max_aspect_ratio)
    if min_h % 2 == 0 then
        min_h = min_h
    else
        min_h = min_h + 1
    end
    meta_copy(meta.size_origin, meta.apply_current)
end

local function is_filter_present(label)
    local filters = mp.get_property_native("vf")
    for index, filter in pairs(filters) do
        if filter["label"] == label then
            return true
        end
    end
    return false
end

local function is_enough_time(seconds)
    local time_needed = seconds + 1
    local playtime_remaining = mp.get_property_native("playtime-remaining")
    if playtime_remaining and time_needed > playtime_remaining then
        mp.msg.warn("Not enough time for autocrop.")
        seek("no-time")
        return false
    end
    return true
end

local function is_cropable()
    local vid = mp.get_property_native("vid")
    local is_album = vid and mp.get_property_native(string.format("track-list/%s/albumart", vid)) or false
    return vid and not is_album
end

local function insert_crop_filter()
    local insert_crop_filter_command =
        mp.command(string.format("no-osd vf pre @%s:lavfi-cropdetect=limit=%d/255:round=%d:reset=0", labels.cropdetect, limit_adjust, options.detect_round))
    if not insert_crop_filter_command then
        mp.msg.error("Does vf=help as #1 line in mvp.conf return libavfilter list with crop/cropdetect in log?")
        cleanup()
        return false
    end
    return true
end

local function remove_filter(label)
    if is_filter_present(label) then
        mp.command(string.format("no-osd vf remove @%s", label))
    end
end

local function collect_metadata()
    local cropdetect_metadata
    repeat
        cropdetect_metadata = mp.get_property_native(string.format("vf-metadata/%s", labels.cropdetect))
        if paused or toggled or seeking then
            break
        end
    until cropdetect_metadata and cropdetect_metadata["lavfi.cropdetect.w"]
    -- Remove filter to reset detection.
    remove_filter(labels.cropdetect)
    if cropdetect_metadata and cropdetect_metadata["lavfi.cropdetect.w"] then
        -- Make metadata usable.
        meta.detect_current = {
            w = tonumber(cropdetect_metadata["lavfi.cropdetect.w"]),
            h = tonumber(cropdetect_metadata["lavfi.cropdetect.h"]),
            x = tonumber(cropdetect_metadata["lavfi.cropdetect.x"]),
            y = tonumber(cropdetect_metadata["lavfi.cropdetect.y"])
        }
        if meta.detect_current.w < 0 or meta.detect_current.h < 0 then
            -- Invalid data, probably a black screen
            detect_seconds_adjust = options.detect_seconds
            return false
        end
        return true
    end
    return false
end

local function auto_crop()
    -- Pause auto_crop
    in_progress = true
    timer.periodic_timer:stop()

    -- Verify if there is enough time to detect crop.
    local time_needed = detect_seconds_adjust
    if not is_enough_time(time_needed) then
        return
    end

    if not insert_crop_filter() then
        return
    end

    -- Wait to gather data.
    timer.crop_detect =
        mp.add_timeout(
        time_needed,
        function()
            if collect_metadata() and not paused and not toggled then
                if options.fixed_width then
                    meta.detect_current.w = meta.size_origin.w
                    meta.detect_current.x = meta.size_origin.x
                end

                -- Debug cropdetect meta
                --[[ mp.msg.info(
                    string.format(
                        "detect_curr=w=%s:h=%s:x=%s:y=%s, Y:%s",
                        meta.detect_current.w,
                        meta.detect_current.h,
                        meta.detect_current.x,
                        meta.detect_current.y,
                        shape_current_y
                    )
                ) ]]
                local symmetric_x = meta.detect_current.x == (meta.size_origin.w - meta.detect_current.w) / 2
                local symmetric_y = meta.detect_current.y == (meta.size_origin.h - meta.detect_current.h) / 2
                local in_margin_y =
                    meta.detect_current.y >= (meta.size_origin.h - meta.detect_current.h - options.height_pxl_margin) / 2 and
                    meta.detect_current.y <= (meta.size_origin.h - meta.detect_current.h + options.height_pxl_margin) / 2

                local shape_current_y
                if symmetric_y then
                    shape_current_y = "Symmetric"
                elseif in_margin_y then
                    shape_current_y = "In Margin"
                else
                    shape_current_y = "Asymmetric"
                end

                local detect_shape_y
                if in_margin_y then
                    -- Store valid cropping meta and find majority shape
                    if meta_stats(meta.detect_current, shape_current_y) then
                        detect_shape_y = symmetric_y
                    end
                else
                    detect_shape_y = in_margin_y
                end

                local bigger_than_min_h = meta.detect_current.h >= min_h
                -- crop with black bar if over max_aspect_ratio
                if in_margin_y and not bigger_than_min_h then
                    meta.detect_current.h = min_h
                    meta.detect_current.y = (meta.size_origin.h - meta.detect_current.h) / 2
                    bigger_than_min_h = true
                end

                local not_already_apply = meta.detect_current.h ~= meta.apply_current.h or meta.detect_current.w ~= meta.apply_current.w
                local pxl_change_h =
                    meta.detect_current.h >= meta.apply_current.h - options.height_pxl_margin and meta.detect_current.h <= meta.apply_current.h + options.height_pxl_margin
                local pct_change_h =
                    meta.detect_current.h >= meta.apply_current.h - meta.apply_current.h * options.height_pct_margin and
                    meta.detect_current.h <= meta.apply_current.h + meta.apply_current.h * height_pct_margin_up
                local detect_confirmation = meta.detect_current.h == meta.detect_last.h

                -- Auto adjust black threshold and detect_seconds
                local detect_size_origin = meta.detect_current.h == meta.size_origin.h
                if in_margin_y then
                    if limit_adjust < limit_max then
                        if detect_size_origin then
                            if limit_adjust + limit_adjust_by + 1 <= limit_max then
                                limit_adjust = limit_adjust + limit_adjust_by + 1
                            else
                                limit_adjust = limit_max
                            end
                        end
                    end
                    detect_seconds_adjust = options.detect_seconds
                else
                    if limit_adjust > 0 then
                        if limit_adjust - limit_adjust_by >= 0 then
                            limit_adjust = limit_adjust - limit_adjust_by
                        else
                            limit_adjust = 0
                        end
                        detect_seconds_adjust = 0
                    end
                end

                -- Crop Filter:
                local crop_filter = not_already_apply and symmetric_x and detect_shape_y and (pxl_change_h or not pct_change_h) and bigger_than_min_h and detect_confirmation
                if crop_filter then
                    -- Apply cropping.
                    mp.command(
                        string.format(
                            "no-osd vf pre @%s:lavfi-crop=w=%s:h=%s:x=%s:y=%s",
                            labels.crop,
                            meta.detect_current.w,
                            meta.detect_current.h,
                            meta.detect_current.x,
                            meta.detect_current.y
                        )
                    )
                    -- Save values to compare later.
                    meta_copy(meta.detect_current, meta.apply_current)
                end
                meta_copy(meta.detect_current, meta.detect_last)
            end
            -- Resume auto_crop
            in_progress = false
            if not paused and not toggled then
                timer.periodic_timer:resume()
            end
        end
    )
end

local function cleanup()
    mp.msg.info("Cleanup.")
    -- Kill all timers.
    for index, value in pairs(timer) do
        if timer[index]:is_enabled() then
            timer[index]:kill()
        end
    end
    -- Remove all timers.
    timer = {}

    -- Remove all existing filters.
    for key, value in pairs(labels) do
        remove_filter(value)
    end

    -- Reset some values
    meta_stat = {}
    meta.size_origin = {}
    limit_adjust = options.detect_limit
end

local function on_start()
    if not is_cropable() then
        mp.msg.warn("Only works for videos.")
        return
    end

    init_size()

    if options.min_aspect_ratio < meta.size_origin.w / meta.size_origin.h then
        mp.msg.info("Disable script, Aspect Ratio > min_aspect_ratio.")
        return
    end

    timer.start_delay =
        mp.add_timeout(
        options.start_delay,
        function()
            -- Run periodic or once.
            if options.auto then
                local time_needed = options.periodic_timer
                timer.periodic_timer = mp.add_periodic_timer(time_needed, auto_crop)
            else
                auto_crop()
            end
        end
    )
end

local function seek(name)
    mp.msg.info(string.format("Stop by %s event.", name))
    meta_stats(_, _, true)
    if timer.periodic_timer and timer.periodic_timer:is_enabled() then
        timer.periodic_timer:kill()
        if timer.crop_detect and timer.crop_detect:is_enabled() then
            timer.crop_detect:kill()
        end
    end
end

local function seek_event()
    seeking = true
end

local function resume(name)
    if timer.periodic_timer and not timer.periodic_timer:is_enabled() and not in_progress then
        timer.periodic_timer:resume()
        mp.msg.info(string.format("Resumed by %s event.", name))
    end

    local playback_time = mp.get_property_native("playback-time")
    if timer.start_delay and timer.start_delay:is_enabled() and playback_time > options.start_delay then
        timer.start_delay.timeout = 0
        timer.start_delay:kill()
        timer.start_delay:resume()
    end
end

local function resume_event()
    seeking = false
end

local function on_toggle()
    if not options.auto then
        auto_crop()
        mp.osd_message(string.format("%s once.", label_prefix), 3)
    else
        if is_filter_present(labels.crop) then
            remove_filter(labels.crop)
            remove_filter(labels.cropdetect)
            meta_copy(meta.size_origin, meta.apply_current)
        end
        if not toggled then
            toggled = true
            if not paused then
                seek("toggle")
            end
            mp.osd_message(string.format("%s paused.", label_prefix), 3)
        else
            toggled = false
            if not paused then
                resume("toggle")
            end
            mp.osd_message(string.format("%s resumed.", label_prefix), 3)
        end
    end
end

local function pause(_, bool)
    if options.auto then
        if bool then
            paused = true
            seek("pause")
        else
            paused = false
            if not toggled then
                resume("unpause")
            end
        end
    end
end

mp.register_event("seek", seek_event)
mp.register_event("playback-restart", resume_event)
mp.add_key_binding("C", "toggle_crop", on_toggle)
mp.observe_property("pause", "bool", pause)
mp.register_event("end-file", cleanup)
mp.register_event("file-loaded", on_start)
