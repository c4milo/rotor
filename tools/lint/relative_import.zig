//! relative-import: a module reaches another module by the name build/modules.zig gives it, never
//! by a path (CLAUDE.md, Layout). An `@import` that climbs out of its own module reaches past
//! the build and takes the enforced dependency direction away.
//!
//! Over every `.zig` file under `src/`, the rule resolves each `@import` path against the
//! importing file's directory and flags one that names a file outside that file's module, the
//! child of `src/` it sits in, or an absolute path. A sibling, a subdirectory, and the module's
//! root directory reached from a subdirectory are untouched.
//!
//! The rule is pepegrillo's `relative_import`. This file holds rotor's configuration of it.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const relative_import = lint.rules.relative_import;

const message_suffix = " reaches out of the module by path;" ++
    " import the module name build/modules.zig declares";

pub const config: relative_import.Config = .{
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{"src"} },
    .mode = .leaves_subsystem,
    .message = "@import(\"{[path]s}\")" ++ message_suffix,
};

const Rule = relative_import.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests.

const testing = std.testing;
const harness = lint.harness;

test "relative-import passes module names, siblings and the module root from a subdirectory" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, "src/sim/fault/fault_draw.zig",
        \\const core = @import("core");
        \\const sibling = @import("fault_class.zig");
        \\const constants = @import("../constants.zig");
    );
    try harness.expect_messages(findings, &.{});
}

test "relative-import flags a path into another module and an absolute path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, "src/sim/sim.zig",
        \\const core = @import("../core/core.zig");
        \\const pinned = @import("/Users/someone/rotor/src/core/core.zig");
    );
    try harness.expect_messages(findings, &.{
        "@import(\"../core/core.zig\")" ++ message_suffix,
        "@import(\"/Users/someone/rotor/src/core/core.zig\")" ++ message_suffix,
    });
}
