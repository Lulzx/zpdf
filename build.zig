const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zpdf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(lib);

    // CLI tool
    const exe = b.addExecutable(.{
        .name = "zpdf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the zpdf CLI");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const simd_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/simd.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_simd_unit_tests = b.addRunArtifact(simd_unit_tests);

    const decompress_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/decompress.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_decompress_unit_tests = b.addRunArtifact(decompress_unit_tests);

    const parser_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_parser_unit_tests = b.addRunArtifact(parser_unit_tests);

    const xref_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/xref.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_xref_unit_tests = b.addRunArtifact(xref_unit_tests);

    const encoding_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/encoding.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_encoding_unit_tests = b.addRunArtifact(encoding_unit_tests);

    const interpreter_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/interpreter.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_interpreter_unit_tests = b.addRunArtifact(interpreter_unit_tests);

    const testpdf_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testpdf.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_testpdf_unit_tests = b.addRunArtifact(testpdf_unit_tests);

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_simd_unit_tests.step);
    test_step.dependOn(&run_decompress_unit_tests.step);
    test_step.dependOn(&run_parser_unit_tests.step);
    test_step.dependOn(&run_xref_unit_tests.step);
    test_step.dependOn(&run_encoding_unit_tests.step);
    test_step.dependOn(&run_interpreter_unit_tests.step);
    test_step.dependOn(&run_testpdf_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // Benchmark
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    const bench_cmd = b.addRunArtifact(bench);
    bench_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);
}
