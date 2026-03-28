/// ext4 module entry point for cross-directory imports.
/// Rooted at kernel/fs/ so that ext4/ files can reach common/ via relative paths.

pub const extents = @import("ext4/extents.zig");
pub const htree = @import("ext4/htree.zig");
pub const inode_ext4 = @import("ext4/inode_ext4.zig");
pub const mballoc = @import("ext4/mballoc.zig");
pub const block_group_64 = @import("ext4/block_group_64.zig");
pub const flex_bg = @import("ext4/flex_bg.zig");
pub const delayed_alloc = @import("ext4/delayed_alloc.zig");
