//! The parsers of the Linux text files `Machine.collect` reads: /proc/cpuinfo, /proc/meminfo and
//! /etc/os-release. Each parser takes one line at a time and never holds the file: /proc/cpuinfo
//! grows with the core count, and `feed_lines` reads it through a buffer of one line. The parsers
//! name no file and no operating system, so their tests run on every host against the fixture
//! text at the end of this file.
const std = @import("std");
const assert = std.debug.assert;
const text_module = @import("text.zig");
const Text = text_module.Text;

/// The most lines `feed_lines` reads from one file: 2^17. An x86-64 /proc/cpuinfo holds about 28
/// lines per logical processor (recalled), so this covers more than 4,096 of them.
pub const lines_max: u32 = 131_072;

/// The most bytes of one line `Machine.collect` buffers. `feed_lines` skips a longer line: the
/// only long lines in these files list CPU feature flags, which no parser reads.
pub const line_bytes_max = 4096;

/// The most sockets `CpuInfo` tells apart: one bit each of a `u64`.
const sockets_max: u32 = 64;

/// /proc/meminfo counts in units it spells `kB`, which are 1,024 bytes.
const meminfo_unit = "kB";
const meminfo_unit_bytes: u64 = 1024;

/// The blanks around a key and a value.
const blank = " \t\r";

/// The words `CpuInfo.model_name` puts around the implementer and the part.
const model_name_format = "CPU implementer {s} part {s}";

/// The bytes `CpuInfo.model_name` formats into: its fixed words and two texts of the largest size.
const model_name_bytes_max =
    model_name_format.len + text_module.text_bytes_max + text_module.text_bytes_max;

pub const Field = struct { key: []const u8, value: []const u8 };

/// Splits `line` at its first `separator` into a key and a value, both without the blanks around
/// them. A line without the separator is not a field.
pub fn split_field(line: []const u8, separator: u8) ?Field {
    const at = std.mem.indexOfScalar(u8, line, separator) orelse return null;
    assert(at < line.len);
    return .{
        .key = std.mem.trim(u8, line[0..at], blank),
        .value = std.mem.trim(u8, line[at + 1 ..], blank),
    };
}

/// The radix these files spell every count in.
const decimal = 10;

/// A number as a file spells it, in decimal, or null when the text is anything else.
fn parse_decimal(comptime Integer: type, value: []const u8) ?Integer {
    return std.fmt.parseInt(Integer, value, decimal) catch null;
}

/// A count as a file spells it, or 0, which every record reads as "not reported".
pub fn parse_count(value: []const u8) u32 {
    return parse_decimal(u32, std.mem.trim(u8, value, blank ++ "\n")) orelse 0;
}

