# zenmap

[![Zig](https://img.shields.io/badge/Zig-0.15%2B-orange)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/bkataru/zenmap/actions/workflows/ci.yml/badge.svg)](https://github.com/bkataru/zenmap/actions/workflows/ci.yml)

A single-file, cross-platform Zig library for memory mapping large files (such as GGUFs) efficiently and effectively.

## Features

- **Single-file library** - Just one `lib.zig` file, easy to understand and maintain
- **Cross-platform** - Works on Linux, macOS, FreeBSD, and Windows
- **Zero-copy access** - Memory-mapped files provide direct access without copying
- **Efficient for large files** - Only pages actually accessed are loaded into memory
- **Simple API** - Just `init`, use the slice, and `deinit`
- **GGUF support** - Built-in parser for GGUF (llama.cpp) model file headers
- **Zig 0.15+** - Uses the latest Zig APIs
- **No dependencies** - Only uses the Zig standard library

## Installation

Add zenmap to your project with `zig fetch`:

```shell
zig fetch --save git+https://github.com/bkataru/zenmap.git
```

This updates your `build.zig.zon`:

```zig
.{
    .name = "your-project",
    .version = "0.1.0",
    .dependencies = .{
        .zenmap = .{
            .url = "git+https://github.com/bkataru/zenmap.git",
            .hash = "...",
        },
    },
}
```

Then in your `build.zig`:

```zig
const zenmap = b.dependency("zenmap", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zenmap", zenmap.module("zenmap"));
```

## Quick Start

### Basic Usage

```zig
const std = @import("std");
const zenmap = @import("zenmap");

pub fn main() !void {
    // Map a file
    var mapped = try zenmap.MappedFile.init("path/to/file.bin");
    defer mapped.deinit();

    // Access the data directly - no copying!
    const data = mapped.slice();
    std.debug.print("File size: {} bytes\n", .{data.len});
    std.debug.print("First byte: 0x{X}\n", .{data[0]});
}
```

### GGUF Model Files

```zig
const zenmap = @import("zenmap");

pub fn main() !void {
    // Quick check if file is GGUF
    if (zenmap.isGgufFile("model.gguf")) {
        std.debug.print("Valid GGUF file!\n", .{});
    }

    // Map and parse GGUF header
    var model = try zenmap.MappedFile.init("model.gguf");
    defer model.deinit();

    if (zenmap.GgufHeader.parse(model.slice())) |header| {
        std.debug.print("GGUF v{}: {} tensors, {} metadata entries\n", .{
            header.version,
            header.tensor_count,
            header.metadata_kv_count,
        });
    }
}
```

### Working with Slices

```zig
var mapped = try zenmap.MappedFile.init("data.bin");
defer mapped.deinit();

// Get a sub-slice
if (mapped.subslice(0, 1024)) |header| {
    // Process first 1KB
}

// Read at specific offset
if (mapped.readAt(4096, 256)) |chunk| {
    // Process 256 bytes starting at offset 4096
}
```

## API Reference

### `MappedFile`

The main struct for memory-mapped file access.

| Method | Description |
|--------|-------------|
| `init(path: []const u8)` | Memory-map a file for reading |
| `initZ(path: [*:0]const u8)` | Initialize from null-terminated path (C interop) |
| `deinit()` | Unmap file and release resources |
| `slice()` | Get a slice of the entire mapped memory |
| `len()` | Get the file size in bytes |
| `isEmpty()` | Check if file is empty |
| `subslice(start, end)` | Get a sub-slice, returns null if out of bounds |
| `readAt(offset, count)` | Read bytes at offset, returns null if out of bounds |

### `GgufHeader`

Parser for GGUF model file headers.

| Field | Type | Description |
|-------|------|-------------|
| `magic` | `u32` | Magic number (0x46554747 = "GGUF") |
| `version` | `u32` | Format version |
| `tensor_count` | `u64` | Number of tensors |
| `metadata_kv_count` | `u64` | Number of metadata key-value pairs |

| Method | Description |
|--------|-------------|
| `parse(data: []const u8)` | Parse header from bytes, returns null if invalid |
| `isValid()` | Check if header has valid magic and version |
| `magicString()` | Get magic as a 4-character string |

### Utility Functions

| Function | Description |
|----------|-------------|
| `pageSize()` | Get system page size |
| `isGgufFile(path)` | Check if file is a GGUF file |
| `createTestFile(path, size_mb)` | Create test file with pattern |
| `createFakeGguf(path, size_mb, tensors, metadata)` | Create fake GGUF for testing |

### Error Types

```zig
pub const MmapError = error{
    FileOpenFailed,           // File doesn't exist or permission denied
    StatFailed,               // Could not get file metadata
    EmptyFile,                // File is empty (zero bytes)
    MmapFailed,               // POSIX mmap() failed
    MunmapFailed,             // POSIX munmap() failed
    WindowsCreateFileFailed,  // Windows CreateFile failed
    WindowsGetFileSizeFailed, // Windows GetFileSizeEx failed
    WindowsCreateSectionFailed, // Windows NtCreateSection failed
    WindowsMapViewFailed,     // Windows NtMapViewOfSection failed
    InvalidPath,              // Path is invalid or too long
};
```

## Platform Support

| Platform | Implementation |
|----------|---------------|
| Linux | `mmap()` via `std.posix` |
| macOS | `mmap()` via `std.posix` |
| FreeBSD | `mmap()` via `std.posix` |
| NetBSD | `mmap()` via `std.posix` |
| OpenBSD | `mmap()` via `std.posix` |
| DragonflyBSD | `mmap()` via `std.posix` |
| Windows | `NtCreateSection` + `NtMapViewOfSection` via ntdll |

## Building

```bash
# Build the demo executable
zig build

# Run the demo
zig build run

# Run all tests
zig build test

# Cross-compile for all platforms
zig build cross

# Quick compilation check
zig build check
```

## Example Output

```
=== zenmap Demo (Zig 0.15) ===

Platform: linux-x86_64
Page size: 4096 bytes

Creating 10 MB test file: zenmap_demo_test.bin
Creating fake GGUF file: zenmap_demo_model.gguf

--- Test 1: Basic Memory Mapping ---
Successfully mapped 10485760 bytes
Verified 1024/1024 bytes match expected pattern

--- Test 2: Slice Operations ---
First 16 bytes: 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 
4 bytes at offset 256: 00 01 02 03 

--- Test 3: GGUF Header Parsing ---
File 'zenmap_demo_model.gguf' is a valid GGUF file
GGUF Header:
  Magic: 0x46554747 ('GGUF')
  Version: 3
  Tensor count: 42
  Metadata KV count: 10
  Valid: true

--- Test 4: Sequential Read Performance ---
Read 10485760 bytes in 5.23 ms
Throughput: 1912.45 MB/s
Checksum: 0x000000007F800000

--- Test 5: Error Handling ---
Expected error for nonexistent file: error.FileOpenFailed

--- Cleanup ---
Test files removed.

=== Demo Complete ===
```

## Use Cases

### Loading Large Language Models

```zig
const zenmap = @import("zenmap");

pub const Model = struct {
    mmap: zenmap.MappedFile,
    header: zenmap.GgufHeader,
    
    pub fn load(path: []const u8) !Model {
        var mmap = try zenmap.MappedFile.init(path);
        errdefer mmap.deinit();
        
        const header = zenmap.GgufHeader.parse(mmap.slice()) orelse {
            mmap.deinit();
            return error.InvalidGgufHeader;
        };
        
        return .{ .mmap = mmap, .header = header };
    }
    
    pub fn deinit(self: *Model) void {
        self.mmap.deinit();
    }
    
    pub fn getTensorData(self: *const Model, offset: usize, size: usize) ?[]const u8 {
        return self.mmap.readAt(offset, size);
    }
};
```

### Memory-Efficient File Processing

```zig
// Process a large file without loading it entirely into memory
var mapped = try zenmap.MappedFile.init("huge_dataset.bin");
defer mapped.deinit();

const data = mapped.slice();

// The OS will page in data as needed
var checksum: u64 = 0;
for (data) |byte| {
    checksum +%= byte;
}
```

## Performance Considerations

- **Sequential access**: The OS automatically prefetches pages for sequential reads
- **Random access**: May cause more page faults; access patterns can help here, need to investigate
- **Large files**: Memory mapping is ideal as the OS handles virtual memory
- **Small files**: Standard file I/O may be faster due to mmap overhead

## Why Memory Mapping?

1. **Zero-copy access**: The OS pages data directly from disk to memory as needed
2. **Efficient for large files**: Only pages actually accessed are loaded
3. **Simple API**: Just use the mapped slice like any other memory
4. **Kernel-managed caching**: The OS handles all the caching complexity
5. **Shared memory**: Multiple processes can share the same physical pages

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Inspired by the need for efficient large file access in LLM inference
- Built with Zig 0.15+'s new IO interface and its APIs.
- GGUF format specification from [llama.cpp](https://github.com/ggerganov/llama.cpp)
