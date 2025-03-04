-- samthree
--
-- v0.0.1 @ooray
-- A simple looper + high (x2) and 
-- low (-1/2x) looper voices
--  where sounds slowly decay
--
-- E1: Move tab in menu
-- play:
-- E2: Number of Beats
-- E3: Pre Level
-- vol:
-- E2: Low loop volume
-- E3: High loop volume
-- div:
-- E2: 1x speed divisor
-- E3: 2x speed divisor
-- shuf:
-- E2: Shuffle 1x loop
-- E3: Shuffle 2x loop
-- Hold K2+turn E1: Tempo
-- E2: Loop preserve rate
-- E3: Rec. mode (loop/one-shot)
-- Hold K2+turn E3: Click (on/off)
-- K2: Start/pause playback
-- K3: Arm/disarm recording
-- Hold K2+tap K3: Tap tempo
-- Hold K1+tap K2: Double buffer
-- Hold K1+tap K3: Clear buffer
--
-- v1.2.0 @21echoes
-- Modified by @laderast

UI = require("ui")
local ControlSpec = require "controlspec"
local TapTempo = include("lib/tap_tempo")
local Alert = include("lib/alert")

-- Use the PolyPerc engine for the click track
engine.name = 'PolyPerc'

local playing = 1
local rec_level = 1.0
local prior_record_mode = 1
local one_shot_metro
local tap_tempo = TapTempo.new()
local tap_tempo_square
local loop_dur
local cur_beat = 0
local clock_tick_id
local pause_beat_offset
local pause_softcut_pos
local resume_after_pause_id
local held_key
local modified_level_params = {
  "cut_input_adc",
  "cut_input_eng",
  "cut_input_tape",
  "monitor_level",
  "softcut_level"
}
local initial_levels = {}
local MAX_NUM_BEATS = 64
local SCREEN_FRAMERATE = 15
local screen_refresh_metro
local is_screen_dirty = false
local ext_clock_alert
local ext_clock_alert_dismiss_metro
local clear_confirm
local click_track_square
local tabs
local my_titles
local seq_buffer = {1,1,3,3,4,4,0,1,1,2,2,2,4,3,5}

-- Initialization
function init()
  my_titles = {'play', 'vol', 'div', 'shuf'}
  tabs = UI.Tabs.new(1,my_titles)
  
  init_params()
  init_softcut()
  init_ui_metro()
  init_clock_tick()
end

function init_params()
  params:add_separator()
  params:add {
    id="pre_level",
    name="Feedback",
    type="control",
    controlspec=ControlSpec.new(0, 1, "lin", 0, 0.95, ""),
    action=function(value) set_pre_level(value) end
  }
  params:add {
    id="low_loop_level",
    name="Low Loop Level",
    type="control",
    controlspec=ControlSpec.new(0, 1, "lin", 0, 0.95, ""),
    action=function(value) set_low_level(value) end
  }

  params:add {
    id="high_loop_level",
    name="High Loop Level",
    type="control",
    controlspec=ControlSpec.new(0, 1, "lin", 0, 0.95, ""),
    action=function(value) set_high_level(value) end
  }
  
  params:add_separator()
  params:add {
    id="num_beats",
    name="Num Beats",
    type="number",
    min=1,
    max=MAX_NUM_BEATS,
    default=8,
    action=function(value) set_num_beats(value) end
  }
  
  params:add {
    id="low_div",
    name="Mid Divisor",
    type="number",
    min=1,
    max=8,
    default=1,
    action=function(value) set_low_div(value) end
  }
  
  params:add {
    id="high_div",
    name="High Divisor",
    type="number",
    min=1,
    max=8,
    default=1,
    action=function(value) set_high_div(value) end
  }
  params:add_separator()
  params:add {
    id="norm_shuf",
    name="Shuf Norm",
    type="option",
    options={"no", "yes"},
    default=1
  }
  
  params:add {
    id="hi_shuf",
    name="Shuf Hi",
    type="option",
    options={"no", "yes"},
    default=2
  }

  params:add_separator()
  params:add {
    id="record_mode",
    name="Recording Mode",
    type="option",
    options={"Continuous", "One-Shot"},
    default=0,
    action=function(value) set_record_mode(value) end
  }
  params:add {
    id="num_input_channels",
    name="Input Mode",
    type="option",
    options={"Mono", "Stereo"},
    default=(params:get("monitor_mode") == 1 and 2 or 1),
    action=function(value) set_num_input_channels(value) end
  }
  params:add {
    id="click_track_enabled",
    name="Click Track",
    type="option",
    options={"Disabled", "Enabled"},
    default=1,
  }
  local default_tempo_action = params:lookup_param("clock_tempo").action
  params:set_action("clock_tempo", function(value)
    default_tempo_action(value)
    set_tempo(value)
  end)
  params:bang()
