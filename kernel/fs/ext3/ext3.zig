/// ext3 module root — re-exports all ext3 journal components.
/// Used as a single named module for architectures where the ext3 directory
/// lives outside the compilation root (e.g., ARM64).

pub const mount = @import("ext3_mount.zig");
pub const journal = @import("journal.zig");
pub const block_io = @import("block_io.zig");
pub const types = @import("journal_types.zig");
pub const replay = @import("journal_replay.zig");
