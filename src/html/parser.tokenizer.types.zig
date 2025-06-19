const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;

pub const TokenSink = fn (token: Token) anyerror!void;

pub const DoctypeToken = struct {
    name: []u21,
    public_id: []u21,
    system_id: []u21,
    force_quirks: bool,
};

pub const TagToken = struct {
    name: []u21,
    self_closing: bool,
    attributes: []*TagAttribute,
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

    const Tag = meta.Tag(Token);

    fn Value(comptime tag: Tag) type {
        return meta.Child(meta.TagPayload(Token, tag));
    }

    fn initPtr(comptime tag: Tag, payload_ptr: meta.TagPayload(Token, tag)) !Token {
        return @unionInit(Token, @tagName(tag), payload_ptr);
    }

    pub fn create(allocator: mem.Allocator, comptime tokenType: TokenTypes) !Token {
        switch (tokenType) {
            .doctype => {
                const doctypeToken: *DoctypeToken = try allocator.create(Token.Value(Tag.doctype));
                doctypeToken.force_quirks = false;
                doctypeToken.name = try allocator.alloc(u21, 2);
                doctypeToken.public_id = try allocator.alloc(u21, 2);
                doctypeToken.system_id = try allocator.alloc(u21, 2);

                return try initPtr(Tag.doctype, doctypeToken);
            },
            .eof => {
                const eofToken: *EOFToken = try allocator.create(Token.Value(Tag.eof));
                return try initPtr(Tag.eof, eofToken);
            },
            .character => {
                const characterToken: *CharacterToken = try allocator.create(Token.Value(Tag.character));
                return try initPtr(Tag.character, characterToken);
            },
            .start_tag => {
                const startTagToken: *TagToken = try allocator.create(Token.Value(Tag.start_tag));
                startTagToken.self_closing = false;
                startTagToken.name = try allocator.alloc(u21, 0);
                startTagToken.attributes = try allocator.alloc(*TagAttribute, 0);
                return try initPtr(Tag.start_tag, startTagToken);
            },
            .end_tag => {
                const endTagToken: *TagToken = try allocator.create(Token.Value(Tag.end_tag));
                endTagToken.self_closing = false;
                endTagToken.name = try allocator.alloc(u21, 0);
                endTagToken.attributes = try allocator.alloc(*TagAttribute, 0);
                return try initPtr(Tag.end_tag, endTagToken);
            },
            .comment => {
                const commentToken: *CommentToken = try allocator.create(Token.Value(Tag.comment));
                commentToken.data = try allocator.alloc(u21, 0);
                return try initPtr(Tag.comment, commentToken);
            },
        }
    }

    pub fn destroy(self: @This(), allocator: mem.Allocator) void {
        switch (self) {
            .doctype => |t| {
                allocator.free(t.system_id);
                allocator.free(t.public_id);
                allocator.free(t.name);
                allocator.destroy(self.doctype);
            },
            .eof => {
                allocator.destroy(self.eof);
            },
            .character => {
                allocator.destroy(self.character);
            },
            .start_tag => |t| {
                for (t.attributes) |attr| {
                    allocator.free(attr.name);
                    allocator.free(attr.value);
                    allocator.destroy(attr);
                }

                allocator.free(t.attributes);
                allocator.free(t.name);
                allocator.destroy(self.start_tag);
            },
            .end_tag => |t| {
                for (t.attributes) |attr| {
                    allocator.free(attr.name);
                    allocator.free(attr.value);
                    allocator.destroy(attr);
                }
                allocator.free(t.attributes);
                allocator.free(t.name);
                allocator.destroy(self.end_tag);
            },
            .comment => |t| {
                allocator.free(t.data);
                allocator.destroy(self.comment);
            },
        }
    }
};

test "should create doctype token" {
    var t = try Token.create(testing.allocator, .doctype);
    t.destroy(testing.allocator);
}
test "should create start tag token" {
    var t = try Token.create(testing.allocator, .start_tag);
    t.destroy(testing.allocator);
}
test "should create end tag token" {
    var t = try Token.create(testing.allocator, .end_tag);
    t.destroy(testing.allocator);
}
test "should create comment token" {
    var t = try Token.create(testing.allocator, .comment);
    t.destroy(testing.allocator);
}
test "should create character token" {
    var t = try Token.create(testing.allocator, .character);
    t.destroy(testing.allocator);
}
test "should create eof token" {
    var t = try Token.create(testing.allocator, .eof);
    t.destroy(testing.allocator);
}
