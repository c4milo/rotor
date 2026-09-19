//! `Machine`, the record of the machine a run was made on. A number without its machine is not
//! evidence (docs/costs.md, Machines), so the harness prints this record beside every result.
//!
//! `collect` fills the record from the operating system: `sysctlbyname` on macOS, and `uname`,
//! /proc/cpuinfo, /proc/meminfo and /etc/os-release on Linux, whose text machine_proc.zig parses.
//! Every string sits in a fixed buffer inside the struct. A field the operating system did not
//! report stays empty or 0 and prints as `unknown`: the record never guesses.
//!
//! `render_markdown` prints a row of the Machines table of docs/costs.md. That table also names
//! what no operating system call reports, such as the role of the machine, so the caller passes
//! those cells in as `Labels`. `render_json_line` prints the whole record, the Zig version and the
//! optimize mode included, as the line that precedes a run's results in a results file.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const text = @import("text.zig");
const proc = @import("machine_proc.zig");
const Text = text.Text;

/// What a renderer prints for a field the operating system did not report.
const unknown = "unknown";

/// 2^20 and 2^30: the units the memory cell prints in.
const bytes_per_mib: u64 = 1_048_576;
const bytes_per_gib: u64 = 1_073_741_824;

/// The bytes `sysctl_text` reads into: more than any name or version this file asks for, which
/// `Text.set` then cuts to its own limit.
const sysctl_bytes_max = 256;

/// `hw.nperflevels` of a machine with performance and efficiency cores: Apple silicon.
const perflevels_two: u64 = 2;

/// Where Linux reports the cache line of CPU 0's first cache, in bytes, on every architecture
/// that fills in its cache information. aarch64 needs it: its /proc/cpuinfo has no such line.
const coherency_path = "/sys/devices/system/cpu/cpu0/cache/index0/coherency_line_size";

/// The header of the Machines table of docs/costs.md, which `render_markdown` prints rows of.
pub const markdown_header =
    "| id | role | CPU | cores | memory | OS and kernel | storage | filled |\n" ++
    "|---|---|---|---|---|---|---|---|\n";

/// The cells of a Machines row that no operating system call reports.
pub const Labels = struct {
    /// The id design arguments cite the machine by: `mac`, `linux`.
    id: []const u8,
    role: []const u8,
    storage: []const u8,
    /// The date the row was filled. The caller supplies it: the record reads no clock.
    filled: []const u8,
};