end

function init_softcut()
  -- Set up default levels
  for i, level_param in ipairs(modified_level_params) do
    initial_levels[level_param] = params:get(level_param)
    -- Setting 0 as it's in dBs and 0 dB is unity gain / amp of 1
    if level_param == "cut_input_eng" then
      -- The click track uses the engine, and we don't want to record the click track to the loop
      params:set("cut_input_eng", -math.huge)
    else
      params:set(level_param, 0)
    end
  end

  softcut.buffer_clear()

  for voice=1,2 do
    softcut.enable(voice, 1)
    softcut.buffer(voice, voice)
    softcut.level(voice, 1.0)
    softcut.pan(voice, voice == 1 and -1.0 or 1.0)
    softcut.rate(voice, 1)
    softcut.loop(voice, 0)
    softcut.loop_start(voice, 0)
    softcut.position(voice, 0)
    softcut.level_input_cut(voice, voice, 1.0)
    softcut.rec_level(voice, rec_level)
    softcut.rec(voice, 1)
  end
  -- voice 3 is for low playing (1/2 reverse speed)
  softcut.enable(3, 1)
  softcut.buffer(3, 1)
  softcut.rate(3, -0.5)
  softcut.rec(3, 0)
  softcut.pan(3,0)
  softcut.level(3, 1.0)
  softcut.pre_level(3, 0)
  softcut.loop(3, 1)
  softcut.loop_start(3,0)
  softcut.position(3,0)

  -- voice 4 is for high playing (2x forward speed)
  softcut.enable(4, 1)
  softcut.buffer(4, 1)
  softcut.rate(4, 2.0)
  softcut.rec(4, 0)
  softcut.pan(4,0)
  softcut.level(4, 1.0)
  softcut.loop(4, 1)
  softcut.pre_level(4, 0.5)
  softcut.loop_start(4,0)
  softcut.position(4,0)
  softcut.phase_quant(4, 0.5)

  for voice=1,4 do
    softcut.play(voice, playing)
  end
end

function init_ui_metro()
  -- Render loop
  screen_refresh_metro = metro.init()
  if not screen_refresh_metro then
    print('ERROR: Unable to initialize screen render loop')
    return
  end
  screen_refresh_metro.event = screen_frame_tick
  screen_refresh_metro:start(1 / SCREEN_FRAMERATE)
end

function init_clock_tick()
  cur_beat = 0
  clock_tick_id = clock.run(clock_tick)
end

-- Interaction hooks
function enc(n, delta)
  if n==1 then
    tabs:set_index_delta(util.clamp(delta, -1, 1), false)
  elseif n==2 then
    if tabs.index == 1 then
      params:delta("num_beats", delta)
    elseif tabs.index == 2 then
      params:delta("low_loop_level", delta)
    elseif tabs.index == 3 then
      params:delta("low_div", delta)
    elseif tabs.index == 4 then
      params:delta("norm_shuf", delta)
    end
  elseif n==3 then
    if tabs.index == 1 then
      params:delta("pre_level", delta)
    elseif tabs.index == 2 then
      params:delta("high_loop_level", delta)
    elseif tabs.index == 3 then
      params:delta("high_div", delta)
    elseif tabs.index == 4 then
      params:delta("hi_shuf", delta)
    end
  end
is_screen_dirty = true
end

