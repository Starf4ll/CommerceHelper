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
}
