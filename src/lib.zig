//! # zenmap
//!
//! A single-file, cross-platform Zig library for memory mapping large files
//! (such as GGUFs) efficiently and effectively.
//!
//! ## Features
//!
//! - **Cross-platform**: Works on Linux, macOS, FreeBSD, and Windows
//! - **Zero-copy access**: Memory-mapped files provide direct access without copying
//! - **Efficient for large files**: Only pages actually accessed are loaded into memory
//! - **Simple API**: Just `init`, use the slice, and `deinit`
//! - **GGUF support**: Built-in parser for GGUF model file headers
//! - **Zig 0.15+**: Uses the latest Zig APIs
//!
//! ## Quick Start
//!
//! ```zig
//! const zenmap = @import("zenmap");
//!
//! // Map a file
//! var mapped = try zenmap.MappedFile.init("path/to/file");
//! defer mapped.deinit();
//!
//! // Access the data directly
//! const data = mapped.slice();
//! std.debug.print("File size: {} bytes\n", .{data.len});
//! std.debug.print("First byte: 0x{X}\n", .{data[0]});
//! ```
//!
//! ## GGUF Model Files
//!
//! ```zig
//! const zenmap = @import("zenmap");
//!
//! var model = try zenmap.MappedFile.init("model.gguf");
//! defer model.deinit();
//!
//! if (zenmap.GgufHeader.parse(model.slice())) |header| {
//!     std.debug.print("GGUF v{}: {} tensors\n", .{
//!         header.version,
//!         header.tensor_count,
//!     });
//! }
//! ```
//!
//! ## Platform Details
//!
//! | Platform | Implementation |
//! |----------|---------------|
//! | Linux    | `mmap()` via `std.posix` |
//! | macOS    | `mmap()` via `std.posix` |
//! | FreeBSD  | `mmap()` via `std.posix` |
//! | Windows  | `NtCreateSection` + `NtMapViewOfSection` via ntdll |
//!

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Error Types
// ============================================================================

/// Errors that can occur during memory mapping operations.
pub const MmapError = error{
    /// Failed to open the file (file not found, permission denied, etc.)
    FileOpenFailed,
    /// Failed to get file metadata/size
    StatFailed,
    /// The file is empty (zero bytes)
    EmptyFile,
    /// POSIX mmap() call failed
    MmapFailed,
    /// POSIX munmap() call failed
    MunmapFailed,
    /// Windows CreateFile failed
    WindowsCreateFileFailed,
    /// Windows GetFileSizeEx failed
    WindowsGetFileSizeFailed,
    /// Windows NtCreateSection failed
    WindowsCreateSectionFailed,
    /// Windows NtMapViewOfSection failed
    WindowsMapViewFailed,
    /// The file path is invalid or too long
    InvalidPath,
};

// ============================================================================
// MappedFile - Cross-Platform Memory-Mapped File
// ============================================================================