pub const Machine = struct {
    cpu_model: Text = .{},
    os_name: Text = .{},
    os_version: Text = .{},
    kernel_name: Text = .{},
    kernel_version: Text = .{},
    /// The Zig version and the optimize mode the harness was built with: a Debug number describes
    /// nothing a consumer runs (build/bench.zig), so a result says which one it is.
    zig_version: Text = .{},
    memory_bytes: u64 = 0,
    cores_physical: u32 = 0,
    cores_logical: u32 = 0,
    /// Performance and efficiency cores, where the operating system tells them apart.
    cores_performance: u32 = 0,
    cores_efficiency: u32 = 0,
    cache_line_bytes: u32 = 0,
    optimize_mode: std.builtin.OptimizeMode = .Debug,

    /// Reads the machine this process runs on. It cannot fail: what the operating system does
    /// not report stays empty. `io` reads the Linux text files; macOS needs no file.
    pub fn collect(io: std.Io) Machine {
        var machine: Machine = .{ .optimize_mode = builtin.mode };
        machine.zig_version.set(builtin.zig_version_string);
        switch (builtin.os.tag) {
            .macos => collect_macos(&machine),
            .linux => collect_linux(&machine, io),
            else => {},
        }
        assert(machine.zig_version.len > 0);
        return machine;
    }

    /// One row of the Machines table of docs/costs.md, under `markdown_header`.
    pub fn render_markdown(
        machine: *const Machine,
        writer: *Writer,
        labels: Labels,
    ) Writer.Error!void {
        // Design arguments cite a machine by its id, so a row without one names nothing.
        assert(labels.id.len >= 1);
        try writer.writeAll("| `");
        try text.markdown_cell(writer, labels.id);
        try writer.writeAll("` | ");
        try text.markdown_cell(writer, labels.role);
        try writer.writeAll(" | ");
        try machine.write_cpu(writer);
        try writer.writeAll(" | ");
        try machine.write_cores(writer);
        try writer.writeAll(" | ");
        try machine.write_memory(writer);
        try writer.writeAll(" | ");
        try write_pair(writer, machine.os_name.slice(), machine.os_version.slice());
        try writer.writeAll(", ");
        try write_pair(writer, machine.kernel_name.slice(), machine.kernel_version.slice());
        try writer.writeAll(" | ");
        try text.markdown_cell(writer, labels.storage);
        try writer.writeAll(" | ");
        try text.markdown_cell(writer, labels.filled);
        try writer.writeAll(" |\n");
    }

    fn write_cpu(machine: *const Machine, writer: *Writer) Writer.Error!void {
        try write_pair(writer, machine.cpu_model.slice(), "");
        if (machine.cache_line_bytes == 0) return;
        try writer.print(", {d}-byte cache line", .{machine.cache_line_bytes});
    }

    /// The most specific count the operating system gave: performance and efficiency cores,
    /// else physical and logical, else logical alone.
    fn write_cores(machine: *const Machine, writer: *Writer) Writer.Error!void {
        if (machine.cores_performance != 0 and machine.cores_efficiency != 0) {
            return writer.print("{d} performance, {d} efficiency", .{
                machine.cores_performance, machine.cores_efficiency,
            });
        }
        if (machine.cores_physical != 0) {
            return writer.print("{d} physical, {d} logical", .{
                machine.cores_physical, machine.cores_logical,
            });
        }
        if (machine.cores_logical == 0) return writer.writeAll(unknown);
        try writer.print("{d} logical", .{machine.cores_logical});
    }

    /// Whole GiB when the memory is that, as macOS reports it; else whole MiB rounded down, as
    /// Linux's `MemTotal`, which leaves out what the kernel reserved, needs.
    fn write_memory(machine: *const Machine, writer: *Writer) Writer.Error!void {
        const bytes = machine.memory_bytes;
        if (bytes == 0) return writer.writeAll(unknown);
        if (bytes % bytes_per_gib == 0) return writer.print("{d} GiB", .{bytes / bytes_per_gib});
        try writer.print("{d} MiB", .{bytes / bytes_per_mib});
    }

    /// The whole record as one JSON object on one line, under the id its results cite.
    pub fn render_json_line(
        machine: *const Machine,
        writer: *Writer,
        id: []const u8,
    ) Writer.Error!void {
        assert(id.len >= 1);
        try writer.writeAll("{\"machine\":");
        try text.json_string(writer, id);
        try json_text(writer, "cpu_model", &machine.cpu_model);
        try writer.print(",\"cores_physical\":{d},\"cores_logical\":{d}", .{
            machine.cores_physical, machine.cores_logical,
        });
        try writer.print(",\"cores_performance\":{d},\"cores_efficiency\":{d}", .{
            machine.cores_performance, machine.cores_efficiency,
        });
        try writer.print(",\"memory_bytes\":{d},\"cache_line_bytes\":{d}", .{
            machine.memory_bytes, machine.cache_line_bytes,
        });
        try json_text(writer, "os_name", &machine.os_name);
        try json_text(writer, "os_version", &machine.os_version);
        try json_text(writer, "kernel_name", &machine.kernel_name);
        try json_text(writer, "kernel_version", &machine.kernel_version);
        try json_text(writer, "zig_version", &machine.zig_version);
        try writer.print(",\"optimize_mode\":\"{t}\"}}\n", .{machine.optimize_mode});
    }
};

/// Writes `first second` as a table cell, either alone when the other is empty, and `unknown`
/// when both are.
fn write_pair(writer: *Writer, first: []const u8, second: []const u8) Writer.Error!void {
    if (first.len == 0 and second.len == 0) return writer.writeAll(unknown);
    try text.markdown_cell(writer, first);
    if (first.len != 0 and second.len != 0) try writer.writeByte(' ');
    try text.markdown_cell(writer, second);
}

