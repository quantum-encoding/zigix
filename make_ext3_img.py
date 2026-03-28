#!/usr/bin/env python3
"""Create an ext3 filesystem image with journal, shell binary, and extra binaries.

Usage: make_ext3_img.py <output.img> [shell_binary] [extra_bins_dir] [scripts_dir] [zig_tree_dir]

Writes raw ext3 structures — no external tools required.
Block size: 4096 bytes, 1 block group, 1GB image, 16384 inodes.
ext3 = ext2 + JBD2 journal (inode 8) + rev1 superblock with feature flags.

Layout (4096-byte blocks):
  Block 0:       superblock at offset 1024 (first 1024 bytes unused/boot)
  Block 1:       block group descriptor table (32-byte descriptors)
  Block 2:       block bitmap
  Block 3:       inode bitmap
  Blocks 4-515:  inode table (16384 inodes x 128 bytes = 512 blocks)
  Block 516:     journal superblock (first block of journal inode 8)
  Blocks 517-1539: journal data (1024 blocks total, 4MB)
  Block 1540+:   file data
"""

import struct
import sys
import os
import time
import math

BLOCK_SIZE = 4096
TOTAL_BLOCKS = 262144         # 1 GB
INODES_PER_GROUP = 16384
INODE_SIZE = 128
INODE_TABLE_BLOCKS = (INODES_PER_GROUP * INODE_SIZE) // BLOCK_SIZE  # 512
FIRST_DATA_BLOCK = 4 + INODE_TABLE_BLOCKS  # Block 516
EXT2_SUPER_MAGIC = 0xEF53
ADDRS_PER_INDIRECT = BLOCK_SIZE // 4  # 1024 for 4096-byte blocks

# JBD2 journal constants
JBD2_MAGIC = 0xC03B3998
JBD2_SUPERBLOCK_V2 = 4
JOURNAL_BLOCKS = 1024  # 4 MB journal

# Feature flags
COMPAT_HAS_JOURNAL = 0x0004
INCOMPAT_FILETYPE = 0x0002

# File type constants for directory entries
FT_REG = 1
FT_DIR = 2