/// What /proc/cpuinfo says, gathered over every processor's block.
pub const CpuInfo = struct {
    model: Text = .{},
    implementer: Text = .{},
    part: Text = .{},
    /// Blocks seen: one per logical processor.
    logical: u32 = 0,
    /// `cpu cores`: the physical cores of one socket. x86-64 reports it; aarch64 does not.
    cores_per_socket: u32 = 0,
    /// `cache_alignment`: the cache line in bytes. x86-64 reports it; aarch64 does not.
    cache_line_bytes: u32 = 0,
    /// One bit per `physical id` seen.
    sockets: u64 = 0,

    /// The keys read, spelled as the kernel spells them. `model` and `siblings` are not among
    /// them: `model` is a number beside `model name`, and `siblings` counts hardware threads.
    const Key = enum {
        processor,
        @"model name",
        @"physical id",
        @"cpu cores",
        cache_alignment,
        @"CPU implementer",
        @"CPU part",
    };

    pub fn feed(info: *CpuInfo, line: []const u8) void {
        assert(std.mem.indexOfScalar(u8, line, '\n') == null);
        const field = split_field(line, ':') orelse return;
        const key = std.meta.stringToEnum(Key, field.key) orelse return;
        switch (key) {
            .processor => info.logical += 1,
            .@"model name" => info.model.set_once(field.value),
            .@"physical id" => info.see_socket(field.value),
            .@"cpu cores" => info.cores_per_socket = parse_count(field.value),
            .cache_alignment => info.cache_line_bytes = parse_count(field.value),
            .@"CPU implementer" => info.implementer.set_once(field.value),
            .@"CPU part" => info.part.set_once(field.value),
        }
    }

    fn see_socket(info: *CpuInfo, value: []const u8) void {
        const socket = parse_decimal(u32, value) orelse return;
        if (socket >= sockets_max) return;
        info.sockets |= @as(u64, 1) << @intCast(socket);
        assert(info.sockets != 0);
    }

    /// Physical cores: sockets times the cores of one socket. 0 when the file names neither, as
    /// on aarch64, where the record then reports logical processors alone.
    pub fn cores_physical(info: *const CpuInfo) u32 {
        const sockets: u32 = @popCount(info.sockets);
        assert(sockets <= sockets_max);
        return sockets * info.cores_per_socket;
    }

    /// The CPU's name: the first `model name` line, which x86-64 has. An aarch64 file has none,
    /// so the name is the implementer and part numbers of the first processor, which identify
    /// the core design; a machine with two core designs is named after the first.
    pub fn model_name(info: *const CpuInfo) Text {
        if (info.model.len > 0 or info.part.len == 0) return info.model;
        var buffer: [model_name_bytes_max]u8 = undefined;
        const name = std.fmt.bufPrint(&buffer, model_name_format, .{
            info.implementer.slice(), info.part.slice(),
        }) catch unreachable; // The buffer holds the fixed words and two full texts.
        return Text.from(name);
    }
};

/// What /proc/meminfo says: `MemTotal`, the memory the kernel manages, in bytes.
pub const MemInfo = struct {
    total_bytes: u64 = 0,

    pub fn feed(info: *MemInfo, line: []const u8) void {
        assert(std.mem.indexOfScalar(u8, line, '\n') == null);
        const field = split_field(line, ':') orelse return;
        if (!std.mem.eql(u8, field.key, "MemTotal")) return;
        var tokens = std.mem.tokenizeAny(u8, field.value, blank);
        const amount = parse_decimal(u64, tokens.next() orelse return) orelse return;
        const unit = tokens.next() orelse return;
        if (!std.mem.eql(u8, unit, meminfo_unit)) return;
        info.total_bytes = std.math.mul(u64, amount, meminfo_unit_bytes) catch return;
        assert(info.total_bytes >= amount);
    }
};

/// What /etc/os-release says: the distribution's `NAME` and `VERSION_ID`. A distribution with no
/// `VERSION_ID`, a rolling one for example, leaves the version empty.
pub const OsRelease = struct {
    name: Text = .{},
    version: Text = .{},

    pub fn feed(release: *OsRelease, line: []const u8) void {
        assert(std.mem.indexOfScalar(u8, line, '\n') == null);
        const field = split_field(line, '=') orelse return;
        const value = std.mem.trim(u8, field.value, "\"'");
        if (std.mem.eql(u8, field.key, "NAME")) release.name.set(value);
        if (std.mem.eql(u8, field.key, "VERSION_ID")) release.version.set(value);
    }
};

/// Hands `parser.feed` each line of `reader`, at most `lines_max` of them. It skips a line longer
/// than the reader's buffer and stops at the first read error: what was parsed until then stands,
/// and every field still empty reads as "not reported". The reader's buffer must hold the longest
/// line a parser needs: `line_bytes_max` does for the files read here.
pub fn feed_lines(reader: *std.Io.Reader, parser: anytype) void {
    for (0..lines_max) |_| {
        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return,
            error.StreamTooLong => {
                _ = reader.discardDelimiterInclusive('\n') catch return;
                continue;
            },
        };
        parser.feed(line orelse return);
    }
}

const testing = std.testing;

/// Backward branches the comptime evaluation of one fixture may take.
const fixture_branch_quota = 100_000;