fn json_text(writer: *Writer, comptime key: []const u8, value: *const Text) Writer.Error!void {
    try writer.writeAll(",\"" ++ key ++ "\":");
    try text.json_string(writer, value.slice());
}

fn collect_macos(machine: *Machine) void {
    machine.os_name.set("macOS");
    sysctl_text("kern.osproductversion", &machine.os_version);
    sysctl_text("kern.ostype", &machine.kernel_name);
    sysctl_text("kern.osrelease", &machine.kernel_version);
    sysctl_text("machdep.cpu.brand_string", &machine.cpu_model);
    machine.memory_bytes = sysctl_integer("hw.memsize");
    machine.cores_physical = sysctl_count("hw.physicalcpu");
    machine.cores_logical = sysctl_count("hw.logicalcpu");
    machine.cache_line_bytes = sysctl_count("hw.cachelinesize");
    // Level 0 is the fastest kind of core and level 1 the other kind, where there are two.
    if (sysctl_integer("hw.nperflevels") != perflevels_two) return;
    machine.cores_performance = sysctl_count("hw.perflevel0.physicalcpu");
    machine.cores_efficiency = sysctl_count("hw.perflevel1.physicalcpu");
}

/// One integer sysctl, which macOS stores in 4 or in 8 bytes, or 0 when it has no such name.
fn sysctl_integer(name: [*:0]const u8) u64 {
    // A 4-byte answer fills the low half of `value`, which is its value on a little-endian CPU.
    comptime assert(builtin.cpu.arch.endian() == .little);
    var value: u64 = 0;
    var value_bytes: usize = @sizeOf(u64);
    if (std.c.sysctlbyname(name, &value, &value_bytes, null, 0) != 0) return 0;
    if (value_bytes != @sizeOf(u32) and value_bytes != @sizeOf(u64)) return 0;
    return value;
}

fn sysctl_count(name: [*:0]const u8) u32 {
    return std.math.cast(u32, sysctl_integer(name)) orelse 0;
}

fn sysctl_text(name: [*:0]const u8, value: *Text) void {
    var buffer: [sysctl_bytes_max]u8 = undefined;
    var buffer_bytes: usize = buffer.len;
    if (std.c.sysctlbyname(name, &buffer, &buffer_bytes, null, 0) != 0) return;
    assert(buffer_bytes <= buffer.len);
    value.set(std.mem.sliceTo(buffer[0..buffer_bytes], 0));
}

fn collect_linux(machine: *Machine, io: std.Io) void {
    const uts = std.posix.uname();
    machine.kernel_name.set(std.mem.sliceTo(&uts.sysname, 0));
    machine.kernel_version.set(std.mem.sliceTo(&uts.release, 0));

    var cpu: proc.CpuInfo = .{};
    feed_file(io, "/proc/cpuinfo", &cpu);
    machine.cpu_model = cpu.model_name();
    machine.cores_logical = cpu.logical;
    machine.cores_physical = cpu.cores_physical();
    machine.cache_line_bytes = cpu.cache_line_bytes;
    if (machine.cache_line_bytes == 0) machine.cache_line_bytes = read_count(io, coherency_path);

    var memory: proc.MemInfo = .{};
    feed_file(io, "/proc/meminfo", &memory);
    machine.memory_bytes = memory.total_bytes;

    var release: proc.OsRelease = .{};
    feed_file(io, "/etc/os-release", &release);
    machine.os_name = release.name;
    machine.os_version = release.version;
    // `uname` cannot fail, so a Linux record always names its kernel.
    assert(machine.kernel_name.len > 0);
}

/// Hands `parser.feed` each line of the file at `path`. A file that does not open feeds nothing.
fn feed_file(io: std.Io, path: []const u8, parser: anytype) void {
    assert(path.len >= 1);
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);
    var buffer: [proc.line_bytes_max]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    proc.feed_lines(&reader.interface, parser);
}

/// The one count a small file holds, or 0 when the file does not open or holds something else.
fn read_count(io: std.Io, path: []const u8) u32 {
    assert(path.len >= 1);
    var buffer: [text.text_bytes_max]u8 = undefined;
    const content = std.Io.Dir.cwd().readFile(io, path, &buffer) catch return 0;
    assert(content.len <= buffer.len);
    return proc.parse_count(content);
}

