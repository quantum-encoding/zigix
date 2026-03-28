# Zigix Filesystem Roadmap: ext2 → ext3 → ext4

## Strategy

Three phases, each building on the last. The ext2 implementation is the foundation — it already works, has read/write support, and passes real-world usage (133 binaries, HTTP server, SSH server serving files from it).

**Phase 1 (ext3):** Add journaling to ext2. Same on-disk format, same block groups, same inodes. The only addition is a journal in inode 8. This gives crash recovery without fsck.

**Phase 2 (ext4 — non-breaking features):** Add ext4 features that don't change the core block mapping. These can be done in parallel: 48-bit block addresses, nanosecond timestamps, checksums, flexible block groups, large extended attributes.

**Phase 3 (ext4 — extents):** Replace the indirect block map with the extent tree. This is the biggest single change but also the biggest performance win for large files. HTree directories follow.

After Phase 1, fork the project: maintain an ext3 kernel (stable, simple) and an ext4 kernel (full-featured, Linux parity). Both share 90%+ of the code — the divergence is in block mapping and directory indexing.

---

## Folder Structure

```
zigix/kernel/fs/
├── MASTER_PLAN.md              ← This file (overall roadmap)
├── ext2/                       ← Current working implementation (preserved as-is)
│   └── ext2.zig                ← Existing code, untouched during ext3 work
│
├── ext3/                       ← Phase 1: Journaling
│   ├── CLAUDE.md               ← Agent instructions for ext3 work
│   ├── journal.zig             ← Journal (JBD2) implementation
│   ├── journal_replay.zig      ← Recovery: replay journal on mount
│   ├── journal_types.zig       ← On-disk structures (superblock, header, tags)
│   └── ext3_mount.zig          ← Mount-time journal detection and init
│
├── ext4/                       ← Phase 2+3: ext4 features
│   ├── CLAUDE.md               ← Agent instructions for ext4 work
│   ├── extents.zig             ← Extent tree (B-tree of contiguous block runs)
│   ├── htree.zig               ← HTree indexed directories
│   ├── checksums.zig           ← CRC32c metadata checksums
│   ├── block_group_64.zig      ← 64-bit block group descriptors
│   ├── inode_ext4.zig          ← Extended inode (256 bytes, nanoseconds, extra fields)
│   ├── mballoc.zig             ← Multiblock allocator
│   ├── delayed_alloc.zig       ← Delayed allocation (write path)
│   └── flex_bg.zig             ← Flexible block groups
│
├── common/                     ← Shared between ext2/ext3/ext4
│   ├── CLAUDE.md               ← Agent instructions for shared code
│   ├── superblock.zig          ← Superblock parsing (handles all versions)
│   ├── block_group.zig         ← Block group descriptor (32-bit and 64-bit)
│   ├── inode.zig               ← Inode structure (128-byte and 256-byte)
│   ├── dir_entry.zig           ← Directory entry parsing
│   ├── bitmap.zig              ← Block/inode bitmap operations
│   └── crc32c.zig              ← CRC32c implementation for checksums
│
└── tests/                      ← Integration tests
    ├── CLAUDE.md               ← Agent instructions for test infrastructure
    ├── test_journal.zig         ← Journal write/replay tests
    ├── test_extents.zig         ← Extent tree CRUD tests
    ├── test_htree.zig           ← HTree directory tests
    ├── test_checksums.zig       ← Checksum verification tests
    └── test_images/             ← Pre-built ext3/ext4 images for testing
        ├── make_ext3_img.py     ← Generate ext3 test image with journal
        └── make_ext4_img.py     ← Generate ext4 test image with extents
```

---

## Phase 1: ext3 (Journaling)

**Goal:** Crash recovery. If power is lost mid-write, the journal replays on next mount instead of requiring a full fsck. The on-disk format is identical to ext2 except for the journal inode and a feature flag.

**Estimated total:** ~800–1000 lines across 4–5 files
**Agent sessions:** 4–5 sessions (can partially parallelize)

