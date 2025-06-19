const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const lib_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const trie_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/trie.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("trie", trie_mod);

    const html_entities_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/html_entities.zig"),
        .target = target,
        .optimize = optimize,
    });
    html_entities_mod.addImport("trie", trie_mod);
    lib_mod.addImport("html_entities", html_entities_mod);

    const html_tokenizer_mod = b.createModule(.{
        .root_source_file = b.path("src/html/parser.tokenizer.zig"),
        .target = target,
        .optimize = optimize,
    });
    html_tokenizer_mod.addImport("trie", trie_mod);
    html_tokenizer_mod.addImport("html_entities", html_entities_mod);
    lib_mod.addImport("html_tokenizer", html_tokenizer_mod);

    // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Modules can depend on one another using the `std.Build.Module.addImport` function.
    // This is what allows Zig source code to use `@import("foo")` where 'foo' is not a
    // file path. In this case, we set up `exe_mod` to import `lib_mod`.
    exe_mod.addImport("browser_lib", lib_mod);
    exe_mod.addImport("trie", trie_mod);

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "browser",
        .root_module = lib_mod,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const trie_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "trie",
        .root_module = trie_mod,
    });

    b.installArtifact(trie_lib);

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "browser",
        .root_module = exe_mod,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const trie_unit_tests = b.addTest(.{
        .root_module = trie_mod,
        .name = "trie tests",
    });

    const run_trie_unit_tests = b.addRunArtifact(trie_unit_tests);

    const html_entities_unit_tests = b.addTest(.{
        .root_module = html_entities_mod,
        .name = "html_entities tests",
    });

    const run_html_entities_unit_tests = b.addRunArtifact(html_entities_unit_tests);

    const html_tokenizer_unit_tests = b.addTest(.{
        .root_module = html_tokenizer_mod,
        .name = "html_tokenizer tests",
        .filter = "tokenizer",
    });
    const run_html_tokenizer_unit_tests = b.addRunArtifact(html_tokenizer_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    exe_unit_tests.root_module.addImport("trie", trie_mod);
    exe_unit_tests.root_module.addImport("html_entities", html_entities_mod);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_trie_unit_tests.step);
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_html_entities_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_html_tokenizer_unit_tests.step);

    const test_html_entities_step = b.step("test-html-entities", "Run unit tests on html-entities");
    test_html_entities_step.dependOn(&run_html_entities_unit_tests.step);

    const test_html_tokenizer_step = b.step("test-html-tokenizer", "Run unit tests on html-tokenizer");
    test_html_tokenizer_step.dependOn(&run_html_tokenizer_unit_tests.step);
}
