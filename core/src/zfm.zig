pub const Sample = f32;
pub const Frame = [2]Sample;
pub const sample_rate = 48_000;
pub const sample_time: f32 = 1.0 / @as(f32, @floatFromInt(sample_rate));

pub const Synth = @import("./Synth.zig");
pub const Driver = @import("./Driver.zig");
pub const Module = @import("./Module.zig");
pub const Compiler = @import("./Compiler.zig");

test {
    _ = Synth;
    _ = Driver;
    _ = Module;
    _ = Compiler;
}
