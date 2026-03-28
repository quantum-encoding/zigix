#!/usr/bin/env python3
"""Create a bootable ext4 filesystem image with all Zigix userspace programs.

Usage: make_ext4_img.py <output.img> [shell_binary] [extra_bins_dir] [scripts_dir] [zig_tree_dir] [kernel_src_dir]

Writes raw ext4 structures — no external tools required.
Block size: 4096 bytes, 8 block groups, 1GB image, 32768 inodes.

ext4 features:
  - Multi-block-group support (8 groups × 32768 blocks each)
  - 256-byte inodes with CRC32c checksums and nanosecond timestamps
  - Extent trees for file block mapping (EXTENTS_FL on every inode)
  - 64-bit block group descriptors (INCOMPAT_64BIT, s_desc_size=64)
  - CRC32c metadata checksums (METADATA_CSUM) on inodes and BGDs
  - JBD2 journal (HAS_JOURNAL, inode 8, 32MB)
  - Flexible block groups (flex_bg)
  - Filesystem UUID for checksum seeding

Layout (4096-byte blocks, flex_bg packed):
  Block 0:          superblock at offset 1024
  Block 1:          block group descriptor table (8 × 64-byte descriptors)
  Blocks 2-9:       block bitmaps (1 per group)
  Blocks 10-17:     inode bitmaps (1 per group)
  Blocks 18-2065:   inode tables (8 groups × 256 blocks, 4096 inodes/group)
  Blocks 2066+:     journal (8192 blocks), then file data
"""

import struct
import sys
import os
import time
import math

BLOCK_SIZE = 4096
TOTAL_BLOCKS = 262144           # 1 GB
BLOCKS_PER_GROUP = 32768        # = BLOCK_SIZE * 8, standard Linux value
NUM_GROUPS = TOTAL_BLOCKS // BLOCKS_PER_GROUP  # 8
INODES_PER_GROUP = 4096         # per group, 32768 total
INODE_SIZE = 256
INODE_TABLE_BLOCKS_PER_GROUP = (INODES_PER_GROUP * INODE_SIZE) // BLOCK_SIZE  # 256
TOTAL_INODES = INODES_PER_GROUP * NUM_GROUPS  # 32768

# Metadata layout (flex_bg: all metadata packed at image start)
BGDT_BLOCK = 1
BB_START = 2                                    # block bitmaps: blocks 2..9
IB_START = BB_START + NUM_GROUPS                # inode bitmaps: blocks 10..17
IT_START = IB_START + NUM_GROUPS                # inode tables: blocks 18..2065
METADATA_END = IT_START + NUM_GROUPS * INODE_TABLE_BLOCKS_PER_GROUP  # 2066

FIRST_DATA_BLOCK = METADATA_END                 # Start allocating data here
EXT2_SUPER_MAGIC = 0xEF53
ADDRS_PER_INDIRECT = BLOCK_SIZE // 4  # 1024

# JBD2 journal constants
JBD2_MAGIC = 0xC03B3998
JBD2_SUPERBLOCK_V2 = 4
JOURNAL_BLOCKS = 8192  # 32 MB journal

# Feature flags
COMPAT_HAS_JOURNAL = 0x0004
COMPAT_DIR_INDEX = 0x0020
INCOMPAT_FILETYPE = 0x0002
INCOMPAT_EXTENTS = 0x0040
INCOMPAT_64BIT = 0x0080
INCOMPAT_FLEX_BG = 0x0200
RO_COMPAT_EXTRA_ISIZE = 0x0040
RO_COMPAT_METADATA_CSUM = 0x0400
RO_COMPAT_SPARSE_SUPER = 0x0001
RO_COMPAT_LARGE_FILE = 0x0002
RO_COMPAT_HUGE_FILE = 0x0008

# Inode flags
EXTENTS_FL = 0x00080000

# Extent tree
EXTENT_MAGIC = 0xF30A
EXTENT_HEADER_SIZE = 12
EXTENT_ENTRY_SIZE = 12
MAX_EXTENTS_IN_INODE = 4  # (60 - 12) / 12

# File type constants
FT_REG = 1
FT_DIR = 2

# Block group descriptor size for ext4 64-bit mode
DESC_SIZE = 64


# ---- CRC32c (Castagnoli) ----

CRC32C_TABLE = None

def _init_crc32c():
    global CRC32C_TABLE
    CRC32C_TABLE = []
    for i in range(256):
        crc = i
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0x82F63B78
            else:
                crc >>= 1
        CRC32C_TABLE.append(crc)

def crc32c_update(crc, data):
    if CRC32C_TABLE is None:
        _init_crc32c()
    for b in data:
        crc = CRC32C_TABLE[(crc ^ b) & 0xFF] ^ (crc >> 8)
    return crc

def crc32c_finalize(crc):
    return crc ^ 0xFFFFFFFF

def crc32c(data, init=0xFFFFFFFF):
    return crc32c_finalize(crc32c_update(init, data))


# ---- Checksums ----

