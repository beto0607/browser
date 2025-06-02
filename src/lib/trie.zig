const std = @import("std");
const testing = std.testing;
const mem = std.mem;

pub fn Node(comptime T: type) type {
    return struct {
        children: [256]?*@This(),
        keyInParent: u8,
        isTerminal: bool,
        value: ?T,
    };
}
pub fn init(comptime T: type, allocator: mem.Allocator) !*Node(T) {
    var trie = try allocator.create(Node(T));
    trie.children = [_]?*Node(T){null} ** 256;
    trie.keyInParent = 0;
    trie.isTerminal = false;
    trie.value = null;
    return trie;
}

pub fn find(comptime T: type, node: *Node(T), key: []const u8) ?*Node(T) {
    var currentNode: *Node(T) = node;
    for (key) |k| {
        if (currentNode.children[k]) |newNode| {
            currentNode = newNode;
        } else {
            return null;
        }
    }
    return currentNode;
}

pub fn insert(comptime T: type, allocator: mem.Allocator, node: *Node(T), key: []const u8, value: T) !void {
    var currentNode: *Node(T) = node;
    for (key) |k| {
        if (currentNode.children[k]) |existingNode| {
            currentNode = existingNode;
            continue;
        }
        var newNode = try allocator.create(Node(T));

        newNode.children = [_]?*Node(T){null} ** 256;
        newNode.keyInParent = k;
        newNode.isTerminal = false;
        newNode.value = null;

        currentNode.children[k] = newNode;
        currentNode = currentNode.children[k].?;
        newNode = undefined;
    }
    currentNode.isTerminal = true;
    currentNode.value = value;
}

// TODO: Test if deletion works.
//
// pub fn delete(comptime T: type, node: Node(T), key: []const u8) Node(T) {
//     if (key.len == 0) {
//         if (node.isTerminal) {
//             node.isTerminal = false;
//             node.value = null;
//         }
//         for (node.children) |child| {
//             if (child != null) {
//                 return child;
//             }
//         }
//         return null;
//     }
//     const k = @as(u8, key[0]);
//     node.children[k] = TrieDeletion(T, node.children[k], key[1..]);
// }

pub fn deinit(comptime T: type, allocator: mem.Allocator, node: *Node(T)) void {
    for (node.children) |child| {
        if (child) |c| {
            deinit(T, allocator, c);
        }
    }
    allocator.destroy(node);
}

test "insert" {
    var trie = try testing.allocator.create(Node(u8));
    trie.children = [_]?*Node(u8){null} ** 256;
    trie.keyInParent = 0;
    trie.isTerminal = false;
    trie.value = null;

    defer deinit(u8, testing.allocator, trie);

    try insert(u8, testing.allocator, trie, "test", 123);
    try insert(u8, testing.allocator, trie, "tess", 123);

    try testing.expect(trie.children['t'] != null);
    try testing.expect(trie.children['t'].?.children['e'] != null);
    try testing.expect(trie.children['t'].?.children['e'].?.children['s'] != null);
    try testing.expect(trie.children['t'].?.children['e'].?.children['s'].?.children['t'] != null);
    try testing.expect(trie.children['t'].?.children['e'].?.children['s'].?.children['t'].?.value == 123);
    try testing.expect(trie.children['t'].?.children['e'].?.children['s'].?.children['s'] != null);
    try testing.expect(trie.children['t'].?.children['e'].?.children['s'].?.children['s'].?.value == 123);
}

test "find" {
    var trie = try testing.allocator.create(Node(u8));
    trie.children = [_]?*Node(u8){null} ** 256;
    trie.keyInParent = 0;
    trie.isTerminal = false;
    trie.value = null;

    defer deinit(u8, testing.allocator, trie);

    try insert(u8, testing.allocator, trie, "test", 123);
    try insert(u8, testing.allocator, trie, "tess", 25);

    try testing.expect(find(u8, trie, "test") != null);
    try testing.expect(find(u8, trie, "test").?.value == 123);
    try testing.expect(find(u8, trie, "tess") != null);
    try testing.expect(find(u8, trie, "tess").?.value == 25);
    try testing.expect(find(u8, trie, "tesr") == null);
    try testing.expect(find(u8, trie, "tes") != null);
    try testing.expect(find(u8, trie, "tes").?.isTerminal == false);
    try testing.expect(find(u8, trie, "tes").?.value == null);
}
