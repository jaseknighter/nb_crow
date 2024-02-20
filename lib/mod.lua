local mod = require 'core/mods'
local music = require 'lib/musicutil'
local voice = require 'lib/voice'

local tuning
local data_path = _path.data .. "nb_crow/"
frequencies={{},nil,{},nil}
voltages={{},nil,{},nil}
local first_pitch = -1
local last_pitch = -1
local first_voltage = nil
local last_voltage = nil
-- local current_freq = -1
-- local last_freq = -1
-- local test_voltage= -5


local ASL_SHAPES = {'linear','sine','logarithmic','exponential','now'}


if note_players == nil then
    note_players = {}
end

--from: https://stackoverflow.com/questions/29987249/find-the-nearest-value
function find_nearest_value(table, number)
    local smallest_so_far, smallest_ix
    for i, y in ipairs(table) do
        if not smallest_so_far or (math.abs(number-y) < smallest_so_far) then
            smallest_so_far = math.abs(number-y)
            smallest_ix = i
        end
    end
    return smallest_ix, table[smallest_ix]
end

local function freq_to_note_num_float(freq)
    local reference = music.note_num_to_freq(60)
    local ratio = freq/reference
    return 60 + 12*math.log(ratio)/math.log(2)
end

function load_freqs_volts(crow_output)
  frequencies[crow_output] = {}
  voltages[crow_output] = {}
  local f = assert(io.open(data_path.."frequencies"..crow_output..".txt", "r"))
  local fstring = f:read("*all")
  for num in string.gmatch(fstring, '([^,]+)') do table.insert(frequencies[crow_output],num) end
  f:close()
  local v = assert(io.open(data_path.."voltages"..crow_output..".txt", "r"))
  local vstring = v:read("*all")
  for num in string.gmatch(vstring, '([^,]+)') do table.insert(voltages[crow_output],num) end
  v:close()
  print(crow_output, ": saved freqs and voltages loaded")
end