/// A Zig string literal may not hold a tab byte, so the fixtures spell a tab as `^I`, the way
/// `cat -A` prints one. This puts the tabs back.
fn with_tabs(comptime text: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(fixture_branch_quota);
        var bytes: [std.mem.replacementSize(u8, text, "^I", "\t")]u8 = undefined;
        _ = std.mem.replace(u8, text, "^I", "\t", &bytes);
        const result = bytes;
        return &result;
    }
}

/// Two sockets of /proc/cpuinfo on x86-64, two hardware threads of each. Written to the format of
/// the kernel's arch/x86/kernel/cpu/proc.c as recalled, not captured from a machine: the harness
/// has no x86-64 machine yet (docs/costs.md, Machines). The `flags` line is cut short.
const cpuinfo_x86_64 = with_tabs(x86_64_block("0", "0", "0") ++ x86_64_block("1", "0", "1") ++
    x86_64_block("64", "1", "0") ++ x86_64_block("65", "1", "1"));

fn x86_64_block(
    comptime processor: []const u8,
    comptime socket: []const u8,
    comptime core: []const u8,
) []const u8 {
    return "processor^I: " ++ processor ++ "\n" ++
        \\vendor_id^I: AuthenticAMD
        \\cpu family^I: 25
        \\model^I^I: 17
        \\model name^I: AMD EPYC 9354 32-Core Processor
        \\stepping^I: 1
        \\cpu MHz^I^I: 3249.998
        \\cache size^I: 1024 KB
        \\
    ++ "physical id^I: " ++ socket ++ "\nsiblings^I: 64\ncore id^I^I: " ++ core ++ "\n" ++
        \\cpu cores^I: 32
        \\fpu^I^I: yes
        \\flags^I^I: fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat
        \\bogomips^I: 6499.99
        \\TLB size^I: 3584 4K pages
        \\clflush size^I: 64
        \\cache_alignment^I: 64
        \\address sizes^I: 52 bits physical, 57 bits virtual
        \\power management: ts ttp tm hwpstate cpb eff_freq_ro [13] [14]
        \\
        \\
    ;
}

/// The first two processors of /proc/cpuinfo on aarch64, captured with `cat -A` on 2026-09-19 from
/// the Linux virtual machine Docker runs on `mac`. It has no `model name`, no `physical id` and no
/// `cache_alignment`, and its `Features` line is 187 bytes long.
const cpuinfo_aarch64 = with_tabs(aarch64_block("0") ++ aarch64_block("1"));

const aarch64_features = "Features^I: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp" ++
    " asimdhp cpuid asimdrdm jscvt fcma lrcpc dcpop sha3 asimddp sha512 asimdfhm dit uscat" ++
    " ilrcpc flagm sb dcpodp flagm2 frint\n";

fn aarch64_block(comptime processor: []const u8) []const u8 {
    return "processor^I: " ++ processor ++ "\n" ++
        \\BogoMIPS^I: 48.00
        \\
    ++ aarch64_features ++
        \\CPU implementer^I: 0x61
        \\CPU architecture: 8
        \\CPU variant^I: 0x0
        \\CPU part^I: 0x000
        \\CPU revision^I: 0
        \\
        \\
    ;
}

/// The head of /proc/meminfo, from the same capture.
const meminfo =
    \\MemTotal:       16425400 kB
    \\MemFree:        15142160 kB
    \\MemAvailable:   15363724 kB
    \\Buffers:             156 kB
    \\
;

/// /etc/os-release of Alpine Linux, from the same capture: one value quoted and one bare.
const os_release =
    \\NAME="Alpine Linux"
    \\ID=alpine
    \\VERSION_ID=3.24.1
    \\PRETTY_NAME="Alpine Linux v3.24"
    \\
;

fn feed_text(parser: anytype, text: []const u8) void {
    var reader: std.Io.Reader = .fixed(text);
    feed_lines(&reader, parser);
}

