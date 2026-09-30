//! undefined-fill: a function's local array is not set to `undefined` in the library. In Debug and
//! ReleaseSafe, the only modes rotor ships, Zig writes a pattern over every `undefined` value, so
//! `var messages: [32]Message = undefined;` stores 512 bytes each time the function runs, whether
//! it uses one element or none. Two such arrays in the drains of a kqueue tick took about a
//! quarter of its own cycles until 2026-09-29 (decision 12, point 6, its amendment of that day).
//!
//! Over every Zig file in `scope`, the rule reads each `var` declared inside a function body, and
//! not one inside a `test` block or one that is a member of a container. It stops at the file's
//! `const testing = std.testing;`, where rotor's files begin their tests: a fixture or a helper
//! only tests call sits after it. It reports a `var` whose
//! declared type is an array and whose value is `undefined`, with `var <name> is an array set to
//! undefined, which ReleaseSafe fills on every call: write into the caller's memory, or declare it
//! only where it is used`. It reports none when:
//!
//! 1. The array's length is a number, not a name, of at most `literal_elements_max`: a few stores.
//! 2. `allowed` names the file and the variable: a path that runs once at init or rarely, which the
//!    configuration below says for each.
//!
//! The rule reads syntax, so it cannot tell how large an element is, and it reports every array
//! whose length is a name. rotor wrote this rule itself on pepegrillo's lint engine. A rule only
//! one project could want stays in that project, and this one may move to pepegrillo if another
//! project adopts it.
const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const Ast = std.zig.Ast;
const Node = Ast.Node;

/// A variable the rule does not report: the file it is in and its name.
pub const Allowed = struct {
    path: []const u8,
    variable: []const u8,
};

pub const Config = struct {
    /// The rule name findings are reported under and `--rule` selects.
    name: []const u8 = "undefined-fill",
    /// The files the rule reads.
    scope: lint.Scope,
    /// The most elements an array whose length is a number may have and not be reported.
    literal_elements_max: u64,
    /// The variables that run on a cold path, which the rule does not report.
    allowed: []const Allowed = &.{},
};

/// Arrays of this many elements or fewer, written as a number, cost a few stores to fill.
const literal_elements_max: u64 = 8;

pub const config: Config = .{
    .scope = .{
        .extensions = &.{lint.paths.zig_extension},
        .include_directories = &.{"src"},
        .exclude_directories = &.{"src/conformance"},
        // Helpers only tests call, named for it.
        .exclude_paths = &.{ "src/kqueue/kqueue_testing.zig", "src/linux_shared/linux_shared_testing.zig" },
        .exclude_stem_segment = "_test",
    },
    .literal_elements_max = literal_elements_max,
    .allowed = &.{
        // A changelist full before the tick's own call: the rare tick that registers more than
        // `changes_max` descriptors pays for it.
        .{ .path = "src/kqueue/kqueue_submit.zig", .variable = "receipts" },
        // Registration of buffers, once per loop, before any tick.
        .{ .path = "src/uring/uring_buffers.zig", .variable = "vectors" },
        // A group's wakes, made once when the group is created.
        .{ .path = "src/rotor/rotor_loop_registry.zig", .variable = "wakes" },
        // A group's pipe ends, made once when the group is created.
        .{ .path = "src/kqueue/kqueue_group.zig", .variable = "ends" },
        // The 64 bytes a group's wake is read into, beside the `read` that drains it.
        .{ .path = "src/kqueue/kqueue_group.zig", .variable = "bytes" },
        // A datagram's control block, 128 bytes, beside the `sendmsg` or `recvmsg` it goes with.
        // What the fill costs against that call is not measured.
        .{ .path = "src/kqueue/kqueue_datagram.zig", .variable = "control" },
        .{ .path = "src/epoll/epoll_datagram.zig", .variable = "control" },
    },
};

const Rule = Checker(config);
pub const name = Rule.name;
pub const check = Rule.check;

/// The rule for one configuration: a type with the `name` and `check` the driver dispatches to.
pub fn Checker(comptime settings: Config) type {
    comptime std.debug.assert(settings.name.len != 0);
    return struct {
        pub const name = settings.name;

        pub fn check(context: *lint.report.Context, file: lint.report.File) !void {
            if (!settings.scope.applies(file.path)) return;
            const tree = file.tree orelse return;
            var visitor: Visitor = .{
                .tree = tree,
                .findings = &context.findings,
                .path = file.path,
                .settings = &settings,
            };
            for (tree.rootDecls()) |declaration| {
                if (is_testing_import(tree, declaration)) break;
                visitor.child(declaration);
            }
            if (visitor.failure) |failure| return failure;
        }
    };
}