def main():
    if len(sys.argv) < 2:
        print("Usage: make_ext3_img.py <output.img> [shell_binary] [extra_bins_dir] [scripts_dir] [zig_tree_dir]")
        sys.exit(1)

    shell_binary = None
    if len(sys.argv) >= 3 and os.path.exists(sys.argv[2]):
        with open(sys.argv[2], 'rb') as f:
            shell_binary = f.read()
        print(f"  Shell binary: {sys.argv[2]} ({len(shell_binary)} bytes)")

    # Load extra binaries from directory
    extra_bins = {}  # name -> bytes
    if len(sys.argv) >= 4 and os.path.isdir(sys.argv[3]):
        bins_dir = sys.argv[3]
        for name in sorted(os.listdir(bins_dir)):
            path = os.path.join(bins_dir, name)
            if os.path.isfile(path):
                with open(path, 'rb') as f:
                    extra_bins[name] = f.read()
                print(f"  Extra binary: {name} ({len(extra_bins[name])} bytes)")

    # Load root-level scripts from directory (4th arg)
    root_scripts = {}  # name -> bytes
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

    # Filesystem UUID
    fs_uuid = struct.pack('<IIII', 0xDEAD0E03, 0xBEEF0E03, now & 0xFFFFFFFF, 0x0E030E03)

    # Track allocated blocks and inodes
    next_block = FIRST_DATA_BLOCK
    next_inode = 12  # First non-reserved inode (1-10 reserved, 11=lost+found)

    def alloc_block():
        nonlocal next_block
        b = next_block
        next_block += 1
        if b >= TOTAL_BLOCKS:
            print(f"ERROR: out of blocks (allocated {b}, max {TOTAL_BLOCKS})")
            sys.exit(1)
        return b

    def alloc_inode():
        nonlocal next_inode
        i = next_inode
        next_inode += 1
        if i > INODES_PER_GROUP:
            print(f"ERROR: out of inodes (allocated {i}, max {INODES_PER_GROUP})")
            sys.exit(1)
        return i

    def write_block(block_num, data):
        offset = block_num * BLOCK_SIZE
        img[offset:offset + len(data)] = data[:BLOCK_SIZE]

    def make_dir_entry(inode, name, file_type, rec_len=None):
        name_bytes = name.encode('ascii')
        name_len = len(name_bytes)
        if rec_len is None:
            # Minimum: 8 + name_len, rounded up to 4
            rec_len = ((8 + name_len + 3) // 4) * 4
        entry = struct.pack('<IHBB', inode, rec_len, name_len, file_type) + name_bytes
        # Pad to rec_len
        entry += b'\x00' * (rec_len - len(entry))
        return entry

    def alloc_file_blocks(data):
        """Allocate data blocks + indirect/double-indirect for a file.
        Returns (data_blocks, indirect_block, dindirect_block).
        Supports files up to ~4 GB (12 direct + 1024 indirect + 1024*1024 dindirect)."""
        num_blocks = math.ceil(len(data) / BLOCK_SIZE) if len(data) > 0 else 0
        blocks = []
        indirect = None
        dindirect = None

        # Direct blocks (0-11)
        for _ in range(min(num_blocks, 12)):
            blocks.append(alloc_block())

        # Single indirect blocks (12 to 12+1023)
        if num_blocks > 12:
            indirect = alloc_block()
            sindirect_count = min(num_blocks - 12, ADDRS_PER_INDIRECT)
            for _ in range(sindirect_count):
                blocks.append(alloc_block())

        # Double indirect blocks (12+1024 to 12+1024+1024*1024)
        if num_blocks > 12 + ADDRS_PER_INDIRECT:
            dindirect = alloc_block()
            remaining = num_blocks - 12 - ADDRS_PER_INDIRECT
            for _ in range(remaining):
                blocks.append(alloc_block())

        return blocks, indirect, dindirect

    def write_file_data(data, blocks, indirect, dindirect=None):
        """Write file data to allocated blocks, indirect, and double-indirect."""
        for i, blk in enumerate(blocks):
            start = i * BLOCK_SIZE
            end = min(start + BLOCK_SIZE, len(data))
            if start < len(data):
                write_block(blk, data[start:end])

        # Write single indirect block
        if indirect:
            sindirect_blocks = blocks[12:12 + ADDRS_PER_INDIRECT]
            indirect_data = b''
            for blk in sindirect_blocks:
                indirect_data += struct.pack('<I', blk)
            indirect_data += b'\x00' * (BLOCK_SIZE - len(indirect_data))
            write_block(indirect, indirect_data)

        # Write double indirect block (array of indirect block pointers)
        if dindirect:
            dind_blocks = blocks[12 + ADDRS_PER_INDIRECT:]
            # Split into groups of ADDRS_PER_INDIRECT
            num_ind_blocks = math.ceil(len(dind_blocks) / ADDRS_PER_INDIRECT)
            ind_block_ptrs = []
            for g in range(num_ind_blocks):
                ind_blk = alloc_block()
                ind_block_ptrs.append(ind_blk)
                group = dind_blocks[g * ADDRS_PER_INDIRECT:(g + 1) * ADDRS_PER_INDIRECT]
                ind_data = b''
                for blk in group:
                    ind_data += struct.pack('<I', blk)
                ind_data += b'\x00' * (BLOCK_SIZE - len(ind_data))
                write_block(ind_blk, ind_data)
            # Write the double-indirect root block
            dind_data = b''
            for ptr in ind_block_ptrs:
                dind_data += struct.pack('<I', ptr)
            dind_data += b'\x00' * (BLOCK_SIZE - len(dind_data))
            write_block(dindirect, dind_data)

    def write_inode(ino, mode, size, blocks, block_ptrs, nlink=1, indirect=None, dindirect=None, uid=0, gid=0):
        # Inode table starts at block 4
        inode_offset = 4 * BLOCK_SIZE + (ino - 1) * INODE_SIZE
        # i_blocks = number of 512-byte sectors used
        total_blks = blocks
        if indirect:
            total_blks += 1  # Count the indirect block itself
        if dindirect:
            # Count dindirect root + all its indirect sub-blocks
            dind_data_blocks = blocks - 12 - ADDRS_PER_INDIRECT if blocks > 12 + ADDRS_PER_INDIRECT else 0
            dind_ind_blocks = math.ceil(dind_data_blocks / ADDRS_PER_INDIRECT)
            total_blks += 1 + dind_ind_blocks
        i_blocks_field = total_blks * (BLOCK_SIZE // 512)
        data = struct.pack('<HHI IIII HHI II',
            mode,           # i_mode
            uid,            # i_uid
            size,           # i_size
            now,            # i_atime
            now,            # i_ctime
            now,            # i_mtime
            0,              # i_dtime
            gid,            # i_gid
            nlink,          # i_links_count
            i_blocks_field, # i_blocks (512-byte sectors)
            0,              # i_flags
            0,              # i_osd1
        )
        # i_block[15] = 15 x u32
        for i in range(15):
            if i < 12:
                if i < len(block_ptrs):
                    data += struct.pack('<I', block_ptrs[i])
                else:
                    data += struct.pack('<I', 0)
            elif i == 12:
                # Singly indirect
                data += struct.pack('<I', indirect if indirect else 0)
            elif i == 13:
                # Doubly indirect
                data += struct.pack('<I', dindirect if dindirect else 0)
            else:
                data += struct.pack('<I', 0)
        # Remaining fields to fill 128 bytes
        data += b'\x00' * (INODE_SIZE - len(data))
        img[inode_offset:inode_offset + INODE_SIZE] = data

    def write_dir_blocks(entries_list):
        """Write directory entries across one or more blocks.
        entries_list = [(inode, name, file_type), ...]
        Returns list of allocated block numbers."""
        dir_blocks = []
        current_block_data = b''

        for idx, (inode, name, file_type) in enumerate(entries_list):
            is_last = (idx == len(entries_list) - 1)
            entry_min_size = ((8 + len(name.encode('ascii')) + 3) // 4) * 4

            if is_last or len(current_block_data) + entry_min_size > BLOCK_SIZE:
                if not is_last and len(current_block_data) + entry_min_size > BLOCK_SIZE:
                    # Current block is full — pad last entry to fill block
                    if current_block_data:
                        # Rewrite the last entry in this block to fill remaining space
                        remaining = BLOCK_SIZE - len(current_block_data)
                        if remaining >= 12:
                            # Add a dummy unused entry to fill the block
                            current_block_data += make_dir_entry(0, '', 0, rec_len=remaining)
                        blk = alloc_block()
                        dir_blocks.append(blk)
                        write_block(blk, current_block_data)
                        current_block_data = b''

            if is_last:
                # Last entry fills remaining space in current block
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

    # --- Recursive directory tree builder (for Zig lib/) ---
    tree_files_added = 0
    tree_dirs_created = 0

    def add_tree(host_dir, self_ino, parent_ino):
        """Recursively add host directory contents to the ext3 image.
        self_ino: pre-allocated inode for this directory.
        parent_ino: inode of the parent directory.
        Returns list of (ino, name, file_type) entries for the caller's dir block.
        Writes all file data/inodes directly."""
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
                blocks, indirect, dindirect = alloc_file_blocks(data)
                write_file_data(data, blocks, indirect, dindirect)
                mode = 0o100755 if os.access(full, os.X_OK) else 0o100644
                write_inode(ino, mode, len(data), len(blocks), blocks[:12],
                            indirect=indirect, dindirect=dindirect)
                entries.append((ino, name, FT_REG))
                tree_files_added += 1
            elif os.path.isdir(full):
                ino = alloc_inode()
                child_entries = add_tree(full, ino, self_ino)
                # Write directory block(s) with . and .. plus children
                dir_entries_list = [(ino, '.', FT_DIR), (self_ino, '..', FT_DIR)]
                dir_entries_list += child_entries
                dir_blocks = write_dir_blocks(dir_entries_list)
                dir_size = len(dir_blocks) * BLOCK_SIZE
                nlink = 2 + sum(1 for _, _, ft in child_entries if ft == FT_DIR)
                write_inode(ino, 0o40755, dir_size, len(dir_blocks),
                            dir_blocks[:12], nlink=nlink)
                entries.append((ino, name, FT_DIR))
                tree_dirs_created += 1
                if tree_dirs_created % 100 == 0:
                    print(f"    ... {tree_dirs_created} dirs, {tree_files_added} files")
        return entries

    # --- Allocate journal (inode 8) ---
    # Journal blocks are allocated first, right after the inode table.
    journal_start = next_block
    journal_block_ptrs = []
    for _ in range(JOURNAL_BLOCKS):
        journal_block_ptrs.append(alloc_block())

    # Write JBD2 journal superblock at first journal block (big-endian!)
    jsb = bytearray(BLOCK_SIZE)
    jsb_data = struct.pack('>IIIIII II I',
        JBD2_MAGIC,          # h_magic
        JBD2_SUPERBLOCK_V2,  # h_blocktype
        1,                   # h_sequence
        BLOCK_SIZE,          # s_blocksize
        JOURNAL_BLOCKS,      # s_maxlen
        1,                   # s_first (first usable journal block)
        1,                   # s_sequence (expected next commit ID)
        0,                   # s_start (0 = clean, no pending transactions)
        0,                   # s_errno
    )
    jsb[:len(jsb_data)] = jsb_data
    write_block(journal_start, jsb)

    # Write journal inode (inode 8) — needs indirect block for 1024 blocks
    journal_indirect = alloc_block()
    # First 12 blocks are direct
    journal_direct = journal_block_ptrs[:12]
    # Remaining go through single indirect
    journal_sindirect = journal_block_ptrs[12:]
    ind_data = b''
    for blk in journal_sindirect:
        ind_data += struct.pack('<I', blk)
    ind_data += b'\x00' * (BLOCK_SIZE - len(ind_data))
    write_block(journal_indirect, ind_data)

    journal_size = JOURNAL_BLOCKS * BLOCK_SIZE
    write_inode(8, 0o100600, journal_size, JOURNAL_BLOCKS, journal_direct,
                indirect=journal_indirect)

    # --- Allocate data blocks for test files ---
    hello_data = b"Hello from ext3!\n"
    test2_data = b"Nested file works (ext3)\n"

    # /etc/motd for grep demos
    motd_data = b"Welcome to Zigix ext3!\nA minimal Unix-like OS written in Zig.\nJournal-protected filesystem.\n"

    # /etc/passwd for multi-user login
    passwd_data = b"root:x:0:0:root:/root:/bin/zsh\nuser:x:1000:1000:user:/home/user:/bin/zsh\n"

    # /www/index.html for zhttpd web server
    www_index_data = b"<html>\n<head><title>Zigix ext3</title></head>\n<body>\n<h1>Welcome to Zigix</h1>\n<p>Served by zhttpd from ext3 filesystem.</p>\n<p><a href=\"/hello.txt\">hello.txt</a> | <a href=\"/etc/\">/etc/</a> | <a href=\"/bin/\">/bin/</a></p>\n</body>\n</html>\n"

    # --- Allocate inodes ---
    # Inode 2 = root dir (reserved)
    # Inode 11 = lost+found (convention)
    hello_ino = alloc_inode()     # 12
    testdir_ino = alloc_inode()   # 13
    test2_ino = alloc_inode()     # 14
    etc_ino = alloc_inode()       # 15
    motd_ino = alloc_inode()      # 16
    passwd_ino = alloc_inode()    # 17
    root_home_ino = alloc_inode() # 18 (/root)
    home_ino = alloc_inode()      # 19 (/home)
    home_user_ino = alloc_inode() # 20 (/home/user)
    www_ino = alloc_inode()       # 21 (/www)
    www_index_ino = alloc_inode() # 22 (/www/index.html)
    tmp_ino = alloc_inode()       # 23 (/tmp)
    hello_zig_ino = alloc_inode() # 24 (/hello.zig)

    # Test file: /hello.zig
    hello_zig_data = b'const std = @import("std");\npub fn main() void {\n    const w = std.io.getStdOut().writer();\n    w.print("Hello from Zigix!\\n", .{}) catch {};\n}\n'

    # Allocate file data blocks
    hello_block = alloc_block()
    write_block(hello_block, hello_data)

    test2_block = alloc_block()
    write_block(test2_block, test2_data)

    motd_block = alloc_block()
    write_block(motd_block, motd_data)

    passwd_block = alloc_block()
    write_block(passwd_block, passwd_data)

    www_index_block = alloc_block()
    write_block(www_index_block, www_index_data)

    hello_zig_block = alloc_block()
    write_block(hello_zig_block, hello_zig_data)

    # /tmp directory (empty, writable)
    tmp_block = alloc_block()
    tmp_entries = b''
    tmp_entries += make_dir_entry(tmp_ino, '.', FT_DIR)
    tmp_last = BLOCK_SIZE - len(tmp_entries)
    tmp_entries += make_dir_entry(2, '..', FT_DIR, rec_len=tmp_last)
    write_block(tmp_block, tmp_entries)

    # /www directory
    www_block = alloc_block()
    www_entries = b''
    www_entries += make_dir_entry(www_ino, '.', FT_DIR)
    www_entries += make_dir_entry(2, '..', FT_DIR)
    www_last = BLOCK_SIZE - len(www_entries)
    www_entries += make_dir_entry(www_index_ino, 'index.html', FT_REG, rec_len=www_last)
    write_block(www_block, www_entries)

    # /root directory
    root_home_block = alloc_block()
    rh_entries = b''
    rh_entries += make_dir_entry(root_home_ino, '.', FT_DIR)
    rh_last = BLOCK_SIZE - len(rh_entries)
    rh_entries += make_dir_entry(2, '..', FT_DIR, rec_len=rh_last)
    write_block(root_home_block, rh_entries)

    # /home directory
    home_block = alloc_block()
    hm_entries = b''
    hm_entries += make_dir_entry(home_ino, '.', FT_DIR)
    hm_entries += make_dir_entry(2, '..', FT_DIR)
    hm_last = BLOCK_SIZE - len(hm_entries)
    hm_entries += make_dir_entry(home_user_ino, 'user', FT_DIR, rec_len=hm_last)
    write_block(home_block, hm_entries)

    # /home/user directory
    home_user_block = alloc_block()
    hu_entries = b''
    hu_entries += make_dir_entry(home_user_ino, '.', FT_DIR)
    hu_last = BLOCK_SIZE - len(hu_entries)
    hu_entries += make_dir_entry(home_ino, '..', FT_DIR, rec_len=hu_last)
    write_block(home_user_block, hu_entries)

    # --- Shell binary and extra binaries ---
    bin_ino = None
    zsh_ino = None
    zsh_blocks = []
    zsh_indirect_block = None
    zsh_dindirect_block = None
    extra_bin_info = []  # [(name, ino, blocks, indirect, dindirect, data)]

    has_bin = shell_binary is not None or len(extra_bins) > 0

    if has_bin:
        bin_ino = alloc_inode()

        if shell_binary:
            zsh_ino = alloc_inode()
            zsh_blocks, zsh_indirect_block, zsh_dindirect_block = alloc_file_blocks(shell_binary)
            write_file_data(shell_binary, zsh_blocks, zsh_indirect_block, zsh_dindirect_block)

        for name in sorted(extra_bins.keys()):
            data = extra_bins[name]
            ino = alloc_inode()
            blocks, indirect, dindirect = alloc_file_blocks(data)
            write_file_data(data, blocks, indirect, dindirect)
            extra_bin_info.append((name, ino, blocks, indirect, dindirect, data))

    # --- Allocate root-level scripts ---
    script_info = []  # [(name, ino, blocks, indirect, dindirect, data)]
    for name in sorted(root_scripts.keys()):
        data = root_scripts[name]
        ino = alloc_inode()
        blocks, indirect, dindirect = alloc_file_blocks(data)
        write_file_data(data, blocks, indirect, dindirect)
        script_info.append((name, ino, blocks, indirect, dindirect, data))

    # --- Zig compiler tree (arg 5) ---
    zig_tree_dir = None
    zig_ino = None
    zig_dir_blocks = []
    zig_entries = []
    if len(sys.argv) >= 6 and os.path.isdir(sys.argv[5]):
        zig_tree_dir = sys.argv[5]
        print(f"  Adding Zig tree from {zig_tree_dir}...")
        zig_ino = alloc_inode()
        zig_entries = add_tree(zig_tree_dir, zig_ino, 2)  # parent = root (inode 2)
        # Write /zig directory blocks
        zig_dir_entries_list = [(zig_ino, '.', FT_DIR), (2, '..', FT_DIR)]
        zig_dir_entries_list += zig_entries
        zig_dir_blocks = write_dir_blocks(zig_dir_entries_list)
        zig_dir_size = len(zig_dir_blocks) * BLOCK_SIZE
        zig_nlink = 2 + sum(1 for _, _, ft in zig_entries if ft == FT_DIR)
        write_inode(zig_ino, 0o40755, zig_dir_size, len(zig_dir_blocks),
                    zig_dir_blocks[:12], nlink=zig_nlink)
        print(f"  Zig tree: {tree_files_added} files, {tree_dirs_created} dirs")

    # --- Write directories ---

    # lost+found directory (inode 11)
    lost_found_block = alloc_block()
    lf_entries = b''
    lf_entries += make_dir_entry(11, '.', FT_DIR)
    last_rec_len = BLOCK_SIZE - len(lf_entries)
    lf_entries += make_dir_entry(2, '..', FT_DIR, rec_len=last_rec_len)
    write_block(lost_found_block, lf_entries)

    # testdir directory (inode 13)
    testdir_block = alloc_block()
    td_entries = b''
    td_entries += make_dir_entry(testdir_ino, '.', FT_DIR)
    td_entries += make_dir_entry(2, '..', FT_DIR)
    last_rec_len = BLOCK_SIZE - len(td_entries)
    td_entries += make_dir_entry(test2_ino, 'test2.txt', FT_REG, rec_len=last_rec_len)
    write_block(testdir_block, td_entries)

    # /etc directory (inode 15)
    etc_block = alloc_block()
    etc_entries = b''
    etc_entries += make_dir_entry(etc_ino, '.', FT_DIR)
    etc_entries += make_dir_entry(2, '..', FT_DIR)
    etc_entries += make_dir_entry(motd_ino, 'motd', FT_REG)
    last_rec_len = BLOCK_SIZE - len(etc_entries)
    etc_entries += make_dir_entry(passwd_ino, 'passwd', FT_REG, rec_len=last_rec_len)
    write_block(etc_block, etc_entries)

    # /bin directory — may have 100+ entries, use multi-block writer
    bin_dir_blocks = []
    if has_bin:
        bin_entries_list = [
            (bin_ino, '.', FT_DIR),
            (2, '..', FT_DIR),
        ]
        if shell_binary:
            bin_entries_list.append((zsh_ino, 'zsh', FT_REG))
        for name, ino, blocks, indirect, dindirect, data in extra_bin_info:
            bin_entries_list.append((ino, name, FT_REG))
        bin_dir_blocks = write_dir_blocks(bin_entries_list)

    # Root directory (inode 2) — written last so we know all sub-dir inodes
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
    for name, ino, blocks, indirect, dindirect, data in script_info:
        root_entries_list.append((ino, name, FT_REG))
    if has_bin:
        root_entries_list.append((bin_ino, 'bin', FT_DIR))
    if zig_ino is not None:
        root_entries_list.append((zig_ino, 'zig', FT_DIR))
    root_dir_blocks = write_dir_blocks(root_entries_list)

    # --- Write inodes ---

    # Count directories for root nlink
    root_nlink = 9  # ., lost+found/.., testdir/.., etc/.., root/.., home/.., www/.., tmp/..
    if has_bin:
        root_nlink += 1  # bin/..
    if zig_ino is not None:
        root_nlink += 1  # zig/..

    root_dir_size = len(root_dir_blocks) * BLOCK_SIZE
    write_inode(2, 0o40755, root_dir_size, len(root_dir_blocks), root_dir_blocks[:12], nlink=root_nlink)
    write_inode(11, 0o40700, BLOCK_SIZE, 1, [lost_found_block], nlink=2)
    write_inode(hello_ino, 0o100644, len(hello_data), 1, [hello_block])
    write_inode(testdir_ino, 0o40755, BLOCK_SIZE, 1, [testdir_block], nlink=3)
    write_inode(test2_ino, 0o100644, len(test2_data), 1, [test2_block])
    write_inode(etc_ino, 0o40755, BLOCK_SIZE, 1, [etc_block], nlink=2)
    write_inode(motd_ino, 0o100644, len(motd_data), 1, [motd_block])
    write_inode(passwd_ino, 0o100644, len(passwd_data), 1, [passwd_block])
    write_inode(root_home_ino, 0o40700, BLOCK_SIZE, 1, [root_home_block], nlink=2, uid=0, gid=0)
    write_inode(home_ino, 0o40755, BLOCK_SIZE, 1, [home_block], nlink=3)  # ., user/..
    write_inode(home_user_ino, 0o40700, BLOCK_SIZE, 1, [home_user_block], nlink=2, uid=1000, gid=1000)
    write_inode(www_ino, 0o40755, BLOCK_SIZE, 1, [www_block], nlink=2)
    write_inode(www_index_ino, 0o100644, len(www_index_data), 1, [www_index_block])
    write_inode(tmp_ino, 0o41777, BLOCK_SIZE, 1, [tmp_block], nlink=2)  # /tmp sticky bit
    write_inode(hello_zig_ino, 0o100644, len(hello_zig_data), 1, [hello_zig_block])

    if has_bin:
        bin_dir_size = len(bin_dir_blocks) * BLOCK_SIZE
        write_inode(bin_ino, 0o40755, bin_dir_size, len(bin_dir_blocks),
                    bin_dir_blocks[:12], nlink=2,
                    indirect=None)  # Won't need indirect for directory

        if shell_binary:
            num_data_blocks = len(zsh_blocks)
            direct_ptrs = zsh_blocks[:12]
            write_inode(zsh_ino, 0o100755, len(shell_binary), num_data_blocks,
                        direct_ptrs, indirect=zsh_indirect_block, dindirect=zsh_dindirect_block)

        for name, ino, blocks, indirect, dindirect, data in extra_bin_info:
            num_data_blocks = len(blocks)
            direct_ptrs = blocks[:12]
            write_inode(ino, 0o100755, len(data), num_data_blocks,
                        direct_ptrs, indirect=indirect, dindirect=dindirect)

    # Write script file inodes
    for name, ino, blocks, indirect, dindirect, data in script_info:
        num_data_blocks = len(blocks)
        direct_ptrs = blocks[:12]
        write_inode(ino, 0o100644, len(data), num_data_blocks,
                    direct_ptrs, indirect=indirect, dindirect=dindirect)

    # --- Write block bitmap (block 2) ---
    # One bitmap block = BLOCK_SIZE * 8 = 32768 bits.  For images using more
    # blocks than that (e.g. with Zig tree), only the first 32768 blocks are
    # bitmap-tracked.  Blocks beyond that are still referenced by inodes and
    # fully readable; the kernel allocates NEW blocks only from the bitmap.
    block_bitmap = bytearray(BLOCK_SIZE)
    bitmap_capacity = BLOCK_SIZE * 8  # 32768
    for b in range(min(next_block, bitmap_capacity)):
        block_bitmap[b // 8] |= (1 << (b % 8))
    write_block(2, block_bitmap)

    # --- Write inode bitmap (block 3) ---
    inode_bitmap = bytearray(BLOCK_SIZE)
    # Mark inodes 1-2 (reserved + root) as used
    inode_bitmap[0] = 0x03  # bits 0,1 = inodes 1,2
    # Mark reserved inodes 3-10 as used
    inode_bitmap[0] |= 0xFC  # bits 2-7 = inodes 3-8
    inode_bitmap[1] |= 0x03  # bits 0-1 = inodes 9-10
    # Mark inode 11 (lost+found) as used
    inode_bitmap[1] |= (1 << 2)  # bit 10 = inode 11
    # Mark all allocated inodes as used
    for ino in range(12, next_inode):
        byte_idx = (ino - 1) // 8
        bit_idx = (ino - 1) % 8
        inode_bitmap[byte_idx] |= (1 << bit_idx)
    write_block(3, inode_bitmap)

    # --- Write block group descriptor (block 1) ---
    free_blocks = TOTAL_BLOCKS - next_block
    free_inodes = INODES_PER_GROUP - next_inode + 1
    used_dirs = 9  # root, lost+found, testdir, etc, /root, /home, /home/user, /www, /tmp
    if has_bin:
        used_dirs += 1  # /bin
    if zig_ino is not None:
        used_dirs += 1 + tree_dirs_created  # /zig + all subdirs
    bgd = struct.pack('<III HHH H 12s',
        2,              # bg_block_bitmap
        3,              # bg_inode_bitmap
        4,              # bg_inode_table
        free_blocks & 0xFFFF,  # bg_free_blocks_count (u16)
        free_inodes & 0xFFFF,  # bg_free_inodes_count (u16)
        used_dirs,      # bg_used_dirs_count
        0,              # bg_pad
        b'\x00' * 12,  # bg_reserved
    )
    write_block(1, bgd)

    # --- Write superblock (at byte offset 1024 in block 0) ---
    sb = bytearray(1024)
    sb_data = struct.pack('<13I 6H 4I 2H',
        INODES_PER_GROUP,   # s_inodes_count
        TOTAL_BLOCKS,       # s_blocks_count
        0,                  # s_r_blocks_count
        free_blocks,        # s_free_blocks_count
        free_inodes,        # s_free_inodes_count
        0,                  # s_first_data_block (0 for block_size > 1024)
        2,                  # s_log_block_size (2 = 4096 bytes: 1024 << 2)
        2,                  # s_log_frag_size
        TOTAL_BLOCKS,       # s_blocks_per_group
        TOTAL_BLOCKS,       # s_frags_per_group
        INODES_PER_GROUP,   # s_inodes_per_group
        now,                # s_mtime
        now,                # s_wtime
        0,                  # s_mnt_count
        100,                # s_max_mnt_count
        EXT2_SUPER_MAGIC,   # s_magic
        1,                  # s_state (clean)
        1,                  # s_errors
        0,                  # s_minor_rev_level
        now,                # s_lastcheck
        0,                  # s_checkinterval
        0,                  # s_creator_os
        1,                  # s_rev_level (1 = dynamic, enables feature flags)
        0,                  # s_def_resuid
        0,                  # s_def_resgid
    )
    sb[:len(sb_data)] = sb_data

    # Rev 1 fields (offset 0x54+)
    # s_first_ino (offset 0x54) = 11
    struct.pack_into('<I', sb, 0x54, 11)
    # s_inode_size (offset 0x58) = 128
    struct.pack_into('<H', sb, 0x58, INODE_SIZE)
    # s_feature_compat (offset 0x5C) = HAS_JOURNAL
    struct.pack_into('<I', sb, 0x5C, COMPAT_HAS_JOURNAL)
    # s_feature_incompat (offset 0x60) = FILETYPE
    struct.pack_into('<I', sb, 0x60, INCOMPAT_FILETYPE)
    # s_feature_ro_compat (offset 0x64) = 0
    struct.pack_into('<I', sb, 0x64, 0)
    # s_uuid (offset 0x68) = 16 bytes
    sb[0x68:0x78] = fs_uuid
    # s_journal_inum (offset 0xE0) = 8
    struct.pack_into('<I', sb, 0xE0, 8)

    # Write superblock at byte offset 1024 (within block 0 for 4096 blocks)
    img[1024:1024 + len(sb)] = sb

    # Write to file
    with open(sys.argv[1], 'wb') as f:
        f.write(img)

    bin_count = (1 if shell_binary else 0) + len(extra_bin_info)
    used_mb = next_block * BLOCK_SIZE / (1024 * 1024)
    print(f"Created ext3 image: {sys.argv[1]}")
    print(f"  Size: {TOTAL_BLOCKS * BLOCK_SIZE // (1024*1024)} MB ({TOTAL_BLOCKS} blocks)")
    print(f"  Journal: {JOURNAL_BLOCKS} blocks ({JOURNAL_BLOCKS * BLOCK_SIZE // (1024*1024)} MB) in inode 8")
    print(f"  Inodes: {INODES_PER_GROUP} ({free_inodes} free)")
    print(f"  Blocks: {TOTAL_BLOCKS} ({free_blocks} free, {next_block} used)")
    print(f"  Used space: {used_mb:.1f} MB")
    print(f"  {bin_count} binaries in /bin/")
    print(f"  Features: has_journal, filetype")


if __name__ == '__main__':
    main()
