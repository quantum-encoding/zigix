/// Comptime registry of kernel subsystems.
/// Each subsystem has a tag name (for output) and a comptime minimum log level.
/// Subsystems filtered at comptime produce zero code — no branch, no call.

pub const Level = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    fatal = 5,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .trace => "TRC",
            .debug => "DBG",
            .info => "INF",
            .warn => "WRN",
            .err => "ERR",
            .fatal => "FAT",
        };
    }
};

pub const Subsystem = enum(u8) {
    boot = 0,
    cpu = 1,
    mem = 2,
    vmm = 3,
    pmm = 4,
    pci = 5,
    nvme = 6,
    virtio = 7,
    ext2 = 8,
    ext3 = 9,
    ext4 = 10,
    vfs = 11,
    proc = 12,
    sched = 13,
    clone = 14,
    execve = 15,
    signal = 16,
    futex = 17,
    epoll = 18,
    syscall = 19,
    net = 20,
    arp = 21,
    icmp = 22,
    tcp = 23,
    udp = 24,
    ipv4 = 25,
    socket = 26,
    irq = 27,
    exc = 28,
    console = 29,
    kbd = 30,
    serial = 31,
    acpi = 32,
    swap = 33,
    fault = 34,
    pipe = 35,
    devfs = 36,
    procfs = 37,
    tmpfs = 38,
    ramfs = 39,
    elf = 40,
    page_cache = 41,

    pub const COUNT = 42;

    pub fn tag(self: Subsystem) []const u8 {
        return switch (self) {
            .boot => "boot",
            .cpu => "cpu",
            .mem => "mem",
            .vmm => "vmm",
            .pmm => "pmm",
            .pci => "pci",
            .nvme => "nvme",
            .virtio => "virtio",
            .ext2 => "ext2",
            .ext3 => "ext3",
            .ext4 => "ext4",
            .vfs => "vfs",
            .proc => "proc",
            .sched => "sched",
            .clone => "clone",
            .execve => "execve",
            .signal => "signal",
            .futex => "futex",
            .epoll => "epoll",
            .syscall => "syscall",
            .net => "net",
            .arp => "arp",
            .icmp => "icmp",
            .tcp => "tcp",
            .udp => "udp",
            .ipv4 => "ipv4",
            .socket => "socket",
            .irq => "irq",
            .exc => "exc",
            .console => "console",
            .kbd => "kbd",
            .serial => "serial",
            .acpi => "acpi",
            .swap => "swap",
            .fault => "fault",
            .pipe => "pipe",
            .devfs => "devfs",
            .procfs => "procfs",
            .tmpfs => "tmpfs",
            .ramfs => "ramfs",
            .elf => "elf",
            .page_cache => "page_cache",
        };
    }
};

/// Comptime minimum log level per subsystem.
/// Messages below this level are eliminated entirely at compile time.
/// Adjust these for release vs debug builds.
const comptime_min_levels: [Subsystem.COUNT]Level = init: {
    var levels: [Subsystem.COUNT]Level = .{Level.trace} ** Subsystem.COUNT;

    // Default: everything at .debug (strip trace in normal builds)
    for (&levels) |*l| l.* = .debug;

    // High-volume subsystems: raise floor for release builds
    levels[@intFromEnum(Subsystem.syscall)] = .warn;
    levels[@intFromEnum(Subsystem.sched)] = .info;
    levels[@intFromEnum(Subsystem.fault)] = .info;
    levels[@intFromEnum(Subsystem.page_cache)] = .info;

    // Critical subsystems: always visible
    levels[@intFromEnum(Subsystem.exc)] = .trace;
    levels[@intFromEnum(Subsystem.boot)] = .trace;

    break :init levels;
};

/// Returns the comptime minimum level for a subsystem.
/// Used by klog.scoped() to eliminate calls below this threshold.
pub fn comptimeMinLevel(sub: Subsystem) Level {
    return comptime_min_levels[@intFromEnum(sub)];
}