local function add_player(cv, env)
    local player = {
        ext = "_"..cv.."_"..env,
        count = 0,
        tuning = false,
    }

    function player:add_params()
        params:add_group("nb_crow_"..self.ext, "crow "..cv.."/"..env, 11+6)
        params:add_control("nb_crow_attack_time"..self.ext, "attack", controlspec.new(0.0001, 3, 'exp', 0, 0.1, "s"))
        params:add_option("nb_crow_attack_shape"..self.ext, "attack shape", ASL_SHAPES, 3)
        params:add_control("nb_crow_decay_time"..self.ext, "decay", controlspec.new(0.0001, 10, 'exp', 0, 1.0, "s"))
        params:add_option("nb_crow_decay_shape"..self.ext, "decay shape", ASL_SHAPES, 3)
        params:add_control("nb_crow_sustain"..self.ext, "sustain", controlspec.new(0.0, 1.0, 'lin', 0, 0.75, ""))
        params:add_control("nb_crow_release_time"..self.ext, "release", controlspec.new(0.0001, 10, 'exp', 0, 0.5, "s"))
        params:add_option("nb_crow_release_shape"..self.ext, "release shape", ASL_SHAPES, 3)
        params:add_control("nb_crow_portomento"..self.ext, "portomento", controlspec.new(0.0, 1, 'lin', 0, 0.0, "s"))
        params:add_binary("nb_crow_legato"..self.ext, "legato", "toggle", 1)
        params:add_control("nb_crow_freq"..self.ext, "tuned to", controlspec.new(20, 4000, 'exp', 0, 440, 'Hz', 0.0003))
        params:add_binary("nb_crow_tune"..self.ext, "tune", "trigger")
        params:set_action("nb_crow_tune"..self.ext, function()
            self:tune()
        end)
        params:add_separator("tuner_2"..self.ext,"tuner 2")
        params:add{type = "option", id = "crow_eval_output"..self.ext, name = "eval output", options={1,3}, default=1, action=function(value)
          osc.send( { "localhost", 57120 }, "/sc_crooner/set_crow_output",{value})
        end}
        voltage_increments={0.001,0.0005}
        params:add{type = "option", id = "voltage_increment"..self.ext, name = "voltage increment", options = voltage_increments, default = 2, action = function(value)
        end}
        params:add{type = "number", id = "confidence_level"..self.ext, name = "confidence level", min=1, max=100, default=50,formatter=function(param) return param:get() .. "%" end}
      
        params:add{type = "trigger", id = "load_last_eval"..self.ext, name = "load last eval"}
        params:set_action("load_last_eval"..self.ext, function() load_freqs_volts(params:get("crow_eval_output"..self.ext)) end)
        params:add{type = "trigger", id = "start_evaluation"..self.ext, name = "start eval"}
        params:set_action("start_evaluation"..self.ext, function()
          first_pitch = -1
          last_pitch = -1
          first_voltage = nil
          last_voltage = nil
          local msg={
            params:get("crow_eval_output"..self.ext),
            voltage_increments[params:get("voltage_increment"..self.ext)],
            params:get("confidence_level"..self.ext)*0.01
          }
          tuning = true
          for i=1,3 do
              crow.output[i].volts = 0
          end
          osc.send( { "localhost", 57120 }, "/sc_crooner/start_evaluation",msg)  
          print("start eval")
        end)
            
       
        params:hide("nb_crow_"..self.ext)


    end

    function player:note_on(note, vel)
        if tuning then return end
        -- I have zero idea why I have to add 50 cents to the tuning for it to sound right.
        -- But I do. WTF.
        local halfsteps = note - freq_to_note_num_float(params:get("nb_crow_freq"..self.ext))
        local v8 = halfsteps/12

        local freq_ix, nearest_voltage = find_nearest_value(frequencies[1],music.note_num_to_freq(note))
        v8 = tonumber(voltages[1][freq_ix])
        
        local v_vel = vel * 10
        local attack = params:get("nb_crow_attack_time"..self.ext)
        local attack_shape = ASL_SHAPES[params:get("nb_crow_attack_shape"..self.ext)]
        local decay = params:get("nb_crow_decay_time"..self.ext)
        local decay_shape = ASL_SHAPES[params:get("nb_crow_decay_shape"..self.ext)]
        local sustain = params:get("nb_crow_sustain"..self.ext)
        local portomento = params:get("nb_crow_portomento"..self.ext)
        local legato = params:get("nb_crow_legato"..self.ext)
        if self.count > 0 then
            crow.output[cv].action = string.format("{ to(%f,%f,sine) }", v8, portomento)
            crow.output[cv]()
            -- print("v8 execute",v8,note,self.count,cv)
        else
            crow.output[cv].volts = v8
        end
        local action
        if self.count > 0 and legato > 0 then
            action = string.format("{ to(%f,%f,'%s') }", v_vel*sustain, decay, decay_shape)
        else
            action = string.format("{ to(%f,%f,'%s'), to(%f,%f,'%s') }", v_vel, attack, attack_shape, v_vel*sustain, decay, decay_shape)
        end
        -- print(action)
        crow.output[env].action = action
        crow.output[env]()
        self.count = self.count + 1
    end

    function player:note_off(note)
        if tuning then return end
        self.count = self.count - 1
        if self.count <= 0 then
            self.count = 0
            local release = params:get("nb_crow_release_time"..self.ext)
            local release_shape = ASL_SHAPES[params:get("nb_crow_release_shape"..self.ext)]
            crow.output[env].action = string.format("{ to(%f,%f,'%s') }", 0, release, release_shape)
            crow.output[env]()
        end
    end

    function player:set_slew(s)
        params:set("nb_crow_portomento"..self.ext, s)
    end

    function player:describe(note)
        return {
            name = "crow "..cv.."/"..env,
            supports_bend = false,
            supports_slew = true,
            modulate_description = "unsupported",
        }
    end

    function player:active()
        params:show("nb_crow_"..self.ext)
        _menu.rebuild_params()
    end

    function player:inactive()
        params:hide("nb_crow_"..self.ext)
        _menu.rebuild_params()
    end

    function player:tune()
        print("OMG TUNING")
        tuning = true
        crow.output[cv].volts = 0
        crow.output[env].volts = 5

        local p = poll.set("pitch_in_l")
        p.callback = function(f) 
            print("in > "..string.format("%.2f",f))
            params:set("nb_crow_freq"..self.ext, f)
        end
        p.time = 0.25
        p:start()
        clock.run(function()
             clock.sleep(10)
             p:stop()
             crow.output[env].volts = 0
             -- crow.input[1].mode('none')
             clock.sleep(0.2)
             tuning = false
        end)
    end
    note_players["crow "..cv.."/"..env] = player
end

