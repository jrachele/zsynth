const AudioPorts = @import("ext/audioports.zig");
const NotePorts = @import("ext/noteports.zig");
const Params = @import("ext/params.zig");
const State = @import("ext/state.zig");
const GUI = @import("ext/gui.zig");

pub const ext_audio_ports = AudioPorts.create();
pub const ext_note_ports = NotePorts.create();
pub const ext_params = Params.create();
pub const ext_state = State.create();
pub const ext_gui = GUI.create();