/// A cross-platform memory-mapped file abstraction.
///
/// This struct provides read-only access to a file's contents through memory mapping,
/// allowing efficient access to large files without loading them entirely into memory.
///
/// ## Example
///
/// ```zig
/// var file = try MappedFile.init("large_file.bin");
/// defer file.deinit();
///
/// // Access file contents directly
/// const contents = file.slice();
/// for (contents) |byte| {
///     // Process each byte
/// }
/// ```
///
/// ## Thread Safety
///
/// Multiple threads can safely read from the same `MappedFile` instance concurrently.
/// However, the `deinit()` method must only be called once, after all reads are complete.
pub const MappedFile = struct {
    /// The mapped file data. This slice provides direct read access to the file contents.
    /// The alignment is guaranteed to be at least `page_size_min` on all platforms.
    data: []align(std.heap.page_size_min) const u8,

    /// Platform-specific implementation details.
    impl: PlatformImpl,

    const PlatformImpl = union(enum) {
        posix: PosixImpl,
        windows: WindowsImpl,
    };

    const PosixImpl = struct {
        fd: std.posix.fd_t,
    };

    const WindowsImpl = struct {
        file_handle: std.os.windows.HANDLE,
        section_handle: std.os.windows.HANDLE,
    };

    /// Memory-map a file for reading.
    ///
    /// Opens the file at the given path and maps it into the process's address space.
    /// The file must exist and be readable. Empty files are not supported.
    ///
    /// ## Arguments
    ///
    /// - `path`: Path to the file to map. Can be absolute or relative to the current
    ///   working directory.
    ///
    /// ## Returns
    ///
    /// A `MappedFile` instance on success, or an error if the operation fails.
    ///
    /// ## Errors
    ///
    /// - `FileOpenFailed`: The file could not be opened (doesn't exist, permission denied, etc.)
    /// - `StatFailed`: Could not retrieve file metadata
    /// - `EmptyFile`: The file is empty (zero bytes)
    /// - `MmapFailed`: The memory mapping operation failed (POSIX)
    /// - `WindowsCreateSectionFailed`: NtCreateSection failed (Windows)
    /// - `WindowsMapViewFailed`: NtMapViewOfSection failed (Windows)
    ///
    /// ## Example
    ///
    /// ```zig
    /// var mapped = MappedFile.init("data.bin") catch |err| {
    ///     std.debug.print("Failed to map file: {}\n", .{err});
    ///     return err;
    /// };
    /// defer mapped.deinit();
    /// ```
    pub fn init(path: []const u8) MmapError!MappedFile {
        switch (builtin.os.tag) {
            .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => {
                return initPosix(path);
            },
            .windows => {
                return initWindows(path);
            },
            else => @compileError("Unsupported OS for memory mapping. Supported: Linux, macOS, FreeBSD, NetBSD, OpenBSD, DragonflyBSD, Windows"),
        }
    }

    /// Initialize from a null-terminated path (useful for C interop).
    ///
    /// ## Example
    ///
    /// ```zig
    /// var mapped = try MappedFile.initZ("/path/to/file.bin");
    /// defer mapped.deinit();
    /// ```
    pub fn initZ(path: [*:0]const u8) MmapError!MappedFile {
        return init(std.mem.sliceTo(path, 0));
    }

    fn initPosix(path: []const u8) MmapError!MappedFile {
        // Open file
        const file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch {
            return MmapError.FileOpenFailed;
        };
        const fd = file.handle;

        // Get file size
        const stat = file.stat() catch {
            std.posix.close(fd);
            return MmapError.StatFailed;
        };
        const file_size = stat.size;

        if (file_size == 0) {
            std.posix.close(fd);
            return MmapError.EmptyFile;
        }

        // Memory map the file
        const mapped = std.posix.mmap(
            null, // Let kernel choose address
            file_size,
            std.posix.PROT.READ, // PROT_READ
            .{ .TYPE = .SHARED }, // MAP_SHARED
            fd,
            0, // offset
        ) catch {
            std.posix.close(fd);
            return MmapError.MmapFailed;
        };

        return MappedFile{
            .data = mapped,
            .impl = .{ .posix = .{ .fd = fd } },
        };
    }

    fn initWindows(path: []const u8) MmapError!MappedFile {
        // This is compiled out on non-Windows platforms
        if (builtin.os.tag != .windows) {
            unreachable;
        }

        const windows = std.os.windows;

        // Open file using std.fs which handles path conversion
        const file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch {
            return MmapError.FileOpenFailed;
        };
        const file_handle = file.handle;

        // Get file size
        const file_size = windows.GetFileSizeEx(file_handle) catch {
            windows.CloseHandle(file_handle);
            return MmapError.WindowsGetFileSizeFailed;
        };

        if (file_size == 0) {
            windows.CloseHandle(file_handle);
            return MmapError.EmptyFile;
        }

        // Create section using ntdll
        var section_handle: windows.HANDLE = undefined;
        const create_section_rc = windows.ntdll.NtCreateSection(
            &section_handle,
            windows.STANDARD_RIGHTS_REQUIRED | windows.SECTION_QUERY | windows.SECTION_MAP_READ,
            null,
            null,
            windows.PAGE_READONLY,
            windows.SEC_COMMIT,
            file_handle,
        );

        if (create_section_rc != .SUCCESS) {
            windows.CloseHandle(file_handle);
            return MmapError.WindowsCreateSectionFailed;
        }

        // Map view of section
        var view_size: usize = 0;
        var base_ptr: usize = 0;
        const map_section_rc = windows.ntdll.NtMapViewOfSection(
            section_handle,
            windows.GetCurrentProcess(),
            @ptrCast(&base_ptr),
            null,
            0,
            null,
            &view_size,
            .ViewUnmap,
            0,
            windows.PAGE_READONLY,
        );

        if (map_section_rc != .SUCCESS) {
            windows.CloseHandle(section_handle);
            windows.CloseHandle(file_handle);
            return MmapError.WindowsMapViewFailed;
        }

        const aligned_ptr: [*]align(std.heap.page_size_min) const u8 = @ptrFromInt(base_ptr);

        return MappedFile{
            .data = aligned_ptr[0..@intCast(file_size)],
            .impl = .{ .windows = .{
                .file_handle = file_handle,
                .section_handle = section_handle,
            } },
        };
    }

    /// Unmap the file and release all associated resources.
    ///
    /// After calling this method, the `MappedFile` instance should not be used.
    /// Any slices or pointers obtained from `slice()` or `data` become invalid.
    ///
    /// This method is safe to call even if the mapping was partially initialized
    /// (though normally you wouldn't have a `MappedFile` in that state).
    ///
    /// ## Example
    ///
    /// ```zig
    /// var mapped = try MappedFile.init("file.bin");
    /// // Use mapped.slice()...
    /// mapped.deinit(); // Clean up
    /// ```
    pub fn deinit(self: *MappedFile) void {
        switch (builtin.os.tag) {
            .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => {
                const posix_impl = self.impl.posix;
                // Use the raw syscall to avoid libc dependency
                _ = std.posix.system.munmap(@ptrCast(@constCast(self.data.ptr)), self.data.len);
                std.posix.close(posix_impl.fd);
            },
            .windows => {
                const windows = std.os.windows;
                const windows_impl = self.impl.windows;
                _ = windows.ntdll.NtUnmapViewOfSection(
                    windows.GetCurrentProcess(),
                    @ptrFromInt(@intFromPtr(self.data.ptr)),
                );
                windows.CloseHandle(windows_impl.section_handle);
                windows.CloseHandle(windows_impl.file_handle);
            },
            else => @compileError("Unsupported OS for memory mapping"),
        }
    }

    /// Get a slice view into the mapped memory.
    ///
    /// Returns a slice that provides read-only access to the entire file contents.
    /// The returned slice is valid until `deinit()` is called.
    ///
    /// ## Example
    ///
    /// ```zig
    /// var mapped = try MappedFile.init("file.bin");
    /// defer mapped.deinit();
    ///
    /// const data = mapped.slice();
    /// if (data.len > 0) {
    ///     std.debug.print("First byte: 0x{X}\n", .{data[0]});
    /// }
    /// ```
    pub fn slice(self: *const MappedFile) []const u8 {
        return self.data;
    }

    /// Get the size of the mapped file in bytes.
    ///
    /// ## Example
    ///
    /// ```zig
    /// var mapped = try MappedFile.init("file.bin");
    /// defer mapped.deinit();
    ///
    /// std.debug.print("File size: {} bytes\n", .{mapped.len()});
    /// ```
    pub fn len(self: *const MappedFile) usize {
        return self.data.len;
    }

    /// Check if the mapped file is empty.
    ///
    /// Note: Since `init()` returns an error for empty files, this will
    /// always return `false` for successfully initialized `MappedFile` instances.
    pub fn isEmpty(self: *const MappedFile) bool {
        return self.data.len == 0;
    }

    /// Get a sub-slice of the mapped memory.
    ///
    /// Returns a slice from `start` to `end` (exclusive), or `null` if the
    /// range is out of bounds.
    ///
    /// ## Arguments
    ///
    /// - `start`: Starting byte offset (inclusive)
    /// - `end`: Ending byte offset (exclusive)
    ///
    /// ## Example
    ///
    /// ```zig
    /// var mapped = try MappedFile.init("file.bin");
    /// defer mapped.deinit();
    ///
    /// if (mapped.subslice(0, 16)) |header| {
    ///     // Process first 16 bytes
    /// }
    /// ```
    pub fn subslice(self: *const MappedFile, start: usize, end: usize) ?[]const u8 {
        if (start > end or end > self.data.len) {
            return null;
        }
        return self.data[start..end];
    }

    /// Read bytes at a specific offset.
    ///
    /// Returns a slice of `count` bytes starting at `offset`, or `null` if
    /// the range would exceed the file bounds.
    ///
    /// ## Example
    ///
    /// ```zig
    /// var mapped = try MappedFile.init("file.bin");
    /// defer mapped.deinit();
    ///
    /// if (mapped.readAt(100, 4)) |bytes| {
    ///     const value = std.mem.readInt(u32, bytes[0..4], .little);
    /// }
    /// ```
    pub fn readAt(self: *const MappedFile, offset: usize, count: usize) ?[]const u8 {
        if (offset + count > self.data.len) {
            return null;
        }
        return self.data[offset..][0..count];
    }
};

