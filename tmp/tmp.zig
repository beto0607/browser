const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

test "testing something" {
    var arr = std.ArrayList(u21).init(testing.allocator);
    try arr.ensureTotalCapacityPrecise(7);
    defer arr.deinit();

    try testing.expectEqual(0, arr.items.len);
    try arr.append(0x0040);
    try testing.expectEqual(1, arr.items.len);

    arr.clearRetainingCapacity();
    try testing.expectEqual(0, arr.items.len);
    try arr.append(0x0040);
    try arr.append(0x3040);

    // try testing.allocator.dupe(u8, arr.items);
    var new_arr = try testing.allocator.alloc(u8, arr.items.len);
    defer testing.allocator.free(new_arr);
    for (arr.items, 0..) |item, i| {
        new_arr[i] = @intCast(item & 0xff);
    }
}