const Visitor = struct {
    tree: *const Ast,
    findings: *lint.report.Findings,
    path: []const u8,
    settings: *const Config,
    /// True while the walk is inside a function body and outside any container declared there, so
    /// a `var` met now is one of the function's locals.
    in_function: bool = false,
    depth: u32 = 0,
    failure: ?anyerror = null,

    pub fn child(self: *Visitor, node: Node.Index) void {
        self.depth += 1;
        defer self.depth -= 1;
        std.debug.assert(self.depth <= lint.ast.max_tree_depth);
        switch (self.tree.nodeTag(node)) {
            // A test's locals run in tests alone.
            .test_decl => return,
            .fn_decl => return self.walk(node, true),
            else => {},
        }
        var buffer: [2]Node.Index = undefined;
        if (self.tree.fullContainerDecl(&buffer, node) != null) return self.walk(node, false);
        if (self.in_function) {
            self.check_local(node) catch |failure| {
                self.failure = failure;
            };
        }
        lint.ast.for_each_child(self.tree, node, self);
    }

    /// Walks the children of `node` with `in_function` set as given, and restores it after.
    fn walk(self: *Visitor, node: Node.Index, in_function: bool) void {
        const outer = self.in_function;
        self.in_function = in_function;
        defer self.in_function = outer;
        lint.ast.for_each_child(self.tree, node, self);
    }

    fn check_local(self: *Visitor, node: Node.Index) !void {
        const declaration = self.tree.fullVarDecl(node) orelse return;
        if (self.tree.tokenTag(declaration.ast.mut_token) != .keyword_var) return;
        const type_node = declaration.ast.type_node.unwrap() orelse return;
        const init_node = declaration.ast.init_node.unwrap() orelse return;
        if (!is_undefined(self.tree, init_node)) return;
        const array = self.tree.fullArrayType(type_node) orelse return;
        if (self.small_literal(array.ast.elem_count)) return;
        const name_token = declaration.ast.mut_token + 1;
        const variable = self.tree.tokenSlice(name_token);
        if (self.is_allowed(variable)) return;
        const location = lint.ast.token_location(self.tree, name_token);
        try self.findings.add(
            self.settings.name,
            self.path,
            location.line,
            location.column,
            "var {s} is an array set to undefined, which ReleaseSafe fills on every call: write " ++
                "into the caller's memory, or declare it only where it is used",
            .{variable},
        );
    }

    /// True when the array's length is a number no larger than `literal_elements_max`.
    fn small_literal(self: *const Visitor, count: Node.Index) bool {
        if (self.tree.nodeTag(count) != .number_literal) return false;
        const text = self.tree.tokenSlice(self.tree.nodeMainToken(count));
        const elements = std.fmt.parseInt(u64, text, 0) catch return false;
        return elements <= self.settings.literal_elements_max;
    }

    fn is_allowed(self: *const Visitor, variable: []const u8) bool {
        for (self.settings.allowed) |allowed| {
            if (std.mem.eql(u8, allowed.path, self.path) and std.mem.eql(u8, allowed.variable, variable)) {
                return true;
            }
        }
        return false;
    }
};

/// True for `const testing = std.testing;`, the line where a rotor file begins its tests.
fn is_testing_import(tree: *const Ast, node: Node.Index) bool {
    const declaration = tree.fullVarDecl(node) orelse return false;
    if (tree.tokenTag(declaration.ast.mut_token) != .keyword_const) return false;
    if (!std.mem.eql(u8, tree.tokenSlice(declaration.ast.mut_token + 1), "testing")) return false;
    const init_node = declaration.ast.init_node.unwrap() orelse return false;
    return std.mem.eql(u8, tree.getNodeSource(init_node), "std.testing");
}

fn is_undefined(tree: *const Ast, node: Node.Index) bool {
    if (tree.nodeTag(node) != .identifier) return false;
    return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "undefined");
}

// Tests. Each fixture pins one shape the rule reports or passes.