// ============================================================================
// GGUF Support
// ============================================================================

/// GGUF Magic Number: "GGUF" in little-endian (0x46554747)
pub const GGUF_MAGIC: u32 = 0x46554747;

/// Parsed GGUF file header.
///
/// GGUF (GGML Universal Format) is the file format used by llama.cpp and other
/// GGML-based projects for storing large language model weights.
///
/// ## Header Structure
///
/// | Offset | Size | Field | Description |
/// |--------|------|-------|-------------|
/// | 0 | 4 | magic | "GGUF" (0x46554747) |
/// | 4 | 4 | version | Format version (currently 3) |
/// | 8 | 8 | tensor_count | Number of tensors in the file |
/// | 16 | 8 | metadata_kv_count | Number of metadata key-value pairs |
///
/// ## Example
///
/// ```zig
/// var mapped = try zenmap.MappedFile.init("model.gguf");
/// defer mapped.deinit();
///
/// if (zenmap.GgufHeader.parse(mapped.slice())) |header| {
///     std.debug.print("GGUF Version: {}\n", .{header.version});
///     std.debug.print("Tensors: {}\n", .{header.tensor_count});
///     std.debug.print("Metadata entries: {}\n", .{header.metadata_kv_count});
/// } else {
///     std.debug.print("Not a valid GGUF file\n", .{});
/// }
/// ```
pub const GgufHeader = struct {
    /// Magic number (should be 0x46554747 = "GGUF")
    magic: u32,
    /// GGUF format version
    version: u32,
    /// Number of tensors in the file
    tensor_count: u64,
    /// Number of metadata key-value pairs
    metadata_kv_count: u64,

    /// Minimum header size in bytes
    pub const HEADER_SIZE: usize = 24;

    /// Parse a GGUF header from raw bytes.
    ///
    /// ## Arguments
    ///
    /// - `data`: Slice containing at least 24 bytes of GGUF header data
    ///
    /// ## Returns
    ///
    /// The parsed `GgufHeader` if the data contains a valid GGUF header,
    /// or `null` if:
    /// - The data is too short (less than 24 bytes)
    /// - The magic number doesn't match "GGUF"
    ///
    /// ## Example
    ///
    /// ```zig
    /// const data = mapped.slice();
    /// if (GgufHeader.parse(data)) |header| {
    ///     // Valid GGUF file
    /// }
    /// ```
    pub fn parse(data: []const u8) ?GgufHeader {
        if (data.len < HEADER_SIZE) return null;

        const magic = std.mem.readInt(u32, data[0..4], .little);
        if (magic != GGUF_MAGIC) return null;

        return GgufHeader{
            .magic = magic,
            .version = std.mem.readInt(u32, data[4..8], .little),
            .tensor_count = std.mem.readInt(u64, data[8..16], .little),
            .metadata_kv_count = std.mem.readInt(u64, data[16..24], .little),
        };
    }

    /// Validate this header.
    ///
    /// ## Returns
    ///
    /// `true` if the header appears valid:
    /// - Magic number is correct
    /// - Version is a known value (1, 2, or 3)
    pub fn isValid(self: *const GgufHeader) bool {
        return self.magic == GGUF_MAGIC and self.version >= 1 and self.version <= 3;
    }

    /// Get the magic number as a string ("GGUF").
    pub fn magicString(self: *const GgufHeader) *const [4]u8 {
        return @ptrCast(&self.magic);
    }
};

