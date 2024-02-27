
Crooner {
  classvar sender, freq, conf, fluidPitch, s;
  classvar <starting_freq= 120,<starting_voltage= -5, <ending_voltage=5,<sample_rate=100;
  classvar first_detected_pitch_voltage,last_detected_pitch_voltage,first_detected_pitch, last_detected_pitch;
  classvar prior_freq=0;
  classvar current_voltage, voltage_incr=0.001, voltage_confidence_level = 0.20, voltage_confidence_hits=0, evaluating=false, 
  <frequencies, <rounded_frequencies, <freq_distances,<voltages,
  found_first_frequency=false;
  classvar samples_per_volt=10;
  classvar lua_sender;     
  classvar data_path;     
  // classvar sc_sender = NetAddr.new("127.0.0.1",57120); 

  
   *dynamicInit {
      if (fluidPitch == nil, {
        fluidPitch = Synth('FluidPitchDetector');
        fluidPitch.set(\crow_output,1);
        frequencies = Array.newClear(4);
        // freq_distances = Array.newClear(4);
        rounded_frequencies = Array.newClear(4);
        voltages = Array.newClear(4);
        lua_sender = NetAddr.new("127.0.0.1",10111);     
        lua_sender.sendMsg("/lua_crooner/sc_inited");
        "dynamic init, fluidPitch synth created".postln;
      });
  }

  *initClass {
    StartUp.add {
      s = Server.default;
      
      //////////////
      //init
      //////////////
      OSCFunc.new({ |msg, time, addr, recvPort|
        "init".postln;
        data_path = msg[1];
        ("data path " ++ data_path).postln;
        Routine.new({
          
          SynthDef('FluidPitchDetector', {
            arg crow_output=1;
            var in = SoundIn.ar(0);
            # freq, conf = FluidPitch.kr(in,windowSize:1024);
            SendReply.kr(Impulse.kr(500), "/sc_crooner/update_freq_conf", [freq, conf]);
            SendReply.kr(Impulse.kr(500), "/sc_crooner/evaluate", [crow_output,freq, conf]);
          }).add;

          s.sync;


          //////////////
          //send frequencies table
          //////////////
          OSCFunc.new({ |msg, time, addr, recvPort|
            var chars_per_slice = 800;
          }, "/sc_crooner/get_freqs");

          //////////////
          //find closest frequency
          //////////////
          OSCFunc.new({ |msg, time, addr, recvPort|
            var closest_frequency, closest_voltage, prior_closest,ix,
            target_frequency,crow_output_ix;

            target_frequency=msg[1].asInteger;
            switch(msg[2].asInteger,
              1,{crow_output_ix=0},
              2,{crow_output_ix=1},
              3,{crow_output_ix=2},
              4,{crow_output_ix=3},
            );            

            (["find closest freq/voltage",target_frequency]).postln;
            (["target_frequency, frequencies[i] ",target_frequency, frequencies[crow_output_ix][0],frequencies[crow_output_ix][1],frequencies]).postln;
            ix = frequencies[crow_output_ix].indexIn(target_frequency);
            closest_frequency = frequencies[crow_output_ix][ix];
            closest_voltage = voltages[crow_output_ix][ix];
            prior_closest = voltages[crow_output_ix][ix-1];
            lua_sender.sendMsg("/lua_crooner/closest_frequency", closest_frequency, closest_voltage, prior_closest, ix);
          }, "/sc_crooner/find_closest_frequency");

          //////////////
          // set crow output from lua
          //////////////
          OSCFunc.new({ |msg, time, addr, recvPort|
            var output = msg[1].asInteger;
            (["set_crow_output", output]).postln;
            fluidPitch.set(\crow_output,output);
            evaluating = false;
          }, "/sc_crooner/set_crow_output");

          //////////////
          // send frequency and confidence data to lua 
          //////////////
          OSCFunc.new({ |msg, time, addr, recvPort|
            var frequency = msg[3];
            var confidence = msg[4];
            lua_sender.sendMsg("/lua_crooner/pitch_confidence", frequency, confidence);
          }, "/sc_crooner/update_freq_conf");

          //////////////
          // voltage & frequency evaluation 
          //////////////

          //start_evaluation
          OSCFunc.new({ |msg, time, addr, recvPort|
            var crow_output_ix;
            starting_freq = msg[4];
            starting_voltage = msg[5]-0.5;
            ending_voltage = msg[6];
            current_voltage = starting_voltage;
            first_detected_pitch_voltage = nil;
            last_detected_pitch_voltage = nil;
            first_detected_pitch = nil;
            last_detected_pitch = nil;
            found_first_frequency = false;
            voltage_confidence_hits=0;
            prior_freq=0; 
            switch(msg[1].asInteger,
              1,{crow_output_ix=0},
              2,{crow_output_ix=1},
              3,{crow_output_ix=2},
              4,{crow_output_ix=3},
            );            
            if (msg[2]>0,{voltage_incr=msg[2]});
            if (msg[3]>0,{voltage_confidence_level=msg[3]});
            (["starting freq",starting_freq]).postln;
            (["crow output set to",crow_output_ix]).postln;
            (["voltage_incr: ",voltage_incr,msg[2]]).postln;
            (["confidence level: ",voltage_confidence_level]).postln;
            (["array size ",((ending_voltage - starting_voltage)/voltage_incr).round]).postln;
            frequencies[crow_output_ix]=Array.new(((ending_voltage - starting_voltage)/voltage_incr).round);
            rounded_frequencies[crow_output_ix]=Array.new(((ending_voltage - starting_voltage)/voltage_incr).round);
            // freq_distances[crow_output_ix]=Array.new(((ending_voltage - starting_voltage)/voltage_incr).round);
            voltages[crow_output_ix]=Array.new(((ending_voltage - starting_voltage)/voltage_incr).round);
            Routine.new({
              0.5.wait;
            }).play;
            evaluating = true;
            ("start evaluation ").postln;  
          }, "/sc_crooner/start_evaluation");

          //evaluate
          OSCFunc.new({ |msg, time, addr, recvPort|
            var crow_output, crow_output_ix, voltage, frequency, confidence;
            var rounded_frequencies_sorted,last_freq_ix;
            var freqs_file,volts_file,freqs_string,volts_string;
            if (evaluating == true, {
              voltage=current_voltage;
              frequency = msg[4];
              confidence = msg[5];
              switch(msg[3],
                1.0,{crow_output="1";crow_output_ix=0},
                2.0,{crow_output="2";crow_output_ix=1},
                3.0,{crow_output="3";crow_output_ix=2},
                4.0,{crow_output="4";crow_output_ix=3},
              );
              lua_sender.sendMsg("/lua_crooner/set_crow_voltage", crow_output, voltage);
              // if ((confidence > voltage_confidence_level).and(frequency.round(0.01) >= prior_freq.round(0.01)).and(found_first_frequency == false), {
              if ((frequency<=(starting_freq+10)).and(confidence > voltage_confidence_level).and(found_first_frequency == false), {
                if (voltage_confidence_hits >= 20, {
                  (["found first frequency: ",
                    found_first_frequency,
                    first_detected_pitch_voltage, 
                    first_detected_pitch,
                    confidence,
                    voltage_confidence_hits,
                    ending_voltage,
                    starting_voltage]).postln;
                  // (["frequency.round(0.01) > prior_freq.round(0.01)",frequency.round(0.01) , prior_freq.round(0.01)]).postln;
                  found_first_frequency = true;
                });
                if (voltage_confidence_hits == 0, {
                  first_detected_pitch_voltage = voltage;
                  first_detected_pitch = frequency;
                  // (["hit 0: ",first_detected_pitch_voltage, frequency,confidence]).postln;
                });
                voltage_confidence_hits = voltage_confidence_hits + 1;
              },{
                if ((voltage_confidence_hits > 0).and(found_first_frequency == false),{
                  // haven't yet found the first pitch, reset the frequency and voltage arrays
                  frequencies[crow_output_ix]=Array.new(((ending_voltage - starting_voltage)/voltage_incr).round);
                  rounded_frequencies[crow_output_ix]=Array.new(((ending_voltage - starting_voltage)/voltage_incr).round);
                  voltages[crow_output_ix]=Array.new(((ending_voltage - starting_voltage)/voltage_incr).round);            
                  voltage_confidence_hits = 0;
                  first_detected_pitch_voltage = nil;
                });
              });
              
              if (confidence > voltage_confidence_level, {
                if ((found_first_frequency == true).and(frequency.round(0.1) > prior_freq.round(0.1)), {
                  frequencies[crow_output_ix].add(frequency);
                  rounded_frequencies[crow_output_ix].add(frequency.round(0.1));
                  voltages[crow_output_ix].add(voltage);
                });
              });

              if ((found_first_frequency == true), {
                var arLen = frequencies[crow_output_ix].size;

                // if (frequencies[crow_output_ix].size > 2,{
                  // freq_distances[crow_output_ix].add(((frequencies[crow_output_ix][arLen-1])-(frequencies[crow_output_ix][arLen-2])));
                // });

                if (current_voltage >= ending_voltage, {
                  // [(frequencies[crow_output_ix][arLen-1])-(frequencies[crow_output_ix][arLen-2])].postln;
                  // (freq_distances[crow_output_ix].sum/freq_distances[crow_output_ix].size).postln;
                  "done".postln;
                  freqs_string = frequencies[crow_output_ix].collect{|v| v.asString }.reduce({|l, r| l ++ "," ++ r });
                  freqs_file = File(data_path++"frequencies"++crow_output++".txt".standardizePath,"w");
                  freqs_file.write( freqs_string );
                  freqs_file.close;
                  volts_string = voltages[crow_output_ix].collect{|v| v.asString }.reduce({|l, r| l ++ "," ++ r });
                  volts_file = File(data_path++"voltages"++crow_output++".txt".standardizePath,"w");
                  volts_file.write( volts_string );
                  volts_file.close;

                  last_freq_ix = frequencies[crow_output_ix].size-1;
                  last_detected_pitch = frequency;

                  last_detected_pitch_voltage = voltages[crow_output_ix][last_freq_ix];
                  (["set last_detected_pitch_voltage", last_freq_ix,last_detected_pitch_voltage,last_detected_pitch]).postln;

                  evaluating=false;
                  lua_sender.sendMsg("/lua_crooner/set_crow_voltage", crow_output, last_detected_pitch_voltage);
                  lua_sender.sendMsg("/lua_crooner/pitch_evaluation_completed", crow_output, 1, first_detected_pitch, last_detected_pitch, first_detected_pitch_voltage, last_detected_pitch_voltage);
                  (["done evaluating (first/last frequency/voltage)",first_detected_pitch, last_detected_pitch, first_detected_pitch_voltage, last_detected_pitch_voltage,frequencies.size,voltages.size]).postln;
                });
                prior_freq = frequency;                  
                current_voltage = current_voltage + voltage_incr;

              });

              current_voltage = current_voltage + voltage_incr;
              
            });
          }, "/sc_crooner/evaluate");


          Crooner.dynamicInit();
        }).play
      }, "/sc_crooner/init");

    }
  }

  free {
    ("free crooner objects").postln;
  }

}