### Milestone J1: Journal Types and Structures
**File:** `ext3/journal_types.zig`
**Lines:** ~100
**Parallelizable:** Yes (no dependencies)
**Agent instructions:**

Define the on-disk structures for the JBD2 journal format:

```
Journal Superblock (at block 0 of journal):
- magic: u32 = 0xC03B3998
- blocktype: u32 = 3 (SUPERBLOCK_V1) or 4 (SUPERBLOCK_V2)
- sequence: u32          — current transaction sequence number
- blocksize: u32         — journal block size (same as fs block size)
- maxlen: u32            — total blocks in journal
- first: u32             — first usable block in journal
- errno: u32             — error value from last recovery
- feature_compat/incompat/ro_compat: u32 each
- For V2: uuid, nr_users, dynsuper, max_transaction, max_trans_data
```

```
Block Header (every journal block starts with this):
- magic: u32 = 0xC03B3998
- blocktype: u32
    1 = DESCRIPTOR   — lists which FS blocks follow
    2 = COMMIT       — marks end of transaction
    3 = SUPERBLOCK_V1
    4 = SUPERBLOCK_V2
    5 = REVOKE       — blocks that should NOT be replayed
- sequence: u32 — transaction ID this block belongs to
```

```
Block Tag (inside DESCRIPTOR blocks, 8 or 12 bytes each):
- blocknr: u32       — filesystem block number
- flags: u16
    FLAG_ESCAPE  = 0x01  — block content has fake magic, needs unescaping
    FLAG_SAME_UUID = 0x02 — same UUID as previous tag
    FLAG_DELETED = 0x04   — block was deleted (skip on replay)
    FLAG_LAST_TAG = 0x08  — last tag in this descriptor
- For 64-bit: blocknr_high: u32 (when INCOMPAT_64BIT is set)
```

```
Revoke Header (in REVOKE blocks):
- count: u32        — byte count of revoke data
- Followed by array of u32 (or u64) block numbers that are revoked
```

Test: parse a real journal superblock from a Linux-created ext3 image and verify all fields decode correctly.

---

### Milestone J2: Journal Replay (Recovery)
**File:** `ext3/journal_replay.zig`
**Lines:** ~250
**Parallelizable:** No (depends on J1)
**Agent instructions:**

