//! zenmap Demo Application
//!
//! This demo showcases the zenmap library's capabilities for memory mapping
//! large files efficiently across different platforms.
//!
//! Run with: zig build run

const std = @import("std");
const builtin = @import("builtin");

const zenmap = @import("lib.zig");

pub fn main() !void {
    // Zig 0.15 style stdout with buffering
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.print("=== zenmap Demo (Zig 0.15) ===\n\n", .{});

    // Platform info
    try stdout.print("Platform: {s}-{s}\n", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });
    try stdout.print("Page size: {} bytes\n\n", .{zenmap.pageSize()});

    // Create test files
    const test_file = "zenmap_demo_test.bin";
    const gguf_file = "zenmap_demo_model.gguf";
    const file_size_mb: usize = 10; // 10 MB test file

    try stdout.print("Creating {} MB test file: {s}\n", .{ file_size_mb, test_file });
    try stdout.flush();

    zenmap.createTestFile(test_file, file_size_mb) catch |err| {
        try stdout.print("Failed to create test file: {}\n", .{err});
        try stdout.flush();
        return;
    };

    try stdout.print("Creating fake GGUF file: {s}\n\n", .{gguf_file});
    try stdout.flush();

    zenmap.createFakeGguf(gguf_file, file_size_mb, 42, 10) catch |err| {
        try stdout.print("Failed to create GGUF file: {}\n", .{err});
        try stdout.flush();
        return;
    };

    // Test 1: Basic memory mapping
    try stdout.print("--- Test 1: Basic Memory Mapping ---\n", .{});
    try stdout.flush();

    var mapped = zenmap.MappedFile.init(test_file) catch |err| {
        try stdout.print("Failed to mmap: {}\n", .{err});
        try stdout.flush();
        return;
    };
    defer mapped.deinit();

    try stdout.print("Successfully mapped {} bytes\n", .{mapped.len()});

    // Verify data pattern
    const data = mapped.slice();
    var verified: usize = 0;
    for (0..@min(1024, data.len)) |i| {
        if (data[i] == @as(u8, @truncate(i))) {
            verified += 1;
        }
    }
    try stdout.print("Verified {}/1024 bytes match expected pattern\n\n", .{verified});
    try stdout.flush();

    // Test 2: subslice and readAt
    try stdout.print("--- Test 2: Slice Operations ---\n", .{});
    if (mapped.subslice(0, 16)) |header_bytes| {
        try stdout.print("First 16 bytes: ", .{});
        for (header_bytes) |b| {
            try stdout.print("{X:0>2} ", .{b});
        }
        try stdout.print("\n", .{});
    }
    if (mapped.readAt(256, 4)) |bytes| {
        try stdout.print("4 bytes at offset 256: ", .{});
        for (bytes) |b| {
            try stdout.print("{X:0>2} ", .{b});
        }
        try stdout.print("\n\n", .{});
    }
    try stdout.flush();

    // Test 3: GGUF header parsing
    try stdout.print("--- Test 3: GGUF Header Parsing ---\n", .{});
    try stdout.flush();

    // Quick check using utility function
    if (zenmap.isGgufFile(gguf_file)) {
        try stdout.print("File '{s}' is a valid GGUF file\n", .{gguf_file});
    }

    var gguf_mapped = zenmap.MappedFile.init(gguf_file) catch |err| {
        try stdout.print("Failed to mmap GGUF: {}\n", .{err});
        try stdout.flush();
        return;
    };
    defer gguf_mapped.deinit();

    const gguf_data = gguf_mapped.slice();
    if (zenmap.GgufHeader.parse(gguf_data)) |header| {
        try stdout.print("GGUF Header:\n", .{});
        try stdout.print("  Magic: 0x{X:0>8} ('{s}')\n", .{
            header.magic,
            header.magicString(),
        });
        try stdout.print("  Version: {}\n", .{header.version});
        try stdout.print("  Tensor count: {}\n", .{header.tensor_count});
        try stdout.print("  Metadata KV count: {}\n", .{header.metadata_kv_count});
        try stdout.print("  Valid: {}\n\n", .{header.isValid()});
    } else {
        try stdout.print("Failed to parse GGUF header\n\n", .{});
    }
    try stdout.flush();

    // Test 4: Performance test - sequential read
    try stdout.print("--- Test 4: Sequential Read Performance ---\n", .{});
    try stdout.flush();

    const start = std.time.nanoTimestamp();
    var checksum: u64 = 0;
    for (data) |byte| {
        checksum +%= byte;
    }
    const end = std.time.nanoTimestamp();
    const elapsed_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;
    const throughput_mb_s = @as(f64, @floatFromInt(data.len)) / (1024.0 * 1024.0) / (elapsed_ms / 1000.0);

    try stdout.print("Read {} bytes in {d:.2} ms\n", .{ data.len, elapsed_ms });
    try stdout.print("Throughput: {d:.2} MB/s\n", .{throughput_mb_s});
    try stdout.print("Checksum: 0x{X:0>16}\n\n", .{checksum});
    try stdout.flush();

    // Test 5: Error handling demo
    try stdout.print("--- Test 5: Error Handling ---\n", .{});
    const bad_result = zenmap.MappedFile.init("nonexistent_file_xyz.bin");
    if (bad_result) |_| {
        try stdout.print("Unexpected success opening nonexistent file\n", .{});
    } else |err| {
        try stdout.print("Expected error for nonexistent file: {}\n\n", .{err});
    }
    try stdout.flush();

    // Cleanup
    try stdout.print("--- Cleanup ---\n", .{});
    std.fs.cwd().deleteFile(test_file) catch {};
    std.fs.cwd().deleteFile(gguf_file) catch {};
    try stdout.print("Test files removed.\n", .{});
    try stdout.print("\n=== Demo Complete ===\n", .{});

    try stdout.flush();
}

// Re-export tests from lib for `zig build test`
test {
    _ = zenmap;
}
