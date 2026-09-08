const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // PlutoVG static library
    const plutovg_mod = b.createModule(.{
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });
    plutovg_mod.addIncludePath(b.path("vendor/plutovg/include"));
    plutovg_mod.addIncludePath(b.path("vendor/plutovg/source"));
    plutovg_mod.addCSourceFiles(.{
        .root = b.path("vendor/plutovg/source/"),
        .files = &[_][]const u8{
            "plutovg-blend.c",
            "plutovg-canvas.c",
            "plutovg-font.c",
            "plutovg-matrix.c",
            "plutovg-paint.c",
            "plutovg-path.c",
            "plutovg-rasterize.c",
            "plutovg-surface.c",
            "plutovg-ft-math.c",
            "plutovg-ft-raster.c",
            "plutovg-ft-stroker.c",
        },
        .flags = &[_][]const u8{
            "-std=gnu11",
            "-DPLUTOVG_BUILD",
            "-DPLUTOVG_BUILD_STATIC",
            "-Wno-sign-compare",
            "-Wno-unused-function",
        },
    });
    if (target.result.os.tag == .linux) {
        plutovg_mod.linkSystemLibrary("m", .{});
        plutovg_mod.linkSystemLibrary("pthread", .{});
    } else if (target.result.os.tag == .macos) {
        plutovg_mod.linkSystemLibrary("pthread", .{});
    }
    const plutovg_lib = b.addLibrary(.{
        .name = "plutovg",
        .linkage = .static,
        .root_module = plutovg_mod,
    });

    // Core
    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    core_mod.linkSystemLibrary("cgraph", .{});
    core_mod.linkSystemLibrary("gvc", .{});
    core_mod.linkLibrary(plutovg_lib);
    core_mod.addIncludePath(b.path("vendor/plutovg/include"));

    const core_tests = b.addTest(.{
        .root_module = core_mod,
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    // Dep: Sqlite
    const sqlite_dep = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });
    core_mod.addImport("sqlite", sqlite_dep.module("sqlite"));

    // Dep: Known folders
    const known_folders_dep = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    });
    core_mod.addImport("known-folders", known_folders_dep.module("known-folders"));

    // Dep: UUID
    const uuid_dep = b.dependency("uuid", .{
        .target = target,
        .optimize = optimize,
    });
    core_mod.addImport("uuid", uuid_dep.module("uuid"));

    // CLI
    const cli_exe = b.addExecutable(.{
        .name = "ilm-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "known-folders", .module = known_folders_dep.module("known-folders") },
            },
        }),
    });
    b.installArtifact(cli_exe);

    const cli_cmd = b.addRunArtifact(cli_exe);
    cli_cmd.step.dependOn(b.getInstallStep());
    const cli_step = b.step("cli", "Start the CLI");
    cli_step.dependOn(&cli_cmd.step);
    if (b.args) |args| {
        cli_cmd.addArgs(args);
    }

    const cli_tests = b.addTest(.{
        .root_module = cli_exe.root_module,
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    // Emacs
    const emacs_mod = b.createModule(.{
        .root_source_file = b.path("src/emacs/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "sqlite", .module = sqlite_dep.module("sqlite") },
        },
    });
    emacs_mod.addIncludePath(b.path("src/emacs/"));
    const emacs_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "ilm",
        .root_module = emacs_mod,
    });

    const install_emacs = b.addInstallArtifact(emacs_lib, .{
        .dest_sub_path = "ilm-core.so", // instead of libilm.so
    });
    b.getInstallStep().dependOn(&install_emacs.step);

    const emacs_step = b.step("emacs", "Build the Emacs dynamic module");
    emacs_step.dependOn(&install_emacs.step);

    // GUI (dvui)
    const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 });

    const gui_exe = b.addExecutable(.{
        .name = "ilm-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gui/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "known-folders", .module = known_folders_dep.module("known-folders") },
                .{ .name = "sqlite", .module = sqlite_dep.module("sqlite") },
            },
        }),
    });

    gui_exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    gui_exe.root_module.addImport("sdl-backend", dvui_dep.module("sdl3")); // for zls

    b.installArtifact(gui_exe);

    const gui_cmd = b.addRunArtifact(gui_exe);
    gui_cmd.step.dependOn(b.getInstallStep());
    const gui_step = b.step("gui", "Start the GUI");
    gui_step.dependOn(&gui_cmd.step);
    if (b.args) |args| {
        gui_cmd.addArgs(args);
    }

    const gui_tests = b.addTest(.{
        .root_module = gui_exe.root_module,
    });
    const run_gui_tests = b.addRunArtifact(gui_tests);

    // Tests
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_gui_tests.step);
}