local function add_paraphonic_player()

    local env = 4

    local player = {
        ext = "_paraphonic",
        alloc = voice.new(3, voice.MODE_LRU),
        notes = {},
        voices = {},
        count = 0,
        tuning = false,
    }

    function player:add_params()
        params:add_group("nb_crow_"..self.ext, "crow para", 10)
        params:add_control("nb_crow_attack_time"..self.ext, "attack", controlspec.new(0.0001, 3, 'exp', 0, 0.1, "s"))
        params:add_option("nb_crow_attack_shape"..self.ext, "attack shape", ASL_SHAPES, 3)
        params:add_control("nb_crow_decay_time"..self.ext, "decay", controlspec.new(0.0001, 10, 'exp', 0, 1.0, "s"))
        params:add_option("nb_crow_decay_shape"..self.ext, "decay shape", ASL_SHAPES, 3)
        params:add_control("nb_crow_sustain"..self.ext, "sustain", controlspec.new(0.0, 1.0, 'lin', 0, 0.75, ""))
        params:add_control("nb_crow_release_time"..self.ext, "release", controlspec.new(0.0001, 10, 'exp', 0, 0.5, "s"))
        params:add_option("nb_crow_release_shape"..self.ext, "release shape", ASL_SHAPES, 3)
        params:add_binary("nb_crow_legato"..self.ext, "legato", "toggle", 1)
        params:add_control("nb_crow_freq"..self.ext, "tuned to", controlspec.new(20, 4000, 'exp', 0, 440, 'Hz', 0.0003))
        params:add_binary("nb_crow_tune"..self.ext, "tune", "trigger")
        params:set_action("nb_crow_tune"..self.ext, function()
            self:tune()
        end)
        params:hide("nb_crow_"..self.ext)
    end

    function player:reallocate()
        local lowest = nil
        for i=1,3 do
            local it = self.voices[i]
            if it ~= nil and (lowest == nil or it < lowest) then
                lowest = it
            end
        end
        if lowest == nil then return end
        for i=1,3 do
            if self.voices[i] == nil then
                crow.output[i].volts = lowest
            end
        end
    end

    function player:note_on(note, vel)
        if tuning then return end
        local slot = self.notes[note]
        if slot == nil then
            slot = self.alloc:get()
            self.count = self.count + 1
            self.notes[note] = slot
            slot.vel = vel
        end
        slot.on_release = function()
            self.voices[slot.id] = nil
            self.count = self.count - 1
            if self.count <= 0 then
                self.count = 0
                local release = params:get("nb_crow_release_time"..self.ext)
                local release_shape = ASL_SHAPES[params:get("nb_crow_release_shape"..self.ext)]
                -- print("release", string.format("{ to(%f,%f,'%s') }", 0, release, release_shape))
                crow.output[env].action = string.format("{ to(%f,%f,'%s') }", 0, release, release_shape)
                crow.output[env]()
            end
        end
        local halfsteps = note - freq_to_note_num_float(params:get("nb_crow_freq"..self.ext))
        local v8 = halfsteps/12
        local max_vel = vel
        for _, slot in pairs(self.notes) do
            max_vel = math.max(max_vel, slot.vel)
        end
        local v_vel = max_vel * 10
        local attack = params:get("nb_crow_attack_time"..self.ext)
        local attack_shape = ASL_SHAPES[params:get("nb_crow_attack_shape"..self.ext)]
        local decay = params:get("nb_crow_decay_time"..self.ext)
        local decay_shape = ASL_SHAPES[params:get("nb_crow_decay_shape"..self.ext)]
        local sustain = params:get("nb_crow_sustain"..self.ext)
        local legato = params:get("nb_crow_legato"..self.ext)
        crow.output[slot.id].volts = v8
        self.voices[slot.id] = v8
        self:reallocate()
        local action
        if self.count > 1 and legato > 0 then
            action = string.format("{ to(%f,%f,'%s') }", v_vel*sustain, decay, decay_shape)
        else
            action = string.format("{ to(%f,%f,'%s'), to(%f,%f,'%s') }", v_vel, attack, attack_shape, v_vel*sustain, decay, decay_shape)
        end
        crow.output[env].action = action
        crow.output[env]()
    end

    function player:note_off(note)
        if tuning then return end
        local slot = self.notes[note]
        if slot == nil then return end
        self.notes[note] = nil
        self.alloc:release(slot)
    end

    function player:pitch_bend(note, val)
        local slot = self.notes[note]
        if slot == nil then return end
        local halfsteps = note + val - freq_to_note_num_float(params:get("nb_crow_freq"..self.ext))
        local v8 = halfsteps/12
        crow.output[slot.id].volts = v8
        self.voices[slot.id] = v8
        self:reallocate()
    end

    function player:describe(note)
        return {
            name = "crow para",
            supports_bend = true,
            supports_slew = false,
            modulate_description = "unsupported",
        }
    end

    function player:stop_all()
        crow.output[env].volts = 0
    end

    function player:active()
        params:show("nb_crow_"..self.ext)
        _menu.rebuild_params()
    end

    function player:inactive()
        params:hide("nb_crow_"..self.ext)
        _menu.rebuild_params()
    end

    function player:tune()
        print("OMG TUNING")
        tuning = true
        for i=1,3 do
            crow.output[i].volts = 0
        end
        crow.output[env].volts = 5

        local p = poll.set("pitch_in_l")
        p.callback = function(f) 
            print("in > "..string.format("%.2f",f))
            params:set("nb_crow_freq"..self.ext, f)
        end
        p.time = 0.25
        p:start()
        -- This is crow pitch tracking that doesn't work
        -- crow.input[1].freq = function(f)
        --     print("freq is", f)
        --     params:set("nb_crow_freq"..self.ext, f)         
        -- end
        -- crow.input[1].mode( 'freq', 2)
        clock.run(function()
             clock.sleep(10)
             p:stop()
             crow.output[env].volts = 0
             -- crow.input[1].mode('none')
             clock.sleep(0.2)
             tuning = false
        end)
    end
    note_players["crow para"] = player
