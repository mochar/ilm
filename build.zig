const std = @import("std");
const Build = std.Build;
const Module = Build.Module;

const android_include_path: std.Build.LazyPath = .{ .cwd_relative = "/home/mochar/Android/Sdk/ndk/27.0.12077973/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include" };

const BuildPart = struct {
    module: *Build.Module,
    step: *Build.Step,
};

fn injectAndroidInclude(b: *Build, target: Build.ResolvedTarget, step_or_mod: anytype) void {
    if (!target.result.abi.isAndroid()) return;

    // NDK requires an arch-specific include path alongside the generic one
    const arch_specific_path = switch (target.result.cpu.arch) {
        .x86 => "i686-linux-android",
        .x86_64 => "x86_64-linux-android",
        .arm => "arm-linux-androideabi",
        .aarch64 => "aarch64-linux-android",
        else => @panic("Unknown Android arch"),
    };

    const T = @TypeOf(step_or_mod);
    if (T == *std.Build.Module) {
        step_or_mod.addSystemIncludePath(android_include_path.path(b, arch_specific_path));
        step_or_mod.addSystemIncludePath(android_include_path);
    } else if (T == *std.Build.Step.TranslateC) {
        step_or_mod.addIncludePath(android_include_path.path(b, arch_specific_path));
        step_or_mod.addIncludePath(android_include_path);

        // Clang's TranslateC parser crashes on Apple's _Nonnull attributes in Android NDK headers.
        // We strip them out entirely to fix the parsing.
        step_or_mod.defineCMacro("_Nonnull", "");
        step_or_mod.defineCMacro("_Nullable", "");
    } else {
        @compileError("Unsupported type for injectAndroidInclude: " ++ @typeName(T));
    }
}

pub fn build(b: *Build) void {
    var target = b.standardTargetOptions(.{});

    if (b.option(bool, "android", "Set target to Android for GUI") orelse false) {
        target = b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .android,
        });
    }

    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const sqlite_dep = b.dependency("sqlite", .{ .target = target, .optimize = optimize });
    if (target.result.abi.isAndroid()) {
        injectAndroidInclude(b, target, sqlite_dep.artifact("sqlite").root_module);
    }
    const known_folders_dep = b.dependency("known_folders", .{ .target = target, .optimize = optimize });
    const uuid_dep = b.dependency("uuid", .{ .target = target, .optimize = optimize });

    const sqlite_mod = sqlite_dep.module("sqlite");
    const known_folders_mod = known_folders_dep.module("known-folders");
    const uuid_mod = uuid_dep.module("uuid");

    // Assets module
    const assets_mod = buildAssets(b, target, optimize);

    // Universal C bindings
    const c_bindings = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    injectAndroidInclude(b, target, c_bindings);
    const c_mod = c_bindings.createModule();

    // Specific Binding Modules
    const plutovg_mod = buildPlutoVG(b, target, optimize, assets_mod, c_mod, c_bindings);
    const graphviz = buildGraphviz(b, target, optimize, c_mod, c_bindings);
    const iroh = buildIroh(b, target, optimize, c_mod, c_bindings);

    // Ensure cargo build runs before translate-c starts parsing
    c_bindings.step.dependOn(iroh.step);
    c_bindings.step.dependOn(graphviz.step);

    // Core module
    const core_mod = buildCore(b, target, optimize, &.{
        .{ .name = "c", .module = c_mod },
        .{ .name = "assets", .module = assets_mod },
        .{ .name = "plutovg", .module = plutovg_mod },
        .{ .name = "graphviz", .module = graphviz.module },
        .{ .name = "sqlite", .module = sqlite_mod },
        .{ .name = "known-folders", .module = known_folders_mod },
        .{ .name = "uuid", .module = uuid_mod },
        .{ .name = "iroh", .module = iroh.module },
    });

    // Targets & Steps
    if (!target.result.abi.isAndroid()) {
        const core_test_step = addCoreTests(b, core_mod);
        const cli_test_step = buildCli(b, target, optimize, &.{
            .{ .name = "ilm", .module = core_mod },
            .{ .name = "known-folders", .module = known_folders_mod },
        });
        buildEmacs(b, target, optimize, &.{
            .{ .name = "ilm", .module = core_mod },
            .{ .name = "sqlite", .module = sqlite_mod },
            .{ .name = "graphviz", .module = graphviz.module },
        });

        // Tests
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(core_test_step);
        test_step.dependOn(cli_test_step);

        const gui_test_step = buildGui(b, target, optimize, &.{
            .{ .name = "ilm", .module = core_mod },
            .{ .name = "known-folders", .module = known_folders_mod },
            .{ .name = "sqlite", .module = sqlite_mod },
        });
        test_step.dependOn(gui_test_step);
    } else {
        buildGuiAndroid(b, target, optimize, &.{
            .{ .name = "ilm", .module = core_mod },
            .{ .name = "known-folders", .module = known_folders_mod },
            .{ .name = "sqlite", .module = sqlite_mod },
        });
    }
}

