/// FAT32 Filesystem Driver — Read-only support for EFI System Partitions and USB drives.
///
/// FAT32 is the universal exchange format: every OS can read it. This driver
/// enables Zigix to mount FAT32 partitions (ESP, USB sticks, SD cards).
///
/// On-disk layout:
///   Sector 0: BPB (BIOS Parameter Block) / boot sector
///   Sectors 1-5: FSInfo + reserved
///   FAT region: File Allocation Table (cluster chain map)
///   Data region: Clusters containing file/directory data
///
/// Key concepts:
///   - Files are stored in chains of clusters
///   - Each FAT entry points to the next cluster (or 0x0FFFFFFF = end)
///   - Directories are files containing 32-byte directory entries
///   - Long filenames use extra entries before the 8.3 entry

const vfs = @import("vfs.zig");

// ---- On-disk structures ----

/// BPB / Boot sector (first 512 bytes of partition)
const BPB = extern struct {
    jmp: [3]u8,            // 0x00: Jump instruction
    oem_name: [8]u8,       // 0x03: OEM name
    bytes_per_sector: u16, // 0x0B: Usually 512
    sectors_per_cluster: u8, // 0x0D: Power of 2 (1,2,4,8,16,32,64)
    reserved_sectors: u16, // 0x0E: Before first FAT (usually 32)
    num_fats: u8,          // 0x10: Usually 2
    root_entry_count: u16, // 0x11: 0 for FAT32
    total_sectors_16: u16, // 0x13: 0 for FAT32
    media_type: u8,        // 0x15: 0xF8 = hard disk
    fat_size_16: u16,      // 0x16: 0 for FAT32
    sectors_per_track: u16, // 0x18
    num_heads: u16,        // 0x1A
    hidden_sectors: u32,   // 0x1C
    total_sectors_32: u32, // 0x20: Total sectors
    // FAT32-specific fields (offset 0x24)
    fat_size_32: u32,      // 0x24: Sectors per FAT
    ext_flags: u16,        // 0x28
    fs_version: u16,       // 0x2A
    root_cluster: u32,     // 0x2C: First cluster of root directory (usually 2)
    fs_info_sector: u16,   // 0x30
    backup_boot_sector: u16, // 0x32
    reserved: [12]u8,      // 0x34
    drive_number: u8,      // 0x40
    reserved1: u8,         // 0x41
    boot_sig: u8,          // 0x42: 0x29
    volume_id: u32,        // 0x43
    volume_label: [11]u8,  // 0x47
    fs_type: [8]u8,        // 0x52: "FAT32   "
};

/// Directory entry (32 bytes)
const DirEntry = extern struct {
    name: [8]u8,     // 0x00: Short name (8.3 format, space-padded)
    ext: [3]u8,      // 0x08: Extension
    attr: u8,        // 0x0B: Attributes
    nt_reserved: u8, // 0x0C
    ctime_tenth: u8, // 0x0D
    ctime: u16,      // 0x0E
    cdate: u16,      // 0x10
    adate: u16,      // 0x12
    cluster_hi: u16, // 0x14: High 16 bits of first cluster
    mtime: u16,      // 0x16
    mdate: u16,      // 0x18
    cluster_lo: u16, // 0x1A: Low 16 bits of first cluster
    size: u32,       // 0x1C: File size in bytes

    const ATTR_READ_ONLY: u8 = 0x01;
    const ATTR_HIDDEN: u8 = 0x02;
    const ATTR_SYSTEM: u8 = 0x04;
    const ATTR_VOLUME_ID: u8 = 0x08;
    const ATTR_DIRECTORY: u8 = 0x10;
    const ATTR_ARCHIVE: u8 = 0x20;
    const ATTR_LONG_NAME: u8 = 0x0F;

    fn firstCluster(self: *const DirEntry) u32 {
        return @as(u32, self.cluster_hi) << 16 | self.cluster_lo;
    }

    fn isDir(self: *const DirEntry) bool {
        return self.attr & ATTR_DIRECTORY != 0;
    }

    fn isLfn(self: *const DirEntry) bool {
        return self.attr == ATTR_LONG_NAME;
    }

    fn isDeleted(self: *const DirEntry) bool {
        return self.name[0] == 0xE5;
    }

    fn isEnd(self: *const DirEntry) bool {
        return self.name[0] == 0x00;
    }

    fn isVolumeLabel(self: *const DirEntry) bool {
        return self.attr & ATTR_VOLUME_ID != 0 and self.attr != ATTR_LONG_NAME;
    }
};

