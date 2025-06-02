const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const trie = @import("trie");

const html_entities_const = @import("./html_entities.const.zig");
pub const Entity = html_entities_const.Entity;

pub const EntitiesTree = struct {
    tree: *trie.Node(Entity),
    number_items: u64,
    allocator: mem.Allocator,

    const Self = @This();

    pub fn init(allocator: mem.Allocator) !Self {
        const root = try trie.init(Entity, allocator);

        var obj: Self = .{
            .tree = root,
            .number_items = 0,
            .allocator = allocator,
        };
        try obj.loadTree(allocator, root);
        return obj;
    }

    pub fn deinit(self: *Self) void {
        trie.deinit(Entity, self.allocator, self.tree);
    }

    fn loadTree(self: *Self, allocator: mem.Allocator, tree: *trie.Node(Entity)) !void {
        for (html_entities_const.html_entities) |entity| {
            try trie.insert(Entity, allocator, tree, entity.name, entity);
            self.number_items += 1;
        }
    }

    pub fn getNamedEntity(self: *Self, name: []const u8) ?*trie.Node(Entity) {
        const item = trie.find(Entity, self.tree, name);
        if (item) |i| {
            return i;
        }
        return null;
    }
};

test "should create entities tree" {
    var entitiesTree = try EntitiesTree.init(testing.allocator);
    defer entitiesTree.deinit();
    try testing.expectEqual(2231, entitiesTree.number_items);
    try testing.expect(entitiesTree.getNamedEntity("&Aring") != null);
    try testing.expect(entitiesTree.getNamedEntity("&zwnj;") != null);
    try testing.expect(entitiesTree.getNamedEntity("&Ar").?.value == null);
    try testing.expect(entitiesTree.getNamedEntity("&bbbb") == null);
    try testing.expect(entitiesTree.getNamedEntity("&").?.isTerminal == false);
    try testing.expect(entitiesTree.getNamedEntity("&Aring;").?.isTerminal);
}