end

mod.hook.register("script_pre_init", "nb crow pre init", function()
    add_player(1, 2)
    add_player(3, 4)
    add_paraphonic_player()


    data_path_exists = os.rename(data_path, data_path) ~= nil
    print("path to nb_crow data dir",data_path,data_path_exists)
    if data_path_exists == false then
      os.execute("mkdir " .. data_path)
    end

    osc.send( { "localhost", 57120 }, "/sc_crooner/init",{data_path})
end)


mod.hook.register("script_post_init", "nb crow post init", function()
  --------------------------
  -- osc functions
  --------------------------
  local script_osc_event = osc.event

  function osc.event(path,args,from)
    if script_osc_event then script_osc_event(path,args,from) end
    
    -- script_osc_event(path,args,from)
    
    if path == "/lua_crooner/sc_inited" then
      print("sc inited")
      -- osc.send( { "localhost", 57120 }, "/sc_crooner/start_evaluation")
    elseif path == "/lua_crooner/pitch_evaluation_completed" then
      local crow_output=tonumber(args[1])
      local success=tonumber(args[2])
      local first_pitch=tonumber(args[3])
      local last_pitch=tonumber(args[4])
      local first_voltage=tonumber(args[5])
      local last_voltage=tonumber(args[6])

      print(success==1 and "sucess" or "fail")
      if success==1 then
        print("first_pitch/last_pitch - first_voltage/last_voltage: " ..
          first_pitch .. "/" .. last_pitch .. " - " ..
          first_voltage .. "/" ..last_voltage)
        load_freqs_volts(crow_output)
      else
        print("pitch eval failed")
      end
      tuning = false


    elseif path == "/lua_crooner/pitch_confidence" then
      
      -- update_freq(args[1])
      
      -- current_fpc_freq=args[1]
      -- current_fpc_conf=args[2]
      -- print("pitch/confidence: ", args[1],args[2])
    elseif path == "/lua_crooner/set_crow_voltage" then
      -- print("cout",args)
      local output = tonumber(args[1])
      local volts = args[2]
      test_voltage = volts
      crow.output[output].volts = volts
    elseif path == "/lua_crooner/frequencies" then
      ftab=args
      tab.print(args)
    elseif path == "/lua_crooner/closest_frequency" then
      local closest_frequency = tonumber(args[1])
      local closest_voltage = tonumber(args[2])
      local prior_closest = tonumber(args[3])
      local index = tonumber(args[4])
      print("found closest freq/volt", closest_frequency, closest_voltage,prior_closest,index)
    end
  end
  -- load_freqs_volts(1)
end)

mod.hook.register("script_post_cleanup", "clear the matrix for the next script", function()
  print("np_crow cleanup")
  osc.event = script_osc_event

end)
