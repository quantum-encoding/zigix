/// Fundamental kernel types — defined early so they never need changing.

pub const ProcessId = u32;
pub const ThreadId = u32;
pub const CpuId = u16;
pub const NumaNode = u8;
pub const CapabilityId = u64;

pub const PhysAddr = u64;
pub const VirtAddr = u64;
pub const PageFrame = u52; // Physical page number: phys_addr >> 12

pub const PAGE_SIZE: u64 = 4096;
pub const PAGE_SHIFT: u6 = 12;
pub const CACHE_LINE: u64 = 64;