// ============================================================================
// Utility Functions
// ============================================================================

/// Get the system page size.
///
/// Returns the minimum page size used for memory mapping alignment.
/// This is a compile-time constant.
pub fn pageSize() usize {
    return std.heap.page_size_min;
}

/// Check if a file appears to be a GGUF file by examining its header.
///
/// This is a convenience function that maps the file, checks the magic number,
/// and unmaps it. For repeated access, prefer using `MappedFile` directly.
///
/// ## Arguments
///
/// - `path`: Path to the file to check
///
/// ## Returns
///
/// `true` if the file exists and starts with the GGUF magic number.
///
/// ## Example
///
/// ```zig
/// if (zenmap.isGgufFile("model.gguf")) {
///     std.debug.print("This is a GGUF file!\n", .{});
/// }
/// ```
pub fn isGgufFile(path: []const u8) bool {
    var mapped = MappedFile.init(path) catch return false;
    defer mapped.deinit();

    const data = mapped.slice();
    if (data.len < 4) return false;

    const magic = std.mem.readInt(u32, data[0..4], .little);
    return magic == GGUF_MAGIC;
}

/// Create a test file with a recognizable pattern.
///
/// Useful for testing and verification. Creates a file with each byte
/// set to its offset modulo 256.
///
/// ## Arguments
///
/// - `path`: Path where the file should be created
/// - `size_mb`: Size of the file in megabytes
///
/// ## Example
///
/// ```zig
/// try zenmap.createTestFile("test.bin", 1); // Create 1 MB test file
/// defer std.fs.cwd().deleteFile("test.bin") catch {};
/// ```
pub fn createTestFile(path: []const u8, size_mb: usize) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    // Write in chunks to avoid huge memory allocation
    const chunk_size = 64 * 1024; // 64KB chunks
    var chunk: [chunk_size]u8 = undefined;

    // Fill with a recognizable pattern
    for (0..chunk_size) |i| {
        chunk[i] = @truncate(i);
    }

    const total_bytes = size_mb * 1024 * 1024;
    var written: usize = 0;

    while (written < total_bytes) {
        const to_write = @min(chunk_size, total_bytes - written);
        try file.writeAll(chunk[0..to_write]);
        written += to_write;
    }
}

