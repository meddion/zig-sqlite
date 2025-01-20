const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Playground
    {
        const playground = b.addExecutable(.{
            .name = "playground",
            .root_source_file = b.path("src/playground.zig"),
            .target = target,
            .optimize = optimize,
        });
        const build_artifact = b.addInstallArtifact(playground, .{});
        const run_artifact = b.addRunArtifact(playground);
        const build_step = b.step("play-build", "Build playground");
        const run_step = b.step("play", "Run playground");
        run_step.dependOn(&run_artifact.step);
        build_step.dependOn(&build_artifact.step);
    }

    // Test
    {
        const tests = b.addTest(.{
            .name = "test",
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        });
        const build_artifact = b.addInstallArtifact(tests, .{});
        const build_step = b.step("test-build", "Build test");
        build_step.dependOn(&build_artifact.step);

        const run_artifact = b.addRunArtifact(tests);
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_artifact.step);
    }

    // Main
    {
        const exe = b.addExecutable(.{
            .name = "sqlite",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        // Deps
        const clap = b.dependency("clap", .{});
        exe.root_module.addImport("clap", clap.module("clap"));

        // This declares intent for the executable to be installed into the
        // standard location when the user invokes the "install" step (the default
        // step when running `zig build`).
        b.installArtifact(exe);

        // This *creates* a Run step in the build graph, to be executed when another
        // step is evaluated that depends on it. The next line below will establish
        // such a dependency.
        const run_cmd = b.addRunArtifact(exe);

        // By making the run step depend on the install step, it will be run from the
        // installation directory rather than directly from within the cache directory.
        // This is not necessary, however, if the application depends on other installed
        // files, this ensures they will be present and in the expected location.
        run_cmd.step.dependOn(b.getInstallStep());

        // This allows the user to pass arguments to the application in the build
        // command itself, like this: `zig build run -- arg1 arg2 etc`
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        // This creates a build step. It will be visible in the `zig build --help` menu,
        // and can be selected like this: `zig build run`
        // This will evaluate the `run` step rather than the default, which is "install".
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    // Will be use by zls to show compile time errors in an editor
    {
        const tests = b.addTest(.{
            .name = "test",
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        });

        const playground = b.addExecutable(.{
            .name = "playground",
            .root_source_file = b.path("src/playground.zig"),
            .target = target,
            .optimize = optimize,
        });

        const exe = b.addExecutable(.{
            .name = "sqlite",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        const check = b.step("check", "Check if foo compiles");
        check.dependOn(&tests.step);
        check.dependOn(&playground.step);
        check.dependOn(&exe.step);
    }
}
