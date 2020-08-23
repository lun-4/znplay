const std = @import("std");
const Builder = std.build.Builder;
const builds = std.build;

fn linkLibraries(step: *builds.LibExeObjStep) void {
    step.linkSystemLibrary("c");
    step.linkSystemLibrary("sndfile");
    step.linkSystemLibrary("soundio");
}

pub fn build(b: *Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("znplay", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addPackagePath("sndfile", "zig-sndfile/src/main.zig");
    exe.install();

    linkLibraries(exe);

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