local just_doubled_buffer = false
function key(n, z)
  -- Any keypress that is not K3 while showing the clear confirm dialog dismisses the dialog
  if clear_confirm ~= nil and n ~= 3 then
    clear_confirm = nil
    is_screen_dirty = true
  end

  if z == 1 then
    if held_key == nil then
      held_key = n
    elseif held_key == 1 and n == 2 then
      just_doubled_buffer = true
      if params:get("num_beats") < MAX_NUM_BEATS then
        double_buffer()
      end
      return
    elseif held_key == 1 and n == 3 then
      if ext_clock_alert == nil then
        if clear_confirm ~= nil then
          softcut.buffer_clear()
          clear_confirm = nil
        else
          clear_confirm = Alert.new({"Continue holding K1", "and press K3 again", "to erase everything"})
        end
        is_screen_dirty = true
      end
      return
    end
  elseif held_key == n and z == 0 then
    held_key = nil
  end

  -- Hold K2 + Tap K3 means tap tempo
  local tempo, short_circuit_value = tap_tempo:key(n, z)
  if tempo and params:get("clock_source") == 1 then
    params:set("clock_tempo", tempo)
  end
  if short_circuit_value ~= nil then
    if n == 3 and z == 1 then
      if params:get("clock_source") == 1 then
        tap_tempo_square = util.time()
        is_screen_dirty = true
      else
        show_ext_clock_alert()
      end
    end
    return short_circuit_value
  end

  -- For K2 we listen to key-up (key-down starts alt mode)
  if n==2 and z==0 then
    if just_doubled_buffer then
      just_doubled_buffer = false
      return
    end
    print(playing)
    if playing == 1 then
      set_playing(0)
      playing = 0
    else
      playing = 1
      set_playing(1)
    end
  elseif n==3 and z==1 then
    -- K3 means toggle recording on/off
    if rec_level == 1.0 then
      -- Even if we're not in one-shot, this stops recording
      one_shot_stop()
    else
      if params:get("record_mode") == 1 then
        set_rec_level(1.0)
      else
        one_shot_start()
      end
    end
  end
end

-- Clock hooks
function clock.transport.start()
  set_playing(1)
end

function clock.transport.stop()
  set_playing(0)
end

-- Metro / Clock callbacks
function clock_tick()
  while true do
    clock.sync(1)
    if playing == 1 then
      local num_beats = params:get("num_beats")
      cur_beat = (cur_beat + 1)
      if cur_beat <= num_beats then
        cur_beat = cur_beat % num_beats 
        --print(cur_beat)
        print(seq_buffer[cur_beat + 1])
        local new_position = seq_buffer[cur_beat+1] * clock.get_beat_sec()
        softcut.position(1, new_position)
        softcut.voice_sync(2, 1, new_position)
        local rand_pos = math.random(num_beats) * clock.get_beat_sec()
        if params:get("hi_shuf") == 2  then
          softcut.position(4, rand_pos)
        end
        if params:get("norm_shuf") == 2 then
          for voice=1,2 do
            softcut.position(voice, rand_pos)
          end
        end
      end

      -- Play click only if enabled, and only if not currently tapping tempo
      --local should_play_click = params:get("click_track_enabled") == 2 and not tap_tempo._tap_tempo_used
      if should_play_click then
        play_click()
      end
    end

    -- For external tempos, redraw the screen in case it's changed
    if params:get("clock_source") ~= 1 then
      is_screen_dirty = true
    end
  end
end

function play_click()
  -- While the user is adjusting the tempo, we can get click track "smears" where it triggers in rapid succession
  -- So we set a lower bound on how quickly back to back clicks can sound
  local is_smearing = false
  if click_track_square ~= nil then
    local time_since_last_click = util.time() - click_track_square
    local beat_dur = (60 / params:get("clock_tempo"))
    is_smearing = time_since_last_click < (beat_dur * 0.5)
  end
  if not is_smearing then
    engine.hz(523.25)
  end
  click_track_square = util.time()
  is_screen_dirty = true
end

