const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zpl = b.addModule("zpl", .{
        .root_source_file = b.path("src/zpl.zig"),
        .target = target,
        .optimize = optimize,
    });

    const make_labels = b.addExecutable(.{
        .name = "make_labels",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/make_labels.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zpl", .module = zpl },
            },
        }),
    });
    b.installArtifact(make_labels);

    const run = b.addRunArtifact(make_labels);
    run.addArg("--printer");
    run.addArg("ZDesigner GK420t");
    // run.addArg("stdout");
    if (b.args) |args| run.addArgs(args);
    b.step("run", "run make_labels").dependOn(&run.step);
}
