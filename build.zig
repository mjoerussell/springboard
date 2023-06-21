const std = @import("std");

const test_files = [_][]const u8{ "src/KeyPair.zig", "src/Timestamp.zig", "src/Board.zig", "src/http/Response.zig", "src/http/Request.zig" };

pub fn build(b: *std.build.Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "springboard",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    // const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    inline for (test_files) |filename| {
        const tests = b.addTest(.{
            .root_source_file = .{ .path = filename },
        });
        test_step.dependOn(&tests.step);
    }
}
