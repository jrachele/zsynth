const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap-bindings");

const Plugin = @import("../plugin.zig");
const Params = @import("../ext/params.zig");
const ThreadPool = @import("../ext/thread_pool.zig");
const ADSR = @import("adsr.zig");
const Voices = @import("voices.zig");

const waves = @import("waves.zig");

const Parameter = Params.Parameter;
const Voice = Voices.Voice;
const Expression = Voices.Expression;

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
    plugin.voices.render_payload = .{
        .data_mutex = .{},
        .start = start,
        .end = end,
        .output_left = output_left,
        .output_right = output_right,
    };

    var did_render_audio = false;
    const should_use_threadpool = builtin.mode != .Debug or plugin.params.get(Parameter.DebugBool1).Bool == true;
    if (should_use_threadpool) {
        if (plugin.host.getExtension(plugin.host, clap.ext.thread_pool.id)) |ext_raw| {
            const thread_pool: *const clap.ext.thread_pool.Host = @ptrCast(@alignCast(ext_raw));
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