function screen_frame_tick()
  if is_screen_dirty then
    is_screen_dirty = false
    redraw()
  end
end

function redraw()
  screen.clear()

  if ext_clock_alert ~= nil then
    ext_clock_alert:redraw()
    screen.update()
    return
  end

  if clear_confirm ~= nil then
    clear_confirm:redraw()
    screen.update()
    return
  end

  tabs:redraw()

  local left_x = 5
  local mid_x1 = 38
  local mid_x2 = 75
  local mid_x3 = 100
  local right_x = 110

  local y = 20

  screen.level(3)
  if tabs.index == 1 then
    screen.level(10)
  end
  screen.move(left_x, y)
  screen.text("Bt:"..params:get("num_beats"))
  screen.level(3)

  if tabs.index == 2 then
    screen.level(10)
  end
  screen.move(mid_x1, y)
  screen.text("LV:"..params:get("low_loop_level"))
  screen.level(3)
  
  if tabs.index == 3 then
    screen.level(10)
  end
  screen.move(mid_x2, y)
  screen.text("MD:"..params:get("low_div"))
  screen.level(3)
  
  if tabs.index == 4 then
    screen.level(10)
  end
  screen.move(mid_x3, y)
  screen.text("MS:"..params:get("norm_shuf"))
  screen.level(3)

  if tap_tempo_square ~= nil then
    if (util.time() - tap_tempo_square) < 0.125 then
      screen.rect(122, 8, 4, 4)
      screen.fill()
      is_screen_dirty = true
    else
      tap_tempo_square = nil
    end
  elseif click_track_square ~= nil then
    if (util.time() - click_track_square) < 0.125 then
      screen.rect(122, 8, 4, 4)
      screen.fill()
      is_screen_dirty = true
    else
      click_track_square = nil
    end
  end

  y = 32
  screen.level(5)  
  if tabs.index == 1 then
    screen.level(10)
  end
  screen.move(left_x, y)
  screen.text("pr:"..params:get("pre_level"))
  screen.level(3)  
  
  if tabs.index == 2 then
    screen.level(10)
  end
  screen.move(mid_x1, y)
  screen.text("HV:"..params:get("high_loop_level"))
  screen.level(3)  

  if tabs.index == 3 then
    screen.level(10)
  end
  screen.move(mid_x2, y)
  screen.text("HD:"..params:get("high_div"))
  screen.level(3)  
  
  if tabs.index == 4 then
    screen.level(10)
  end
  screen.move(mid_x3, y)
  screen.text("HS:"..params:get("hi_shuf"))
    screen.level(3)


  y = 45

 screen.move(left_x, y)
  screen.text("length: ")
  screen.move(right_x, y)
  local tempo = params:get("clock_tempo")
  local num_beats = params:get("num_beats")
  screen.text_right(num_beats.." beats, "..math.floor(tempo+0.5).." bpm")

  y = 57
  screen.move(left_x, y)
  if playing == 1 then
    screen.text("playing")
  else
    screen.text("paused")
  end
  screen.move(right_x, y)
  if rec_level == 1.0 then
    screen.text_right("recording")
  else
    screen.text_right("not recording")
  end

  screen.update()
end

function show_ext_clock_alert()
  if ext_clock_alert ~= nil then
    return
  end
  local source = ({"", "MIDI", "Link", "crow"})[params:get("clock_source")]
  ext_clock_alert = Alert.new({"Tempo is following "..source, "", "Use params menu to change", "your clock settings"})
  ext_clock_alert_dismiss_metro = metro.init(dismiss_ext_clock_alert, 2, 1)
  if ext_clock_alert_dismiss_metro then
    ext_clock_alert_dismiss_metro:start()
  else
    print('ERROR: Unable to dismiss external clock alert UI')
  end
  is_screen_dirty = true
end

function dismiss_ext_clock_alert()
  ext_clock_alert = nil
  if ext_clock_alert_dismiss_metro then
    metro.free(ext_clock_alert_dismiss_metro.id)
    ext_clock_alert_dismiss_metro = nil
  end
  is_screen_dirty = true
end

