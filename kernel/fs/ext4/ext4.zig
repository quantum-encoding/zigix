/// ext4 module root — re-exports all ext4 components.
/// Used as a single named module for architectures where the ext4 directory
/// lives outside the compilation root (e.g., ARM64).

pub const extents = @import("extents.zig");
pub const htree = @import("htree.zig");
pub const inode_ext4 = @import("inode_ext4.zig");
pub const mballoc = @import("mballoc.zig");
pub const block_group_64 = @import("block_group_64.zig");
pub const flex_bg = @import("flex_bg.zig");
pub const delayed_alloc = @import("delayed_alloc.zig");
