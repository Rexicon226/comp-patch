const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .windows,
        .abi = .gnu,
    });
    const optimize = b.standardOptimizeOption(.{});

    const patch = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });

    const win32_dep = b.dependency("win32", .{});
    patch.addImport("win32", win32_dep.module("win32"));

    patch.linkSystemLibrary("kernel32", .{});
    patch.linkSystemLibrary("user32", .{});
    patch.linkSystemLibrary("advapi32", .{});

    const dll = b.addLibrary(.{
        .name = "TMCompPatch",
        .linkage = .dynamic,
        .root_module = patch,
    });
    b.installArtifact(dll);
}
