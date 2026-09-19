//! Commit-message linter for the Conventional Commit rules of CLAUDE.md (Commits). It reads commit
//! messages out of git, or one message from a file, and prints one line per finding; it changes
//! nothing.
//!
//! Run:  zig build lint-commits            # the commits this branch adds to origin/main
//!       zig-out/bin/commit_lint --range REV [REV...]
//!       zig-out/bin/commit_lint --message PATH
//!
//! The linter is pepegrillo's. This file holds rotor's configuration of it: the module scopes of
//! build/modules.zig and docs/decisions/0001-interface.md, and the first words refused as not
//! imperative. The limits are the ones CLAUDE.md states, which are pepegrillo's defaults.
//!
//! `error` marks a rule of CLAUDE.md that was broken, and `warning` a scope outside the module
//! graph, which never changes the exit status: the graph is the authority on what modules exist,
//! not this tool.
//!
//! Exit status: 0 when no rule was violated, warnings included; 1 when any rule was violated; 2 on
//! a usage error, an unreadable message file, or a git log that failed.

const std = @import("std");
const pepegrillo = @import("pepegrillo");

/// The scopes CLAUDE.md names: one per module, plus `bench` and `tools`.
pub const module_scopes = [_][]const u8{
    "core", "uring", "kqueue", "adapter", "bench", "tools",
};

/// First words that describe the commit instead of commanding it.
const third_person_forms = [_][]const u8{
    "adds",    "fixes", "updates", "removes", "implements", "splits",
    "renames", "moves", "makes",   "drops",   "lands",      "keeps",
};

/// Commands whose spelling ends in `ed` or `ing` all the same.
const imperative_exceptions = [_][]const u8{
    "bring",  "embed", "seed", "speed", "feed", "exceed", "proceed", "succeed", "shed", "ring",
    "string",
};

pub const config: pepegrillo.commit.Config = .{
    .scope_admits_digits = false,
    .known_scopes = &module_scopes,
    .unknown_scope_reason = "is not a module of the graph",
    .third_person_forms = &third_person_forms,
    .imperative_exceptions = &imperative_exceptions,
};

pub fn main(init: std.process.Init) !void {
    return pepegrillo.commit.main(init, config);
}

// Tests. pepegrillo tests the rules; these pin rotor's configuration of them.

const testing = std.testing;
const commit = pepegrillo.commit;

fn expect_findings(text: []const u8, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var findings: commit.Findings = .{ .arena = arena, .max_findings = config.max_findings };
    try commit.lint_message_text(arena, config, &findings, "message", text);
    try testing.expectEqual(expected.len, findings.items.items.len);
    for (findings.items.items, expected) |finding, wanted| {
        const line = try std.fmt.allocPrint(arena, "{s}: {s}: {s}", .{
            finding.severity.text(), finding.rule, finding.message,
        });
        try testing.expectEqualStrings(wanted, line);
    }
}

test "every scope CLAUDE.md names passes" {
    // Written out rather than read from `module_scopes`, so a scope dropped from that list fails.
    const scopes = [_][]const u8{ "core", "uring", "kqueue", "adapter", "bench", "tools" };
    try testing.expectEqual(scopes.len, module_scopes.len);
    for (scopes) |scope| {
        var buffer: [96]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "feat({s}): add the queue\n", .{scope});
        try expect_findings(text, &.{});
    }
}

test "a well-formed scope the graph does not name draws a warning" {
    try expect_findings("feat(epoll): add the submission queue\n", &.{
        "warning: scope-known: the scope \"epoll\" is not a module of the graph" ++
            " (core, uring, kqueue, adapter, bench, tools)",
    });
}

test "a third-person subject is refused" {
    try expect_findings("feat(core): adds the timer heap\n", &.{
        "violation: subject-description: \"adds\" is a third-person form, not imperative",
    });
}