const testing = std.testing;
const harness = lint.harness;

test "undefined-fill reports a local array whose length is a name, and passes one it fills" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try harness.expect_messages(try harness.run(arena, Rule, "src/core/inbox.zig",
        \\const count = 32;
        \\fn drain() void {
        \\    var messages: [count]u64 = undefined;
        \\    _ = &messages;
        \\}
    ), &.{"var messages is an array set to undefined, which ReleaseSafe fills on every call: " ++
        "write into the caller's memory, or declare it only where it is used"});
    try harness.expect_messages(try harness.run(arena, Rule, "src/core/inbox.zig",
        \\const count = 32;
        \\fn drain() void {
        \\    var messages: [count]u64 = @splat(0);
        \\    _ = &messages;
        \\}
    ), &.{});
}

test "undefined-fill passes a few elements written as a number, and reports one more" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try harness.expect_messages(try harness.run(arena, Rule, "src/core/inbox.zig",
        \\fn few() void {
        \\    var events: [8]u64 = undefined;
        \\    _ = &events;
        \\}
    ), &.{});
    const findings = try harness.run(arena, Rule, "src/core/inbox.zig",
        \\fn more() void {
        \\    var events: [9]u64 = undefined;
        \\    _ = &events;
        \\}
    );
    try testing.expectEqual(@as(usize, 1), findings.len);
}

test "undefined-fill reads no test, no container member, and no file outside its scope" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try harness.expect_messages(try harness.run(arena, Rule, "src/core/inbox.zig",
        \\const count = 32;
        \\var shared: [count]u64 = undefined;
        \\const Holder = struct { var inner: [count]u64 = undefined; };
        \\test "a fixture" {
        \\    var messages: [count]u64 = undefined;
        \\    _ = &messages;
        \\    const Helper = struct {
        \\        fn fill() void {
        \\            var slots: [count]u64 = undefined;
        \\            _ = &slots;
        \\        }
        \\    };
        \\    Helper.fill();
        \\}
    ), &.{});
    // A struct declared inside a function has members, not locals; a function inside it has locals.
    const nested = try harness.run(arena, Rule, "src/core/inbox.zig",
        \\const count = 32;
        \\fn outer() void {
        \\    const Inner = struct {
        \\        var member: [count]u64 = undefined;
        \\        fn inner() void {
        \\            var local: [count]u64 = undefined;
        \\            _ = &local;
        \\        }
        \\    };
        \\    _ = Inner;
        \\}
    );
    try testing.expectEqual(@as(usize, 1), nested.len);
    try testing.expect(std.mem.indexOf(u8, nested[0].message, "var local ") != null);
    try testing.expect(!config.scope.applies("src/conformance/conformance_tcp.zig"));
    try testing.expect(!config.scope.applies("src/kqueue/kqueue_mailbox_test.zig"));
    try testing.expect(!config.scope.applies("src/kqueue/kqueue_testing.zig"));
    try testing.expect(config.scope.applies("src/kqueue/kqueue_tick.zig"));
}

test "undefined-fill passes a variable the configuration allows, in its own file only" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\const changes_max = 256;
        \\fn apply_early() void {
        \\    var receipts: [changes_max]u64 = undefined;
        \\    _ = &receipts;
        \\}
    ;
    try harness.expect_messages(try harness.run(arena, Rule, "src/kqueue/kqueue_submit.zig", source), &.{});
    const elsewhere = try harness.run(arena, Rule, "src/kqueue/kqueue_reap.zig", source);
    try testing.expectEqual(@as(usize, 1), elsewhere.len);
}

test "undefined-fill stops where a file begins its tests, and not at another name for testing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try harness.expect_messages(try harness.run(arena, Rule, "src/core/inbox.zig",
        \\const std = @import("std");
        \\const count = 32;
        \\const testing = std.testing;
        \\fn fixture() void {
        \\    var slots: [count]u64 = undefined;
        \\    _ = &slots;
        \\}
    ), &.{});
    const findings = try harness.run(arena, Rule, "src/core/inbox.zig",
        \\const count = 32;
        \\pub const testing = @import("inbox_testing.zig");
        \\fn drain() void {
        \\    var messages: [count]u64 = undefined;
        \\    _ = &messages;
        \\}
    );
    try testing.expectEqual(@as(usize, 1), findings.len);
}
