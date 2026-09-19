const std = @import("std");
const Build = std.Build;
const Module = Build.Module;

const BuildPart = struct {
    module: *Build.Module,
    step: *Build.Step,
};

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const sqlite_dep = b.dependency("sqlite", .{ .target = target, .optimize = optimize });
    const known_folders_dep = b.dependency("known_folders", .{ .target = target, .optimize = optimize });
    const uuid_dep = b.dependency("uuid", .{ .target = target, .optimize = optimize });

    const sqlite_mod = sqlite_dep.module("sqlite");
    const known_folders_mod = known_folders_dep.module("known-folders");
    const uuid_mod = uuid_dep.module("uuid");

    // Universal C bindings
    const c_bindings = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    const c_mod = c_bindings.createModule();

    // Specific Binding Modules
    const plutovg_mod = buildPlutoVG(b, target, optimize, c_mod, c_bindings);
    const graphviz = buildGraphviz(b, target, optimize, c_mod, c_bindings);
    const iroh = buildIroh(b, target, optimize, c_mod, c_bindings);

    // Ensure cargo build runs before translate-c starts parsing
    c_bindings.step.dependOn(iroh.step);
    c_bindings.step.dependOn(graphviz.step);

    // Core module
    const core_mod = buildCore(b, target, optimize, &.{
        .{ .name = "c", .module = c_mod },
        .{ .name = "plutovg", .module = plutovg_mod },
        .{ .name = "graphviz", .module = graphviz.module },
        .{ .name = "sqlite", .module = sqlite_mod },
        .{ .name = "known-folders", .module = known_folders_mod },
        .{ .name = "uuid", .module = uuid_mod },
        .{ .name = "iroh", .module = iroh.module },
    });

    // Targets & Steps
    const core_test_step = addCoreTests(b, core_mod);
    const cli_test_step = buildCli(b, target, optimize, &.{
        .{ .name = "ilm", .module = core_mod },
        .{ .name = "known-folders", .module = known_folders_mod },
    });
    buildEmacs(b, target, optimize, &.{
        .{ .name = "ilm", .module = core_mod },
        .{ .name = "sqlite", .module = sqlite_mod },
    });
    const gui_test_step = buildGui(b, target, optimize, &.{
        .{ .name = "ilm", .module = core_mod },
        .{ .name = "known-folders", .module = known_folders_mod },
        .{ .name = "sqlite", .module = sqlite_mod },
    });

    // Tests
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(core_test_step);
    test_step.dependOn(cli_test_step);
    test_step.dependOn(gui_test_step);
}

