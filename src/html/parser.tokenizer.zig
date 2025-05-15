const std = @import("std");
const io = std.io;
const mem = std.mem;
const print = std.debug.print;
const testing = std.testing;
const unicode = std.unicode;

const parser_stream = @import("./parser.stream.zig");
const tokenizer_types = @import("./parser.tokenizer.types.zig");

const HTMLTokenizer = struct {
    state: tokenizer_types.TokenizerState,
    return_state: tokenizer_types.TokenizerState,
    allocator: mem.Allocator,
    input_stream: parser_stream.HTMLParserInputStream,
    tokens: std.ArrayList(tokenizer_types.Token),
    current_character: ?parser_stream.InputStreamItem,
    current_token: ?tokenizer_types.Token,
    current_attribute: ?tokenizer_types.TagAttribute,

    const Self = @This();

    pub fn init(allocator: mem.Allocator, reader: io.AnyReader) Self {
        return .{
            .state = .data,
            .return_state = .data,
            .allocator = allocator,
            .input_stream = parser_stream.HTMLParserInputStream.init(reader),
            .current_character = null,
            .tokens = std.ArrayList(tokenizer_types.Token).init(allocator),
            .current_token = null,
            .current_attribute = null,
        };
    }

    pub fn parseStream(self: *Self, sink: tokenizer_types.TokenSink) !void {
        print("parseStream...\n", .{});
        while (try self.input_stream.next()) |item| {
            // print("item... {c}\n", .{item.byte});
            try self.consumeItem(item, sink);
            self.current_character = item;
        }
        // TODO: handle EOF
    }

    fn consumeItem(self: *Self, item: parser_stream.InputStreamItem, sink: tokenizer_types.TokenSink) !void {
        var t: tokenizer_types.Token = undefined;
        switch (self.state) {
            .data => {
                if (item.eof) {
                    t = .{ .eof = .{ .index = self.input_stream.index } };
                    try sink(t);
                    try self.tokens.append(t);
                    return;
                }
                switch (item.code_point) {
                    0x0026 => { // AMPERSAND &
                        self.return_state = .data;
                        self.state = .character_reference;
                    },
                    0x003c => { // LESS-THAN SIGN <
                        self.state = .tag_open;
                    },
                    0x0000 => { // NULL
                        // TODO: emit unexpected-null-character
                        t = .{ .character = .{ .data = item.code_point } };
                        try sink(t);
                        try self.tokens.append(t);
                    },
                    else => {
                        t = .{ .character = .{ .data = item.code_point } };
                        try sink(t);
                        try self.tokens.append(t);
                    },
                }
            },
            .tag_open => {
                if (item.eof) {
                    // TODO: emit eof-before-tag-name
                    t = .{ .character = .{ .data = 0x003c } }; // emit LESS-THAN SIGN
                    try sink(t);
                    try self.tokens.append(t);
                    t = .{ .eof = .{ .index = self.input_stream.index } };
                    try sink(t);
                    try self.tokens.append(t);
                    return;
                }
                switch (item.code_point) {
                    0x0021 => { // EXCLAMATION MARK (!)
                        self.state = .markup_declaration_open;
                    },
                    0x002f => { // SOLIDUS (/)
                        self.state = .end_tag_open;
                    },
                    0x0041...0x005a, // ASCII upper alpha
                    0x0061...0x007a, // ASCII lower alpha
                    => { // ASCII alpha
                        self.current_token = .{
                            .start_tag = .{
                                .name = try self.allocator.alloc(u21, 0),
                                .self_closing = false,
                                .attributes = undefined,
                            },
                        };
                        self.state = .tag_name;
                        try self.consumeItem(item, sink);
                    },
                    0x003f => { // QUESTION MARK (?)
                        // TODO: emit unexpected-question-mark-instead-of-tag-name
                        self.current_token = .{ .comment = .{ .data = try self.allocator.alloc(u21, 0) } };
                        self.state = .bogus_comment;
                        try self.consumeItem(item, sink);
                    },
                    else => {
                        // TODO: emit  invalid-first-character-of-tag-name
                        t = .{ .character = .{ .data = 0x003c } }; // emit LESS-THANK SIGN
                        try sink(t);
                        try self.tokens.append(t);
                        self.state = .data;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .end_tag_open => {
                if (item.eof) {
                    // TODO: emit eof-before-tag-name
                    t = .{ .character = .{ .data = 0x003c } }; // emit LESS-THANK SIGN
                    try sink(t);
                    try self.tokens.append(t);
                    t = .{ .character = .{ .data = 0x002f } }; // emit SOLIDUS
                    try sink(t);
                    try self.tokens.append(t);
                    t = .{ .eof = .{ .index = self.input_stream.index } };
                    try sink(t);
                    try self.tokens.append(t);
                    return;
                }
                switch (item.code_point) {
                    0x0041...0x005a, // ASCII upper alpha
                    0x0061...0x007a, // ASCII lower alpha
                    => { // ASCII alpha
                        self.current_token = .{
                            .end_tag = .{
                                .name = try self.allocator.alloc(u21, 0),
                                .self_closing = false,
                                .attributes = undefined,
                            },
                        };
                        self.state = .tag_name;
                        try self.consumeItem(item, sink);
                    },
                    0x003e => { // GREATER-THAN SIGN (>)
                        // TODO: emit missing-end-tag-name
                        self.state = .data;
                    },
                    else => {
                        // TODO: emit invalid-first-character-of-tag-name
                        self.current_token = .{ .comment = .{
                            .data = try self.allocator.alloc(u21, 0),
                        } };
                        self.state = .bogus_comment;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .tag_name => {
                if (item.eof) {
                    // TODO: emit eof-in-tag
                    t = .{ .eof = .{ .index = self.input_stream.index } };
                    try sink(t);
                    try self.tokens.append(t);
                    return;
                }
                switch (item.code_point) {
                    0x0009, // CHARACTER TABULATION (tab)
                    0x000A, // LINE FEED (LF)
                    0x000C, // FORM FEED (FF)
                    0x0020, // SPACE
                    => {
                        self.state = .before_attribute_name;
                    },
                    0x002f => { // SOLIDUS (/)
                        self.state = .self_closing_start_tag;
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        self.state = .data;
                        if (self.current_token) |current_token| {
                            try sink(current_token);
                            try self.tokens.append(current_token);
                        }
                    },
                    0x0041...0x005a => { // ASCII upper alpha
                        const lowercase_code_point = item.code_point + 0x0020;
                        try self.appendCharacterToCurrentTagName(lowercase_code_point);
                    },
                    0x0000 => { // NULL
                        // TODO: emit unexpected-null-character
                        try self.appendCharacterToCurrentTagName(0xfffd);
                    },
                    else => {
                        try self.appendCharacterToCurrentTagName(item.code_point);
                    },
                }
            },
            .before_attribute_name => {
                if (item.eof) {
                    self.state = .after_attribute_name;
                    try self.consumeItem(item, sink);
                    return;
                }
                switch (item.code_point) {
                    0x0009, // CHARACTER TABULATION (tab)
                    0x000A, // LINE FEED (LF)
                    0x000C, // FORM FEED (FF)
                    0x0020, // SPACE
                    => {
                        return;
                    },
                    0x002f, // SOLIDUS (/)
                    0x003E, // GREATER-THAN SIGN (>)
                    => {
                        self.state = .after_attribute_name;
                        try self.consumeItem(item, sink);
                    },
                    0x003d => { // EQUALS SIGN (=)
                        // TODO: emit unexpected-equals-sign-before-attribute-name

                        self.current_attribute = .{
                            .name = try self.allocator.alloc(u21, 1),
                            .value = try self.allocator.alloc(u21, 0),
                        };
                        self.current_attribute.?.name[0] = self.current_character.?.code_point;
                        self.state = .attribute_name;
                    },
                    else => {
                        self.current_attribute = .{
                            .name = try self.allocator.alloc(u21, 0),
                            .value = try self.allocator.alloc(u21, 0),
                        };
                        self.state = .attribute_name;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .attribute_name => {
                if (item.eof) {
                    self.state = .after_attribute_name;
                    try self.consumeItem(item, sink);
                    return;
                }
                switch (item.code_point) {
                    0x0009, // CHARACTER TABULATION (tab)
                    0x000A, // LINE FEED (LF)
                    0x000C, // FORM FEED (FF)
                    0x0020, // SPACE
                    0x002f, // SOLIDUS (/)
                    0x003E, // GREATER-THAN SIGN (>)
                    => {
                        try self.appendAttributeToCurrentTag();
                        self.state = .after_attribute_name;
                        try self.consumeItem(item, sink);
                    },
                    0x003d => { // EQUALS SIGN (=)
                        self.state = .before_attribute_value;
                    },
                    0x0041...0x005a => { // ASCII upper alpha
                        const lowercase_code_point = item.code_point + 0x0020;
                        try self.appendCharacterToCurrentAttributeName(lowercase_code_point);
                    },
                    0x0000 => {
                        // TODO: emit unexpected-null-character
                        try self.appendCharacterToCurrentAttributeName(0xfffd);
                    },
                    0x0022, // QUOTATION MARK (")
                    0x0027, //APOSTROPHE (')
                    0x003C, //LESS-THAN SIGN (<
                    => {
                        //TODO: emit unexpected-character-in-attribute-name
                        try self.appendCharacterToCurrentAttributeName(item.code_point);
                    },
                    else => {
                        try self.appendCharacterToCurrentAttributeName(item.code_point);
                    },
                }
            },
            .after_attribute_name => {
                if (item.eof) {
                    // TODO: emit eof-in-tag
                    t = .{ .eof = .{ .index = self.input_stream.index } };
                    try sink(t);
                    try self.tokens.append(t);
                    return;
                }
                switch (item.code_point) {
                    0x0009, // CHARACTER TABULATION (tab)
                    0x000A, // LINE FEED (LF)
                    0x000C, // FORM FEED (FF)
                    0x0020, // SPACE
                    => {
                        // Ignore
                    },
                    0x002f => { // SOLIDUS (/)
                        self.state = .self_closing_start_tag;
                    },
                    0x003d => { // EQUALS SIGN (=)
                        self.state = .before_attribute_value;
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        self.state = .data;
                        try sink(self.current_token.?);
                    },
                    else => {
                        self.current_attribute = .{
                            .name = try self.allocator.alloc(u21, 0),
                            .value = try self.allocator.alloc(u21, 0),
                        };
                        self.state = .attribute_name;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .before_attribute_value => {
                switch (item.code_point) {
                    0x0009, // CHARACTER TABULATION (tab)
                    0x000A, // LINE FEED (LF)
                    0x000C, // FORM FEED (FF)
                    0x0020, // SPACE
                    => {
                        // Ignore
                    },
                    0x0022 => { // QUOTATION MARK (")
                        self.state = .attribute_value_double_quoted;
                    },
                    0x0027 => { // APOSTROPHE (')
                        self.state = .attribute_value_single_quoted;
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // TODO: emit missing-attribute-value
                        self.state = .data;
                        try sink(self.current_token.?);
                        try self.tokens.append(self.current_token.?);
                    },
                    else => {
                        self.state = .attribute_value_unquoted;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .attribute_value_double_quoted => {
                if (item.eof) {
                    // TODO: emit eof-in-tag
                    t = .{ .eof = .{ .index = self.input_stream.index } };
                    try sink(t);
                    try self.tokens.append(t);
                    return;
                }
                switch (item.code_point) {
                    0x0022 => { // QUOTATION MARK (")
                        self.state = .after_attribute_value_quoted;
                    },
                    0x0026 => { // AMPERSAND (&)
                        self.return_state = .attribute_value_double_quoted;
                        self.state = .character_reference;
                    },
                    0x0000 => { // NULL
                        // TODO: emit  unexpected-null-character
                        try self.appendCharacterToCurrentAttributeValue(0xfffd);
                    },
                    else => {
                        try self.appendCharacterToCurrentAttributeValue(item.code_point);
                    },
                }
            },
            .attribute_value_single_quoted => {
                if (item.eof) {
                    // TODO: emit eof-in-tag
                    t = .{ .eof = .{ .index = self.input_stream.index } };
                    try sink(t);
                    try self.tokens.append(t);
                    return;
                }
                switch (item.code_point) {
                    0x0027 => { // APOSTROPHE (')
                        self.state = .after_attribute_value_quoted;
                    },
                    0x0026 => { // AMPERSAND (&)
                        self.return_state = .attribute_value_single_quoted;
                        self.state = .character_reference;
                    },
                    0x0000 => { // NULL
                        // TODO: emit  unexpected-null-character
                        self.appendCharacterToCurrentAttributeValue(0xfffd);
                    },
                    else => {
                        self.appendCharacterToCurrentAttributeValue(item.code_point);
                    },
                }
            },
            .attribute_value_unquoted => {
                if (item.eof) {
                    // TODO: emit eof-in-tag
                    t = .{ .eof = .{ .index = self.input_stream.index } };
                    try sink(t);
                    try self.tokens.append(t);
                    return;
                }
                switch (item.code_point) {
                    0x0009, // CHARACTER TABULATION (tab)
                    0x000A, // LINE FEED (LF)
                    0x000C, // FORM FEED (FF)
                    0x0020, //SPACE
                    => {
                        self.state = .before_attribute_name;
                    },
                    0x0026, //AMPERSAND (&)
                    => {
                        self.return_state = .attribute_value_unquoted;
                        self.state = .character_reference;
                    },
                    0x003E, // GREATER-THAN SIGN (>)
                    => {
                        self.state = .data;
                        try sink(self.current_token.?);
                        try self.tokens.append(self.current_token.?);
                    },
                    0x0000, // NULL
                    => {
                        //TODO: emit unexpected-null-character parse error.
                        try self.appendCharacterToCurrentAttributeValue(0xfffd);
                    },
                    0x0022, //QUOTATION MARK (")
                    0x0027, //APOSTROPHE (')
                    0x003C, //LESS-THAN SIGN (<)
                    0x003D, //EQUALS SIGN (=)
                    0x0060, //GRAVE ACCENT (`)
                    => {
                        // TODO: emit  unexpected-character-in-unquoted-attribute-value
                        try self.appendCharacterToCurrentAttributeValue(item.code_point);
                    },
                    else => {
                        try self.appendCharacterToCurrentAttributeValue(item.code_point);
                    },
                }
            },
            else => {
                return;
            },
        }
    }

    fn appendCharacterToCurrentTagName(self: *Self, code_point: u21) !void {
        switch (self.current_token.?) {
            .start_tag => |tag| {
                var new_name = try self.allocator.realloc(tag.name, tag.name.len + 1);
                new_name[new_name.len - 1] = code_point;
                self.current_token.?.start_tag.name = new_name;
            },
            .end_tag => |tag| {
                var new_name = try self.allocator.realloc(tag.name, tag.name.len + 1);
                new_name[new_name.len - 1] = code_point;
                self.current_token.?.end_tag.name = new_name;
            },
            else => {},
        }
    }

    fn appendCharacterToCurrentAttributeName(self: *Self, code_point: u21) !void {
        const new_len = self.current_attribute.?.name.len + 1;
        var new_name = try self.allocator.realloc(self.current_attribute.?.name, new_len);
        new_name[new_name.len - 1] = code_point;
        self.current_attribute.?.name = new_name;
    }

    fn appendCharacterToCurrentAttributeValue(self: *Self, code_point: u21) !void {
        const new_len = self.current_attribute.?.value.len + 1;
        var new_name = try self.allocator.realloc(self.current_attribute.?.value, new_len);
        new_name[new_name.len - 1] = code_point;
        self.current_attribute.?.value = new_name;
    }

    fn appendAttributeToCurrentTag(self: *Self) !void {
        switch (self.current_token.?) {
            .start_tag => |tag| {
                for (tag.attributes) |attribute| {
                    if (mem.eql(u21, attribute.name, self.current_attribute.?.name)) {
                        // TODO: emit duplicate-attribute
                        self.current_attribute = null;
                        return;
                    }
                }
                const new_len = self.current_token.?.start_tag.attributes.len + 1;
                var new_attributes = try self.allocator.realloc(self.current_token.?.start_tag.attributes, new_len);
                new_attributes[new_len - 1] = self.current_attribute.?;
                self.current_token.?.start_tag.attributes = new_attributes;
            },
            .end_tag => |tag| {
                for (tag.attributes) |attribute| {
                    if (mem.eql(u21, attribute.name, self.current_attribute.?.name)) {
                        // TODO: emit duplicate-attribute
                        self.current_attribute = null;
                        return;
                    }
                }
                const new_len = self.current_token.?.end_tag.attributes.len + 1;
                var new_attributes = try self.allocator.realloc(self.current_token.?.end_tag.attributes, new_len);
                new_attributes[new_len - 1] = self.current_attribute.?;
                self.current_token.?.end_tag.attributes = new_attributes;
            },
            else => {},
        }
        self.current_attribute = null;
    }
};

test "tokenizer" {
    const input =
        "<!DOCTYPE html>\r" ++
        "<html>\n" ++
        "<head><title>Test2</title></head>\r\n" ++
        "<body>\n" ++
        "Hello, world!\r" ++
        "</body>\n" ++
        "</html>";
    const allocator = testing.allocator;
    var stream = std.io.fixedBufferStream(input);
    const reader = stream.reader().any();
    var parser = HTMLTokenizer.init(allocator, reader);
    print("testing...\n", .{});
    try parser.parseStream(testSink);
}
fn testSink(token: tokenizer_types.Token) !void {
    print("sink...\n", .{});
    switch (token) {
        .character => {
            print("{u}\n", .{token.character.data});
        },
        .comment => {
            print("{u}\n", .{token.comment.data});
        },
        .doctype => {
            print("{u}\n", .{token.doctype.name});
        },
        .eof => {
            print("eof: {d}\n", .{token.eof.index});
        },
        .start_tag, .end_tag => |tag| {
            print("tag: {u} - self closing: {}\n", .{ tag.name, tag.self_closing });
            for (tag.attributes) |attribute| {
                print("attribute: {u} - {u} \n", .{ attribute.name, attribute.value });
            }
        },
    }
}
