const std = @import("std");

const Node = union(enum) {
    const Tag = std.meta.Tag(Node);

    Foo: *struct { shared: u8, text: []const u8 },
    Bar: *struct { shared: u8, num: f64 },

    pub fn Value(comptime tag: Tag) type {
        return std.meta.Child(std.meta.TagPayload(Node, tag));
    }

    pub fn initPtr(comptime tag: Tag, payload_ptr: std.meta.TagPayload(Node, tag)) !Node {
        return @unionInit(Node, @tagName(tag), payload_ptr);
    }

    pub fn init(alloc: std.mem.Allocator, comptime tag: Tag, payload_value: Value(tag)) !Node {
        const ptr = try alloc.create(@TypeOf(payload_value));
        ptr.* = payload_value;
        return initPtr(tag, ptr);
    }

    pub fn deinit(self: *Node, alloc: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |n| alloc.destroy(n),
        }
    }

    pub fn selfPrint(self: *Node) void {
        switch (self.*) {
            inline else => |n| std.debug.print("{any}\n", .{n}),
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const Foo = Node.Value(.Foo);
    const foo = try allocator.create(Foo);
    foo.* = .{ .shared = 1, .text = "hello" };

    var foo_node = try Node.initPtr(.Foo, foo);
    defer foo_node.deinit(allocator);
    foo_node.selfPrint();

    var bar_node = try Node.init(allocator, .Bar, .{ .shared = 1, .num = 4.2 });
    defer bar_node.deinit(allocator);
    bar_node.selfPrint();
}
