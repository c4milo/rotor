//! `zig build tla`: TLC over every model under spec/tla/, through pepegrillo's `tla` tool
//! (`tools/tla.zig`). The models are the sleep handshake of decision 12, point 6, and decision 18
//! (spec/tla/wake/).
//!
//! It is a step of its own and not part of `zig build test`, so a contributor without Java can run
//! the gate, and CI runs it in a job of its own. `zig build test` compiles the tool, so it cannot
//! stop building unseen.
const std = @import("std");

/// Adds the `tla` step, which runs `tool` from the repository's root, and returns the tool's
/// compile step.
pub fn add(b: *std.Build, tool: *std.Build.Step.Compile) *std.Build.Step {
    const run = b.addRunArtifact(tool);
    run.setCwd(b.path("."));
    // TLC reads the models from the tree, which the build does not track, so the step runs every
    // time.
    run.has_side_effects = true;
    if (b.args) |arguments| run.addArgs(arguments);
    const step = b.step("tla", "Check the TLA+ models with TLC");
    step.dependOn(&run.step);
    return &tool.step;
}
