const builtin = @import("builtin");
pub const sdf = @import("sdf.zig");
pub const Vmm = @import("vmm.zig");
pub const lionsos = @import("lionsos.zig");
pub const sddf = @import("sddf/sddf.zig");
pub const dtb = @import("dtb.zig");
pub const data = @import("data.zig");
pub const log = @import("log.zig");

comptime {
    // Zig has many breaking changes between minor releases so it is important that
    // we check the user has the right version.
    if (!(builtin.zig_version.major == 0 and builtin.zig_version.minor == 15)) {
        @compileError("expected Zig version 0.15.x to be used, you have " ++ builtin.zig_version_string);
    }
}
