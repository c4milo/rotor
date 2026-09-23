//! `zig build proofs`: checks the Lean proofs in proofs/ with `lake build`. The proofs model the
//! timer heap and the timer lifecycle of `src/core` and prove what decisions 5 and 14 claim of
//! them; proofs/README.md says which theorem covers which claim and what each model leaves out.
//!
//! It is a step of its own and not part of `zig build test`, so a contributor without Lean can run
//! the gate. It needs the Lean toolchain proofs/lean-toolchain names, which `elan` installs, and CI
//! runs it in a job of its own.
const std = @import("std");

pub fn add(b: *std.Build) void {
    const run = b.addSystemCommand(&.{ "lake", "build" });
    run.setCwd(b.path("proofs"));
    // Lake keeps its own record of what it has checked, under proofs/.lake, so the step runs
    // every time and Lake decides what to recheck.
    run.has_side_effects = true;
    const step = b.step("proofs", "Check the Lean proofs of the timer heap and the timer lifecycle");
    step.dependOn(&run.step);
}