test "cpuinfo of x86-64: the model name, the logical processors, the cores and the cache line" {
    var info: CpuInfo = .{};
    feed_text(&info, cpuinfo_x86_64);
    try testing.expectEqualStrings("AMD EPYC 9354 32-Core Processor", info.model_name().slice());
    try testing.expectEqual(@as(u32, 4), info.logical);
    try testing.expectEqual(@as(u64, 0b11), info.sockets);
    try testing.expectEqual(@as(u32, 32), info.cores_per_socket);
    // Two sockets of 32 cores. `siblings`, 64, would make 128.
    try testing.expectEqual(@as(u32, 64), info.cores_physical());
    try testing.expectEqual(@as(u32, 64), info.cache_line_bytes);
}

test "cpuinfo of aarch64: a name from the implementer and the part, and no physical count" {
    var info: CpuInfo = .{};
    feed_text(&info, cpuinfo_aarch64);
    try testing.expectEqualStrings("CPU implementer 0x61 part 0x000", info.model_name().slice());
    try testing.expectEqual(@as(u32, 2), info.logical);
    try testing.expectEqual(@as(u32, 0), info.cores_physical());
    try testing.expectEqual(@as(u32, 0), info.cache_line_bytes);
    try testing.expectEqualStrings("", info.model.slice());
}

test "cpuinfo ignores what it cannot read: a bad count, a far socket, a line with no colon" {
    var info: CpuInfo = .{};
    feed_text(&info, "cpu cores : many\nphysical id : 64\nphysical id : x\nno colon here\n");
    try testing.expectEqual(@as(u32, 0), info.cores_per_socket);
    try testing.expectEqual(@as(u64, 0), info.sockets);
    try testing.expectEqual(@as(u32, 0), info.logical);
    try testing.expectEqualStrings("", info.model_name().slice());
    info.feed("physical id\t: 63");
    try testing.expectEqual(@as(u64, 1) << 63, info.sockets);
}

test "meminfo reads MemTotal in bytes and nothing else" {
    var info: MemInfo = .{};
    feed_text(&info, meminfo);
    try testing.expectEqual(@as(u64, 16_425_400 * 1024), info.total_bytes);

    var other: MemInfo = .{};
    feed_text(&other, "MemFree: 15142160 kB\nMemTotal: 5 MB\nMemTotal: lots kB\nMemTotal:\n");
    try testing.expectEqual(@as(u64, 0), other.total_bytes);
}

test "os-release reads NAME and VERSION_ID, quoted or bare" {
    var release: OsRelease = .{};
    feed_text(&release, os_release);
    try testing.expectEqualStrings("Alpine Linux", release.name.slice());
    try testing.expectEqualStrings("3.24.1", release.version.slice());

    var quoted: OsRelease = .{};
    feed_text(&quoted, "PRETTY_NAME=\"Ubuntu 24.04.1 LTS\"\nNAME=\"Ubuntu\"\nVERSION_ID=\"24.04\"");
    try testing.expectEqualStrings("Ubuntu", quoted.name.slice());
    try testing.expectEqualStrings("24.04", quoted.version.slice());
}

test "split_field splits at the first separator and trims both sides" {
    const field = split_field("address sizes\t: 52 bits: physical ", ':').?;
    try testing.expectEqualStrings("address sizes", field.key);
    try testing.expectEqualStrings("52 bits: physical", field.value);
    try testing.expectEqual(@as(?Field, null), split_field("no separator", ':'));
    try testing.expectEqualStrings("", split_field("key:", ':').?.value);
}

test "feed_lines skips a line longer than its buffer and reads the lines after it" {
    // 96 bytes hold every line of the capture but `Features`, which is 187 bytes long.
    try testing.expectEqual(187, comptime with_tabs(aarch64_features).len - 1);
    var buffer: [96]u8 = undefined;
    var source = std.testing.Reader.init(&buffer, &.{.{ .buffer = cpuinfo_aarch64 }});
    var info: CpuInfo = .{};
    feed_lines(&source.interface, &info);
    try testing.expectEqual(@as(u32, 2), info.logical);
    try testing.expectEqualStrings("0x61", info.implementer.slice());
    try testing.expectEqualStrings("0x000", info.part.slice());
}