Implement journal recovery — this runs at mount time when the journal is dirty (wasn't cleanly unmounted).

**The replay algorithm:**

```
1. Read journal superblock → get sequence number and first block
2. PASS 1 — SCAN: Walk the journal from `first` block forward:
   - Read each block header
   - If DESCRIPTOR: record (sequence, fs_block_number) pairs from tags
   - If COMMIT: mark that transaction as complete
   - If REVOKE: record revoked block numbers with their sequence
   - Stop when: sequence goes backward, magic doesn't match, or we wrap around to start
   - Build: committed_transactions[] and revoke_table{}

3. PASS 2 — REVOKE: For each revoked block, remove it from committed_transactions
   if the revoke sequence >= the transaction that wrote it

4. PASS 3 — REPLAY: For each surviving entry in committed_transactions (oldest first):
   - Read the data block from the journal
   - Write it to the corresponding filesystem block number
   - This restores the filesystem to a consistent state

5. Clear the journal: write zeros to journal superblock sequence, sync
```

**Key details:**
- The journal wraps around — block numbers are modular (block_idx % journal_maxlen)
- COMMIT blocks may contain a commit timestamp and checksum (V2)
- Escaped blocks: if a data block happens to contain 0xC03B3998 at offset 0, the journal sets FLAG_ESCAPE and zeros the magic. On replay, restore the magic byte.
- The revoke table prevents replaying old data over newer writes

**Test:** Create an ext3 image on Linux, write some files, simulate crash (don't unmount), mount in Zigix, verify journal replays and files are intact.

---

### Milestone J3: Journal Write Path (Transactions)
**File:** `ext3/journal.zig`
**Lines:** ~300
**Parallelizable:** No (depends on J1, integrates with ext2 write path)
**Agent instructions:**

Implement transactional metadata writes. Every ext2 metadata operation (allocate block, allocate inode, update directory, update inode) now goes through the journal.

**Transaction lifecycle:**

```
journal_start(nblocks) → handle
  — Reserve space in journal for up to nblocks metadata blocks
  — Returns a transaction handle

journal_write_block(handle, block_buf, fs_block_number)
  — Queue a metadata block for journaling
  — The block is copied into the journal's in-memory buffer
  — Does NOT write to the filesystem yet

journal_stop(handle)
  — Write DESCRIPTOR block listing all queued fs_block_numbers
  — Write the actual block data after the descriptor
  — Write COMMIT block
  — fsync the journal
  — NOW write the blocks to their real filesystem locations
  — This is "ordered" journaling mode (journal metadata, write data first)
```

**Three journaling modes (implement ordered first):**

1. **journal** — Both data and metadata go through journal. Safest, slowest. Double-write everything.
2. **ordered** (default, implement this) — Data is written to its final location BEFORE the metadata transaction commits. If crash happens: either data+metadata are both committed, or neither is. No stale data exposure.
3. **writeback** — Data and metadata written independently. Fastest, but stale data possible after crash.

**Integration with existing ext2:**

The current ext2.zig has functions like:
- `ext2AllocBlock()` — allocates a block from bitmap
- `ext2AllocInode()` — allocates an inode from bitmap
- `ext2WriteInode()` — writes inode to disk
- `ext2AddDirEntry()` — adds directory entry

Each of these currently calls `blockWrite()` directly. With journaling:
```zig
// Before (ext2):
ext2AllocBlock() → blockWrite(bitmap_block)

// After (ext3):
ext2AllocBlock() → journal_write_block(handle, bitmap_block, bitmap_block_nr)
// ... more operations in same transaction ...
journal_stop(handle) → writes journal, then writes real blocks
```

The ext2 functions don't change — just the call sites wrap them in transactions.

**Journal sizing:**
- Default: 32 MB journal (8192 blocks at 4KB). For Zigix's small images, 4 MB (1024 blocks) is plenty.
- Journal lives in inode 8 (EXT3_JOURNAL_INO). Pre-allocate contiguous blocks when creating the image.

---

### Milestone J4: ext3 Mount Integration
**File:** `ext3/ext3_mount.zig`
**Lines:** ~100
**Parallelizable:** No (depends on J2 + J3)
**Agent instructions:**

Wire journaling into the mount/unmount path:

**Mount:**
1. Read superblock → check `has_journal` feature flag (s_feature_compat & 0x04)
2. If set: read inode 8 → locate journal blocks on disk
3. Check journal superblock → if sequence != 0 (dirty), run journal_replay()
4. Initialize journal state: current sequence, write position, free space
5. Set `journal_active = true` so all metadata writes go through transactions

**Unmount:**
1. Flush all pending transactions (journal_stop any open handle)
2. Write journal superblock with sequence = 0 (marks clean unmount)
3. Sync all dirty blocks to disk
4. Existing ext2 unmount continues

**Superblock changes:**
- Set `s_feature_compat |= 0x04` (has_journal)
- Set `s_journal_inum = 8`
- Optionally set `s_journal_uuid`

**Backward compatibility:**
- If `has_journal` is NOT set, mount as plain ext2 (no journal overhead). All existing ext2 images continue to work unchanged.
- If `has_journal` IS set but journal is clean, skip replay and just init journal state.

---

### Milestone J5: ext3 Image Builder
**File:** `tests/test_images/make_ext3_img.py`
**Lines:** ~150
**Parallelizable:** Yes (just uses mkfs.ext3 from Linux)
**Agent instructions:**

Modify the existing `make_ext2_img.sh` to create ext3 images:

```bash
# Option 1: Create ext3 directly
mkfs.ext3 -b 4096 -J size=4 zigix-ext3.img 262144  # 1GB with 4MB journal

# Option 2: Convert existing ext2 to ext3
tune2fs -j zigix.img  # Adds journal to existing ext2 image
```

Also create a Python script that can:
1. Create an ext3 image with a known journal
2. Write some files to it
3. Intentionally corrupt it (simulate crash by not unmounting)
4. Verify the journal contains the expected transactions

This provides test fixtures for J2 (journal replay).

---

## Phase 2: ext4 Non-Breaking Features

These features can be added independently to the ext3 codebase. Each is a bounded task. Most can be done **in parallel** by separate agents since they touch different files.

**Estimated total:** ~1500–2000 lines across 6–7 files
**Agent sessions:** 6–8 sessions (highly parallelizable)

### Milestone E1: CRC32c Checksums
**File:** `common/crc32c.zig`
**Lines:** ~150
**Parallelizable:** Yes (pure function, no dependencies)
**Agent instructions:**

Implement CRC32c (Castagnoli) — this is the checksum used throughout ext4 for metadata integrity.

CRC32c uses polynomial 0x1EDC6F41 (different from standard CRC32's 0x04C11DB7). It has hardware acceleration on modern CPUs (SSE4.2 `crc32` instruction on x86, CRC extension on ARM64) but a software lookup table implementation is fine to start.

```zig
pub fn crc32c(crc: u32, data: []const u8) u32 {
    // Standard table-based CRC32c
    // 256-entry lookup table generated at comptime
}

// Used for:
// - Block group descriptor checksum
// - Inode checksum
// - Extent tree block checksum
// - Directory entry block checksum
// - Journal commit block checksum (V3)
```

The seed value is typically the filesystem UUID (from superblock) XORed with the block/inode number being checksummed. Each structure type has its own checksumming convention — document these in comments.

**Test:** Compute CRC32c of known test vectors, compare against Linux kernel's crc32c output. The IETF test vector is: CRC32c("123456789") = 0xE3069283.

---

### Milestone E2: 256-Byte Inodes (ext4 Extended Inode)
**File:** `common/inode.zig` and `ext4/inode_ext4.zig`
**Lines:** ~200
**Parallelizable:** Yes (after E1 for checksum field)
**Agent instructions:**

ext2/ext3 inodes are 128 bytes. ext4 inodes are 256 bytes with additional fields:

```
Standard inode fields (0x00–0x7F, 128 bytes):
  [same as ext2 — mode, uid, size, timestamps, blocks, block_map/extent_tree]

Extra inode fields (0x80–0xFF, 128 bytes):
  0x80: i_extra_isize: u16     — size of extra fields actually used
  0x82: i_checksum_hi: u16     — high 16 bits of inode checksum
  0x84: i_ctime_extra: u32     — extra ctime precision (nanoseconds + epoch bits)
  0x88: i_mtime_extra: u32     — extra mtime precision
  0x8C: i_atime_extra: u32     — extra atime precision
  0x90: i_crtime: u32          — creation time (seconds)
  0x94: i_crtime_extra: u32    — creation time nanoseconds
  0x98: i_version_hi: u32      — high 32 bits of inode version
  0x9C: i_projid: u32          — project ID (for quotas)
  0xA0–0xFE: reserved/padding
  0x7C (in standard area): i_checksum_lo: u16  — low 16 bits of checksum (repurposed from i_osd2)
```

**Nanosecond timestamp encoding:**
```
extra_time = (epoch_bits << 30) | nanoseconds
  epoch_bits (2 bits): extends seconds range past 2038
  nanoseconds (30 bits): 0–999999999
```

**Integration:**
- When reading inodes: check s_inode_size in superblock. If 256, read extra fields.
- When writing inodes: compute and store checksum using CRC32c (E1).
- Maintain backward compatibility: if s_inode_size == 128, ignore extra fields.

---

### Milestone E3: 64-Bit Block Group Descriptors
**File:** `ext4/block_group_64.zig`
**Lines:** ~150
**Parallelizable:** Yes (independent of E1/E2)
**Agent instructions:**

ext2/ext3 block group descriptors are 32 bytes. ext4 extends them to 64 bytes for 64-bit block numbers (supports volumes >16TB).

```
Standard fields (0x00–0x1F, 32 bytes):
  bg_block_bitmap_lo: u32
  bg_inode_bitmap_lo: u32
  bg_inode_table_lo: u32
  bg_free_blocks_count_lo: u16
  bg_free_inodes_count_lo: u16
  bg_used_dirs_count_lo: u16
  bg_flags: u16
  bg_exclude_bitmap_lo: u32
  bg_block_bitmap_csum_lo: u16
  bg_inode_bitmap_csum_lo: u16
  bg_itable_unused_lo: u16
  bg_checksum: u16

Extended fields (0x20–0x3F, 32 bytes):
  bg_block_bitmap_hi: u32     — high 32 bits of block bitmap location
  bg_inode_bitmap_hi: u32     — high 32 bits of inode bitmap location
  bg_inode_table_hi: u32      — high 32 bits of inode table location
  bg_free_blocks_count_hi: u16
  bg_free_inodes_count_hi: u16
  bg_used_dirs_count_hi: u16
  bg_itable_unused_hi: u16
  bg_exclude_bitmap_hi: u32
  bg_block_bitmap_csum_hi: u16
  bg_inode_bitmap_csum_hi: u16
  bg_reserved: u32
```

**Integration:**
- Check INCOMPAT_64BIT feature flag in superblock
- If set: s_desc_size = 64, read both lo and hi fields, combine into u64
- If not set: s_desc_size = 32, only read standard fields (existing ext2 behavior)
- Block group descriptor checksum: CRC32c over descriptor contents (E1)

---

### Milestone E4: Flexible Block Groups
**File:** `ext4/flex_bg.zig`
**Lines:** ~150
**Parallelizable:** Yes (independent)
**Agent instructions:**

Flexible block groups pack the metadata (bitmaps + inode table) of multiple block groups into the first block group of a "flex group." This improves locality — all metadata I/O for a flex group hits the same disk region.

```
Superblock field:
  s_log_groups_per_flex — log2 of block groups per flex group
  e.g., 4 means 16 block groups per flex group

Layout change:
  Without flex_bg:
    BG0: [superblock][gdt][bmap0][imap0][itable0][data...]
    BG1: [bmap1][imap1][itable1][data...]
    BG2: [bmap2][imap2][itable2][data...]

  With flex_bg (groups_per_flex=4):
    BG0: [superblock][gdt][bmap0][bmap1][bmap2][bmap3][imap0][imap1][imap2][imap3][itable0][itable1][itable2][itable3][data...]
    BG1: [data only...]
    BG2: [data only...]
    BG3: [data only...]
```

**Implementation:**
- On mount: compute flex group boundaries from s_log_groups_per_flex
- When locating bitmaps/inode tables: use the block numbers from the block group descriptor (which already point to the right place in the flex group leader), NOT computed offsets
- Block/inode allocation: prefer allocating from within the same flex group for locality
- This is mostly a change in how you interpret block group descriptors, not a new on-disk format

---

### Milestone E5: Multiblock Allocator
**File:** `ext4/mballoc.zig`
**Lines:** ~300
**Parallelizable:** Yes (after flex_bg for best results)
**Agent instructions:**

ext2's allocator allocates one block at a time. ext4's multiblock allocator (mballoc) allocates multiple contiguous blocks in one operation. This reduces fragmentation and improves write throughput for large files.

**Algorithm:**
```
1. Request: allocate N contiguous blocks near goal_block
2. Search strategy (in order of preference):
   a. Check current block group's bitmap for N contiguous free blocks near goal
   b. Use buddy allocator within block group (power-of-2 grouping)
   c. Try neighboring block groups in the same flex group
   d. Fall back to any block group with enough free blocks
   e. Fall back to any block group with any free blocks (fragmented allocation)
3. Update bitmap, block group descriptors, and superblock free counts
```

**Buddy allocator per block group:**
```
For a block group with 32768 blocks:
  Order 0: individual blocks (32768 entries)
  Order 1: pairs of 2 blocks (16384 entries)
  Order 2: groups of 4 blocks (8192 entries)
  ...
  Order 14: groups of 16384 blocks (2 entries)

Bitmap at each order: 1 = free, 0 = allocated
Split higher-order block when lower order is exhausted
Merge adjacent blocks when freed
```

**For Zigix's current scale (128MB–1GB images), a simplified version is fine:**
- Scan bitmap for N contiguous free bits
- Use a simple first-fit or best-fit within the block group
- No buddy bitmaps needed until images exceed ~4GB

---

### Milestone E6: Delayed Allocation
**File:** `ext4/delayed_alloc.zig`
**Lines:** ~200
**Parallelizable:** No (depends on E5 multiblock allocator)
**Agent instructions:**

Delayed allocation (delalloc) postpones block allocation until data is actually written to disk (at fsync or writeback time). This lets the allocator see the full size of the write and allocate contiguous blocks.

**How it works:**
```
write(fd, data, 64KB):
  ext2: allocate 16 blocks immediately → may fragment
  ext4: mark 16 blocks as "reserved" in memory, DON'T allocate yet

fsync(fd) or writeback timer:
  NOW allocate 16 contiguous blocks via mballoc
  Write all data blocks
  Update inode block map/extents
```

**Implementation:**
- Per-inode: track "delalloc reserved blocks" count
- Superblock: track total "reserved but not allocated" blocks (s_dirtyclusters_counter)
- On write: increment reserved count, don't touch bitmap
- On writeback/fsync: call mballoc to allocate, then write data, then update metadata
- On truncate/delete: release reserved blocks without touching bitmap

**Benefit:** Large sequential writes get contiguous allocation. A 1MB write becomes one extent instead of scattered blocks.

---

## Phase 3: ext4 Extent Tree and HTree Directories

These are the two big structural changes that make ext4 fundamentally different from ext3. They should be done after Phase 2 because they depend on 64-bit block numbers and checksums.

**Estimated total:** ~1200–1500 lines across 2 files
**Agent sessions:** 3–4 sessions (sequential within phase, but phase itself is parallelizable with Phase 2 late items)

### Milestone X1: Extent Tree
**File:** `ext4/extents.zig`
**Lines:** ~600–800
**Parallelizable:** No (this is the core structural change)
**Agent instructions:**

The extent tree replaces ext2/ext3's indirect block map (i_block[15] in the inode) with a B-tree of extents. Each extent maps a contiguous range of logical blocks to physical blocks.

**On-disk format in the inode's i_block[60 bytes]:**

```
Extent Header (12 bytes):
  eh_magic: u16 = 0xF30A
  eh_entries: u16      — number of valid entries following
  eh_max: u16          — maximum entries that fit in this node
  eh_depth: u16        — depth of tree (0 = leaf, >0 = internal)
  eh_generation: u32   — tree generation (for checksums)

Extent Index (internal node entry, 12 bytes):
  ei_block: u32        — logical block number this subtree covers
  ei_leaf_lo: u32      — physical block of child node (low 32 bits)
  ei_leaf_hi: u16      — physical block high 16 bits
  ei_unused: u16

Extent (leaf entry, 12 bytes):
  ee_block: u32        — first logical block
  ee_len: u16          — number of blocks (max 32768; if bit 15 set: uninitialized/prealloc)
  ee_start_hi: u16     — physical block high 16 bits
  ee_start_lo: u32     — physical block low 32 bits
```

**Tree structure:**
```
Inode i_block (60 bytes):
  [header(12)] [entry(12)] [entry(12)] [entry(12)] [entry(12)]
  → 1 header + 4 entries fit in the inode (depth 0: 4 extents, depth 1+: 4 index entries)

Internal node block (4096 bytes):
  [header(12)] [index(12)] × 340 entries
  → each index points to a child block

Leaf node block (4096 bytes):
  [header(12)] [extent(12)] × 340 entries
  → each extent maps up to 32768 contiguous blocks
```

**Operations to implement:**

```
ext4_extent_lookup(inode, logical_block) → physical_block
  Walk tree from root (in inode) → internal nodes → leaf
  Binary search at each level

ext4_extent_insert(inode, logical_block, physical_block, len)
  Find insertion point in leaf
  If leaf has space: insert
  If leaf is full: split leaf, propagate split up the tree
  If root is full: increase tree depth (new root block)

ext4_extent_remove(inode, logical_block, len)
  Find extent(s) covering the range
  Shrink, split, or remove extents as needed
  Merge adjacent extents if possible
  Free empty internal nodes

ext4_extent_read(inode, offset, buf, len) → bytes_read
  Map logical blocks to physical via lookup
  Handle holes (unallocated blocks → zero-fill)
  Batch contiguous physical blocks into single disk read

ext4_extent_write(inode, offset, data, len) → bytes_written
  Allocate new physical blocks via mballoc (E5)
  Insert extents for new blocks
  Extend existing extents where possible (append optimization)
```

**Feature flag:** INCOMPAT_EXTENTS (0x0040). When set, inode i_block contains extent tree instead of block map. Both formats can coexist (per-inode flag EXT4_EXTENTS_FL in i_flags).

**Compatibility:**
- Inodes without EXT4_EXTENTS_FL still use the old block map (ext2 code path)
- New files get extents by default
- Existing files keep their block map until rewritten

**Test:** Create a file with 100MB of data, verify the extent tree has a small number of extents (ideally 1–3 for sequential write). Read back and verify data integrity.

---

### Milestone X2: HTree Indexed Directories
**File:** `ext4/htree.zig`
**Lines:** ~400–500
**Parallelizable:** Yes (independent of X1)
**Agent instructions:**

Linear directory scanning is O(n) per lookup. HTree uses a hash-indexed B-tree that gives O(1) average-case lookup for directories with thousands of entries.

**On-disk format (fits in existing directory block structure):**

```
Root block (first directory block):
  Fake "." entry:
    inode: u32 = self
    rec_len: u16 = 12
    name: "."
  Fake ".." entry:
    inode: u32 = parent
    rec_len: u16 = block_size - 12  (covers rest of block)
    name: ".."
  Hidden after ".." entry's padding:
    dx_root structure:
      info.hash_version: u8    — 0=legacy, 1=half_md4, 2=tea
      info.indirect_levels: u8 — 0 = single level, 1 = two levels
      info.unused_flags: u16
      limit: u16               — max entries in this block
      count: u16               — current number of entries
      block: u32               — block number of first child (always 0 for root)
      entries[]:               — (hash: u32, block: u32) pairs, sorted by hash

Internal node blocks:
  Fake dirent header (8 bytes, inode=0) — makes block look like valid directory block
  dx_node:
    limit: u16
    count: u16
    block: u32
    entries[]: (hash: u32, block: u32) pairs

Leaf blocks:
  Normal ext2 directory entries (linear within the block)
  Each leaf block contains entries whose hash falls in the range [this_hash, next_hash)
```

**Hash function (half_md4 — default):**
```
hash = half_md4(filename, seed_from_superblock)
Hash space is u32, distributed across leaf blocks
Each internal entry says "hashes >= this value are in block N"
```

**Operations:**

```
htree_lookup(dir_inode, name) → inode_number
  1. Compute hash(name)
  2. Read root block → binary search entries for hash range
  3. If indirect_levels > 0: read internal node → binary search again
  4. Read leaf block → linear scan for exact name match
  Average: 2–3 block reads regardless of directory size

htree_insert(dir_inode, name, inode)
  1. Find target leaf block via hash
  2. If leaf has space: insert entry
  3. If leaf is full: split leaf block
     - Allocate new block
     - Move half the entries (by hash) to new block
     - Add new (hash, block) entry to parent internal node
     - If internal node is full: split internal node (increase depth if needed)

htree_remove(dir_inode, name)
  1. Find leaf block via hash
  2. Remove entry (mark as deleted, merge rec_len with previous)
  3. Don't bother rebalancing — deleted space is reclaimed on next insert
```

**Feature flag:** EXT4_INDEX_FL on directory inode (i_flags & 0x1000). Directories without this flag use linear scanning (existing ext2 code path).

**Compatibility:**
- Small directories (<1 block of entries) don't need HTree — linear scan is fast enough
- HTree is activated when a directory grows beyond one block
- Existing directory reading code works unchanged (leaf blocks are normal directory blocks)

**Test:** Create a directory with 10,000 files, verify lookup time is O(1) not O(n). Compare against linear scan performance.

---

## Phase Summary and Parallel Execution Plan

```
PHASE 1 — ext3 Journaling (sequential, ~800 lines):
Session 1: J1 (types)
Session 2: J2 (replay) — depends on J1
Session 3: J3 (write path) — depends on J1, can overlap with J2
Session 4: J4 (mount integration) — depends on J2 + J3
Session 5: J5 (image builder) — parallelizable with J1–J4

PHASE 2 — ext4 Non-Breaking (parallel, ~1500 lines):
┌─ Session A: E1 (CRC32c)        — no dependencies
├─ Session B: E3 (64-bit BGD)    — no dependencies
├─ Session C: E4 (flex_bg)       — no dependencies
├─ Session D: E2 (256-byte inode) — after E1 for checksum
├─ Session E: E5 (mballoc)       — after E4 for best results
└─ Session F: E6 (delalloc)      — after E5

PHASE 3 — ext4 Structural (partially parallel, ~1200 lines):
┌─ Session G: X1 (extents)  — after E3 (64-bit blocks), E5 (mballoc)
└─ Session H: X2 (htree)    — independent of X1, after E1 (checksums)

Total: ~3500–4500 lines across ~13 agent sessions
Timeline: Phase 1 in 2-3 days, Phase 2 in 2-3 days, Phase 3 in 2-3 days
With parallel agents: entire thing could be done in under a week
```

---

## Feature Flags Reference

```
Superblock s_feature_compat:
  0x0004  has_journal (ext3)
  0x0020  dir_prealloc
  0x0200  has_journal_dev

Superblock s_feature_incompat:
  0x0001  compression
  0x0002  filetype (directory entries have type field — already in ext2)
  0x0004  recover (journal needs replay)
  0x0008  journal_dev (separate journal device)
  0x0010  meta_bg
  0x0040  extents (ext4)
  0x0080  64bit (ext4, 64-bit block numbers)
  0x0200  flex_bg (ext4)
  0x0400  ea_inode (large extended attributes in inodes)
  0x1000  dirdata
  0x8000  encrypt

Superblock s_feature_ro_compat:
  0x0001  sparse_super
  0x0002  large_file (>2GB)
  0x0004  btree_dir (not actually used, HTree is per-inode flag)
  0x0008  huge_file (>2TB via i_blocks_hi)
  0x0010  gdt_csum (block group descriptor checksums)
  0x0020  dir_nlink (>65000 subdirectories)
  0x0040  extra_isize (256-byte inodes)
  0x0400  metadata_csum (CRC32c on all metadata)
```

---

## Verification Milestones

After each phase, verify with real Linux tools:

```bash
# Phase 1: ext3
mkfs.ext3 test.img && mount test.img /mnt && echo "hello" > /mnt/test.txt && umount /mnt
# Boot Zigix with test.img → verify reads file → verify journal is clean

# Phase 2: ext4 (no extents)
mkfs.ext4 -O ^extents test.img && mount test.img /mnt && ...
# Verify 256-byte inodes, checksums, 64-bit BGDs all parse

# Phase 3: ext4 (full)
mkfs.ext4 test.img && mount test.img /mnt && dd if=/dev/urandom of=/mnt/bigfile bs=1M count=100
# Verify extent tree, large file read, checksum validation
```

Each verification can be scripted and run automatically as part of the build/test pipeline.