const testing = std.testing;

/// The numbers of the `mac` row of docs/costs.md, as `collect` reads them on that machine.
const mac_memory_gib = 32;
const mac_cores = 10;
const mac_cores_performance = 8;
const mac_cores_efficiency = 2;
const mac_cache_line_bytes = 128;

const mac: Machine = .{
    .cpu_model = Text.from("Apple M1 Pro"),
    .os_name = Text.from("macOS"),
    .os_version = Text.from("26.6.2"),
    .kernel_name = Text.from("Darwin"),
    .kernel_version = Text.from("25.6.0"),
    .zig_version = Text.from("0.16.0"),
    .memory_bytes = mac_memory_gib * bytes_per_gib,
    .cores_physical = mac_cores,
    .cores_logical = mac_cores,
    .cores_performance = mac_cores_performance,
    .cores_efficiency = mac_cores_efficiency,
    .cache_line_bytes = mac_cache_line_bytes,
    .optimize_mode = .ReleaseSafe,
};

/// Bytes that hold any one row the tests render.
const row_bytes_max = 512;

fn expect_row(expected: []const u8, machine: Machine, labels: Labels) !void {
    var buffer: [row_bytes_max]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    try machine.render_markdown(&writer, labels);
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "the header and the mac row are those of the Machines table of docs/costs.md" {
    var buffer: [512]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    try writer.writeAll(markdown_header);
    try testing.expectEqualStrings(
        \\| id | role | CPU | cores | memory | OS and kernel | storage | filled |
        \\|---|---|---|---|---|---|---|---|
        \\
    , writer.buffered());
    // docs/costs.md adds the L1d and L2 sizes to the CPU cell by hand; the rest is this text.
    try expect_row("| `mac` | development, kqueue backend | Apple M1 Pro, 128-byte cache line" ++
        " | 8 performance, 2 efficiency | 32 GiB | macOS 26.6.2, Darwin 25.6.0 | internal NVMe" ++
        " | 2026-09-19 |\n", mac, .{
        .id = "mac",
        .role = "development, kqueue backend",
        .storage = "internal NVMe",
        .filled = "2026-09-19",
    });
}

test "a row prints physical and logical cores, memory that is no whole GiB, and unknowns" {
    const labels: Labels = .{ .id = "linux", .role = "target", .storage = "NVMe", .filled = "no" };
    var server: Machine = .{
        .cpu_model = Text.from("AMD EPYC 9354 32-Core Processor"),
        .os_name = Text.from("Ubuntu"),
        .os_version = Text.from("24.04"),
        .kernel_name = Text.from("Linux"),
        .kernel_version = Text.from("6.8.0-45-generic"),
        .memory_bytes = 16_425_400 * 1024,
        .cores_physical = 64,
        .cores_logical = 128,
        .cache_line_bytes = 64,
    };
    try expect_row("| `linux` | target | AMD EPYC 9354 32-Core Processor, 64-byte cache line" ++
        " | 64 physical, 128 logical | 16040 MiB | Ubuntu 24.04, Linux 6.8.0-45-generic" ++
        " | NVMe | no |\n", server, labels);

    // No physical count, as on aarch64, and a distribution with no version.
    server.cores_physical = 0;
    server.os_version.set("");
    try expect_row("| `linux` | target | AMD EPYC 9354 32-Core Processor, 64-byte cache line" ++
        " | 128 logical | 16040 MiB | Ubuntu, Linux 6.8.0-45-generic" ++
        " | NVMe | no |\n", server, labels);

    try expect_row("| `linux` | target | unknown | unknown | unknown | unknown, unknown" ++
        " | NVMe | no |\n", .{}, labels);
}

test "a pipe in a label or in a name the machine reported cannot add a column" {
    var machine = mac;
    machine.cpu_model.set("Odd|CPU");
    try expect_row("| `a\\|b` | r | Odd\\|CPU, 128-byte cache line | 8 performance, 2 efficiency" ++
        " | 32 GiB | macOS 26.6.2, Darwin 25.6.0 | s | f |\n", machine, .{
        .id = "a|b",
        .role = "r",
        .storage = "s",
        .filled = "f",
    });
}

test "the JSON line holds every field, the Zig version and the optimize mode included" {
    var buffer: [512]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    try mac.render_json_line(&writer, "mac");
    try testing.expectEqualStrings("{\"machine\":\"mac\",\"cpu_model\":\"Apple M1 Pro\"," ++
        "\"cores_physical\":10,\"cores_logical\":10,\"cores_performance\":8," ++
        "\"cores_efficiency\":2,\"memory_bytes\":34359738368,\"cache_line_bytes\":128," ++
        "\"os_name\":\"macOS\",\"os_version\":\"26.6.2\",\"kernel_name\":\"Darwin\"," ++
        "\"kernel_version\":\"25.6.0\",\"zig_version\":\"0.16.0\"," ++
        "\"optimize_mode\":\"ReleaseSafe\"}\n", writer.buffered());

    var short: [16]u8 = undefined;
    var short_writer: Writer = .fixed(&short);
    try testing.expectError(error.WriteFailed, mac.render_json_line(&short_writer, "mac"));
}

test "collect fills every field this host reports" {
    const machine = Machine.collect(testing.io);
    try testing.expectEqualStrings(builtin.zig_version_string, machine.zig_version.slice());
    try testing.expectEqual(builtin.mode, machine.optimize_mode);
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    try testing.expect(machine.cpu_model.len > 0);
    try testing.expect(machine.os_name.len > 0);
    try testing.expect(machine.kernel_name.len > 0);
    try testing.expect(machine.kernel_version.len > 0);
    try testing.expect(machine.cores_logical >= 1);
    try testing.expect(machine.cores_physical <= machine.cores_logical);
    try testing.expect(machine.memory_bytes >= bytes_per_gib);
    // macOS and x86-64 Linux always report the cache line. Another Linux does so only when its
    // kernel fills in the cache information, and then the value is checked too.
    const must_report = builtin.os.tag == .macos or builtin.cpu.arch == .x86_64;
    if (must_report or machine.cache_line_bytes != 0) {
        try testing.expect(machine.cache_line_bytes >= 32 and machine.cache_line_bytes <= 256);
        try testing.expectEqual(1, @popCount(machine.cache_line_bytes));
    }
    const kernel = if (builtin.os.tag == .macos) "Darwin" else "Linux";
    try testing.expectEqualStrings(kernel, machine.kernel_name.slice());
}

test "collect on macOS reports the version, the physical cores and both kinds of core" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const machine = Machine.collect(testing.io);
    try testing.expectEqualStrings("macOS", machine.os_name.slice());
    try testing.expect(machine.os_version.len > 0);
    try testing.expect(machine.cores_physical >= 1);
    // Both counts or neither: an Intel Mac has one kind of core and reports no levels.
    const kinds = machine.cores_performance + machine.cores_efficiency;
    try testing.expect(kinds == 0 or kinds == machine.cores_physical);
    try testing.expectEqual(@as(u64, 0), sysctl_integer("hw.rotor_has_no_such_name"));
}

/// Counts the lines it is fed: what the tests of `feed_file` parse a file with.
const LineCounter = struct {
    lines: u32 = 0,

    pub fn feed(counter: *LineCounter, line: []const u8) void {
        _ = line;
        counter.lines += 1;
    }
};

test "feed_file reads a file's lines and feeds nothing from a file that does not open" {
    var missing: LineCounter = .{};
    feed_file(testing.io, "/rotor/has/no/such/file", &missing);
    try testing.expectEqual(@as(u32, 0), missing.lines);
    try testing.expectEqual(@as(u32, 0), read_count(testing.io, "/rotor/has/no/such/file"));

    // This source file: `zig build` runs the tests from the root of the tree.
    var source: LineCounter = .{};
    feed_file(testing.io, "bench/harness/machine.zig", &source);
    if (source.lines == 0) return error.SkipZigTest;
    try testing.expect(source.lines >= 100 and source.lines <= 500);
}