// ---- Driver state ----

const MAX_INODES: usize = 256;
const CLUSTER_BUF_SIZE: usize = 32768; // max 64 sectors/cluster * 512

/// Per-inode metadata (maps VFS inodes to FAT32 clusters)
const FatInode = struct {
    first_cluster: u32,
    size: u32,
    is_dir: bool,
    in_use: bool,
};

var fat_inodes: [MAX_INODES]FatInode = [_]FatInode{.{
    .first_cluster = 0,
    .size = 0,
    .is_dir = false,
    .in_use = false,
}} ** MAX_INODES;

var vfs_inodes: [MAX_INODES]vfs.Inode = undefined;
var next_ino: usize = 1;

// BPB cached values
var sectors_per_cluster: u32 = 0;
var bytes_per_cluster: u32 = 0;
var fat_start_sector: u64 = 0;    // absolute sector of first FAT
var data_start_sector: u64 = 0;   // absolute sector of first data cluster
var root_cluster: u32 = 0;
var partition_start: u64 = 0;      // partition offset in sectors
var initialized: bool = false;

// Block I/O function (set during init)
var readSectorsFn: *const fn (sector: u64, count: u32, buf: [*]u8) bool = &defaultRead;
fn defaultRead(_: u64, _: u32, _: [*]u8) bool { return false; }

// Buffers
var sector_buf: [512]u8 = undefined;
var cluster_buf: [CLUSTER_BUF_SIZE]u8 = undefined;
var fat_cache_sector: u64 = 0xFFFFFFFFFFFFFFFF;
var fat_cache: [512]u8 = undefined;

// ---- VFS operations ----

const fat32_ops = vfs.FileOperations{
    .read = fat32Read,
    .readdir = fat32Readdir,
    .lookup = fat32Lookup,
};

fn fat32Read(desc: *vfs.FileDescription, buf: [*]u8, count: usize) isize {
    const fi = getFatInode(desc.inode) orelse return 0;
    if (fi.is_dir) return -21; // EISDIR

    const remaining = if (desc.offset < fi.size) fi.size - @as(u32, @truncate(desc.offset)) else 0;
    const to_read = @min(count, remaining);
    if (to_read == 0) return 0;

    var bytes_read: usize = 0;
    var offset: u32 = @truncate(desc.offset);
    var cluster = fi.first_cluster;

    // Skip to the cluster containing our offset
    const skip_clusters = offset / bytes_per_cluster;
    var i: u32 = 0;
    while (i < skip_clusters) : (i += 1) {
        cluster = nextCluster(cluster) orelse return @intCast(bytes_read);
    }
    offset -= skip_clusters * bytes_per_cluster;

    // Read data cluster by cluster
    while (bytes_read < to_read and cluster >= 2 and cluster < 0x0FFFFFF8) {
        if (!readCluster(cluster)) break;
        const avail = bytes_per_cluster - offset;
        const chunk = @min(avail, to_read - bytes_read);
        for (0..chunk) |j| buf[bytes_read + j] = cluster_buf[offset + j];
        bytes_read += chunk;
        offset = 0; // subsequent clusters read from start
        cluster = nextCluster(cluster) orelse break;
    }

    desc.offset += bytes_read;
    return @intCast(bytes_read);
}