fn buildPlutoVG(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    c_mod: *Build.Module,
    c_bindings: *Build.Step.TranslateC,
) *Build.Module {
    // Inject headers into the universal c_bindings translation
    c_bindings.addIncludePath(b.path("vendor/plutovg/include"));

    const lib_mod = b.createModule(.{
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addIncludePath(b.path("vendor/plutovg/include"));
    lib_mod.addIncludePath(b.path("vendor/plutovg/source"));
    lib_mod.addCSourceFiles(.{
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
        lib_mod.linkSystemLibrary("m", .{});
        lib_mod.linkSystemLibrary("pthread", .{});
    } else if (target.result.os.tag == .macos) {
        lib_mod.linkSystemLibrary("pthread", .{});
    }

    const lib = b.addLibrary(.{
        .name = "plutovg",
        .linkage = .static,
        .root_module = lib_mod,
    });

    const plutovg_mod = b.createModule(.{
        .root_source_file = b.path("src/bindings/plutovg.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = c_mod },
        },
    });
    plutovg_mod.linkLibrary(lib);

    return plutovg_mod;
}

fn buildGraphviz(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    c_mod: *Build.Module,
    c_bindings: *Build.Step.TranslateC,
) BuildPart {
    const is_release = optimize != .Debug;

    const cmake_cfg = b.addSystemCommand(&.{
        "cmake", "-B", "vendor/graphviz/build", "-S", "vendor/graphviz",
    });
    if (is_release) {
        cmake_cfg.addArgs(&.{"-DCMAKE_BUILD_TYPE=Release"});
    }

    const cmake_build = b.addSystemCommand(&.{ "cmake", "--build", "vendor/graphviz/build", "--parallel" });

    // Only configure if CMakeCache.txt doesn't exist.
    // cmake --build will automatically reconfigure if CMakeLists.txt changes.
    std.Io.Dir.accessAbsolute(b.graph.io, b.pathFromRoot("vendor/graphviz/build/CMakeCache.txt"), .{}) catch {
        cmake_build.step.dependOn(&cmake_cfg.step);
    };

    c_bindings.addIncludePath(b.path("vendor/graphviz/lib/cgraph"));
    c_bindings.addIncludePath(b.path("vendor/graphviz/lib/gvc"));
    c_bindings.addIncludePath(b.path("vendor/graphviz/build")); // For generated headers

    const graphviz_mod = b.createModule(.{
        .root_source_file = b.path("src/bindings/graphviz.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = c_mod },
        },
    });

    graphviz_mod.addLibraryPath(b.path("vendor/graphviz/build/lib/cgraph"));
    graphviz_mod.addLibraryPath(b.path("vendor/graphviz/build/lib/gvc"));
    graphviz_mod.addLibraryPath(b.path("vendor/graphviz/build/lib/cdt"));

    graphviz_mod.linkSystemLibrary("cgraph", .{});
    graphviz_mod.linkSystemLibrary("gvc", .{});
    graphviz_mod.linkSystemLibrary("cdt", .{});

    return .{
        .module = graphviz_mod,
        .step = &cmake_build.step,
    };
}

fn buildIroh(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    c_mod: *Build.Module,
    c_bindings: *Build.Step.TranslateC,
) BuildPart {
    // Inject headers into the universal c_bindings translation
    c_bindings.addIncludePath(b.path("vendor/iroh-c-ffi"));

    const is_release = optimize != .Debug;
    const rel_target = if (is_release) "release" else "debug";

    const cargo_build = b.addSystemCommand(&.{ "cargo", "build", "--manifest-path", "vendor/iroh-c-ffi/Cargo.toml" });
    if (is_release) {
        cargo_build.addArgs(&.{"--release"});
    }
    cargo_build.setEnvironmentVariable("CARGO_PROFILE_DEV_DEBUG", "0");
    cargo_build.has_side_effects = true;

    const lib_dir = b.pathJoin(&.{ "vendor/iroh-c-ffi/target", rel_target });
    const lib_path = b.path(lib_dir);

    const iroh_mod = b.createModule(.{
        .root_source_file = b.path("src/bindings/iroh.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = c_mod },
        },
    });
    iroh_mod.addLibraryPath(lib_path);
    iroh_mod.linkSystemLibrary("iroh_c_ffi", .{});

    switch (target.result.os.tag) {
        .linux => {
            iroh_mod.linkSystemLibrary("unwind", .{});
            iroh_mod.linkSystemLibrary("m", .{});
            iroh_mod.linkSystemLibrary("pthread", .{});
            iroh_mod.linkSystemLibrary("dl", .{});
        },
        .macos => {
            iroh_mod.linkSystemLibrary("System", .{});
            iroh_mod.linkSystemLibrary("m", .{});
            iroh_mod.linkSystemLibrary("pthread", .{});
        },
        else => {},
    }

    const gen_headers = b.addSystemCommand(&.{
        "cargo",
        "run",
    });
    gen_headers.setCwd(b.path("vendor/iroh-c-ffi"));
    gen_headers.addArgs(&.{
        "--features",
        "headers",
        "--bin",
        "generate_headers",
    });
    const headers_step = b.step("iroh-headers", "Generate C headers for iroh-c-ffi");
    headers_step.dependOn(&gen_headers.step);

    return .{
        .module = iroh_mod,
        .step = &cargo_build.step,
    };
}

fn buildCore(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const Module.Import,
) *Module {
    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });

    return core_mod;
}

fn addCoreTests(b: *Build, core_mod: *Build.Module) *Build.Step {
    const core_tests = b.addTest(.{
        .root_module = core_mod,
    });
    const run_core_tests = b.addRunArtifact(core_tests);
    return &run_core_tests.step;
}

fn buildCli(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const Module.Import,
) *Build.Step {
    const cli_exe = b.addExecutable(.{
        .name = "ilm-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
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
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const Module.Import,
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
        .imports = imports,
    });
    emacs_mod.addImport("emacs_c", emacs_c.createModule());

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
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const Module.Import,
) *Build.Step {
    const dvui_dep = b.dependency(
        "dvui",
        .{
            .target = target,
            .optimize = optimize,
            .backend = .sdl3,
        },
    );

    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/gui/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    gui_mod.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    gui_mod.addImport("sdl-backend", dvui_dep.module("sdl3")); // for zls

    const gui_exe = b.addExecutable(.{
        .name = "ilm-gui",
        .root_module = gui_mod,
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
