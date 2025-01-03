const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap-bindings");

const Plugin = @import("../plugin.zig");
const Params = @import("../ext/params.zig");
const waves = @import("waves.zig");
const ADSR = @import("adsr.zig");
const Voices = @import("voices.zig");

const Parameter = Params.Parameter;
const Voice = Voices.Voice;
const Expression = Voices.Expression;

const Wave = waves.Wave;

fn calculatePhaseOffsetForSecondVoice(voice: *const Voice, previous_voice: ?*const Voice, sample_rate: f64) u64 {
    if (previous_voice) |prev| {
        const original_key = prev.getTunedKey();
        const original_frequency = waves.getFrequency(original_key);
        const original_phase = (original_frequency / sample_rate) * @as(f64, @floatFromInt(prev.elapsed_frames));

        const new_key = voice.getTunedKey();
        const new_frequency = waves.getFrequency(new_key);
        // (new_frequency / sample_rate) * frames = original_phase
        return @intFromFloat(original_phase * (sample_rate / new_frequency));
    }
    return 0;
}

// Processing logic
pub fn processNoteChanges(plugin: *Plugin, event: *const clap.events.Header) void {
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
                plugin.params.get(Parameter.Attack),
                plugin.params.get(Parameter.Decay),
                plugin.params.get(Parameter.Sustain),
                plugin.params.get(Parameter.Release),
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
    const wave_value: u32 = @intFromFloat(plugin.params.values.get(Parameter.WaveShape));
    const wave_type: Wave = std.meta.intToEnum(Wave, wave_value) catch Wave.Sine;

    var index = start;
    while (index < end) : (index += 1) {
        var voice_sum_l: f64 = 0;
        var voice_sum_r: f64 = 0;
        var voice_sum_mono: f64 = 0;
        for (plugin.voices.voices.items) |*voice| {
            var wave: f64 = undefined;
            const t: f64 = @floatFromInt(voice.elapsed_frames);

            // retrieve the wave data from the pre-calculated table
            wave = waves.get(&plugin.wave_table, wave_type, plugin.sample_rate.?, voice.getTunedKey(), t);

            // Elapse the voice time by a frame and update envelope
            voice.elapsed_frames += 1;

            const pan = voice.expression_values.get(Expression.pan);
            voice_sum_mono += wave * voice.adsr.value * 0.5;
            voice_sum_l += voice_sum_mono * (1 - pan);
            voice_sum_r += voice_sum_mono * pan;

            const dt = (1 / plugin.sample_rate.?) * 1000;
            voice.adsr.update(dt);
        }

        var output_l: f32 = @floatCast(voice_sum_l);
        var output_r: f32 = @floatCast(voice_sum_r);

        if (plugin.params.get(.ScaleVoices) == 1.0) {
            // Apply scaling to prevent the amplitude to go too crazy
            const scaling = 1.0 / @max(1, std.math.sqrt(@as(f32, @floatFromInt(plugin.voices.getVoiceCount()))));
            output_l *= scaling;
            output_r *= scaling;
        }
        output_left[index] = output_l;
        output_right[index] = output_r;
    }
}