/// Create a fake GGUF file for testing.
///
/// Creates a file with a valid GGUF header followed by padding.
/// Useful for testing GGUF parsing without needing actual model files.
///
/// ## Arguments
///
/// - `path`: Path where the file should be created
/// - `size_mb`: Size of the file in megabytes
/// - `tensor_count`: Number of tensors to report in the header
/// - `metadata_kv_count`: Number of metadata entries to report
///
/// ## Example
///
/// ```zig
/// try zenmap.createFakeGguf("test.gguf", 1, 42, 10);
/// defer std.fs.cwd().deleteFile("test.gguf") catch {};
/// ```
pub fn createFakeGguf(
    path: []const u8,
    size_mb: usize,
    tensor_count: u64,
    metadata_kv_count: u64,
) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    // Write GGUF header
    var header: [GgufHeader.HEADER_SIZE]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], GGUF_MAGIC, .little);
    std.mem.writeInt(u32, header[4..8], 3, .little); // version 3
    std.mem.writeInt(u64, header[8..16], tensor_count, .little);
    std.mem.writeInt(u64, header[16..24], metadata_kv_count, .little);

    try file.writeAll(&header);

    // Fill rest with padding
    const chunk_size = 64 * 1024;
    const chunk: [chunk_size]u8 = [_]u8{0xAB} ** chunk_size;

    const total_bytes = size_mb * 1024 * 1024;
    var written: usize = GgufHeader.HEADER_SIZE;

    while (written < total_bytes) {
        const to_write = @min(chunk_size, total_bytes - written);
        try file.writeAll(chunk[0..to_write]);
        written += to_write;
    }
}

