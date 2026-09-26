//! readme_examples: holds the Zig code the README and the guide show to the programs that `zig
//! build test` builds and runs. Every ```zig block of `README.md` and `docs/using.md` must be an
//! excerpt of one of the files under `examples/`: each of its lines, blank lines aside, is a line of
//! that file, word for word and in the same order. Indentation is not compared, because a block that
//! shows two lines of a function shows them without the function around them. A block may leave
//! lines out, such as comments, and it may not add one. So a page can shorten a program that works, and cannot show code that
//! no longer compiles or no longer matches what runs.
//!
//! The build hands each file in as an anonymous import, so a change to any of them reruns the test.
const std = @import("std");

const Document = struct { name: []const u8, text: []const u8 };

const documents = [_]Document{
    .{ .name = "README.md", .text = @embedFile("README.md") },
    .{ .name = "docs/using.md", .text = @embedFile("docs/using.md") },
};

const examples = [_]Document{
    .{ .name = "examples/echo.zig", .text = @embedFile("examples/echo.zig") },
    .{ .name = "examples/guide.zig", .text = @embedFile("examples/guide.zig") },
    .{ .name = "examples/consumer/build.zig", .text = @embedFile("examples/consumer/build.zig") },
};

const fence_open = "```zig";
const fence_close = "```";

/// True when every non-blank line of `block` is a line of `program`, in the same order, once the
/// spaces around each line are set aside.
fn is_excerpt(block: []const u8, program: []const u8) bool {
    var lines = std.mem.splitScalar(u8, program, '\n');
    var wanted = std.mem.splitScalar(u8, block, '\n');
    next_wanted: while (wanted.next()) |line| {
        const text = std.mem.trim(u8, line, " ");
        if (text.len == 0) continue;
        while (lines.next()) |candidate| {
            if (std.mem.eql(u8, std.mem.trim(u8, candidate, " "), text)) continue :next_wanted;
        }
        return false;
    }
    return true;
}

/// The name of the example `block` is an excerpt of, or null when it is an excerpt of none.
fn source_of(block: []const u8) ?[]const u8 {
    for (examples) |example| {
        if (is_excerpt(block, example.text)) return example.name;
    }
    return null;
}

/// Where the block that starts at `text` ends: the offset of the newline before its closing fence.
fn closing_fence(text: []const u8) ?usize {
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " "), fence_close)) return offset -| 1;
        offset += line.len + 1;
    }
    return null;
}

/// Checks every Zig block of `document`, and returns how many it checked.
fn check_document(document: Document) !u32 {
    var checked: u32 = 0;
    var rest = document.text;
    while (std.mem.indexOf(u8, rest, fence_open ++ "\n")) |open| {
        const start = open + fence_open.len + 1;
        // The closing fence is the first line that holds nothing else, whatever its indentation:
        // a block inside a list item is indented with it.
        const length = closing_fence(rest[start..]) orelse return error.UnclosedBlock;
        const block = rest[start .. start + length];
        if (source_of(block) == null) {
            std.debug.print("{s}: this block is not an excerpt of any file under examples/:\n{s}\n", .{
                document.name, block,
            });
            return error.BlockMatchesNoExample;
        }
        checked += 1;
        rest = rest[start + length ..];
    }
    return checked;
}

test "every Zig block of the README and the guide is an excerpt of an example that builds and runs" {
    for (documents) |document| {
        const checked = try check_document(document);
        // A document that lost all its blocks, or a fence this test no longer finds, checks
        // nothing and would pass; each of these documents has code to check.
        try std.testing.expect(checked >= 2);
    }
}

test "an excerpt keeps the order of its lines and adds none" {
    const program = "a\nb\nc\nd\n";
    try std.testing.expect(is_excerpt("a\n\nc", program));
    try std.testing.expect(is_excerpt("b\nd", program));
    try std.testing.expect(!is_excerpt("c\na", program));
    try std.testing.expect(!is_excerpt("a\ne", program));
    // A line must match whole: a prefix of a line is not that line.
    try std.testing.expect(!is_excerpt("a\nx", "a\nxy\n"));
    // Indentation is set aside.
    try std.testing.expect(is_excerpt("  b\nc", "a\n    b\n c\n"));
}
