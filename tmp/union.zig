const std = @import("std");
const mem = std.mem;
const testing = std.testing;

/// https://html.spec.whatwg.org/multipage/parsing.html#tokenization
const TokenType = enum {
    doctype,
    start_tag,
    end_tag,
    comment,
    character,
    eof,
};

pub const DoctypeToken = struct {
    name: []u21,
    public_id: []u21,
    system_id: []u21,
    force_quirks: bool,
};

pub const TagToken = struct {
    name: []u21,
    self_closing: bool,
    attributes: []TagAttribute,
};

pub const TagAttribute = struct {
    name: []u21,
    value: []u21,
};

pub const CommentToken = struct {
    data: []u21,
};
pub const CharacterToken = struct {
    data: u21,
};
pub const EOFToken = struct {
    index: u64,
};

pub const TokenTypes = enum {
    doctype,
    start_tag,
    end_tag,
    comment,
    character,
    eof,
};

pub const Token = union(TokenTypes) {
    doctype: *DoctypeToken,
    start_tag: *TagToken,
    end_tag: *TagToken,
    comment: *CommentToken,
    character: *CharacterToken,
    eof: *EOFToken,

    const Tag = std.meta.Tag(Token);

    pub fn Value(comptime tag: Tag) type {
        // return (std.meta.TagPayload(Token, tag));
        return std.meta.Child(std.meta.TagPayload(Token, tag));
    }

    pub fn initPtr(comptime tag: Tag, payload_ptr: std.meta.TagPayload(Token, tag)) !Token {
        return @unionInit(Token, @tagName(tag), payload_ptr);
    }

    pub fn create(allocator: mem.Allocator, comptime tokenType: TokenTypes) !Token {
        switch (tokenType) {
            .doctype => {
                const tmp = Token.Value(Tag.doctype);
                const doctypeToken: *DoctypeToken = try allocator.create(tmp);

                doctypeToken.force_quirks = false;
                doctypeToken.name = try allocator.alloc(u21, 2);
                doctypeToken.public_id = try allocator.alloc(u21, 2);
                doctypeToken.system_id = try allocator.alloc(u21, 2);
                const result = try initPtr(Tag.doctype, doctypeToken);
                return result;
            },
            else => {
                unreachable;
            },
        }
    }
    pub fn destroy(self: @This(), allocator: mem.Allocator) void {
        switch (self) {
            .doctype => |t| {
                std.debug.print("ahhhhh", .{});
                allocator.free(t.system_id);
                allocator.free(t.public_id);
                allocator.free(t.name);
                allocator.destroy(self.doctype);
                // allocator.destroy(self);
            },
            else => {
                std.debug.print("ahhhh2", .{});
            },
        }
    }

    pub fn selfPrint(self: *Token) void {
        switch (self.*) {
            inline else => |n| std.debug.print("{any}\n", .{n}),
        }
    }
};

fn createDoctypeToken(allocator: mem.Allocator, force_quirks: bool) !Token {
    var token = try Token.create(allocator, .doctype);
    token.doctype.force_quirks = force_quirks;
    std.debug.print("d--: {*}\n", .{token.doctype});
    token.selfPrint();
    return token;
}
test "teet" {
    const t = try createDoctypeToken(testing.allocator, true);
    // const tt = try createDoctypeToken(testing.allocator, false);

    t.destroy(testing.allocator);
    // tt.destroy(testing.allocator);
    // testing.allocator.destroy(t);
    // testing.allocator.destroy(tt);
}
