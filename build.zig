const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = @as([]const u8, "dx11"),
    });

    const exe = b.addExecutable(.{
        .name = "CommerceHelper",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the dvui_dx11 module (dvui + DX11 backend, already linked together)
    const dvui_dx11_mod = dvui_dep.module("dvui_dx11");
    exe.root_module.addImport("dvui", dvui_dx11_mod);

    // Add the dx11 backend module separately so main.zig can import it as "dx11-backend"
    const dx11_mod = dvui_dep.module("dx11");
    exe.root_module.addImport("dx11-backend", dx11_mod);

    // Link Windows system libraries required by DX11
    exe.linkSystemLibrary("d3d11");
    exe.linkSystemLibrary("dxgi");
    exe.linkSystemLibrary("dxguid");

    // Create a module rooted in assets/ so that @embedFile can reach goods.json
    // and routes.json (siblings of embedded.zig).  The main source tree at
    // src/ cannot embed files from outside its own directory tree.
    const embedded_assets_mod = b.createModule(.{
        .root_source_file = b.path("assets/embedded.zig"),
    });
    exe.root_module.addImport("embedded_assets", embedded_assets_mod);

    b.installArtifact(exe);

    // Install goods.json and routes.json directly alongside the exe (not in a
    // subdirectory) so the data-loading code can find them via selfExeDirPath.
    const install_goods = b.addInstallFile(b.path("assets/goods.json"), "bin/goods.json");
    b.getInstallStep().dependOn(&install_goods.step);

    const install_routes = b.addInstallFile(b.path("assets/routes.json"), "bin/routes.json");
    b.getInstallStep().dependOn(&install_routes.step);

    // Install static/ as a subdirectory of the exe directory (for Good icons).
    const install_static = b.addInstallDirectory(.{
        .source_dir = b.path("static"),
        .install_dir = .bin,
        .install_subdir = "static",
    });
    b.getInstallStep().dependOn(&install_static.step);

    // `zig build run`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run CommerceHelper");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` — run optimizer unit tests
    const optimizer_tests = b.addTest(.{
        .root_source_file = b.path("src/engine/optimizer.zig"),
        .target = target,
        .optimize = optimize,
    });
    // optimizer.zig uses @import("../data/config.zig") as a relative file path;
    // when it is a test root the relative import escapes the module boundary.
    // Register config.zig as a named module matching that exact import string.
    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/data/config.zig"),
    });
    optimizer_tests.root_module.addImport("../data/config.zig", config_mod);
    // goods.zig imports "embedded_assets"; create a test-side embedded_assets module
    // so that the goods module resolves its @import("embedded_assets") when compiled
    // as a test dependency (same assets/ root as the exe module above).
    const test_embedded_assets_mod = b.createModule(.{
        .root_source_file = b.path("assets/embedded.zig"),
    });
    const goods_mod = b.createModule(.{
        .root_source_file = b.path("src/data/goods.zig"),
        .imports = &.{.{ .name = "embedded_assets", .module = test_embedded_assets_mod }},
    });
    optimizer_tests.root_module.addImport("../data/goods.zig", goods_mod);
    const run_optimizer_tests = b.addRunArtifact(optimizer_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_optimizer_tests.step);

    // `zig build test` — run threshold engine unit tests
    const threshold_tests = b.addTest(.{
        .root_source_file = b.path("src/engine/threshold.zig"),
        .target = target,
        .optimize = optimize,
    });
    // threshold.zig (and its sibling engine/matrix.zig, engine/optimizer.zig,
    // pulled in via same-directory relative imports) escape the test root's
    // module boundary (src/engine/) via "../data/*.zig" — register each exact
    // import string, reusing the modules created above where possible.
    threshold_tests.root_module.addImport("../data/config.zig", config_mod);
    threshold_tests.root_module.addImport("../data/goods.zig", goods_mod);
    const routes_mod = b.createModule(.{
        .root_source_file = b.path("src/data/routes.zig"),
        .imports = &.{.{ .name = "embedded_assets", .module = test_embedded_assets_mod }},
    });
    threshold_tests.root_module.addImport("../data/routes.zig", routes_mod);
    const run_threshold_tests = b.addRunArtifact(threshold_tests);
    test_step.dependOn(&run_threshold_tests.step);

    // `zig build test` — run Live Mode calculation engine unit tests (Story 3.2)
    const live_tests = b.addTest(.{
        .root_source_file = b.path("src/engine/live.zig"),
        .target = target,
        .optimize = optimize,
    });
    // live.zig (and its sibling engine/matrix.zig, engine/optimizer.zig,
    // engine/threshold.zig, pulled in via same-directory relative imports)
    // escapes the test root's module boundary (src/engine/) via
    // "../data/*.zig" — register each exact import string, reusing the
    // modules created above, same convention as threshold_tests.
    live_tests.root_module.addImport("../data/config.zig", config_mod);
    live_tests.root_module.addImport("../data/goods.zig", goods_mod);
    live_tests.root_module.addImport("../data/routes.zig", routes_mod);
    const run_live_tests = b.addRunArtifact(live_tests);
    test_step.dependOn(&run_live_tests.step);

    // `zig build test` — run routes data-layer unit tests
    const routes_tests = b.addTest(.{
        .root_source_file = b.path("src/data/routes.zig"),
        .target = target,
        .optimize = optimize,
    });
    // routes.zig imports "embedded_assets" directly; register the same
    // test-side embedded_assets module used above.
    routes_tests.root_module.addImport("embedded_assets", test_embedded_assets_mod);
    const run_routes_tests = b.addRunArtifact(routes_tests);
    test_step.dependOn(&run_routes_tests.step);

    // `zig build test` — run live_profits data-layer unit tests (Story 3.4).
    // No embedded_assets import needed — unlike routes.zig/goods.zig, this
    // file has no shipped default and is absent until the first save.
    const live_profits_tests = b.addTest(.{
        .root_source_file = b.path("src/data/live_profits.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_live_profits_tests = b.addRunArtifact(live_profits_tests);
    test_step.dependOn(&run_live_profits_tests.step);

    // `zig build test` — run AppState orchestration unit tests (Story 2.5:
    // AppState.saveRoutes success/no-op/failure paths).
    const app_tests = b.addTest(.{
        .root_source_file = b.path("src/ui/app.zig"),
        .target = target,
        .optimize = optimize,
    });
    // app.zig (and its sibling ui/onboarding.zig, ui/settings.zig,
    // ui/threshold.zig, ui/live.zig — pulled in via same-directory relative
    // imports, so no registration needed for those) escapes the test root's
    // module boundary (src/ui/) via "dvui" and "../data|engine/*.zig" —
    // register each exact import string, reusing the modules created above.
    app_tests.root_module.addImport("dvui", dvui_dx11_mod);
    app_tests.root_module.addImport("../data/config.zig", config_mod);
    app_tests.root_module.addImport("../data/goods.zig", goods_mod);
    app_tests.root_module.addImport("../data/routes.zig", routes_mod);
    // app.zig also imports "../data/live_profits.zig" directly (Story 3.4) —
    // register it the same way as routes_mod. It only imports "std", so no
    // further sibling-import registration is needed for it.
    const live_profits_mod = b.createModule(.{
        .root_source_file = b.path("src/data/live_profits.zig"),
    });
    app_tests.root_module.addImport("../data/live_profits.zig", live_profits_mod);
    // engine/matrix.zig is reached two ways here: directly by app.zig
    // ("../engine/matrix.zig") and internally by engine/threshold.zig's own
    // sibling import ("matrix.zig"). Build ONE module for it and override
    // threshold's sibling-import name to point at that same instance, so
    // RouteMatrix is one identical type on both sides of build()/updateCache()
    // — two separate modules for the same file would produce two distinct
    // (incompatible) RouteMatrix types.
    const engine_matrix_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/matrix.zig"),
        .imports = &.{.{ .name = "../data/routes.zig", .module = routes_mod }},
    });
    // engine/optimizer.zig is reached the same way, both by engine/threshold.zig
    // and (below) by engine/live.zig's own sibling import ("optimizer.zig") —
    // build ONE module for it up front and have both override their
    // sibling-import name to point at it. Zig also flatly rejects the same
    // source file backing two independently auto-resolved modules within one
    // compilation ("file exists in multiple modules"), which is what an
    // unregistered import from two different parent modules produces.
    const engine_optimizer_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/optimizer.zig"),
        .imports = &.{
            .{ .name = "../data/config.zig", .module = config_mod },
            .{ .name = "../data/goods.zig", .module = goods_mod },
        },
    });
    const engine_threshold_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/threshold.zig"),
        .imports = &.{
            .{ .name = "../data/config.zig", .module = config_mod },
            .{ .name = "../data/goods.zig", .module = goods_mod },
            .{ .name = "matrix.zig", .module = engine_matrix_mod },
            .{ .name = "optimizer.zig", .module = engine_optimizer_mod },
        },
    });
    app_tests.root_module.addImport("../engine/matrix.zig", engine_matrix_mod);
    app_tests.root_module.addImport("../engine/threshold.zig", engine_threshold_mod);
    // app.zig also imports "../engine/live.zig" (Story 3.2) directly, for
    // AppState.calculateLive(). engine/live.zig itself reaches
    // engine/matrix.zig, engine/optimizer.zig and engine/threshold.zig via
    // its own sibling imports — override all three to the exact same module
    // instances already built above, for the same reason matrix.zig and
    // optimizer.zig are unified above: two separately-compiled instances of
    // the same file would produce distinct, incompatible types (RouteMatrix,
    // OriginResult) on either side of AppState's fields, or outright
    // conflict at the module-graph level (as optimizer.zig did above).
    const engine_live_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/live.zig"),
        .imports = &.{
            .{ .name = "../data/config.zig", .module = config_mod },
            .{ .name = "../data/goods.zig", .module = goods_mod },
            .{ .name = "matrix.zig", .module = engine_matrix_mod },
            .{ .name = "optimizer.zig", .module = engine_optimizer_mod },
            .{ .name = "threshold.zig", .module = engine_threshold_mod },
        },
    });
    app_tests.root_module.addImport("../engine/live.zig", engine_live_mod);
    const run_app_tests = b.addRunArtifact(app_tests);
    test_step.dependOn(&run_app_tests.step);

    // `zig build test` — run the render loop's idle-wait micros→ms conversion
    // unit tests. Extracted from main.zig into its own dependency-free module
    // because main.zig itself has no test target: it imports "dvui" and
    // "dx11-backend" and links d3d11/dxgi/dxguid, so testing it would require
    // duplicating the exe target's full DirectX link setup for a test binary.
    const idle_wait_tests = b.addTest(.{
        .root_source_file = b.path("src/util/idle_wait.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_idle_wait_tests = b.addRunArtifact(idle_wait_tests);
    test_step.dependOn(&run_idle_wait_tests.step);
}
