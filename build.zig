const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const sqlite_dep = b.dependency("sqlite", .{ .target = target, .optimize = optimize });
    const known_folders_dep = b.dependency("known_folders", .{ .target = target, .optimize = optimize });
    const uuid_dep = b.dependency("uuid", .{ .target = target, .optimize = optimize });

    const sqlite_mod = sqlite_dep.module("sqlite");
    const known_folders_mod = known_folders_dep.module("known-folders");
    const uuid_mod = uuid_dep.module("uuid");

    // Libraries & Modules
    const plutovg_lib = buildPlutoVG(b, target, optimize);
    const core_mod = buildCore(b, target, optimize, plutovg_lib, sqlite_mod, known_folders_mod, uuid_mod);

    // Targets & Steps
    const core_test_step = addCoreTests(b, core_mod);
    const cli_test_step = buildCli(b, target, optimize, core_mod, known_folders_mod);
    buildEmacs(b, target, optimize, core_mod, sqlite_mod);
    const gui_test_step = buildGui(b, target, optimize, core_mod, sqlite_mod, known_folders_mod);

    // Tests
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(core_test_step);
    test_step.dependOn(cli_test_step);
    test_step.dependOn(gui_test_step);
}

fn buildPlutoVG(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
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

    return b.addLibrary(.{
        .name = "plutovg",
        .linkage = .static,
        .root_module = plutovg_mod,
    });
}

fn buildCore(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    plutovg_lib: *std.Build.Step.Compile,
    sqlite_mod: *std.Build.Module,
    known_folders_mod: *std.Build.Module,
    uuid_mod: *std.Build.Module,
) *std.Build.Module {
    const core_c = b.addTranslateC(.{
        .root_source_file = b.path("src/core/c.h"),
        .target = target,
        .optimize = optimize,
    });
    core_c.addIncludePath(b.path("vendor/plutovg/include"));

    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = core_c.createModule() },
            .{ .name = "sqlite", .module = sqlite_mod },
            .{ .name = "known-folders", .module = known_folders_mod },
            .{ .name = "uuid", .module = uuid_mod },
        },
    });

    core_mod.linkSystemLibrary("cgraph", .{});
    core_mod.linkSystemLibrary("gvc", .{});
    core_mod.linkLibrary(plutovg_lib);

    return core_mod;
}

fn addCoreTests(b: *std.Build, core_mod: *std.Build.Module) *std.Build.Step {
    const core_tests = b.addTest(.{
        .root_module = core_mod,
    });
    const run_core_tests = b.addRunArtifact(core_tests);
    return &run_core_tests.step;
}

fn buildCli(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core_mod: *std.Build.Module,
    known_folders_mod: *std.Build.Module,
) *std.Build.Step {
    const cli_exe = b.addExecutable(.{
        .name = "ilm-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ilm", .module = core_mod },
                .{ .name = "known-folders", .module = known_folders_mod },
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
    return &run_cli_tests.step;
}

fn buildEmacs(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core_mod: *std.Build.Module,
    sqlite_mod: *std.Build.Module,
) void {
    const emacs_c = b.addTranslateC(.{
        .root_source_file = b.path("src/emacs/emacs-module.h"),
        .target = target,
        .optimize = optimize,
    });

    const emacs_mod = b.createModule(.{
        .root_source_file = b.path("src/emacs/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "ilm", .module = core_mod },
            .{ .name = "sqlite", .module = sqlite_mod },
            .{ .name = "emacs_c", .module = emacs_c.createModule() },
        },
    });

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
}

fn buildGui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core_mod: *std.Build.Module,
    sqlite_mod: *std.Build.Module,
    known_folders_mod: *std.Build.Module,
) *std.Build.Step {
    const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 });

    const gui_exe = b.addExecutable(.{
        .name = "ilm-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gui/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ilm", .module = core_mod },
                .{ .name = "known-folders", .module = known_folders_mod },
                .{ .name = "sqlite", .module = sqlite_mod },
                .{ .name = "dvui", .module = dvui_dep.module("dvui_sdl3") },
                .{ .name = "sdl-backend", .module = dvui_dep.module("sdl3") }, // for zls
            },
        }),
    });
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
    return &run_gui_tests.step;
}
