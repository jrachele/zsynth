const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap-bindings");
const tracy = @import("tracy");

const Plugin = @import("../plugin.zig");
const Params = @import("../ext/params.zig");
const ThreadPool = @import("../ext/thread_pool.zig");
const ADSR = @import("adsr.zig");
const Voices = @import("voices.zig");

const waves = @import("waves.zig");

const Wave = waves.Wave;
const Parameter = Params.Parameter;
const Voice = Voices.Voice;
const Expression = Voices.Expression;

fn calculatePhaseOffsetForSecondVoice(voice: *const Voice, previous_voice: ?*const Voice, sample_rate: f64) u64 {
    if (previous_voice) |prev| {
        const original_key = prev.getTunedKey(0, 0);
        const original_frequency = waves.getFrequency(original_key);
        const original_phase = (original_frequency / sample_rate) * @as(f64, @floatFromInt(prev.elapsed_frames));

        const new_key = voice.getTunedKey(0, 0);
        const new_frequency = waves.getFrequency(new_key);
        // (new_frequency / sample_rate) * frames = original_phase
        return @intFromFloat(original_phase * (sample_rate / new_frequency));
    }
    return 0;
}

// Processing logic
pub fn processNoteChanges(plugin: *Plugin, event: *const clap.events.Header) void {
    const zone = tracy.ZoneN(@src(), "Note change");
    defer zone.End();

    if (event.space_id != clap.events.core_space_id) {
        return;
    }
    switch (event.type) {
        .note_on => {
            // A new note was pressed
            const note_event: *const clap.events.Note = @ptrCast(@alignCast(event));

            // Voice stealing
            if (Voices.getVoiceByKey(plugin.voices.voices.items, note_event.key)) |voice| {
                voice.adsr.reset();
                return;
            }

            const adsr = ADSR.init(
                plugin.params.get(Parameter.Attack).Float,
                plugin.params.get(Parameter.Decay).Float,
                plugin.params.get(Parameter.Sustain).Float,
                plugin.params.get(Parameter.Release).Float,
            );

            var new_voice = Voice{};
            new_voice = .{
                .noteId = note_event.note_id,
                .channel = note_event.channel,
                .key = note_event.key,
                .velocity = note_event.velocity,
                .adsr = adsr,
            };

            // Calculate phase offset based on previous voice
            // if (plugin.voices.voices.getLastOrNull()) |previous_voice| {
            //     new_voice.elapsed_frames = calculatePhaseOffsetForSecondVoice(&new_voice, &previous_voice, plugin.sample_rate.?);
            // }

            plugin.voices.addVoice(new_voice) catch unreachable;
        },
        .note_off => {
            const note_event: *const clap.events.Note = @ptrCast(@alignCast(event));

            for (plugin.voices.getVoices()) |*voice| {
                if ((voice.channel == note_event.channel or note_event.channel == .unspecified) and
                    (voice.key == note_event.key or note_event.key == .unspecified) and
                    (voice.noteId == note_event.note_id or note_event.note_id == .unspecified))
                {
                    voice.adsr.onNoteOff();
                }
            }
        },
        .note_choke => {
            const note_event: *const clap.events.Note = @ptrCast(@alignCast(event));

            for (plugin.voices.getVoices(), 0..) |*voice, i| {
                if ((voice.channel == note_event.channel or note_event.channel == .unspecified) and
                    (voice.key == note_event.key or note_event.key == .unspecified) and
                    (voice.noteId == note_event.note_id or note_event.note_id == .unspecified))
                {
                    _ = plugin.voices.voices.orderedRemove(i);
                    return;
                }
            }
        },
        .note_expression => {
            const note_expression_event: *const clap.events.NoteExpression = @ptrCast(@alignCast(event));
            if (Voices.getVoiceByKey(plugin.voices.voices.items, note_expression_event.key)) |voice| {
                // When we detune, shift the phase appropriately to match the phase of the previous tuning
                if (note_expression_event.expression_id == .tuning) {
                    const voice_before_tuning = voice.*;

                    voice.expression_values.set(note_expression_event.expression_id, note_expression_event.value);
                    voice.elapsed_frames = calculatePhaseOffsetForSecondVoice(voice, &voice_before_tuning, plugin.sample_rate.?);
                } else {
                    voice.expression_values.set(note_expression_event.expression_id, note_expression_event.value);
                }
            }
        },
        else => {},
    }
}