-- Setters
function set_playing(value)
  -- Okay, so there's a lot of hackiness in this function basically working around two related bugs:
  -- inside clock.run coroutines, softcut.enable doesn't resume playhead movement
  -- You can make it actually resume by calling softcut.position inside that same coroutine,
  -- but it doesn't actually put the playhead at that requested position!
  --
  -- So instead, we softcut.enable outside of the coroutine, but keep levels at 0
  -- We then set the position to some "preroll" amount, so that when the coroutine waits
  -- and then turns back up the levels, we're at the expected playhead position.
  -- This has one other complication, which is we can't set the position to < 0 for "preroll",
  -- so we have to set a metro to wait a bit before we set position to 0 to make it actually line up. UGH
  if resume_after_pause_id ~= nil then
    return
  end
  if value == 0 then
    pause_beat_offset = clock.get_beats() % 1
    pause_softcut_pos = (cur_beat + pause_beat_offset) * clock.get_beat_sec()
    for voice=1,4 do
      softcut.rec_level(voice, 0.0)
      softcut.level(voice, 0.0)
      softcut.enable(voice, 0)
    end
    playing = 0
  else
    if pause_beat_offset == nil then
      _resume_playing()
    else
      -- Calculate "preroll" position so that we can synchronously softcut.enable
      -- before we use a coroutine to wait a bit before we actually turn up the voice levels to truly unpause
      local current_offset = clock.get_beats() % 1
      local beats_to_wait = ((pause_beat_offset - current_offset) + 1) % 1
      local time_to_wait = beats_to_wait * clock.get_beat_sec()
      local new_position = pause_softcut_pos - time_to_wait
      if new_position >= 0 then
        softcut.position(1, new_position)
        softcut.voice_sync(2, 1, 0)
      else
        -- We can't set the position less than zero, so just wait for the preroll *then* set the position
        softcut.position(1, 0)
        softcut.voice_sync(2, 1, 0)
        unpause_metro = metro.init(function()
          softcut.position(1, 0)
          softcut.voice_sync(2, 1, 0)
        end, -new_position, 1)
        if unpause_metro then
          unpause_metro:start()
        else
          print('ERROR: Unable to properly re-sync a pause within the first beat')
        end
      end
      for voice=1,4 do
        softcut.enable(voice, 1)
      end
      resume_after_pause_id = clock.run(function()
        if current_offset > pause_beat_offset then
          clock.sync(1)
        end
        clock.sync(pause_beat_offset)
        _resume_playing()
      end)
    end
  end
  is_screen_dirty = true
end

function _resume_playing()
  for voice=1,2 do
    softcut.rec_level(voice, rec_level)
    softcut.level(voice, 1.0)
  end
  softcut.level(3, params:get("low_loop_vol"))
  softcut.level(4, params:get("high_loop_vol"))
  pause_softcut_pos = nil
  pause_beat_offset = nil
  resume_after_pause_id = true
  playing = 1
  is_screen_dirty = true
end

function set_rec_level(value)
  rec_level = value
  for voice=1,2 do
    softcut.rec_level(voice, rec_level)
    -- TODO: if you want rec_level == 0 to turn off deterioration:
    -- softcut.pre_level(voice, rec_level == 0.0 and 1.0 or params:get("pre_level"))
  end
  is_screen_dirty = true
end

function set_pre_level(pre_level)
  for voice=1,2 do
    -- We set both level and pre-level,
    -- because we want both real-time manipulation
    -- *and* to write that manipulation to the buffer
    --
    -- TODO: confirm this is really how it works
    -- (when head passes over sample, it first plays it back,
    --  then modifies its level in the buffer)
    softcut.level(voice, pre_level)
    softcut.pre_level(voice, pre_level)
  end
  is_screen_dirty = true
end

function set_high_level(pre_level)
  voice=4
  softcut.level(voice, pre_level)
  is_screen_dirty = true
end


function set_low_level(pre_level)
  voice=3
  softcut.level(voice, pre_level)
  is_screen_dirty = true
end