/// Simplified GGUF creation with default values.
pub fn createFakeGgufSimple(path: []const u8, size_mb: usize) !void {
    return createFakeGguf(path, size_mb, 42, 10);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "MappedFile: create and map small file" {
    const test_path = "zenmap_test_small.bin";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    // Create small test file
    {
        const file = try std.fs.cwd().createFile(test_path, .{});
        defer file.close();
        try file.writeAll("Hello, zenmap!");
    }

    // Map it
    var mapped = try MappedFile.init(test_path);
    defer mapped.deinit();

    try std.testing.expectEqualSlices(u8, "Hello, zenmap!", mapped.slice());
    try std.testing.expectEqual(@as(usize, 14), mapped.len());
    try std.testing.expect(!mapped.isEmpty());
}

test "MappedFile: initZ with null-terminated string" {
    const test_path = "zenmap_test_initz.bin";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    {
        const file = try std.fs.cwd().createFile(test_path, .{});
        defer file.close();
        try file.writeAll("test data");
    }

    var mapped = try MappedFile.initZ("zenmap_test_initz.bin");
    defer mapped.deinit();

    try std.testing.expectEqualSlices(u8, "test data", mapped.slice());
}

test "MappedFile: subslice and readAt" {
    const test_path = "zenmap_test_subslice.bin";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    {
        const file = try std.fs.cwd().createFile(test_path, .{});
        defer file.close();
        try file.writeAll("0123456789ABCDEF");
    }

    var mapped = try MappedFile.init(test_path);
    defer mapped.deinit();

    // Test subslice
    const sub = mapped.subslice(4, 8);
    try std.testing.expect(sub != null);
    try std.testing.expectEqualSlices(u8, "4567", sub.?);

    // Test invalid subslice
    try std.testing.expect(mapped.subslice(10, 5) == null); // start > end
    try std.testing.expect(mapped.subslice(0, 100) == null); // end > len

    // Test readAt
    const bytes = mapped.readAt(8, 4);
    try std.testing.expect(bytes != null);
    try std.testing.expectEqualSlices(u8, "89AB", bytes.?);

    // Test invalid readAt
    try std.testing.expect(mapped.readAt(14, 4) == null); // would exceed bounds
}

test "MappedFile: file not found returns error" {
    const result = MappedFile.init("nonexistent_file_12345.bin");
    try std.testing.expectError(MmapError.FileOpenFailed, result);
}

test "MappedFile: empty file returns error" {
    const test_path = "zenmap_test_empty.bin";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    // Create empty file
    {
        const file = try std.fs.cwd().createFile(test_path, .{});
        file.close();
    }

    const result = MappedFile.init(test_path);
    try std.testing.expectError(MmapError.EmptyFile, result);
}

test "MappedFile: larger file with pattern verification" {
    const test_path = "zenmap_test_pattern.bin";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    // Create test file with pattern
    try createTestFile(test_path, 1); // 1 MB

    var mapped = try MappedFile.init(test_path);
    defer mapped.deinit();

    // Verify size
    try std.testing.expectEqual(@as(usize, 1024 * 1024), mapped.len());

    // Verify pattern at various offsets
    const data = mapped.slice();
    for (0..256) |i| {
        try std.testing.expectEqual(@as(u8, @truncate(i)), data[i]);
    }

    // Check pattern repeats correctly
    try std.testing.expectEqual(@as(u8, 0), data[256 * 256]); // 65536 mod 256 = 0
}

test "GgufHeader: parse valid header" {
    var data: [24]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], GGUF_MAGIC, .little);
    std.mem.writeInt(u32, data[4..8], 3, .little);
    std.mem.writeInt(u64, data[8..16], 100, .little);
    std.mem.writeInt(u64, data[16..24], 50, .little);

    const header = GgufHeader.parse(&data).?;
    try std.testing.expectEqual(GGUF_MAGIC, header.magic);
    try std.testing.expectEqual(@as(u32, 3), header.version);
    try std.testing.expectEqual(@as(u64, 100), header.tensor_count);
    try std.testing.expectEqual(@as(u64, 50), header.metadata_kv_count);
    try std.testing.expect(header.isValid());
    try std.testing.expectEqualSlices(u8, "GGUF", header.magicString());
}