fn fat32Readdir(desc: *vfs.FileDescription, entry: *vfs.DirEntry) bool {
    const fi = getFatInode(desc.inode) orelse return false;
    if (!fi.is_dir) return false;

    var cluster = fi.first_cluster;
    var entry_idx: u32 = @truncate(desc.offset);

    // Walk cluster chain to find the right position
    const entries_per_cluster = bytes_per_cluster / 32;
    while (entry_idx >= entries_per_cluster) {
        cluster = nextCluster(cluster) orelse return false;
        entry_idx -= entries_per_cluster;
    }

    // Scan for next valid entry
    while (cluster >= 2 and cluster < 0x0FFFFFF8) {
        if (!readCluster(cluster)) return false;

        while (entry_idx < entries_per_cluster) {
            const de: *const DirEntry = @ptrCast(@alignCast(&cluster_buf[entry_idx * 32]));
            entry_idx += 1;
            desc.offset += 1;

            if (de.isEnd()) return false;
            if (de.isDeleted() or de.isLfn() or de.isVolumeLabel()) continue;

            // Format 8.3 name
            var name_len: usize = 0;
            // Copy name part (trim trailing spaces)
            var name_end: usize = 8;
            while (name_end > 0 and de.name[name_end - 1] == ' ') name_end -= 1;
            for (0..name_end) |j| {
                entry.name[name_len] = if (de.name[j] >= 'A' and de.name[j] <= 'Z')
                    de.name[j] + 32 // lowercase
                else
                    de.name[j];
                name_len += 1;
            }
            // Add extension if present
            var ext_end: usize = 3;
            while (ext_end > 0 and de.ext[ext_end - 1] == ' ') ext_end -= 1;
            if (ext_end > 0) {
                entry.name[name_len] = '.';
                name_len += 1;
                for (0..ext_end) |j| {
                    entry.name[name_len] = if (de.ext[j] >= 'A' and de.ext[j] <= 'Z')
                        de.ext[j] + 32
                    else
                        de.ext[j];
                    name_len += 1;
                }
            }
            entry.name_len = @truncate(name_len);
            entry.ino = 0;
            entry.d_type = if (de.isDir()) vfs.DT_DIR else vfs.DT_REG;
            return true;
        }

        // Next cluster
        cluster = nextCluster(cluster) orelse return false;
        entry_idx = 0;
    }
    return false;
}

fn fat32Lookup(parent: *vfs.Inode, name: []const u8) ?*vfs.Inode {
    const fi = getFatInode(parent) orelse return null;
    if (!fi.is_dir) return null;

    var cluster = fi.first_cluster;
    while (cluster >= 2 and cluster < 0x0FFFFFF8) {
        if (!readCluster(cluster)) return null;

        const entries_per_cluster = bytes_per_cluster / 32;
        for (0..entries_per_cluster) |i| {
            const de: *const DirEntry = @ptrCast(@alignCast(&cluster_buf[i * 32]));
            if (de.isEnd()) return null;
            if (de.isDeleted() or de.isLfn() or de.isVolumeLabel()) continue;

            // Build 8.3 name and compare
            var fname: [13]u8 = undefined;
            var flen: usize = 0;
            var ne: usize = 8;
            while (ne > 0 and de.name[ne - 1] == ' ') ne -= 1;
            for (0..ne) |j| {
                fname[flen] = if (de.name[j] >= 'A' and de.name[j] <= 'Z')
                    de.name[j] + 32
                else
                    de.name[j];
                flen += 1;
            }
            var ee: usize = 3;
            while (ee > 0 and de.ext[ee - 1] == ' ') ee -= 1;
            if (ee > 0) {
                fname[flen] = '.';
                flen += 1;
                for (0..ee) |j| {
                    fname[flen] = if (de.ext[j] >= 'A' and de.ext[j] <= 'Z')
                        de.ext[j] + 32
                    else
                        de.ext[j];
                    flen += 1;
                }
            }

            if (flen == name.len and eqlIgnoreCase(fname[0..flen], name)) {
                return allocInode(de.firstCluster(), de.size, de.isDir());
            }
        }
        cluster = nextCluster(cluster) orelse return null;
    }
    return null;
}

// ---- FAT chain helpers ----

