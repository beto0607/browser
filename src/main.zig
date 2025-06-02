//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const testing = std.testing;

const trie = @import("trie");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) unreachable;
    }

    var root = try trie.InitTrie(u8, allocator);
    root.keyInParent = 0;
    defer trie.TrieDealocate(u8, allocator, root);

    try trie.TrieInsert(u8, allocator, root, "test", 123);
    std.debug.print("yay!\n", .{});
    // // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    // std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
    //
    // // stdout is for the actual output of your application, for example if you
    // // are implementing gzip, then only the compressed bytes should be sent to
    // // stdout, not any debugging messages.
    // const stdout_file = std.io.getStdOut().writer();
    // var bw = std.io.bufferedWriter(stdout_file);
    // const stdout = bw.writer();
    //
    // try stdout.print("Run `zig build test` to run the tests.\n", .{});
    //
    // try bw.flush(); // Don't forget to flush!
}

test "simple test" {
    //     var list = std.ArrayList(i32).init(std.testing.allocator);
    //     defer list.deinit(); // Try commenting this out and see if zig detects the memory leak!
    //     try list.append(42);
    //     try std.testing.expectEqual(@as(i32, 42), list.pop());
    try testing.expect(true);
}
//
// test "use other module" {
//     try std.testing.expectEqual(@as(i32, 150), lib.add(100, 50));
// }
//
// test "fuzz example" {
//     const Context = struct {
//         fn testOne(context: @This(), input: []const u8) anyerror!void {
//             _ = context;
//             // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
//             try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
//         }
//     };
//     try std.testing.fuzz(Context{}, Context.testOne, .{});
// }
//
//
// /// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
// const lib = @import("browser_lib");