test "GgufHeader: parse invalid magic returns null" {
    var data: [24]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 0xDEADBEEF, .little);
    std.mem.writeInt(u32, data[4..8], 3, .little);
    std.mem.writeInt(u64, data[8..16], 100, .little);
    std.mem.writeInt(u64, data[16..24], 50, .little);

    try std.testing.expectEqual(@as(?GgufHeader, null), GgufHeader.parse(&data));
}

test "GgufHeader: parse too short data returns null" {
    const data = [_]u8{ 0x47, 0x47, 0x55, 0x46 }; // Just "GGUF" magic, no rest
    try std.testing.expectEqual(@as(?GgufHeader, null), GgufHeader.parse(&data));
}

test "GgufHeader: isValid checks version" {
    var header = GgufHeader{
        .magic = GGUF_MAGIC,
        .version = 0, // Invalid version
        .tensor_count = 0,
        .metadata_kv_count = 0,
    };
    try std.testing.expect(!header.isValid());

    header.version = 1;
    try std.testing.expect(header.isValid());

    header.version = 2;
    try std.testing.expect(header.isValid());

    header.version = 3;
    try std.testing.expect(header.isValid());

    header.version = 4; // Future version, currently invalid
    try std.testing.expect(!header.isValid());
}

test "createFakeGguf and isGgufFile" {
    const test_path = "zenmap_test_fake.gguf";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    try createFakeGguf(test_path, 1, 123, 45);

    try std.testing.expect(isGgufFile(test_path));
    try std.testing.expect(!isGgufFile("nonexistent_file.gguf"));

    // Verify header contents
    var mapped = try MappedFile.init(test_path);
    defer mapped.deinit();

    const header = GgufHeader.parse(mapped.slice()).?;
    try std.testing.expectEqual(@as(u64, 123), header.tensor_count);
    try std.testing.expectEqual(@as(u64, 45), header.metadata_kv_count);
}

test "pageSize returns non-zero value" {
    const size = pageSize();
    try std.testing.expect(size > 0);
    // Page size should be a power of 2
    try std.testing.expect(size & (size - 1) == 0);
}

test "MappedFile: multiple sequential reads" {
    const test_path = "zenmap_test_sequential.bin";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    // Create a file with known content
    {
        const file = try std.fs.cwd().createFile(test_path, .{});
        defer file.close();
        var i: u8 = 0;
        while (true) {
            try file.writeAll(&[_]u8{i});
            if (i == 255) break;
            i += 1;
        }
    }

    var mapped = try MappedFile.init(test_path);
    defer mapped.deinit();

    const data = mapped.slice();
    try std.testing.expectEqual(@as(usize, 256), data.len);

    // Sequential read verification
    var checksum: u32 = 0;
    for (data) |byte| {
        checksum += byte;
    }
    // Sum of 0..255 = 255 * 256 / 2 = 32640
    try std.testing.expectEqual(@as(u32, 32640), checksum);
}