fn nextCluster(cluster: u32) ?u32 {
    // Each FAT32 entry is 4 bytes; 128 entries per 512-byte sector
    const fat_offset = cluster * 4;
    const fat_sector = fat_start_sector + fat_offset / 512;
    const entry_offset = fat_offset % 512;

    // Cache one FAT sector
    if (fat_sector != fat_cache_sector) {
        if (!readSectorsFn(fat_sector, 1, &fat_cache)) return null;
        fat_cache_sector = fat_sector;
    }

    const val = @as(u32, fat_cache[entry_offset]) |
        (@as(u32, fat_cache[entry_offset + 1]) << 8) |
        (@as(u32, fat_cache[entry_offset + 2]) << 16) |
        (@as(u32, fat_cache[entry_offset + 3]) << 24);
    const next = val & 0x0FFFFFFF;

    if (next >= 0x0FFFFFF8) return null; // end of chain
    if (next < 2) return null; // invalid
    return next;
}

fn readCluster(cluster: u32) bool {
    if (cluster < 2) return false;
    const sector = data_start_sector + @as(u64, cluster - 2) * sectors_per_cluster;
    return readSectorsFn(sector, @truncate(sectors_per_cluster), &cluster_buf);
}

// ---- Inode allocation ----

fn allocInode(first_cluster: u32, size: u32, is_dir: bool) ?*vfs.Inode {
    // Check if we already have an inode for this cluster
    for (0..MAX_INODES) |i| {
        if (fat_inodes[i].in_use and fat_inodes[i].first_cluster == first_cluster) {
            return &vfs_inodes[i];
        }
    }

    // Allocate new
    if (next_ino >= MAX_INODES) return null;
    const idx = next_ino;
    next_ino += 1;

    fat_inodes[idx] = .{
        .first_cluster = first_cluster,
        .size = size,
        .is_dir = is_dir,
        .in_use = true,
    };

    vfs_inodes[idx] = .{
        .ino = idx,
        .mode = if (is_dir) vfs.S_IFDIR | 0o755 else vfs.S_IFREG | 0o644,
        .size = size,
        .nlink = 1,
        .ops = &fat32_ops,
        .fs_data = null,
    };

    return &vfs_inodes[idx];
}

fn getFatInode(inode: *vfs.Inode) ?*FatInode {
    if (inode.ino >= MAX_INODES) return null;
    const fi = &fat_inodes[inode.ino];
    if (!fi.in_use) return null;
    return fi;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

// ---- Public init ----

/// Initialize FAT32 driver for a partition.
/// partition_start_sector: absolute sector offset of the FAT32 partition
/// read_fn: sector read function (reads absolute sectors)
/// Returns the root directory inode, or null on failure.
pub fn init(
    part_start: u64,
    read_fn: *const fn (sector: u64, count: u32, buf: [*]u8) bool,
) ?*vfs.Inode {
    readSectorsFn = read_fn;
    partition_start = part_start;

    // Read BPB (boot sector)
    if (!read_fn(part_start, 1, &sector_buf)) return null;
    const bpb: *const BPB = @ptrCast(@alignCast(&sector_buf));

    // Validate
    if (bpb.bytes_per_sector != 512) return null;
    if (bpb.sectors_per_cluster == 0) return null;
    if (bpb.num_fats == 0) return null;
    if (bpb.fat_size_32 == 0) return null;
    if (bpb.root_cluster < 2) return null;

    // Cache key values
    sectors_per_cluster = bpb.sectors_per_cluster;
    bytes_per_cluster = @as(u32, sectors_per_cluster) * 512;
    root_cluster = bpb.root_cluster;

    fat_start_sector = part_start + bpb.reserved_sectors;
    data_start_sector = fat_start_sector + @as(u64, bpb.num_fats) * bpb.fat_size_32;

    // Allocate root directory inode
    const root = allocInode(root_cluster, 0, true) orelse return null;
    initialized = true;
    return root;
}

pub fn isInitialized() bool {
    return initialized;
}
