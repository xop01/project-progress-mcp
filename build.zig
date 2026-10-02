const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    if (b.option([]const u8, "sqlite_source", "Path to sqlite3.c from the SQLite amalgamation")) |sqlite_source| {
        module.addCSourceFile(.{
            .file = .{ .cwd_relative = sqlite_source },
            .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION" },
        });
        if (std.fs.path.dirname(sqlite_source)) |source_dir| {
            module.addIncludePath(.{ .cwd_relative = source_dir });
        }
    } else {
        if (b.option([]const u8, "sqlite_include", "Directory containing sqlite3.h")) |include_dir| {
            module.addIncludePath(.{ .cwd_relative = include_dir });
        }
        if (b.option([]const u8, "sqlite_lib_dir", "Directory containing sqlite3 library files")) |lib_dir| {
            module.addLibraryPath(.{ .cwd_relative = lib_dir });
        }
        module.linkSystemLibrary("sqlite3", .{});
    }

    const exe = b.addExecutable(.{
        .name = "project-progress-mcp",
        .root_module = module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the MCP server over stdio");
    run_step.dependOn(&run_cmd.step);
}
