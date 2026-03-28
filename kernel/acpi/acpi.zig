/// ACPI module root — re-exports all ACPI components.
/// Used as a single named module for architectures where the acpi directory
/// lives outside the compilation root (e.g., ARM64 at kernel/arch/aarch64/).

pub const parser = @import("acpi_parser.zig");
pub const tables = @import("acpi_tables.zig");
pub const io = @import("acpi_io.zig");