pub fn renderAudio(plugin: *Plugin, start: u32, end: u32, output_left: [*]f32, output_right: [*]f32) void {
    const zone = tracy.ZoneN(@src(), "Render audio");
    defer zone.End();

    plugin.voices.render_payload = .{
        .start = start,
        .end = end,
        .output_left = output_left,
        .output_right = output_right,
    };

    var did_render_audio = false;
    const should_use_threadpool = builtin.mode != .Debug or plugin.params.get(Parameter.DebugBool1).Bool == true;
    // After this many voices, it's faster to multi-thread them
    if (should_use_threadpool) {
        if (plugin.host.getExtension(plugin.host, clap.ext.thread_pool.id)) |ext_raw| {
            const thread_pool: *const clap.ext.thread_pool.Host = @ptrCast(@alignCast(ext_raw));
            // This calls processVoice under the hood
            did_render_audio = thread_pool.requestExec(plugin.host, @intCast(plugin.voices.getVoiceCount()));
            if (!did_render_audio) {
                std.log.debug("Unable to dispatch voices to thread pool! Num voices: {d}", .{plugin.voices.getVoiceCount()});
            }
        }
    }

    // If the thread pool wasn't available, synchronously render all voices individually
    if (!did_render_audio) {
        for (0..plugin.voices.getVoiceCount()) |i| {
            ThreadPool._exec(&plugin.plugin, @intCast(i));
        }
    }
}

pub fn processVoice(plugin: *Plugin, voice_index: u32) !void {
    const zone = tracy.ZoneN(@src(), "Process voice");
    defer zone.End();

    var voices = &plugin.voices;
    if (voices.render_payload == null) {
        return error.NoRenderPayload;
    }

    if (voice_index >= voices.voices.items.len) {
        return error.InvalidVoiceIndex;
    }

    var render_payload = &voices.render_payload.?;

    const voice: *Voice = voices.getVoice(@intCast(voice_index)).?;

    const osc1_wave_value: u32 = @intFromEnum(plugin.params.get(.WaveShape1).Wave);
    const osc1_wave_shape: Wave = try std.meta.intToEnum(Wave, osc1_wave_value);
    const osc2_wave_value: u32 = @intFromEnum(plugin.params.get(.WaveShape2).Wave);
    const osc2_wave_shape: Wave = try std.meta.intToEnum(Wave, osc2_wave_value);
    const osc1_detune: f64 = plugin.params.get(.Pitch1).Float;
    const osc2_detune: f64 = plugin.params.get(.Pitch2).Float;
    const osc1_octave: f64 = plugin.params.get(.Octave1).Float;
    const osc2_octave: f64 = plugin.params.get(.Octave2).Float;
    const oscillator_mix: f64 = plugin.params.get(.Mix).Float;

    var index = render_payload.start;
    while (index < render_payload.end) : (index += 1) {
        var voice_sum_l: f64 = 0;
        var voice_sum_r: f64 = 0;
        var voice_sum_mono: f64 = 0;
        var wave: f64 = undefined;
        const t: f64 = @floatFromInt(voice.elapsed_frames);

        // retrieve the wave data from the pre-calculated table
        var osc1_wave: f64 = 0;
        var osc2_wave: f64 = 0;
        if (oscillator_mix < 1) {
            // Retrieve oscillator 1
            osc1_wave = waves.get(&plugin.wave_table, osc1_wave_shape, plugin.sample_rate.?, voice.getTunedKey(osc1_detune, osc1_octave), t);
        }
        if (oscillator_mix > 0) {
            // Retrieve oscillator 2
            osc2_wave = waves.get(&plugin.wave_table, osc2_wave_shape, plugin.sample_rate.?, voice.getTunedKey(osc2_detune, osc2_octave), t);
        }

        const zone_postprocess = tracy.ZoneN(@src(), "Wave post-process");
        defer zone_postprocess.End();
        wave = (osc1_wave * (1 - oscillator_mix)) + (osc2_wave * oscillator_mix);

        // Elapse the voice time by a frame and update envelope
        voice.elapsed_frames += 1;

        const pan = voice.expression_values.get(Expression.pan);
        voice_sum_mono += wave * voice.adsr.value * 0.5;
        voice_sum_l += voice_sum_mono * (1 - pan);
        voice_sum_r += voice_sum_mono * pan;

        const dt = (1 / plugin.sample_rate.?) * 1000;
        voice.adsr.update(dt);

        var output_l: f32 = @floatCast(voice_sum_l);
        var output_r: f32 = @floatCast(voice_sum_r);

        if (plugin.params.get(.ScaleVoices).Bool) {
            // Apply scaling to prevent the amplitude from going too crazy
            const scaling = 1.0 / @max(1, std.math.sqrt(@as(f32, @floatFromInt(voices.getVoiceCount()))));
            output_l *= scaling;
            output_r *= scaling;
        }

        const zone_access_render_mutex = tracy.ZoneN(@src(), "Wave wait for render mutex and write");
        defer zone_access_render_mutex.End();
        voices.render_mutex.lock();
        defer voices.render_mutex.unlock();

        render_payload.output_left[index] += output_l;
        render_payload.output_right[index] += output_r;
    }
}