def inode_checksum(inode_buf, inode_size, inode_number, fs_uuid):
    """Compute ext4 inode CRC32c checksum."""
    seed = crc32c_update(0xFFFFFFFF, fs_uuid)
    seed = crc32c_update(seed, struct.pack('<I', inode_number))
    gen = struct.unpack_from('<I', inode_buf, 0x64)[0]
    seed = crc32c_update(seed, struct.pack('<I', gen))
    buf = bytearray(inode_buf[:inode_size])
    buf[0x7C:0x7E] = b'\x00\x00'
    if inode_size >= 256:
        buf[0x82:0x84] = b'\x00\x00'
    crc = crc32c_update(seed, bytes(buf))
    return crc32c_finalize(crc)

def bgd_checksum(bgd_buf, desc_size, bg_number, fs_uuid):
    """Compute ext4 block group descriptor CRC32c checksum (lower 16 bits)."""
    seed = crc32c_update(0xFFFFFFFF, fs_uuid)
    seed = crc32c_update(seed, struct.pack('<I', bg_number))
    buf = bytearray(bgd_buf[:desc_size])
    buf[0x1E:0x20] = b'\x00\x00'
    crc = crc32c_update(seed, bytes(buf))
    return crc32c_finalize(crc) & 0xFFFF


def main():
    if len(sys.argv) < 2:
        print("Usage: make_ext4_img.py <output.img> [shell_binary] [extra_bins_dir] [scripts_dir] [zig_tree_dir] [kernel_src_dir]")
        sys.exit(1)

    shell_binary = None
    if len(sys.argv) >= 3 and os.path.exists(sys.argv[2]):
        with open(sys.argv[2], 'rb') as f:
            shell_binary = f.read()
        print(f"  Shell binary: {sys.argv[2]} ({len(shell_binary)} bytes)")

    extra_bins = {}
    if len(sys.argv) >= 4 and os.path.isdir(sys.argv[3]):
        bins_dir = sys.argv[3]
        for name in sorted(os.listdir(bins_dir)):
            path = os.path.join(bins_dir, name)
            if os.path.isfile(path):
                with open(path, 'rb') as f:
                    extra_bins[name] = f.read()
                print(f"  Extra binary: {name} ({len(extra_bins[name])} bytes)")

    root_scripts = {}
    if len(sys.argv) >= 5 and os.path.isdir(sys.argv[4]):
        scripts_dir = sys.argv[4]
        for name in sorted(os.listdir(scripts_dir)):
            path = os.path.join(scripts_dir, name)
            if os.path.isfile(path):
                with open(path, 'rb') as f:
                    root_scripts[name] = f.read()
                print(f"  Script: /{name} ({len(root_scripts[name])} bytes)")

    img = bytearray(TOTAL_BLOCKS * BLOCK_SIZE)
    now = int(time.time())

    # Filesystem UUID (semi-random, seeded with timestamp)
    fs_uuid = struct.pack('<IIII', 0xDEAD0E4F, 0xBEEF0E4F, now & 0xFFFFFFFF, 0x0E4F0E4F)

    next_block = FIRST_DATA_BLOCK
    next_inode = 12

    # Track all allocated blocks for bitmap generation
    allocated_blocks = set()
    # Mark metadata blocks as used
    for b in range(METADATA_END):
        allocated_blocks.add(b)

    def alloc_block():
        nonlocal next_block
        b = next_block
        next_block += 1
        if b >= TOTAL_BLOCKS:
            print(f"ERROR: out of blocks (allocated {b}, max {TOTAL_BLOCKS})")
            sys.exit(1)
        allocated_blocks.add(b)
        return b

    def alloc_inode():
        nonlocal next_inode
        i = next_inode
        next_inode += 1
        if i > TOTAL_INODES:
            print(f"ERROR: out of inodes (allocated {i}, max {TOTAL_INODES})")
            sys.exit(1)
        return i

    def write_block(block_num, data):
        offset = block_num * BLOCK_SIZE
        img[offset:offset + len(data)] = data[:BLOCK_SIZE]

    def make_dir_entry(inode, name, file_type, rec_len=None):
        name_bytes = name.encode('ascii')
        name_len = len(name_bytes)
        if rec_len is None:
            rec_len = ((8 + name_len + 3) // 4) * 4
        entry = struct.pack('<IHBB', inode, rec_len, name_len, file_type) + name_bytes
        entry += b'\x00' * (rec_len - len(entry))
        return entry

    def alloc_file_blocks(data):
        """Allocate contiguous blocks for file data. Returns list of block numbers."""
        num_blocks = math.ceil(len(data) / BLOCK_SIZE) if len(data) > 0 else 0
        blocks = []
        for _ in range(num_blocks):
            blocks.append(alloc_block())
        return blocks

    def write_file_data(data, blocks):
        """Write file data to pre-allocated blocks."""
        for i, blk in enumerate(blocks):
            start = i * BLOCK_SIZE
            end = min(start + BLOCK_SIZE, len(data))
            if start < len(data):
                write_block(blk, data[start:end])

    def make_extent_iblock(blocks):
        """Build extent tree root for i_block (60 bytes).
        Since we allocate contiguously, all blocks form one extent.
        For files with >4 extents, allocate an extent tree block."""
        if len(blocks) == 0:
            # Empty file — extent header with 0 entries
            header = struct.pack('<HHHHI', EXTENT_MAGIC, 0, 4, 0, 0)
            return header + b'\x00' * (60 - len(header))

        # Group contiguous blocks into extents, capping at 32768 blocks each.
        MAX_EXTENT_LEN = 32768
        extents = []
        if blocks:
            run_start = blocks[0]
            run_logical = 0
            run_len = 1
            for i in range(1, len(blocks)):
                if blocks[i] == run_start + run_len and run_len < MAX_EXTENT_LEN:
                    run_len += 1
                else:
                    extents.append((run_logical, run_len, run_start))
                    run_logical = i
                    run_start = blocks[i]
                    run_len = 1
            extents.append((run_logical, run_len, run_start))

        if len(extents) <= MAX_EXTENTS_IN_INODE:
            # Fits in inode root (depth 0)
            header = struct.pack('<HHHHI',
                EXTENT_MAGIC, len(extents), MAX_EXTENTS_IN_INODE, 0, 0)
            data = header
            for logical, length, physical in extents:
                data += struct.pack('<IHHI',
                    logical, length, (physical >> 32) & 0xFFFF, physical & 0xFFFFFFFF)
            data += b'\x00' * (60 - len(data))
            return data
        else:
            # Need external extent tree block (depth 1)
            leaf_blk = alloc_block()
            max_in_block = (BLOCK_SIZE - EXTENT_HEADER_SIZE) // EXTENT_ENTRY_SIZE
            leaf_header = struct.pack('<HHHHI',
                EXTENT_MAGIC, len(extents), max_in_block, 0, 0)
            leaf_data = leaf_header
            for logical, length, physical in extents:
                leaf_data += struct.pack('<IHHI',
                    logical, length, (physical >> 32) & 0xFFFF, physical & 0xFFFFFFFF)
            leaf_data += b'\x00' * (BLOCK_SIZE - len(leaf_data))
            write_block(leaf_blk, leaf_data)

            # Root node: depth 1, single index entry pointing to leaf
            root_header = struct.pack('<HHHHI',
                EXTENT_MAGIC, 1, MAX_EXTENTS_IN_INODE, 1, 0)
            root_idx = struct.pack('<IIHH',
                0, leaf_blk & 0xFFFFFFFF, (leaf_blk >> 32) & 0xFFFF, 0)
            root = root_header + root_idx
            root += b'\x00' * (60 - len(root))
            return root

    def inode_table_offset(ino):
        """Compute byte offset in image for a given inode number (multi-BG aware)."""
        group = (ino - 1) // INODES_PER_GROUP
        local_idx = (ino - 1) % INODES_PER_GROUP
        table_start_block = IT_START + group * INODE_TABLE_BLOCKS_PER_GROUP
        return table_start_block * BLOCK_SIZE + local_idx * INODE_SIZE

    def write_inode_ext4(ino, mode, size, num_data_blocks, iblock_data, nlink=1, flags=0, uid=0, gid=0):
        """Write a 256-byte ext4 inode with extent tree and CRC32c checksum."""
        offset = inode_table_offset(ino)
        i_blocks_field = num_data_blocks * (BLOCK_SIZE // 512)

        data = bytearray(INODE_SIZE)
        struct.pack_into('<HHI', data, 0x00, mode, uid, size & 0xFFFFFFFF)
        struct.pack_into('<IIII', data, 0x08, now, now, now, 0)  # atime, ctime, mtime, dtime
        struct.pack_into('<HHI', data, 0x18, gid, nlink, i_blocks_field)
        struct.pack_into('<II', data, 0x20, flags | EXTENTS_FL, 0)  # i_flags, i_osd1

        # i_block[15] = extent tree (60 bytes at offset 0x28)
        data[0x28:0x28 + 60] = iblock_data[:60]

        # i_generation at 0x64 = 0
        struct.pack_into('<I', data, 0x64, 0)
        # i_size_high at 0x6C (for files > 4GB)
        struct.pack_into('<I', data, 0x6C, (size >> 32) & 0xFFFFFFFF)

        # Extended inode fields (offset 0x80+)
        struct.pack_into('<H', data, 0x80, 28)   # extra_isize
        struct.pack_into('<I', data, 0x84, 0)     # ctime_extra
        struct.pack_into('<I', data, 0x88, 0)     # mtime_extra
        struct.pack_into('<I', data, 0x8C, 0)     # atime_extra
        struct.pack_into('<I', data, 0x90, now)   # crtime
        struct.pack_into('<I', data, 0x94, 0)     # crtime_extra

        # Compute and store CRC32c checksum
        csum = inode_checksum(bytes(data), INODE_SIZE, ino, fs_uuid)
        struct.pack_into('<H', data, 0x7C, csum & 0xFFFF)
        struct.pack_into('<H', data, 0x82, (csum >> 16) & 0xFFFF)

        img[offset:offset + INODE_SIZE] = data

    def write_dir_blocks(entries_list):
        """Write directory entries across one or more blocks. Returns block list."""
        dir_blocks = []
        current_block_data = b''

        for idx, (inode, name, file_type) in enumerate(entries_list):
            is_last = (idx == len(entries_list) - 1)
            entry_min_size = ((8 + len(name.encode('ascii')) + 3) // 4) * 4

            if is_last or len(current_block_data) + entry_min_size > BLOCK_SIZE:
                if not is_last and len(current_block_data) + entry_min_size > BLOCK_SIZE:
                    if current_block_data:
                        remaining = BLOCK_SIZE - len(current_block_data)
                        if remaining >= 12:
                            current_block_data += make_dir_entry(0, '', 0, rec_len=remaining)
                        blk = alloc_block()
                        dir_blocks.append(blk)
                        write_block(blk, current_block_data)
                        current_block_data = b''

            if is_last:
                remaining = BLOCK_SIZE - len(current_block_data)
                entry = make_dir_entry(inode, name, file_type, rec_len=remaining)
                current_block_data += entry
                blk = alloc_block()
                dir_blocks.append(blk)
                write_block(blk, current_block_data)
            else:
                entry = make_dir_entry(inode, name, file_type)
                current_block_data += entry

        return dir_blocks

    # ---- Recursive directory tree builder (for Zig lib/) ----
    tree_files_added = 0
    tree_dirs_created = 0

    def add_tree(host_dir, self_ino, parent_ino):
        nonlocal tree_files_added, tree_dirs_created
        entries = []
        try:
            names = sorted(os.listdir(host_dir))
        except OSError:
            return entries

        for name in names:
            full = os.path.join(host_dir, name)
            if os.path.islink(full):
                continue
            if os.path.isfile(full):
                with open(full, 'rb') as f:
                    data = f.read()
                ino = alloc_inode()
                blocks = alloc_file_blocks(data)
                write_file_data(data, blocks)
                mode = 0o100755 if os.access(full, os.X_OK) else 0o100644
                iblock = make_extent_iblock(blocks)
                write_inode_ext4(ino, mode, len(data), len(blocks), iblock)
                entries.append((ino, name, FT_REG))
                tree_files_added += 1
            elif os.path.isdir(full):
                ino = alloc_inode()
                child_entries = add_tree(full, ino, self_ino)
                dir_entries_list = [(ino, '.', FT_DIR), (self_ino, '..', FT_DIR)]
                dir_entries_list += child_entries
                dir_blocks = write_dir_blocks(dir_entries_list)
                dir_size = len(dir_blocks) * BLOCK_SIZE
                nlink = 2 + sum(1 for _, _, ft in child_entries if ft == FT_DIR)
                iblock = make_extent_iblock(dir_blocks)
                write_inode_ext4(ino, 0o40755, dir_size, len(dir_blocks), iblock, nlink=nlink)
                entries.append((ino, name, FT_DIR))
                tree_dirs_created += 1
                if tree_dirs_created % 100 == 0:
                    print(f"    ... {tree_dirs_created} dirs, {tree_files_added} files")
        return entries

    # ---- Allocate journal (inode 8, 32MB) ----
    journal_start = next_block
    journal_block_ptrs = []
    for _ in range(JOURNAL_BLOCKS):
        journal_block_ptrs.append(alloc_block())

    # JBD2 journal superblock (big-endian!)
    jsb = bytearray(BLOCK_SIZE)
    jsb_data = struct.pack('>IIIIII II I',
        JBD2_MAGIC, JBD2_SUPERBLOCK_V2, 1,
        BLOCK_SIZE, JOURNAL_BLOCKS, 1, 1, 0, 0)
    jsb[:len(jsb_data)] = jsb_data
    write_block(journal_start, jsb)

    # Journal inode (inode 8) — uses indirect blocks (tradition, not extents)
    j_direct = journal_block_ptrs[:12]
    j_sindirect = journal_block_ptrs[12:12 + ADDRS_PER_INDIRECT]
    j_remaining = journal_block_ptrs[12 + ADDRS_PER_INDIRECT:]

    # Single indirect block
    j_ind_blk = alloc_block()
    ind_data = b''
    for blk in j_sindirect:
        ind_data += struct.pack('<I', blk)
    ind_data += b'\x00' * (BLOCK_SIZE - len(ind_data))
    write_block(j_ind_blk, ind_data)

    # Double indirect block (if journal > 12 + 1024 = 1036 blocks)
    j_dind_blk = 0
    j_dind_sub_count = 0
    if j_remaining:
        j_dind_blk = alloc_block()
        num_ind = math.ceil(len(j_remaining) / ADDRS_PER_INDIRECT)
        j_dind_sub_count = num_ind
        dind_ptrs = []
        for g in range(num_ind):
            sub_ind_blk = alloc_block()
            dind_ptrs.append(sub_ind_blk)
            group = j_remaining[g * ADDRS_PER_INDIRECT:(g + 1) * ADDRS_PER_INDIRECT]
            sub_data = b''
            for blk in group:
                sub_data += struct.pack('<I', blk)
            sub_data += b'\x00' * (BLOCK_SIZE - len(sub_data))
            write_block(sub_ind_blk, sub_data)
        dind_data = b''
        for ptr in dind_ptrs:
            dind_data += struct.pack('<I', ptr)
        dind_data += b'\x00' * (BLOCK_SIZE - len(dind_data))
        write_block(j_dind_blk, dind_data)

    # Write journal inode as raw 256 bytes (no extents flag)
    journal_size = JOURNAL_BLOCKS * BLOCK_SIZE
    total_meta_blks = JOURNAL_BLOCKS + 1 + (1 if j_dind_blk else 0) + j_dind_sub_count
    j_offset = inode_table_offset(8)
    j_data = bytearray(INODE_SIZE)
    struct.pack_into('<HHI', j_data, 0x00, 0o100600, 0, journal_size & 0xFFFFFFFF)
    struct.pack_into('<IIII', j_data, 0x08, now, now, now, 0)
    struct.pack_into('<HHI', j_data, 0x18, 0, 1, total_meta_blks * (BLOCK_SIZE // 512))
    struct.pack_into('<II', j_data, 0x20, 0, 0)  # no EXTENTS_FL
    # i_block[15]: direct + indirect + dindirect
    for i in range(15):
        off = 0x28 + i * 4
        if i < 12:
            struct.pack_into('<I', j_data, off, j_direct[i] if i < len(j_direct) else 0)
        elif i == 12:
            struct.pack_into('<I', j_data, off, j_ind_blk)
        elif i == 13:
            struct.pack_into('<I', j_data, off, j_dind_blk)
        else:
            struct.pack_into('<I', j_data, off, 0)
    struct.pack_into('<I', j_data, 0x6C, (journal_size >> 32) & 0xFFFFFFFF)
    # Extra fields
    struct.pack_into('<H', j_data, 0x80, 28)  # extra_isize
    struct.pack_into('<I', j_data, 0x90, now)  # crtime
    # Checksum
    j_csum = inode_checksum(bytes(j_data), INODE_SIZE, 8, fs_uuid)
    struct.pack_into('<H', j_data, 0x7C, j_csum & 0xFFFF)
    struct.pack_into('<H', j_data, 0x82, (j_csum >> 16) & 0xFFFF)
    img[j_offset:j_offset + INODE_SIZE] = j_data

    # ---- Test files ----
    hello_data = b"Hello from ext4!\n"
    test2_data = b"Nested file with extent tree (ext4)\n"
    motd_data = b"Welcome to Zigix ext4!\nExtent trees, checksums, 64-bit block groups.\n"
    passwd_data = b"root:x:0:0:root:/root:/bin/zsh\nuser:x:1000:1000:user:/home/user:/bin/zsh\n"
    www_index_data = b"<html>\n<head><title>Zigix ext4</title></head>\n<body>\n<h1>Welcome to Zigix</h1>\n<p>Served by zhttpd from ext4 filesystem.</p>\n<p><a href=\"/hello.txt\">hello.txt</a> | <a href=\"/etc/\">/etc/</a> | <a href=\"/bin/\">/bin/</a></p>\n</body>\n</html>\n"
    hello_zig_data = b'const std = @import("std");\npub fn main() void {\n    const w = std.io.getStdOut().writer();\n    w.print("Hello from Zigix!\\n", .{}) catch {};\n}\n'

    hello_ino = alloc_inode()
    testdir_ino = alloc_inode()
    test2_ino = alloc_inode()
    etc_ino = alloc_inode()
    motd_ino = alloc_inode()
    passwd_ino = alloc_inode()
    root_home_ino = alloc_inode()
    home_ino = alloc_inode()
    home_user_ino = alloc_inode()
    www_ino = alloc_inode()
    www_index_ino = alloc_inode()
    tmp_ino = alloc_inode()
    hello_zig_ino = alloc_inode()

    # Allocate and write file data
    for ino, data_bytes, mode in [
        (hello_ino, hello_data, 0o100644),
        (test2_ino, test2_data, 0o100644),
        (motd_ino, motd_data, 0o100644),
        (passwd_ino, passwd_data, 0o100644),
        (www_index_ino, www_index_data, 0o100644),
        (hello_zig_ino, hello_zig_data, 0o100644),
    ]:
        blocks = alloc_file_blocks(data_bytes)
        write_file_data(data_bytes, blocks)
        iblock = make_extent_iblock(blocks)
        write_inode_ext4(ino, mode, len(data_bytes), len(blocks), iblock)

    # ---- Shell and extra binaries ----
    bin_ino = None
    zsh_ino = None
    extra_bin_info = []
    has_bin = shell_binary is not None or len(extra_bins) > 0

    if has_bin:
        bin_ino = alloc_inode()
        if shell_binary:
            zsh_ino = alloc_inode()
            blocks = alloc_file_blocks(shell_binary)
            write_file_data(shell_binary, blocks)
            iblock = make_extent_iblock(blocks)
            write_inode_ext4(zsh_ino, 0o100755, len(shell_binary), len(blocks), iblock)

        for name in sorted(extra_bins.keys()):
            data = extra_bins[name]
            ino = alloc_inode()
            blocks = alloc_file_blocks(data)
            write_file_data(data, blocks)
            iblock = make_extent_iblock(blocks)
            write_inode_ext4(ino, 0o100755, len(data), len(blocks), iblock)
            extra_bin_info.append((name, ino))

    # Root-level scripts
    script_info = []
    for name in sorted(root_scripts.keys()):
        data = root_scripts[name]
        ino = alloc_inode()
        blocks = alloc_file_blocks(data)
        write_file_data(data, blocks)
        iblock = make_extent_iblock(blocks)
        write_inode_ext4(ino, 0o100644, len(data), len(blocks), iblock)
        script_info.append((name, ino))

    # ---- Zig compiler tree (arg 5) ----
    zig_ino = None
    if len(sys.argv) >= 6 and os.path.isdir(sys.argv[5]):
        zig_tree_dir = sys.argv[5]
        print(f"  Adding Zig tree from {zig_tree_dir}...")
        zig_ino = alloc_inode()
        zig_entries = add_tree(zig_tree_dir, zig_ino, 2)
        zig_dir_entries_list = [(zig_ino, '.', FT_DIR), (2, '..', FT_DIR)]
        zig_dir_entries_list += zig_entries
        zig_dir_blocks = write_dir_blocks(zig_dir_entries_list)
        zig_dir_size = len(zig_dir_blocks) * BLOCK_SIZE
        zig_nlink = 2 + sum(1 for _, _, ft in zig_entries if ft == FT_DIR)
        iblock = make_extent_iblock(zig_dir_blocks)
        write_inode_ext4(zig_ino, 0o40755, zig_dir_size, len(zig_dir_blocks), iblock, nlink=zig_nlink)
        print(f"  Zig tree: {tree_files_added} files, {tree_dirs_created} dirs")

    # ---- Kernel source tree (arg 6) → /zigix/ for self-host build ----
    kernel_src_ino = None
    if len(sys.argv) >= 7 and os.path.isdir(sys.argv[6]):
        kernel_src_dir = sys.argv[6]
        print(f"  Adding kernel source from {kernel_src_dir}...")
        prev_files = tree_files_added
        prev_dirs = tree_dirs_created
        kernel_src_ino = alloc_inode()
        ks_entries = add_tree(kernel_src_dir, kernel_src_ino, 2)
        ks_dir_entries_list = [(kernel_src_ino, '.', FT_DIR), (2, '..', FT_DIR)]
        ks_dir_entries_list += ks_entries
        ks_dir_blocks = write_dir_blocks(ks_dir_entries_list)
        ks_dir_size = len(ks_dir_blocks) * BLOCK_SIZE
        ks_nlink = 2 + sum(1 for _, _, ft in ks_entries if ft == FT_DIR)
        iblock = make_extent_iblock(ks_dir_blocks)
        write_inode_ext4(kernel_src_ino, 0o40755, ks_dir_size, len(ks_dir_blocks), iblock, nlink=ks_nlink)
        print(f"  Kernel source: {tree_files_added - prev_files} files, {tree_dirs_created - prev_dirs} dirs")

    # ---- Directories ----

    # Empty directories
    for ino, parent_ino, mode, uid, gid in [
        (11, 2, 0o40700, 0, 0),              # lost+found
        (root_home_ino, 2, 0o40700, 0, 0),   # /root
        (home_user_ino, home_ino, 0o40700, 1000, 1000),  # /home/user
        (tmp_ino, 2, 0o41777, 0, 0),          # /tmp
    ]:
        blk = alloc_block()
        entries = make_dir_entry(ino, '.', FT_DIR)
        entries += make_dir_entry(parent_ino, '..', FT_DIR, rec_len=BLOCK_SIZE - len(entries))
        write_block(blk, entries)
        iblock = make_extent_iblock([blk])
        write_inode_ext4(ino, mode, BLOCK_SIZE, 1, iblock, nlink=2, uid=uid, gid=gid)

    # /testdir
    td_block = alloc_block()
    td_entries = make_dir_entry(testdir_ino, '.', FT_DIR)
    td_entries += make_dir_entry(2, '..', FT_DIR)
    td_entries += make_dir_entry(test2_ino, 'test2.txt', FT_REG, rec_len=BLOCK_SIZE - len(td_entries))
    write_block(td_block, td_entries)
    write_inode_ext4(testdir_ino, 0o40755, BLOCK_SIZE, 1,
                     make_extent_iblock([td_block]), nlink=2)

    # /etc
    etc_block = alloc_block()
    etc_entries = make_dir_entry(etc_ino, '.', FT_DIR)
    etc_entries += make_dir_entry(2, '..', FT_DIR)
    etc_entries += make_dir_entry(motd_ino, 'motd', FT_REG)
    etc_entries += make_dir_entry(passwd_ino, 'passwd', FT_REG, rec_len=BLOCK_SIZE - len(etc_entries))
    write_block(etc_block, etc_entries)
    write_inode_ext4(etc_ino, 0o40755, BLOCK_SIZE, 1,
                     make_extent_iblock([etc_block]), nlink=2)

    # /www
    www_block = alloc_block()
    www_entries = make_dir_entry(www_ino, '.', FT_DIR)
    www_entries += make_dir_entry(2, '..', FT_DIR)
    www_entries += make_dir_entry(www_index_ino, 'index.html', FT_REG, rec_len=BLOCK_SIZE - len(www_entries))
    write_block(www_block, www_entries)
    write_inode_ext4(www_ino, 0o40755, BLOCK_SIZE, 1,
                     make_extent_iblock([www_block]), nlink=2)

    # /home (has user/ subdir)
    home_block = alloc_block()
    hm_entries = make_dir_entry(home_ino, '.', FT_DIR)
    hm_entries += make_dir_entry(2, '..', FT_DIR)
    hm_entries += make_dir_entry(home_user_ino, 'user', FT_DIR, rec_len=BLOCK_SIZE - len(hm_entries))
    write_block(home_block, hm_entries)
    write_inode_ext4(home_ino, 0o40755, BLOCK_SIZE, 1,
                     make_extent_iblock([home_block]), nlink=3)

    # /bin directory (potentially 100+ entries)
    bin_dir_blocks = []
    if has_bin:
        bin_entries_list = [(bin_ino, '.', FT_DIR), (2, '..', FT_DIR)]
        if shell_binary:
            bin_entries_list.append((zsh_ino, 'zsh', FT_REG))
        for name, ino in extra_bin_info:
            bin_entries_list.append((ino, name, FT_REG))
        bin_dir_blocks = write_dir_blocks(bin_entries_list)
        bin_dir_size = len(bin_dir_blocks) * BLOCK_SIZE
        iblock = make_extent_iblock(bin_dir_blocks)
        write_inode_ext4(bin_ino, 0o40755, bin_dir_size, len(bin_dir_blocks), iblock, nlink=2)

    # Root directory (inode 2)
    root_entries_list = [
        (2, '.', FT_DIR),
        (2, '..', FT_DIR),
        (11, 'lost+found', FT_DIR),
        (hello_ino, 'hello.txt', FT_REG),
        (hello_zig_ino, 'hello.zig', FT_REG),
        (testdir_ino, 'testdir', FT_DIR),
        (etc_ino, 'etc', FT_DIR),
        (root_home_ino, 'root', FT_DIR),
        (home_ino, 'home', FT_DIR),
        (www_ino, 'www', FT_DIR),
        (tmp_ino, 'tmp', FT_DIR),
    ]
    for name, ino in script_info:
        root_entries_list.append((ino, name, FT_REG))
    if has_bin:
        root_entries_list.append((bin_ino, 'bin', FT_DIR))
    if zig_ino is not None:
        root_entries_list.append((zig_ino, 'zig', FT_DIR))
    if kernel_src_ino is not None:
        root_entries_list.append((kernel_src_ino, 'zigix', FT_DIR))
    root_dir_blocks = write_dir_blocks(root_entries_list)

    root_nlink = 9  # ., lf/.., testdir/.., etc/.., root/.., home/.., www/.., tmp/..
    if has_bin:
        root_nlink += 1
    if zig_ino is not None:
        root_nlink += 1
    if kernel_src_ino is not None:
        root_nlink += 1
    root_dir_size = len(root_dir_blocks) * BLOCK_SIZE
    iblock = make_extent_iblock(root_dir_blocks)
    write_inode_ext4(2, 0o40755, root_dir_size, len(root_dir_blocks), iblock, nlink=root_nlink)

    # ---- Block bitmaps (blocks 2..9, one per group) ----
    for g in range(NUM_GROUPS):
        bitmap = bytearray(BLOCK_SIZE)
        group_start = g * BLOCKS_PER_GROUP
        for b in allocated_blocks:
            if group_start <= b < group_start + BLOCKS_PER_GROUP:
                local_bit = b - group_start
                bitmap[local_bit // 8] |= (1 << (local_bit % 8))
        write_block(BB_START + g, bitmap)

    # ---- Inode bitmaps (blocks 10..17, one per group) ----
    for g in range(NUM_GROUPS):
        bitmap = bytearray(BLOCK_SIZE)
        # Inodes in this group: g*INODES_PER_GROUP+1 .. (g+1)*INODES_PER_GROUP
        group_ino_start = g * INODES_PER_GROUP + 1
        group_ino_end = (g + 1) * INODES_PER_GROUP

        if g == 0:
            # Reserved inodes 1-11, plus allocated user inodes
            for ino in range(1, min(next_inode, group_ino_end + 1)):
                local = ino - group_ino_start
                if 0 <= local < INODES_PER_GROUP:
                    bitmap[local // 8] |= (1 << (local % 8))
        else:
            # User inodes that fall in this group
            for ino in range(max(12, group_ino_start), min(next_inode, group_ino_end + 1)):
                local = ino - group_ino_start
                if 0 <= local < INODES_PER_GROUP:
                    bitmap[local // 8] |= (1 << (local % 8))
        write_block(IB_START + g, bitmap)

    # ---- Block group descriptors (block 1, 8 × 64 bytes) ----
    used_dirs = 9  # root, lf, testdir, etc, /root, /home, /home/user, /www, /tmp
    if has_bin:
        used_dirs += 1
    if zig_ino is not None:
        used_dirs += 1 + tree_dirs_created

    bgd_block_data = bytearray(BLOCK_SIZE)
    total_free_blocks = 0
    total_free_inodes = 0

    for g in range(NUM_GROUPS):
        group_start = g * BLOCKS_PER_GROUP
        # Count used blocks in this group
        used_in_group = sum(1 for b in allocated_blocks if group_start <= b < group_start + BLOCKS_PER_GROUP)
        free_blocks_g = BLOCKS_PER_GROUP - used_in_group

        # Count used inodes in this group
        group_ino_start = g * INODES_PER_GROUP + 1
        group_ino_end = (g + 1) * INODES_PER_GROUP
        if g == 0:
            used_inodes_g = min(next_inode, group_ino_end + 1) - 1  # inodes 1..min(next-1, 4096)
        else:
            used_inodes_g = max(0, min(next_inode, group_ino_end + 1) - group_ino_start)
        free_inodes_g = INODES_PER_GROUP - used_inodes_g

        total_free_blocks += free_blocks_g
        total_free_inodes += free_inodes_g

        # All dirs are in group 0 for this simple image
        used_dirs_g = used_dirs if g == 0 else 0

        bgd = bytearray(DESC_SIZE)
        # Block bitmap, inode bitmap, inode table locations (flex_bg packed)
        struct.pack_into('<I', bgd, 0x00, BB_START + g)                              # block bitmap
        struct.pack_into('<I', bgd, 0x04, IB_START + g)                              # inode bitmap
        struct.pack_into('<I', bgd, 0x08, IT_START + g * INODE_TABLE_BLOCKS_PER_GROUP) # inode table
        struct.pack_into('<H', bgd, 0x0C, free_blocks_g & 0xFFFF)
        struct.pack_into('<H', bgd, 0x0E, free_inodes_g & 0xFFFF)
        struct.pack_into('<H', bgd, 0x10, used_dirs_g & 0xFFFF)

        # Compute and store checksum
        csum = bgd_checksum(bytes(bgd), DESC_SIZE, g, fs_uuid)
        struct.pack_into('<H', bgd, 0x1E, csum)

        bgd_block_data[g * DESC_SIZE:(g + 1) * DESC_SIZE] = bgd

    write_block(BGDT_BLOCK, bgd_block_data)

    # ---- Superblock (byte offset 1024 in block 0) ----
    sb = bytearray(1024)
    sb_data = struct.pack('<13I 6H 4I 2H',
        TOTAL_INODES,           # s_inodes_count (total across all groups)
        TOTAL_BLOCKS,
        0,
        total_free_blocks,
        total_free_inodes,
        0,                      # s_first_data_block
        2,                      # s_log_block_size (4096)
        2,                      # s_log_frag_size
        BLOCKS_PER_GROUP,       # s_blocks_per_group
        BLOCKS_PER_GROUP,       # s_frags_per_group
        INODES_PER_GROUP,       # s_inodes_per_group
        now,                    # s_mtime
        now,                    # s_wtime
        0, 100,                 # s_mnt_count, s_max_mnt_count
        EXT2_SUPER_MAGIC,
        1, 1, 0,                # s_state, s_errors, s_minor_rev
        now, 0, 0,              # s_lastcheck, s_checkinterval, s_creator_os
        1,                      # s_rev_level = 1 (dynamic)
        0, 0,                   # s_def_resuid, s_def_resgid
    )
    sb[:len(sb_data)] = sb_data

    struct.pack_into('<I', sb, 0x54, 11)           # s_first_ino
    struct.pack_into('<H', sb, 0x58, INODE_SIZE)   # s_inode_size = 256
    struct.pack_into('<I', sb, 0x5C, COMPAT_HAS_JOURNAL | COMPAT_DIR_INDEX)
    struct.pack_into('<I', sb, 0x60, INCOMPAT_FILETYPE | INCOMPAT_EXTENTS | INCOMPAT_64BIT | INCOMPAT_FLEX_BG)
    struct.pack_into('<I', sb, 0x64, RO_COMPAT_EXTRA_ISIZE | RO_COMPAT_METADATA_CSUM |
                     RO_COMPAT_SPARSE_SUPER | RO_COMPAT_LARGE_FILE | RO_COMPAT_HUGE_FILE)
    sb[0x68:0x78] = fs_uuid
    struct.pack_into('<I', sb, 0xE0, 8)            # s_journal_inum

    # Hash seed for HTree directories (s_hash_seed at 0xEC, 4 x u32)
    import hashlib
    hash_seed_bytes = hashlib.md5(fs_uuid).digest()
    for i in range(4):
        struct.pack_into('<I', sb, 0xEC + i * 4, struct.unpack_from('<I', hash_seed_bytes, i * 4)[0])
    sb[0xFC] = 1    # s_def_hash_version = 1 (half_md4)

    struct.pack_into('<H', sb, 0xFE, DESC_SIZE)    # s_desc_size = 64
    struct.pack_into('<H', sb, 0x104, 28)          # s_min_extra_isize
    struct.pack_into('<H', sb, 0x106, 28)          # s_want_extra_isize

    # Flex block groups: s_log_groups_per_flex at 0x174
    # 4 means 2^4 = 16 groups per flex group
    sb[0x174] = 4   # s_log_groups_per_flex

    img[1024:1024 + len(sb)] = sb

    # ---- Write image ----
    with open(sys.argv[1], 'wb') as f:
        f.write(img)

    bin_count = (1 if shell_binary else 0) + len(extra_bin_info)
    used_mb = next_block * BLOCK_SIZE / (1024 * 1024)
    print(f"Created ext4 image: {sys.argv[1]}")
    print(f"  Size: {TOTAL_BLOCKS * BLOCK_SIZE // (1024*1024)} MB ({TOTAL_BLOCKS} blocks)")
    print(f"  Block groups: {NUM_GROUPS} ({BLOCKS_PER_GROUP} blocks/group, {INODES_PER_GROUP} inodes/group)")
    print(f"  Inode size: {INODE_SIZE} bytes (CRC32c checksummed)")
    print(f"  Descriptor size: {DESC_SIZE} bytes (64-bit mode)")
    print(f"  Journal: {JOURNAL_BLOCKS} blocks ({JOURNAL_BLOCKS * BLOCK_SIZE // (1024*1024)} MB)")
    print(f"  Inodes: {TOTAL_INODES} ({total_free_inodes} free)")
    print(f"  Blocks: {TOTAL_BLOCKS} ({total_free_blocks} free, {len(allocated_blocks)} used)")
    print(f"  Used space: {used_mb:.1f} MB")
    print(f"  {bin_count} binaries in /bin/")
    print(f"  Features: has_journal, dir_index, filetype, extents, 64bit, flex_bg, extra_isize, metadata_csum, sparse_super, large_file, huge_file")


if __name__ == '__main__':
    main()
