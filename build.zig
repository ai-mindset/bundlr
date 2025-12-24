const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("bundlr", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/bundlr.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Build-time configuration options
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", "0.1.0");
    build_options.addOption([]const u8, "default_python_version", "3.13");

    // Allow build-time project configuration via environment variables
    if (std.process.getEnvVarOwned(b.allocator, "BUNDLR_PROJECT_NAME")) |project_name| {
        build_options.addOption(?[]const u8, "embedded_project_name", project_name);
    } else |_| {
        build_options.addOption(?[]const u8, "embedded_project_name", null);
    }

    if (std.process.getEnvVarOwned(b.allocator, "BUNDLR_PROJECT_VERSION")) |project_version| {
        build_options.addOption(?[]const u8, "embedded_project_version", project_version);
    } else |_| {
        build_options.addOption(?[]const u8, "embedded_project_version", null);
    }

    if (std.process.getEnvVarOwned(b.allocator, "BUNDLR_PYTHON_VERSION")) |python_version| {
        build_options.addOption(?[]const u8, "embedded_python_version", python_version);
    } else |_| {
        build_options.addOption(?[]const u8, "embedded_python_version", null);
    }

    // Main bundlr executable with build-time configuration
    const exe = b.addExecutable(.{
        .name = "bundlr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bundlr", .module = mod },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Integration tests executable
    const integration_tests = b.addExecutable(.{
        .name = "integration-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bundlr", .module = mod },
            },
        }),
    });

    // Integration test run step
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("test-integration", "Run comprehensive integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    // Demo program to show working functionality
    const demo = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("demo_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bundlr", .module = mod },
            },
        }),
    });

    const run_demo = b.addRunArtifact(demo);
    const demo_step = b.step("demo", "Run demo showing working bundlr functionality");
    demo_step.dependOn(&run_demo.step);

    // Phase 3 test program
    const phase3_test = b.addExecutable(.{
        .name = "phase3-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("phase3_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bundlr", .module = mod },
            },
        }),
    });

    const run_phase3_test = b.addRunArtifact(phase3_test);
    const phase3_test_step = b.step("test-phase3", "Test Phase 3: Virtual Environment & Package Management");
    phase3_test_step.dependOn(&run_phase3_test.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
