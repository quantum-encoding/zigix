# A52: ext4 Dual-Architecture Integration

**Date:** 2026-02-13
**Milestone:** A52

## What Happened

All ext4 Phase 2 (E1-E6) and Phase 3 (X1-X2) modules already existed in
`kernel/fs/ext4/` and `kernel/fs/common/`. They were fully integrated into
x86_64's `kernel/fs/ext2.zig` — but ARM64's `kernel/arch/aarch64/ext2.zig`
had **zero** ext4 code.

The real work was porting the ext4 integration to ARM64.

## Module Path Problem

Zig's build system enforces a module boundary: `@import()` cannot reach files
outside the module root directory.

**Failed approach:**
```
build.zig: module root = kernel/fs/ext4/ext4.zig
ext4/inode_ext4.zig: @import("../common/crc32c.zig")  // ERROR: outside module
```

**Working approach:**
```
build.zig: module root = kernel/fs/ext4_module.zig  (at kernel/fs/ level)
ext4/inode_ext4.zig: @import("../common/crc32c.zig")  // OK: within kernel/fs/
```

Created `kernel/fs/ext4_module.zig` as a re-export hub:
```zig
pub const extents = @import("ext4/extents.zig");
pub const inode_ext4 = @import("ext4/inode_ext4.zig");
pub const block_group_64 = @import("ext4/block_group_64.zig");
// ... etc
```

## ARM64 ext2.zig Changes

### State variables
```zig
var desc_size: u16 = 32;       // 32 for ext2/3, 64 for ext4-64bit
var is_64bit_mode: bool = false;
```

### init() — 64-bit BGD detection
Reads `s_desc_size` from superblock raw bytes (offset 254-255).
Calls `block_group_64.is64Bit()` and `block_group_64.descSize()`.

### blockGroupInodeTable64() — new function
Combines low 32 bits from standard BGD + high 32 bits from 64-bit BGD
for inode table block addresses > 4GB.

### readBlockGroup() — updated
Uses module-level `desc_size` instead of hardcoded 32.

### loadInodeDisk() — ext4 additions
- Uses `blockGroupInodeTable64()` for inode table address
- Verifies CRC32c inode checksum if `RO_COMPAT_METADATA_CSUM` is set

### writeInodeDisk() — ext4 additions
- Uses `blockGroupInodeTable64()` for inode table address
- Stores CRC32c inode checksum if `RO_COMPAT_METADATA_CSUM` is set

### getFileBlock() — extent tree path
```zig
if (extents.usesExtents(inode.i_flags)) {
    const iblock: *const [60]u8 = @ptrCast(&inode.i_block);
    const phys = extents.lookup(iblock, file_block, &readBlockConst);
    return @truncate(phys);
}
```

### getOrAllocFileBlock() — extent tree insert
Allocates block, calls `extents.insertInLeaf()` for extent-mapped inodes.

### readBlockConst() — new callback
Adapter function for extent tree: reads a block and returns `?[*]const u8`.

## run_aarch64.sh Changes

- Image filename: `ext2-aarch64.img` → `ext4-aarch64.img`
- Image builder: `make_ext2_img.py` → `make_ext4_img.py`
- Comment update to reflect ext4

## ext4 Image Features (make_ext4_img.py)

```
Inode size: 256 bytes (CRC32c checksummed)
Descriptor size: 64 bytes (64-bit mode)
Journal: 8192 blocks (32 MB)
Features: has_journal, filetype, extents, 64bit, extra_isize, metadata_csum
```

## Boot Verification

```
[ext2] block_size=4096, inodes=16384, groups=1, ext4-64bit desc_size=64
[ext3] Journal detected (inode 8)
[ext3] Journal replay complete (0 transactions, 0 blocks)
```

Full boot to login prompt with zhttpd on port 80, 2 CPUs online.

## ext4 Module Inventory

| File | Lines | Purpose |
|------|-------|---------|
| `common/crc32c.zig` | 66 | CRC32c with IETF test vectors |
| `ext4/inode_ext4.zig` | 194 | 256-byte inode checksums |
| `ext4/block_group_64.zig` | 180 | 64-bit BGD with checksums |
| `ext4/extents.zig` | 290 | Extent tree B-tree |
| `ext4/htree.zig` | ~200 | HTree indexed directories |
| `ext4/mballoc.zig` | ~300 | Multiblock allocator |
| `ext4/delayed_alloc.zig` | ~200 | Delayed allocation |
| `ext4/flex_bg.zig` | ~150 | Flexible block groups |
| `common/superblock.zig` | 231 | Unified ext2/3/4 parser |
| `ext4_module.zig` | 11 | Build system re-export hub |