fn buildAssets(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *Build.Module {
    // Dynamic assets can be loaded at runtime.
    const install_assets = b.addInstallDirectory(.{
        .source_dir = b.path("assets/dynamic/"),
        .install_dir = .bin,
        .install_subdir = "assets", // installed as zig-out/bin/assets/
    });
    b.getInstallStep().dependOn(&install_assets.step);

    // Static assets module contains embedded assets.
    const assets_mod = b.createModule(.{
        .root_source_file = b.path("assets/assets.zig"),
        .target = target,
        .optimize = optimize,
    });
    return assets_mod;
}

fn buildPlutoVG(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    assets_mod: *Build.Module,
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
    injectAndroidInclude(b, target, lib_mod);
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

    if (!target.result.abi.isAndroid()) {
        if (target.result.os.tag == .linux) {
            lib_mod.linkSystemLibrary("m", .{});
            lib_mod.linkSystemLibrary("pthread", .{});
        } else if (target.result.os.tag == .macos) {
            lib_mod.linkSystemLibrary("pthread", .{});
        }
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
            .{ .name = "assets", .module = assets_mod },
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
    const cmake_cfg = b.addSystemCommand(&.{
        "cmake", "-B", "vendor/graphviz/build", "-S", "vendor/graphviz",
    });
    if (optimize != .Debug) {
        cmake_cfg.addArgs(&.{"-DCMAKE_BUILD_TYPE=Release"});
    }

    // Only configure if generated grammar.c doesn't exist yet.
    var cmake_needed = false;
    std.Io.Dir.accessAbsolute(b.graph.io, b.pathFromRoot("vendor/graphviz/build/lib/cgraph/grammar.c"), .{}) catch {
        cmake_needed = true;
    };

    // Header files setup for <graphviz/...> includes
    const inc_files = b.addWriteFiles();
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/cgraph/cgraph.h"), "graphviz/cgraph.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/gvc/gvc.h"), "graphviz/gvc.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/cdt/cdt.h"), "graphviz/cdt.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/gvc/gvcext.h"), "graphviz/gvcext.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/gvc/gvcjob.h"), "graphviz/gvcjob.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/gvc/gvcommon.h"), "graphviz/gvcommon.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/gvc/gvconfig.h"), "graphviz/gvconfig.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/gvc/gvplugin.h"), "graphviz/gvplugin.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/gvc/gvplugin_device.h"), "graphviz/gvplugin_device.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/gvc/gvplugin_layout.h"), "graphviz/gvplugin_layout.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/gvc/gvplugin_loadimage.h"), "graphviz/gvplugin_loadimage.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/gvc/gvplugin_render.h"), "graphviz/gvplugin_render.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/gvc/gvplugin_textlayout.h"), "graphviz/gvplugin_textlayout.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/pathplan/pathgeom.h"), "graphviz/pathgeom.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/pathplan/pathplan.h"), "graphviz/pathplan.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/pack/pack.h"), "graphviz/pack.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/xdot/xdot.h"), "graphviz/xdot.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/common/arith.h"), "graphviz/arith.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/common/color.h"), "graphviz/color.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/common/geom.h"), "graphviz/geom.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/common/textspan.h"), "graphviz/textspan.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/common/types.h"), "graphviz/types.h");
    _ = inc_files.addCopyFile(b.path("vendor/graphviz/lib/common/usershape.h"), "graphviz/usershape.h");

    // Config header
    const config_h_source =
        \\#pragma once
        \\
        \\#if !defined(_WIN32)
        \\#define HAVE_SYS_IOCTL_H
        \\#define HAVE_SYS_MMAN_H
        \\#define HAVE_SYS_SELECT_H
        \\#define HAVE_SYS_TIME_H
        \\#define HAVE_GETOPT_H
        \\#define HAVE_DRAND48
        \\#define HAVE_MEMRCHR
        \\#define HAVE_SETENV
        \\#define HAVE_SRAND48
        \\#define HAVE_STRCASESTR
        \\#endif
        \\
        \\#define BROWSER "xdg-open"
        \\#define DEFAULT_DPI 96
        \\#define GVPLUGIN_CONFIG_FILE "config8"
        \\#define PACKAGE_VERSION "16.1.1"
    ;
    _ = inc_files.add("config.h", config_h_source);

    c_bindings.addIncludePath(inc_files.getDirectory());
    c_bindings.addIncludePath(b.path("vendor/graphviz/lib"));
    c_bindings.addIncludePath(b.path("vendor/graphviz/lib/cgraph"));
    c_bindings.addIncludePath(b.path("vendor/graphviz/lib/gvc"));
    c_bindings.addIncludePath(b.path("vendor/graphviz/lib/cdt"));
    c_bindings.addIncludePath(b.path("vendor/graphviz/build"));
    c_bindings.addIncludePath(b.path("vendor/graphviz/build/lib/common"));

    // Builtins and plugin registration with hardcoded layout algorithms: dot, dotx, neato
    const builtins_source =
        \\#include "config.h"
        \\#include <gvc/gvc.h>
        \\#include <gvc/gvplugin.h>
        \\#include <gvc/gvplugin_layout.h>
        \\#include <gvc/gvplugin_render.h>
        \\#include <gvc/gvplugin_device.h>
        \\#include <gvc/gvplugin_loadimage.h>
        \\#include <gvc/gvcext.h>
        \\
        \\// dot layout engine
        \\extern void dot_layout(graph_t *g);
        \\extern void dot_cleanup(graph_t *g);
        \\
        \\static gvlayout_engine_t dotgen_engine = {
        \\    dot_layout,
        \\    dot_cleanup,
        \\};
        \\
        \\static gvlayout_features_t dotgen_features = {
        \\    LAYOUT_USES_RANKDIR,
        \\};
        \\
        \\static gvplugin_installed_t gvlayout_dot_types[] = {
        \\    {0, "dot", 0, &dotgen_engine, &dotgen_features},
        \\    {0, "dotx", 0, &dotgen_engine, &dotgen_features},
        \\    {0, NULL, 0, NULL, NULL}
        \\};
        \\
        \\static gvplugin_api_t dot_apis[] = {
        \\    {API_layout, gvlayout_dot_types},
        \\    {(api_t)0, 0},
        \\};
        \\
        \\gvplugin_library_t gvplugin_dot_layout_LTX_library = { "dot_layout", dot_apis };
        \\
        \\// neato layout engine
        \\extern void neato_layout(graph_t *g);
        \\extern void neato_cleanup(graph_t *g);
        \\
        \\static gvlayout_engine_t neatogen_engine = {
        \\    neato_layout,
        \\    neato_cleanup,
        \\};
        \\
        \\static gvlayout_features_t neatogen_features = {
        \\    0,
        \\};
        \\
        \\static void nop1_layout(graph_t *g) {
        \\    extern int Nop;
        \\    Nop = 1;
        \\    neato_layout(g);
        \\    Nop = 0;
        \\}
        \\
        \\static void nop2_layout(graph_t *g) {
        \\    extern int Nop;
        \\    Nop = 2;
        \\    neato_layout(g);
        \\    Nop = 0;
        \\}
        \\
        \\static gvlayout_engine_t nop1gen_engine = {
        \\    nop1_layout,
        \\    neato_cleanup,
        \\};
        \\
        \\static gvlayout_engine_t nop2gen_engine = {
        \\    nop2_layout,
        \\    neato_cleanup,
        \\};
        \\
        \\static gvplugin_installed_t gvlayout_neato_types[] = {
        \\    {0, "neato", 0, &neatogen_engine, &neatogen_features},
        \\    {0, "nop", 0, &nop1gen_engine, &neatogen_features},
        \\    {0, "nop1", 0, &nop1gen_engine, &neatogen_features},
        \\    {0, "nop2", 0, &nop2gen_engine, &neatogen_features},
        \\    {0, NULL, 0, NULL, NULL}
        \\};
        \\
        \\static gvplugin_api_t neato_apis[] = {
        \\    {API_layout, gvlayout_neato_types},
        \\    {(api_t)0, 0},
        \\};
        \\
        \\gvplugin_library_t gvplugin_neato_layout_LTX_library = { "neato_layout", neato_apis };
        \\
        \\// core plugin declaration (renderers, devices)
        \\extern gvplugin_library_t gvplugin_core_LTX_library;
        \\
        \\// Preloaded symbol table containing our built-in plugins
        \\lt_symlist_t lt_preloaded_symbols[] = {
        \\    { "gvplugin_dot_layout_LTX_library", &gvplugin_dot_layout_LTX_library },
        \\    { "gvplugin_neato_layout_LTX_library", &gvplugin_neato_layout_LTX_library },
        \\    { "gvplugin_core_LTX_library", &gvplugin_core_LTX_library },
        \\    { 0, 0 }
        \\};
        \\
        \\#undef gvContext
        \\GVC_t *gvContext(void) {
        \\    return gvContextPlugins(lt_preloaded_symbols, 0);
        \\}
    ;

    const builtins_file = inc_files.add("builtins.c", builtins_source);

    const lib_mod = b.createModule(.{
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });
    injectAndroidInclude(b, target, lib_mod);

    lib_mod.addIncludePath(inc_files.getDirectory());
    lib_mod.addIncludePath(b.path("vendor/graphviz/lib"));
    lib_mod.addIncludePath(b.path("vendor/graphviz/lib/cdt"));
    lib_mod.addIncludePath(b.path("vendor/graphviz/lib/cgraph"));
    lib_mod.addIncludePath(b.path("vendor/graphviz/lib/common"));
    lib_mod.addIncludePath(b.path("vendor/graphviz/lib/gvc"));
    lib_mod.addIncludePath(b.path("vendor/graphviz/lib/pathplan"));
    lib_mod.addIncludePath(b.path("vendor/graphviz/lib/pack"));
    lib_mod.addIncludePath(b.path("vendor/graphviz/lib/xdot"));
    lib_mod.addIncludePath(b.path("vendor/graphviz/lib/neatogen"));
    lib_mod.addIncludePath(b.path("vendor/graphviz/lib/dotgen"));
    lib_mod.addIncludePath(b.path("vendor/graphviz/lib/sparse"));
    lib_mod.addIncludePath(b.path("vendor/graphviz/lib/rbtree"));
    lib_mod.addIncludePath(b.path("vendor/graphviz/lib/label"));
    lib_mod.addIncludePath(b.path("vendor/graphviz/lib/util"));
    lib_mod.addIncludePath(b.path("vendor/graphviz/plugin/core"));
    lib_mod.addIncludePath(b.path("vendor/graphviz/build"));
    lib_mod.addIncludePath(b.path("vendor/graphviz/build/lib/cgraph"));
    lib_mod.addIncludePath(b.path("vendor/graphviz/build/lib/common"));

    const c_flags = &[_][]const u8{
        "-std=gnu11",
        "-DEXPORT_CDT",
        "-DEXPORT_CGRAPH",
        "-DEXPORT_CGHDR",
        "-DPATHPLAN_EXPORTS",
        "-DEXPORT_XDOT",
        "-DGVC_EXPORTS",
        "-DNEATOGEN_EXPORTS=1",
        "-DGVLIBDIR=\"\"",
        "-DgvContext=orig_gvContext",
        "-Wno-unused-parameter",
        "-Wno-sign-compare",
        "-Wno-unused-function",
        "-Wno-implicit-fallthrough",
        "-Wno-deprecated-declarations",
        "-Wno-unused-but-set-variable",
        "-Wno-strict-prototypes",
        "-Wno-incompatible-pointer-types",
        "-Wno-return-type",
    };

    // cdt
    lib_mod.addCSourceFiles(.{
        .root = b.path("vendor/graphviz/lib/cdt"),
        .files = &.{
            "dtclose.c",  "dtdisc.c",    "dtextract.c", "dtflatten.c", "dthash.c",
            "dtmethod.c", "dtopen.c",    "dtrenew.c",   "dtrestore.c", "dtsize.c",
            "dtstat.c",   "dtstrhash.c", "dttree.c",    "dtview.c",    "dtwalk.c",
        },
        .flags = c_flags,
    });

    // cgraph
    lib_mod.addCSourceFiles(.{
        .root = b.path("vendor/graphviz/lib/cgraph"),
        .files = &.{
            "acyclic.c", "agerror.c",     "apply.c",     "attr.c",     "edge.c",
            "graph.c",   "id.c",          "imap.c",      "ingraphs.c", "io.c",
            "node.c",    "node_induce.c", "obj.c",       "rec.c",      "refstr.c",
            "subg.c",    "tred.c",        "unflatten.c", "utils.c",    "write.c",
        },
        .flags = c_flags,
    });
    lib_mod.addCSourceFiles(.{
        .root = b.path("vendor/graphviz/build/lib/cgraph"),
        .files = &.{ "grammar.c", "scan.c" },
        .flags = c_flags,
    });

    // util
    lib_mod.addCSourceFiles(.{
        .root = b.path("vendor/graphviz/lib/util"),
        .files = &.{
            "arena.c", "base64.c", "gv_find_me.c", "gv_fopen.c",
            "list.c",  "random.c", "xml.c",
        },
        .flags = c_flags,
    });

    // pathplan
    lib_mod.addCSourceFiles(.{
        .root = b.path("vendor/graphviz/lib/pathplan"),
        .files = &.{
            "cvt.c",         "inpoly.c",  "route.c",  "shortest.c",
            "shortestpth.c", "solvers.c", "triang.c", "util.c",
            "visibility.c",
        },
        .flags = c_flags,
    });

    // pack
    lib_mod.addCSourceFiles(.{
        .root = b.path("vendor/graphviz/lib/pack"),
        .files = &.{ "ccomps.c", "pack.c" },
        .flags = c_flags,
    });

    // xdot
    lib_mod.addCSourceFiles(.{
        .root = b.path("vendor/graphviz/lib/xdot"),
        .files = &.{"xdot.c"},
        .flags = c_flags,
    });

    // label
    lib_mod.addCSourceFiles(.{
        .root = b.path("vendor/graphviz/lib/label"),
        .files = &.{
            "index.c", "node.c", "rectangle.c", "split.q.c", "xlabels.c",
        },
        .flags = c_flags,
    });

    // common
    lib_mod.addCSourceFiles(.{
        .root = b.path("vendor/graphviz/lib/common"),
        .files = &.{
            "args.c",        "arrows.c",       "colxlate.c", "ellipse.c",   "emit.c",
            "geom.c",        "globals.c",      "htmllex.c",  "htmltable.c", "input.c",
            "labels.c",      "ns.c",           "output.c",   "pointset.c",  "postproc.c",
            "psusershape.c", "routespl.c",     "shapes.c",   "splines.c",   "taper.c",
            "textspan.c",    "textspan_lut.c", "timing.c",   "utils.c",
        },
        .flags = c_flags,
    });
    lib_mod.addCSourceFiles(.{
        .root = b.path("vendor/graphviz/build/lib/common"),
        .files = &.{"htmlparse.c"},
        .flags = c_flags,
    });

    // gvc
    lib_mod.addCSourceFiles(.{
        .root = b.path("vendor/graphviz/lib/gvc"),
        .files = &.{
            "gvc.c",          "gvconfig.c",    "gvcontext.c",   "gvdevice.c", "gvevent.c",
            "gvjobs.c",       "gvlayout.c",    "gvloadimage.c", "gvplugin.c", "gvrender.c",
            "gvtextlayout.c", "gvtool_tred.c", "gvusershape.c",
        },
        .flags = c_flags,
    });

    // dot layout (dotgen)
    lib_mod.addCSourceFiles(.{
        .root = b.path("vendor/graphviz/lib/dotgen"),
        .files = &.{
            "acyclic.c",  "aspect.c", "class1.c",   "class2.c",   "cluster.c",
            "compound.c", "conc.c",   "decomp.c",   "dotinit.c",  "dotsplines.c",
            "fastgr.c",   "flat.c",   "mincross.c", "position.c", "rank.c",
            "sameport.c",
        },
        .flags = c_flags,
    });

    // neato layout (neatogen, sparse, rbtree)
    lib_mod.addCSourceFiles(.{
        .root = b.path("vendor/graphviz/lib/neatogen"),
        .files = &.{
            "adjust.c",            "bfs.c",        "call_tri.c",                 "circuit.c",     "closest.c",
            "compute_hierarchy.c", "conjgrad.c",   "constrained_majorization.c", "constraint.c",  "delaunay.c",
            "dijkstra.c",          "edges.c",      "embed_graph.c",              "geometry.c",    "heap.c",
            "hedges.c",            "info.c",       "kkutils.c",                  "legal.c",       "lu.c",
            "matinv.c",            "matrix_ops.c", "multispline.c",              "neatoinit.c",   "neatosplines.c",
            "opt_arrangement.c",   "overlap.c",    "pca.c",                      "poly.c",        "quad_prog_solve.c",
            "randomkit.c",         "sgd.c",        "site.c",                     "smart_ini_x.c", "solve.c",
            "stress.c",            "stuff.c",      "voronoi.c",
        },
        .flags = c_flags,
    });
    lib_mod.addCSourceFiles(.{
        .root = b.path("vendor/graphviz/lib/sparse"),
        .files = &.{
            "clustering.c", "color_palette.c", "colorutil.c", "DotIO.c",
            "general.c",    "mq.c",            "QuadTree.c",  "SparseMatrix.c",
        },
        .flags = c_flags,
    });
    lib_mod.addCSourceFiles(.{
        .root = b.path("vendor/graphviz/lib/rbtree"),
        .files = &.{"red_black_tree.c"},
        .flags = c_flags,
    });

    // core plugins (renderers: dot, xdot, svg, json, plain, etc.)
    lib_mod.addCSourceFiles(.{
        .root = b.path("vendor/graphviz/plugin/core"),
        .files = &.{
            "gvplugin_core.c",     "gvrender_core_dot.c", "gvrender_core_fig.c", "gvrender_core_json.c",
            "gvrender_core_map.c", "gvrender_core_pic.c", "gvrender_core_pov.c", "gvrender_core_ps.c",
            "gvrender_core_svg.c", "gvrender_core_tk.c",  "gvloadimage_core.c",
        },
        .flags = c_flags,
    });

    // Builtins registration
    lib_mod.addCSourceFile(.{
        .file = builtins_file,
        .flags = c_flags,
    });

    if (!target.result.abi.isAndroid()) {
        switch (target.result.os.tag) {
            .linux => {
                lib_mod.linkSystemLibrary("m", .{});
                lib_mod.linkSystemLibrary("pthread", .{});
            },
            .macos => {
                lib_mod.linkSystemLibrary("pthread", .{});
                lib_mod.linkSystemLibrary("m", .{});
            },
            else => {},
        }
    }

    const lib = b.addLibrary(.{
        .name = "graphviz",
        .linkage = .static,
        .root_module = lib_mod,
    });

    if (cmake_needed) {
        lib.step.dependOn(&cmake_cfg.step);
    }

    const graphviz_mod = b.createModule(.{
        .root_source_file = b.path("src/bindings/graphviz.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = c_mod },
        },
    });
    graphviz_mod.linkLibrary(lib);

    return .{
        .module = graphviz_mod,
        .step = &lib.step,
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

    const iroh_mod = b.createModule(.{
        .root_source_file = b.path("src/bindings/iroh.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = c_mod },
        },
    });
    iroh_mod.addObjectFile(b.path(b.pathJoin(&.{ lib_dir, "libiroh_c_ffi.a" })));

    switch (target.result.os.tag) {
        .linux => {
            iroh_mod.linkSystemLibrary("unwind", .{});
            if (!target.result.abi.isAndroid()) {
                iroh_mod.linkSystemLibrary("m", .{});
                iroh_mod.linkSystemLibrary("pthread", .{});
                iroh_mod.linkSystemLibrary("dl", .{});
            }
        },
        .macos => {
            iroh_mod.linkSystemLibrary("System", .{});
            if (!target.result.abi.isAndroid()) {
                iroh_mod.linkSystemLibrary("m", .{});
                iroh_mod.linkSystemLibrary("pthread", .{});
            }
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
    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    });
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

/// dvui's build script is intrinsically broken for Android on Zig 0.14+ because it uses hardcoded
/// `b.addTranslateC` steps for its C bindings without exposing any way to pass Android NDK include
/// paths, nor does it pass the fetched sdl3 artifact include tree to its sdl backend translator on Android.
///
/// Instead of heavily patching the transient dependency inside zig-pkg/ or .zig-cache/, this function
/// reaches into the dvui dependency's compiled module graph, unearths the hidden TranslateC steps via
/// `@fieldParentPtr`, and injects the necessary include paths and Clang macro workarounds at configure time.
fn injectDvuiAndroidHack(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, dvui_dep: *std.Build.Dependency) void {
    const dvui_mod = dvui_dep.module("dvui_sdl3");

    // 1. Fix standard stb_image bindings (needs NDK stdio.h, etc.)
    const dvui_c_mod = dvui_mod.import_table.get("dvui-c").?;
    const dvui_c_step = dvui_c_mod.root_source_file.?.generated.file.step;
    const dvui_tr = @as(*std.Build.Step.TranslateC, @fieldParentPtr("step", dvui_c_step));
    injectAndroidInclude(b, target, dvui_tr);

    // 2. Fix SDL3 backend bindings (needs NDK headers AND the SDL3 package headers)
    const sdl3_dep = dvui_dep.builder.lazyDependency("sdl3", .{ .target = target, .optimize = optimize });
    const sdl3_include = sdl3_dep.?.artifact("SDL3").getEmittedIncludeTree();

    const sdl3_backend_mod = dvui_mod.import_table.get("backend").?;
    const sdl3_c_mod = sdl3_backend_mod.import_table.get("sdl3-c").?;
    const sdl3_c_step = sdl3_c_mod.root_source_file.?.generated.file.step;
    const sdl3_tr = @as(*std.Build.Step.TranslateC, @fieldParentPtr("step", sdl3_c_step));

    injectAndroidInclude(b, target, sdl3_tr);
    sdl3_tr.addIncludePath(sdl3_include);
}

fn buildGuiAndroid(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const std.Build.Module.Import,
) void {
    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
        .android_include_path = android_include_path,
    });

    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/gui/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    gui_mod.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    gui_mod.addImport("sdl-backend", dvui_dep.module("sdl3")); // for zls

    const gui_lib = b.addLibrary(.{
        .name = "ilm-gui",
        .root_module = gui_mod,
    });

    injectDvuiAndroidHack(b, target, optimize, dvui_dep);

    b.installArtifact(gui_lib);

    const gui_android_step = b.step("gui-android", "Build GUI library for Android");
    gui_android_step.dependOn(&b.addInstallArtifact(gui_lib, .{}).step);
    b.default_step = gui_android_step;
}