function set_num_beats(num_beats)
  local tempo = params:get("clock_tempo")
  set_loop_dur(tempo, num_beats)
  is_screen_dirty = true
end

function set_low_div(div)
  softcut.phase_quant(3, div)
  is_screen_dirty = true
end

function set_high_div(div)
  softcut.phase_quant(4, 1/div)
  is_screen_dirty = true
end

function set_tempo(tempo)
  local num_beats = params:get("num_beats")
  set_loop_dur(tempo, num_beats)
  is_screen_dirty = true
end

function set_loop_dur(tempo, num_beats)
  loop_dur = (num_beats/tempo) * 60
  for voice=1,4 do
    -- Not really clear why we have to set loop(0) and loop_end(large_number) to get this all working :shrug:
    -- You'd think without messing with the loop settings at all, we could have a play head that runs
    -- and which we can manipulate its position
    softcut.loop_end(voice, loop_dur * 2)
  end
end

function set_record_mode(value)
  local record_mode = value
  if value == "Continuous" then record_mode = 1 elseif value == "One-Shot" then record_mode = 2 end
  if rec_level == 1.0 and record_mode ~= prior_record_mode then
    if record_mode == 1 and one_shot_metro then
      metro.free(one_shot_metro.id)
      one_shot_metro = nil
    else
      one_shot_start()
    end
  end
  prior_record_mode = record_mode
  is_screen_dirty = true
end

function one_shot_start()
  set_rec_level(1.0)
  one_shot_metro = metro.init(one_shot_stop, loop_dur, 1)
  if not one_shot_metro then
    print('ERROR: Unable to stop one-shot recording')
    return
  end
  one_shot_metro:start()
end

function one_shot_stop()
  set_rec_level(0.0)
  if one_shot_metro then
    metro.free(one_shot_metro.id)
    one_shot_metro = nil
  end
end

function set_num_input_channels(value)
  local coerced_value = value
  if value == "Stereo" then coerced_value = 2 elseif value == "Mono" then coerced_value = 1 end
  if coerced_value == 2 then
    softcut.level_input_cut(1, 1, 1.0)
    softcut.level_input_cut(1, 2, 0.0)
    softcut.level_input_cut(2, 1, 0.0)
    softcut.level_input_cut(2, 2, 1.0)
  else
    softcut.level_input_cut(1, 1, 1.0)
    softcut.level_input_cut(1, 2, 1.0)
    softcut.level_input_cut(2, 1, 0.0)
    softcut.level_input_cut(2, 2, 0.0)
  end
end

function double_buffer()
  -- Duplicate the buffer immediately after the current buffer ends
  local full_path = "/home/we/dust/code/samthree/tmp.wav"
  -- Write an additional second to disk to get nice cross-fade behavior
  softcut.buffer_write_stereo(full_path, 0, loop_dur + 1)
  softcut.buffer_read_stereo(full_path, 0, loop_dur, loop_dur + 1)
  local num_beats = params:get("num_beats")
  params:set("num_beats", num_beats * 2)
  -- Sleep is there because it takes a bit for the file system to recognize the file exists
  -- Also, os.remove doesn't work...
  os.execute("sleep 0.2; rm "..full_path)
end

-- Cleanup
function cleanup()
  if screen_refresh_metro then
    metro.free(screen_refresh_metro.id)
    screen_refresh_metro = nil
  end
  if one_shot_metro then
    metro.free(one_shot_metro.id)
    one_shot_metro = nil
  end
  if ext_clock_alert_dismiss_metro then
    metro.free(ext_clock_alert_dismiss_metro.id)
    ext_clock_alert_dismiss_metro = nil
  end
  if clock_tick_id then
    clock.cancel(clock_tick_id)
    clock_tick_id = nil
  end
  if resume_after_pause_id then
    clock.cancel(resume_after_pause_id)
    resume_after_pause_id = nil
  end
  tap_tempo = nil
  ext_clock_alert = nil
  clear_confirm = nil

  -- Restore prior levels
  for level_param, level in ipairs(initial_levels) do
    params:set(level_param, level)
  end
  modified_level_params = nil
  initial_levels = nil
end
