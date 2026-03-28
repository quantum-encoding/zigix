# Zigix Filesystem Upgrade: ext2 → ext3 → ext4

## Overview

This project upgrades the Zigix kernel's filesystem from ext2 (currently working, read/write, serving HTTP and SSH) through ext3 (adds journaling for crash recovery) to ext4 (full Linux parity with extents, HTree directories, checksums, and 64-bit support).

The existing ext2 implementation lives at `zigix/kernel/fs/ext2.zig` and is approximately 1,200 lines. It supports: superblock parsing, block group descriptors, inode read/write, block allocation/deallocation, directory entry read/write/create, file read/write, and symlinks.

## Strategy

**Phase 1 (ext3):** Add journaling on top of ext2. Same on-disk format. Only addition is a journal in inode 8. After this phase, fork the codebase — maintain an ext3 kernel (stable) and an ext4 kernel (full-featured).

**Phase 2 (ext4 non-breaking):** Add features that don't change core block mapping: CRC32c checksums, 256-byte inodes with nanosecond timestamps, 64-bit block group descriptors, flexible block groups, multiblock allocator, delayed allocation.

**Phase 3 (ext4 structural):** Replace indirect block map with extent tree. Add HTree indexed directories. These are the biggest changes but also the biggest wins.

## Milestone Execution Order

```
PHASE 1 — ext3 Journaling (~800-1000 lines, 4-5 sessions):

  J1: Journal types/structures     → ext3/CLAUDE.md §J1    [NO DEPS]
  J2: Journal replay (recovery)    → ext3/CLAUDE.md §J2    [DEPENDS: J1]
  J3: Journal write path           → ext3/CLAUDE.md §J3    [DEPENDS: J1]
  J4: Mount integration            → ext3/CLAUDE.md §J4    [DEPENDS: J2, J3]
  J5: ext3 image builder           → tests/CLAUDE.md §J5   [NO DEPS, parallel]

PHASE 2 — ext4 Non-Breaking (~1500-2000 lines, 6-8 sessions):

  E1: CRC32c checksums             → common/CLAUDE.md §E1  [NO DEPS]
  E2: 256-byte inodes              → ext4/CLAUDE.md §E2    [DEPENDS: E1]
  E3: 64-bit block group descs     → ext4/CLAUDE.md §E3    [NO DEPS]
  E4: Flexible block groups         → ext4/CLAUDE.md §E4    [NO DEPS]
  E5: Multiblock allocator          → ext4/CLAUDE.md §E5    [SOFT DEP: E4]
  E6: Delayed allocation            → ext4/CLAUDE.md §E6    [DEPENDS: E5]

PHASE 3 — ext4 Structural (~1200-1500 lines, 3-4 sessions):

  X1: Extent tree                   → ext4/CLAUDE.md §X1   [DEPENDS: E3, E5]
  X2: HTree indexed directories     → ext4/CLAUDE.md §X2   [DEPENDS: E1]
```

## Parallel Execution Map

```
Time →
Agent 1: [J1] → [J2] → [J4] ──────────────────→ [X1 extent tree]
Agent 2: [J5] → [J3] → ─────────────────────────→ [X2 htree]
Agent 3: ──────→ [E1 crc32c] → [E2 inodes] ────→ done
Agent 4: ──────→ [E3 64-bit] → [E4 flex_bg] ──→ done
Agent 5: ────────────────────→ [E5 mballoc] → [E6 delalloc]
```

With 3-5 agents running parallel, the entire project is completable in ~5-7 days.

## File Locations

All new code goes into `zigix/kernel/fs/`:

```
zigix/kernel/fs/
├── ext2.zig                 ← EXISTING, do not modify during Phase 1
├── ext3/
│   ├── journal_types.zig    ← J1: on-disk structures
│   ├── journal_replay.zig   ← J2: recovery/replay
│   ├── journal.zig          ← J3: transaction write path
│   └── ext3_mount.zig       ← J4: mount/unmount integration
├── ext4/
│   ├── extents.zig          ← X1: extent tree B-tree
│   ├── htree.zig            ← X2: HTree indexed directories
│   ├── inode_ext4.zig       ← E2: 256-byte inode support
│   ├── block_group_64.zig   ← E3: 64-bit block group descriptors
│   ├── flex_bg.zig          ← E4: flexible block groups
│   ├── mballoc.zig          ← E5: multiblock allocator
│   └── delayed_alloc.zig    ← E6: delayed allocation
├── common/
│   ├── crc32c.zig           ← E1: CRC32c checksum implementation
│   ├── superblock.zig       ← Shared superblock parsing (all versions)
│   └── bitmap.zig           ← Shared bitmap operations
└── tests/
    ├── test_journal.zig     ← Journal write/replay tests
    ├── test_extents.zig     ← Extent tree tests
    └── test_images/
        ├── make_ext3_img.sh ← Generate ext3 test images
        └── make_ext4_img.sh ← Generate ext4 test images
```

## Critical Constraints

1. **Do NOT break ext2.** The existing ext2 implementation must continue working unchanged. ext3 adds to it, ext4 extends it. Feature flags in the superblock determine which code path runs.

2. **All code is freestanding Zig.** No libc, no std. The kernel provides blockRead()/blockWrite() for disk I/O. Use the same patterns as the existing ext2.zig.

3. **Both architectures.** All filesystem code is architecture-independent. It compiles for both x86_64 and aarch64 without changes.

4. **Test with real Linux images.** Create ext3/ext4 images using Linux mkfs tools, mount in Zigix, verify correct parsing. This catches spec interpretation errors early.

5. **Syscall numbers.** The VFS layer (vfs.zig) already dispatches to ext2 functions. New filesystem features integrate at the same level — the VFS doesn't need to know whether it's ext2/3/4 underneath.

## Feature Flags Reference

```zig
// Superblock s_feature_compat
const HAS_JOURNAL: u32 = 0x0004;        // ext3

// Superblock s_feature_incompat
const FILETYPE: u32 = 0x0002;           // dir entries have type (already in ext2)
const RECOVER: u32 = 0x0004;            // journal needs replay
const EXTENTS: u32 = 0x0040;            // ext4 extent tree
const BIT64: u32 = 0x0080;              // 64-bit block numbers
const FLEX_BG: u32 = 0x0200;            // flexible block groups

// Superblock s_feature_ro_compat
const SPARSE_SUPER: u32 = 0x0001;
const LARGE_FILE: u32 = 0x0002;
const HUGE_FILE: u32 = 0x0008;
const GDT_CSUM: u32 = 0x0010;
const EXTRA_ISIZE: u32 = 0x0040;
const METADATA_CSUM: u32 = 0x0400;

// Inode i_flags
const EXTENTS_FL: u32 = 0x00080000;     // inode uses extent tree
const INDEX_FL: u32 = 0x00001000;       // directory uses HTree
```

## Success Criteria

- Phase 1 complete: Zigix boots from ext3 image, survives simulated crash, journal replays correctly
- Phase 2 complete: Zigix reads ext4 images created by Linux (256-byte inodes, checksums validate)
- Phase 3 complete: Zigix creates and reads files using extent tree, large directories use HTree
- Full demo: Same zhttpd serving files from ext4 filesystem on both x86_64 and ARM64
