const std = @import("std");
const io = std.io;
const mem = std.mem;
const print = std.debug.print;
const testing = std.testing;
const unicode = std.unicode;

const parser_stream = @import("./parser.stream.zig");
const HTMLParserErrors = @import("./parser.errors.zig").HTMLParserErrors;
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
    current_open_markup: std.ArrayList(u21),
    after_doctype_string: std.ArrayList(u21),
    adjusted_current_node: bool,

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
            .current_open_markup = std.ArrayList(u21).init(allocator),
            .after_doctype_string = std.ArrayList(u21).init(allocator),
            .adjusted_current_node = false,
        };
    }

    pub fn parseStream(self: *Self, sink: tokenizer_types.TokenSink) !void {
        print("parseStream...\n", .{});
        while (try self.input_stream.next()) |item| {
            try self.consumeItem(item, sink);
            self.current_character = item;
        }
    }

    fn consumeItem(self: *Self, item: parser_stream.InputStreamItem, sink: tokenizer_types.TokenSink) anyerror!void {
        switch (self.state) {
            .data => {
                if (item.eof) {
                    try self.emitEOFToken(sink);
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
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.emitToken(.{ .character = .{ .data = item.code_point } }, sink);
                    },
                    else => {
                        try self.emitToken(.{ .character = .{ .data = item.code_point } }, sink);
                    },
                }
            },
            .tag_open => {
                if (item.eof) {
                    try self.emitError(HTMLParserErrors.EofBeforeTagName);
                    try self.emitToken(.{ .character = .{ .data = 0x003c } }, sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0021 => { // EXCLAMATION MARK (!)
                        self.state = .markup_declaration_open;
                        try self.current_open_markup.ensureTotalCapacity(7);
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
                        try self.emitError(HTMLParserErrors.UnexpectedQuestionMarkInsteadOfTagName);
                        self.current_token = .{ .comment = .{ .data = try self.allocator.alloc(u21, 0) } };
                        self.state = .bogus_comment;
                        try self.consumeItem(item, sink);
                    },
                    else => {
                        try self.emitError(HTMLParserErrors.InvalidFirstCharacterOfTagName);
                        // emit LESS-THAN SIGN
                        try self.emitToken(.{ .character = .{ .data = 0x003c } }, sink);
                        self.state = .data;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .end_tag_open => {
                if (item.eof) {
                    try self.emitError(HTMLParserErrors.EofBeforeTagName);
                    // emit LESS-THAN SIGN
                    try self.emitToken(.{ .character = .{ .data = 0x003c } }, sink);
                    // emit SOLIDUS
                    try self.emitToken(.{ .character = .{ .data = 0x002f } }, sink);
                    try self.emitEOFToken(sink);
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
                        try self.emitError(HTMLParserErrors.MissingEndTagName);
                        self.state = .data;
                    },
                    else => {
                        try self.emitError(HTMLParserErrors.InvalidFirstCharacterOfTagName);
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
                    try self.emitError(HTMLParserErrors.EOFInTag);
                    try self.emitEOFToken(sink);
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
                        try self.emitCurrentToken(sink);
                    },
                    0x0041...0x005a => { // ASCII upper alpha
                        const lowercase_code_point = item.code_point + 0x0020;
                        try self.appendCharacterToCurrentTagName(lowercase_code_point);
                    },
                    0x0000 => { // NULL
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
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
                        try self.emitError(HTMLParserErrors.UnexpectedEqualsSignBeforeAttributeName);

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
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.appendCharacterToCurrentAttributeName(0xfffd);
                    },
                    0x0022, // QUOTATION MARK (")
                    0x0027, //APOSTROPHE (')
                    0x003C, //LESS-THAN SIGN (<
                    => {
                        try self.emitError(HTMLParserErrors.UnexpectedCharacterInAttributeName);
                        try self.appendCharacterToCurrentAttributeName(item.code_point);
                    },
                    else => {
                        try self.appendCharacterToCurrentAttributeName(item.code_point);
                    },
                }
            },
            .after_attribute_name => {
                if (item.eof) {
                    try self.emitError(HTMLParserErrors.EOFInTag);
                    try self.emitEOFToken(sink);
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
                        try self.emitCurrentToken(sink);
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
                        try self.emitError(HTMLParserErrors.MissingAttributeValue);
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => {
                        self.state = .attribute_value_unquoted;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .attribute_value_double_quoted => {
                if (item.eof) {
                    try self.emitError(HTMLParserErrors.EOFInTag);
                    try self.emitEOFToken(sink);
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
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.appendCharacterToCurrentAttributeValue(0xfffd);
                    },
                    else => {
                        try self.appendCharacterToCurrentAttributeValue(item.code_point);
                    },
                }
            },
            .attribute_value_single_quoted => {
                if (item.eof) {
                    try self.emitError(HTMLParserErrors.EOFInTag);
                    try self.emitEOFToken(sink);
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
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.appendCharacterToCurrentAttributeValue(0xfffd);
                    },
                    else => {
                        try self.appendCharacterToCurrentAttributeValue(item.code_point);
                    },
                }
            },
            .attribute_value_unquoted => {
                if (item.eof) {
                    try self.emitError(HTMLParserErrors.EOFInTag);
                    try self.emitEOFToken(sink);
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
                        try self.emitCurrentToken(sink);
                    },
                    0x0000, // NULL
                    => {
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.appendCharacterToCurrentAttributeValue(0xfffd);
                    },
                    0x0022, //QUOTATION MARK (")
                    0x0027, //APOSTROPHE (')
                    0x003C, //LESS-THAN SIGN (<)
                    0x003D, //EQUALS SIGN (=)
                    0x0060, //GRAVE ACCENT (`)
                    => {
                        try self.emitError(HTMLParserErrors.UnexpectedCharacterInUnquotedAttributeValue);
                        try self.appendCharacterToCurrentAttributeValue(item.code_point);
                    },
                    else => {
                        try self.appendCharacterToCurrentAttributeValue(item.code_point);
                    },
                }
            },
            .after_attribute_value_quoted => {
                if (item.eof) {
                    try self.emitError(HTMLParserErrors.EOFInTag);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0009, // CHARACTER TABULATION (tab)
                    0x000A, // LINE FEED (LF)
                    0x000C, // FORM FEED (FF)
                    0x0020, // SPACE
                    => {
                        //Switch to the before attribute name state.
                        self.state = .before_attribute_name;
                    },
                    0x002F, //SOLIDUS (/)
                    => {
                        //Switch to the self-closing start tag state.
                        self.state = .self_closing_start_tag;
                    },
                    0x003E, //GREATER-THAN SIGN (>)
                    => {
                        //Switch to the data state. Emit the current tag token.
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => {
                        // This is a missing-whitespace-between-attributes parse error. Reconsume in the before attribute name state.
                        try self.emitError(HTMLParserErrors.MissingWhitespaceBetweenAttributes);
                        self.state = .before_attribute_name;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .self_closing_start_tag => {
                if (item.eof) {
                    try self.emitError(HTMLParserErrors.EOFInTag);
                    try self.emitEOFToken(sink);
                    return;
                }

                switch (item.code_point) {
                    0x003E, //GREATER-THAN SIGN (>)
                    => {
                        //Set the self-closing flag of the current tag token. Switch to the data state. Emit the current tag token.
                        switch (self.current_token.?) {
                            .start_tag => {
                                self.current_token.?.start_tag.self_closing = true;
                            },
                            .end_tag => {
                                self.current_token.?.end_tag.self_closing = true;
                            },
                            else => {},
                        }
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => {
                        // This is an unexpected-solidus-in-tag parse error. Reconsume in the before attribute name state.
                        try self.emitError(HTMLParserErrors.UnexpectedSolidusInTag);
                        self.state = .before_attribute_name;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .bogus_comment => {
                if (item.eof) {
                    // Emit the comment. Emit an end-of-file token.
                    try self.emitCurrentToken(sink);

                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x003E, //GREATER-THAN SIGN (>)
                    => {
                        // Switch to the data state. Emit the current comment token.
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    0x0000, //NULL
                    => {
                        // Append a 0xFFFD REPLACEMENT CHARACTER character to the comment token's data.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.appendCharacterToCurrentComment(0xfffd);
                    },
                    else => {
                        // Append the current input character to the comment token's data.
                        try self.appendCharacterToCurrentComment(item.code_point);
                    },
                }
            },
            .markup_declaration_open => {
                if (item.eof) {
                    try self.handleIncorrectlyOpenedComment(sink);
                    return;
                }
                try self.current_open_markup.append(item.code_point);
                switch (self.current_open_markup.items[0]) {
                    0x002D => { //HYPHEN-MINUS (-)
                        if (self.current_open_markup.items.len == 1) {
                            // wait for 2nd char
                            return;
                        }
                        if (self.current_open_markup.items.len == 2 and
                            self.current_open_markup.items[1] == 0x002D)
                        {
                            // Consume those two characters, create a comment token whose data is the empty string, and switch to the comment start state.
                            self.current_open_markup.clearRetainingCapacity();
                            self.current_token = .{ .comment = .{ .data = &[_]u21{} } };
                            self.state = .comment_start;
                            return;
                        }
                        try self.handleIncorrectlyOpenedComment(sink);
                    },
                    // ASCII case-insensitive match for the word "DOCTYPE"
                    0x0044, 0x0064 => { // d or D character. pointing to DOCTYPE
                        // Consume those characters and switch to the DOCTYPE state.
                        const doctype_string = [_]u21{ 0x0044, 0x004F, 0x0043, 0x0054, 0x0059, 0x0050, 0x0045 };
                        const index = self.current_open_markup.items.len - 1;
                        if (self.current_open_markup.items[index] != doctype_string[index] and
                            self.current_open_markup.items[index] != doctype_string[index] + 0x0020)
                        {
                            // unexpected character, cancel processing of doctype
                            try self.handleIncorrectlyOpenedComment(sink);
                            return;
                        }
                        if (self.current_open_markup.items.len == doctype_string.len) {
                            // word is complete
                            self.current_open_markup.clearRetainingCapacity();
                            self.state = .doctype;
                            return;
                        }
                    },
                    // The string "[CDATA[" (the five uppercase letters "CDATA" with a 0x005B LEFT SQUARE BRACKET character before and after)
                    0x005B => {
                        // Consume those characters. If there is an adjusted current node and it is not an element in the HTML namespace,
                        // then switch to the CDATA section state. Otherwise, this is a cdata-in-html-content parse error. Create a
                        // comment token whose data is the "[CDATA[" string. Switch to the bogus comment state.
                        const cdata = [_]u21{ 0x005B, 0x0043, 0x0044, 0x0041, 0x0054, 0x0041, 0x005B };
                        const index = self.current_open_markup.items.len - 1;
                        if (self.current_open_markup.items[index] != cdata[index]) {
                            // unexpected character, cancel processing of doctype
                            try self.handleIncorrectlyOpenedComment(sink);
                            return;
                        }
                        self.current_open_markup.clearRetainingCapacity();
                        // TODO: check for an element not in the HTML namespace
                        if (self.adjusted_current_node) {
                            self.state = .cdata_section;
                            return;
                        }

                        try self.emitError(HTMLParserErrors.CdataInHtmlContent);

                        self.current_token = .{ .comment = .{ .data = try self.allocator.dupe(u21, &cdata) } };
                        self.state = .bogus_comment;
                        return;
                    },
                    else => {
                        try self.handleIncorrectlyOpenedComment(sink);
                    },
                }
            },
            .comment_start => {
                if (item.eof) { // Anything else
                    // Reconsume in the comment state.
                    self.state = .comment;
                    try self.consumeItem(item, sink);
                    return;
                }
                switch (item.code_point) {
                    0x002d => { //  HYPHEN-MINUS (-)
                        // Switch to the comment start dash state.
                        self.state = .comment_start_dash;
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // Switch to the data state. Emit the current comment token.
                        try self.emitError(HTMLParserErrors.AbruptClosingOfEmptyComment);
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => { // Anything else
                        // Reconsume in the comment state.
                        self.state = .comment;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .comment_start_dash => {
                if (item.eof) {
                    // This is an eof-in-comment parse error. Emit the current comment token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInComment);

                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x002d => { // HYPHEN-MINUS (-)
                        // Switch to the comment end state.
                        self.start = .comment_end_dash;
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // Switch to the data state. Emit the current comment token.
                        try self.emitError(HTMLParserErrors.AbruptClosingOfEmptyComment);
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => { // Anything else
                        // Append a 0x002D HYPHEN-MINUS character (-) to the comment token's data. Reconsume in the comment state.
                        try self.appendCharacterToCurrentComment(0x002d);
                        self.state = .comment;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .comment => {
                if (item.eof) {
                    // Emit the current comment token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInComment);
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x003C => { // LESS-THAN SIGN (<)
                        // Append the current input character to the comment token's data. Switch to the comment less-than sign state.
                        try self.appendCharacterToCurrentComment(self.current_character.?.code_point);
                        self.state = .comment_less_than_sign;
                    },
                    0x002D => { // HYPHEN-MINUS (-)
                        // Switch to the comment end dash state.
                        self.state = .comment_end_dash;
                    },
                    0x0000 => { // NULL
                        // Append a 0xFFFD REPLACEMENT CHARACTER character to the comment token's data.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.appendCharacterToCurrentComment(0xfffd);
                    },
                    else => { // Anything else
                        // Append the current input character to the comment token's data.
                        try self.appendCharacterToCurrentComment(item.code_point);
                    },
                }
            },
            .comment_less_than_sign => {
                switch (item.code_point) {
                    0x0021 => { // EXCLAMATION MARK (!)
                        // Append the current input character to the comment token's data. Switch to the comment less-than sign bang state.
                        try self.appendCharacterToCurrentComment(self.current_character.?.code_point);
                        self.state = .comment_less_than_sign_bang;
                    },
                    0x003C => { // LESS-THAN SIGN (<)
                        // Append the current input character to the comment token's data.
                        try self.appendCharacterToCurrentComment(self.current_character.?.code_point);
                    },
                    else => { // Anything else
                        // Reconsume in the comment state.
                        self.state = .comment;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .comment_less_than_sign_bang => {
                switch (item.code_point) {
                    0x002D => { // HYPHEN-MINUS (-)
                        // Switch to the comment less-than sign bang dash state.
                        self.state = .comment_less_than_sign_bang_dash;
                    },
                    else => { // Anything else
                        // Reconsume in the comment state.
                        self.state = .comment;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .comment_less_than_sign_bang_dash => {
                switch (item.code_point) {
                    0x002D => { //HYPHEN-MINUS (-)
                        // Switch to the comment less-than sign bang dash dash state.
                        self.state = .comment_less_than_sign_bang_dash_dash;
                    },
                    else => { // Anything else
                        // Reconsume in the comment end dash state.
                        self.state = .comment_end_dash;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .comment_less_than_sign_bang_dash_dash => {
                if (item.eof) { // EOF
                    // Reconsume in the comment end state.
                    self.state = .comment_end;
                    try self.consumeItem(item, sink);
                    return;
                }
                switch (item.code_point) {
                    0x003E => { // GREATER-THAN SIGN (>)
                        // Reconsume in the comment end state.
                        self.state = .comment_end;
                        try self.consumeItem(item, sink);
                    },
                    else => { // Anything else
                        // This is a nested-comment parse error. Reconsume in the comment end state.
                        try self.emitError(HTMLParserErrors.NestedComment);
                        self.state = .comment_end;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .comment_end_dash => {
                if (item.eof) { // EOF
                    // Emit the current comment token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInComment);
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x002D => { // HYPHEN-MINUS (-)
                        // Switch to the comment end state.
                        self.state = .comment_end;
                    },
                    else => { // Anything else
                        // Append a 0x002D HYPHEN-MINUS character (-) to the comment token's data. Reconsume in the comment state.
                        try self.appendCharacterToCurrentComment(0x002d);
                        self.state = .comment;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .comment_end => {
                if (item.eof) { // EOF
                    // Emit the current comment token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInComment);

                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x003E => { // GREATER-THAN SIGN (>)
                        // Switch to the data state. Emit the current comment token.
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    0x0021 => { //EXCLAMATION MARK (!)
                        // Switch to the comment end bang state.
                        self.state = .comment_end_bang;
                    },
                    0x002D => { //HYPHEN-MINUS (-)
                        // Append a 0x002D HYPHEN-MINUS character (-) to the comment token's data.
                        try self.appendCharacterToCurrentComment(0x002d);
                    },
                    else => { // Anything else
                        // Append two 0x002D HYPHEN-MINUS characters (-) to the comment token's data. Reconsume in the comment state.
                        try self.appendCharacterToCurrentComment(0x002d);
                        try self.appendCharacterToCurrentComment(0x002d);
                        self.state = .comment;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .comment_end_bang => {
                if (item.eof) { // EOF
                    // Emit the current comment token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInComment);
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x002d => { // 0x002D HYPHEN-MINUS (-)
                        // Append two 0x002D HYPHEN-MINUS characters (-) and a 0x0021 EXCLAMATION MARK character (!) to the comment token's data. Switch to the comment end dash state.
                        try self.appendCharacterToCurrentComment(0x002d);
                        try self.appendCharacterToCurrentComment(0x002d);
                        try self.appendCharacterToCurrentComment(0x0021);
                        self.state = .comment_end_dash;
                    },
                    0x003e => { // 0x003E GREATER-THAN SIGN (>)
                        // Switch to the data state. Emit the current comment token.
                        try self.emitError(HTMLParserErrors.IncorrectlyClosedComment);
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => { // Anything else
                        // Append two 0x002D HYPHEN-MINUS characters (-) and a 0x0021 EXCLAMATION MARK character (!) to the comment token's data. Reconsume in the comment state.
                        try self.appendCharacterToCurrentComment(0x002d);
                        try self.appendCharacterToCurrentComment(0x002d);
                        try self.appendCharacterToCurrentComment(0x0021);
                        self.state = .comment;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .doctype => {
                if (item.eof) { // EOF
                    // Create a new DOCTYPE token. Set its force-quirks flag to on. Emit the current token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInDoctype);
                    self.current_token = .{ .doctype = .{
                        .force_quirks = true,
                    } };
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0009, //CHARACTER TABULATION (tab)
                    0x000A, //LINE FEED (LF)
                    0x000C, //FORM FEED (FF)
                    0x0020, //SPACE
                    => {
                        // Switch to the before DOCTYPE name state.
                        self.state = .before_doctype_name;
                    },
                    0x003E => { //GREATER-THAN SIGN (>)
                        // Reconsume in the before DOCTYPE name state.
                        self.state = .before_doctype_name;
                        try self.consumeItem(item, sink);
                    },
                    else => { // Anything else
                        // Reconsume in the before DOCTYPE name state.
                        try self.emitError(HTMLParserErrors.MissingWhitespaceBeforeDoctypeName);
                        self.state = .before_doctype_name;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .before_doctype_name => {
                if (item.eof) { // EOF
                    // Create a new DOCTYPE token. Set its force-quirks flag to on. Emit the current token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInDoctype);
                    self.current_token = .{ .doctype = .{
                        .force_quirks = true,
                    } };
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0009, //CHARACTER TABULATION (tab)
                    0x000A, //LINE FEED (LF)
                    0x000C, //FORM FEED (FF)
                    0x0020, //SPACE
                    => {
                        // Ignore the character.
                    },
                    0x0041...0x005a, // ASCII upper alpha
                    => {
                        // Create a new DOCTYPE token. Set the token's name to the lowercase version of the current input character (add 0x0020 to the character's code point). Switch to the DOCTYPE name state.
                        self.current_token = .{
                            .doctype = .{
                                .force_quirks = false,
                                .name = [_]u21{item.code_point + 0x0020},
                            },
                        };
                        self.state = .doctype_name;
                    },
                    0x0000 => { // NULL
                        // Create a new DOCTYPE token. Set the token's name to a 0xFFFD REPLACEMENT CHARACTER character. Switch to the DOCTYPE name state.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        self.current_token = .{
                            .doctype = .{
                                .force_quirks = false,
                                .name = [_]u21{0xfffd},
                            },
                        };
                        self.state = .doctype_name;
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // Create a new DOCTYPE token. Set its force-quirks flag to on. Switch to the data state. Emit the current token.
                        try self.emitError(HTMLParserErrors.MissingDoctypeName);
                        self.current_token = .{
                            .doctype = .{
                                .force_quirks = false,
                                .name = [_]u21{0xfffd},
                            },
                        };
                        try self.emitCurrentToken(sink);
                        self.state = .data;
                    },
                    else => { // Anything else
                        // Create a new DOCTYPE token. Set the token's name to the current input character. Switch to the DOCTYPE name state.
                        self.current_token = .{
                            .doctype = .{
                                .force_quirks = false,
                                .name = [_]u21{item.code_point},
                            },
                        };
                        self.state = .doctype_name;
                    },
                }
            },
            .doctype_name => {
                if (item.eof) { // EOF
                    // Set the current DOCTYPE token's force-quirks flag to on. Emit the current DOCTYPE token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInDoctype);
                    self.current_token.?.doctype.force_quirks = true;
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0009, // CHARACTER TABULATION (tab)
                    0x000A, // LINE FEED (LF)
                    0x000C, // FORM FEED (FF)
                    0x0020, // SPACE
                    => {
                        // Switch to the after DOCTYPE name state.
                        self.state = .after_doctype_name;
                        try self.after_doctype_string.ensureTotalCapacityPrecise(6);
                        self.after_doctype_string.clearRetainingCapacity();
                    },
                    0x003E, // GREATER-THAN SIGN (>)
                    => {
                        // Switch to the data state. Emit the current DOCTYPE token.
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    0x0041...0x005a, // ASCII upper alpha
                    => {
                        // Append the lowercase version of the current input character (add 0x0020 to the character's code point) to the current DOCTYPE token's name.
                        try self.appendCharacterToDoctypeName(item.code_point + 0x0020);
                    },
                    0x0000, // NULL
                    => {
                        // Append a 0xFFFD REPLACEMENT CHARACTER character to the current DOCTYPE token's name.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.appendCharacterToDoctypeName(0xfffd);
                    },
                    else => { // Anything else
                        // Append the current input character to the current DOCTYPE token's name.
                        try self.appendCharacterToDoctypeName(item.code_point);
                    },
                }
            },
            .after_doctype_name => {
                if (item.eof) { // EOF
                    if (self.after_doctype_string.items.len > 0) {
                        // EOF while reading word SYSTEM/PUBLIC
                        try self.emitError(HTMLParserErrors.InvalidCharacterSequenceAfterDoctypeName);
                        self.current_token.?.doctype.force_quirks = true;

                        self.state = .bogus_doctype;
                        for (self.after_doctype_string.items, 0..) |char, index| {
                            try self.consumeItem(.{ .byte = 0, .code_point = char, .eof = index == self.after_doctype_string.items.len - 1 }, sink);
                        }
                        self.after_doctype_string.clearRetainingCapacity();
                        return;
                    }
                    // This is an eof-in-doctype parse error. Set the current DOCTYPE token's force-quirks flag to on. Emit the current DOCTYPE token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInDoctype);
                    self.current_token.?.doctype.force_quirks = true;
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0009, // CHARACTER TABULATION (tab)
                    0x000A, // LINE FEED (LF)
                    0x000C, // FORM FEED (FF)
                    0x0020, // SPACE
                    => {
                        // Ignore the character.
                    },
                    0x003E, // GREATER-THAN SIGN (>)
                    => {
                        // Switch to the data state. Emit the current DOCTYPE token.
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => { // Anything else
                        try self.after_doctype_string.append(item.code_point);
                        const index = self.after_doctype_string.items.len - 1;
                        // If the six characters starting from the current input character are an ASCII case-insensitive match for the word "PUBLIC", then consume those characters and switch to the after DOCTYPE public keyword state.
                        const public_const = [_]u21{ 0x0050, 0x0055, 0x0042, 0x004C, 0x0049, 0x0043 };
                        if (self.after_doctype_string.items[index] == public_const[index] or
                            self.after_doctype_string.items[index] == public_const[index] + 0x0020)
                        {
                            if (self.after_doctype_string.items.len == 6) {
                                self.after_doctype_string.clearRetainingCapacity();
                                self.state = .after_doctype_public_keyword;
                                return;
                            }
                        }

                        // Otherwise, if the six characters starting from the current input character are an ASCII case-insensitive match for the word "SYSTEM", then consume those characters and switch to the after DOCTYPE system keyword state.
                        const system_const = [_]u21{ 0x0053, 0x0059, 0x0053, 0x0054, 0x0045, 0x004D };
                        if (self.after_doctype_string.items[index] == system_const[index] or
                            self.after_doctype_string.items[index] == system_const[index] + 0x0020)
                        {
                            if (self.after_doctype_string.items.len == 6) {
                                self.after_doctype_string.clearRetainingCapacity();
                                self.state = .after_doctype_system_keyword;
                                return;
                            }
                        }
                        // Otherwise, this is an invalid-character-sequence-after-doctype-name parse error. Set the current DOCTYPE token's force-quirks flag to on. Reconsume in the bogus DOCTYPE state.
                        try self.emitError(HTMLParserErrors.InvalidCharacterSequenceAfterDoctypeName);
                        self.current_token.?.doctype.force_quirks = true;

                        self.state = .bogus_doctype;
                        for (self.after_doctype_string.items) |char| {
                            try self.consumeItem(.{ .byte = 0, .code_point = char, .eof = false }, sink);
                        }
                        self.after_doctype_string.clearRetainingCapacity();
                    },
                }
            },
            .after_doctype_public_keyword => {
                if (item.eof) { // EOF
                    // This is an eof-in-doctype parse error. Set the current DOCTYPE token's force-quirks flag to on. Emit the current DOCTYPE token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInDoctype);
                    self.current_token.?.doctype.force_quirks = true;
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0009, //CHARACTER TABULATION (tab)
                    0x000A, //LINE FEED (LF)
                    0x000C, //FORM FEED (FF)
                    0x0020, //SPACE
                    => {
                        //     Switch to the before DOCTYPE public identifier state.
                        self.state = .before_doctype_public_identifier;
                    },
                    0x0022, //QUOTATION MARK (")
                    => {
                        // This is a missing-whitespace-after-doctype-public-keyword parse error. Set the current DOCTYPE token's public identifier to the empty string (not missing), then switch to the DOCTYPE public identifier (double-quoted) state.
                        try self.emitError(HTMLParserErrors.MissingWhitespaceAfterDoctypePublicKeyword);
                        self.current_token.?.doctype.publid_id = [_]u21{};
                        self.state = .doctype_public_identifier_double_quoted;
                    },
                    0x0027, //APOSTROPHE (')
                    => {
                        // This is a missing-whitespace-after-doctype-public-keyword parse error. Set the current DOCTYPE token's public identifier to the empty string (not missing), then switch to the DOCTYPE public identifier (single-quoted) state.
                        try self.emitError(HTMLParserErrors.MissingWhitespaceAfterDoctypePublicKeyword);
                        self.current_token.?.doctype.publid_id = [_]u21{};
                        self.state = .doctype_public_identifier_single_quoted;
                    },
                    0x003E, //GREATER-THAN SIGN (>)
                    => {
                        // This is a missing-doctype-public-identifier parse error. Set the current DOCTYPE token's force-quirks flag to on. Switch to the data state. Emit the current DOCTYPE token.
                        try self.emitError(HTMLParserErrors.MissingDoctypePublicIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => {
                        // This is a missing-quote-before-doctype-public-identifier parse error. Set the current DOCTYPE token's force-quirks flag to on. Reconsume in the bogus DOCTYPE state.
                        try self.emitError(HTMLParserErrors.MissingQuoteBeforeDoctypePublicIdentifier);
                        self.current_token.?.doctype = true;
                        self.state = .bogus_doctype;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .before_doctype_public_identifier => {
                if (item.eof) { // EOF
                    //     This is an eof-in-doctype parse error. Set the current DOCTYPE token's force-quirks flag to on. Emit the current DOCTYPE token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInDoctype);
                    self.current_token.?.doctype.force_quirks = true;
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0009, //CHARACTER TABULATION (tab)
                    0x000A, //LINE FEED (LF)
                    0x000C, //FORM FEED (FF)
                    0x0020, //SPACE
                    => {
                        //     Ignore the character.
                    },
                    0x0022, //QUOTATION MARK (")
                    => {
                        //     Set the current DOCTYPE token's public identifier to the empty string (not missing), then switch to the DOCTYPE public identifier (double-quoted) state.
                        self.current_token.?.doctype.publid_id = [_]u21{};
                        self.state = .doctype_public_identifier_double_quoted;
                    },
                    0x0027, //APOSTROPHE (')
                    => {
                        //     Set the current DOCTYPE token's public identifier to the empty string (not missing), then switch to the DOCTYPE public identifier (single-quoted) state.
                        self.current_token.?.doctype.publid_id = [_]u21{};
                        self.state = .doctype_public_identifier_single_quoted;
                    },
                    0x003E, //GREATER-THAN SIGN (>)
                    => {
                        //     This is a missing-doctype-public-identifier parse error. Set the current DOCTYPE token's force-quirks flag to on. Switch to the data state. Emit the current DOCTYPE token.
                        try self.emitError(HTMLParserErrors.MissingDoctypePublicIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = true;
                        try self.emitCurrentToken(sink);
                    },
                    else => { // Anything else
                        //     This is a missing-quote-before-doctype-public-identifier parse error. Set the current DOCTYPE token's force-quirks flag to on. Reconsume in the bogus DOCTYPE state.
                        try self.emitError(HTMLParserErrors.MissingQuoteBeforeDoctypePublicIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .bogus_doctype;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .doctype_public_identifier_double_quoted => {
                if (item.eof) { // EOF
                    //     This is an eof-in-doctype parse error. Set the current DOCTYPE token's force-quirks flag to on. Emit the current DOCTYPE token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInDoctype);
                    self.current_token.?.doctype.force_quirks = true;
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0022, //QUOTATION MARK (")
                    => {
                        //     Switch to the after DOCTYPE public identifier state.
                        self.state = .after_doctype_public_identifier;
                    },
                    0x0000, //NULL
                    => {
                        //     This is an unexpected-null-character parse error. Append a 0xFFFD REPLACEMENT CHARACTER character to the current DOCTYPE token's public identifier.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.appendCharacterToDoctypePublicIdentifier(0xfffd);
                    },
                    0x003E, //GREATER-THAN SIGN (>)
                    => {
                        //     This is an abrupt-doctype-public-identifier parse error. Set the current DOCTYPE token's force-quirks flag to on. Switch to the data state. Emit the current DOCTYPE token.
                        self.emitError(HTMLParserErrors.AbruptDoctypePublicIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => { // Anything else
                        //     Append the current input character to the current DOCTYPE token's public identifier.
                        try self.appendCharacterToDoctypePublicIdentifier(item.code_point);
                    },
                }
            },
            .doctype_public_identifier_single_quoted => {
                if (item.eof) { // EOF
                    // This is an eof-in-doctype parse error. Set the current DOCTYPE token's force-quirks flag to on. Emit the current DOCTYPE token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInDoctype);
                    self.current_token.?.doctype.force_quirks = true;
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0027, //APOSTROPHE (')
                    => {
                        //     Switch to the after DOCTYPE public identifier state.
                        self.state = .after_doctype_public_identifier;
                    },
                    0x0000, //NULL
                    => {
                        //     This is an unexpected-null-character parse error. Append a 0xFFFD REPLACEMENT CHARACTER character to the current DOCTYPE token's public identifier.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.appendCharacterToDoctypePublicIdentifier(0xfffd);
                    },
                    0x003E, //GREATER-THAN SIGN (>)
                    => {
                        //     This is an abrupt-doctype-public-identifier parse error. Set the current DOCTYPE token's force-quirks flag to on. Switch to the data state. Emit the current DOCTYPE token.
                        try self.emitError(HTMLParserErrors.AbruptDoctypePublicIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => { // Anything else
                        //     Append the current input character to the current DOCTYPE token's public identifier.
                        try self.appendCharacterToDoctypePublicIdentifier(item.code_point);
                    },
                }
            },
            .after_doctype_public_identifier => {
                if (item.eof) { // EOF
                    //     This is an eof-in-doctype parse error. Set the current DOCTYPE token's force-quirks flag to on. Emit the current DOCTYPE token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInDoctype);
                    self.current_token.?.doctype.force_quirks = true;
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0009, //CHARACTER TABULATION (tab)
                    0x000A, //LINE FEED (LF)
                    0x000C, //FORM FEED (FF)
                    0x0020, //SPACE
                    => {
                        //     Switch to the between DOCTYPE public and system identifiers state.
                        self.state = .between_doctype_public_and_system_identifiers;
                    },
                    0x003E, //GREATER-THAN SIGN (>)
                    => {
                        //     Switch to the data state. Emit the current DOCTYPE token.
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    0x0022, //QUOTATION MARK (")
                    => {
                        //     This is a missing-whitespace-between-doctype-public-and-system-identifiers parse error. Set the current DOCTYPE token's system identifier to the empty string (not missing), then switch to the DOCTYPE system identifier (double-quoted) state.
                        try self.emitError(HTMLParserErrors.MissingWhitespaceBetweenDoctypePublicAndSystemIdentifiers);
                        self.current_token.?.doctype.system_id = [_]u21{};
                        self.state = .doctype_system_identifier_double_quoted;
                    },
                    0x0027, //APOSTROPHE (')
                    => {
                        //     This is a missing-whitespace-between-doctype-public-and-system-identifiers parse error. Set the current DOCTYPE token's system identifier to the empty string (not missing), then switch to the DOCTYPE system identifier (single-quoted) state.
                        try self.emitError(HTMLParserErrors.MissingWhitespaceBetweenDoctypePublicAndSystemIdentifiers);
                        self.current_token.?.doctype.system_id = [_]u21{};
                        self.state = .doctype_system_identifier_single_quoted;
                    },
                    else => { // Anything else
                        //     This is a missing-quote-before-doctype-system-identifier parse error. Set the current DOCTYPE token's force-quirks flag to on. Reconsume in the bogus DOCTYPE state.,
                        try self.emitError(HTMLParserErrors.MissingQuoteBeforeDoctypeSystemIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .bogus_doctype;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .between_doctype_public_and_system_identifiers => {
                if (item.eof) { // EOF
                    //     This is an eof-in-doctype parse error. Set the current DOCTYPE token's force-quirks flag to on. Emit the current DOCTYPE token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInDoctype);
                    self.current_token.?.doctype.force_quirks = true;
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0009, //CHARACTER TABULATION (tab)
                    0x000A, //LINE FEED (LF)
                    0x000C, //FORM FEED (FF)
                    0x0020, //SPACE
                    => {
                        //     Ignore the character.
                    },
                    0x003E, //GREATER-THAN SIGN (>)
                    => {
                        //     Switch to the data state. Emit the current DOCTYPE token.
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    0x0022, //QUOTATION MARK (")
                    => {
                        //     Set the current DOCTYPE token's system identifier to the empty string (not missing), then switch to the DOCTYPE system identifier (double-quoted) state.
                        self.current_token.?.doctype.system_id = [_]u21{};
                        self.state = .doctype_system_identifier_double_quoted;
                    },
                    0x0027, //APOSTROPHE (')
                    => {
                        //     Set the current DOCTYPE token's system identifier to the empty string (not missing), then switch to the DOCTYPE system identifier (single-quoted) state.
                        self.current_token.?.doctype.system_id = [_]u21{};
                        self.state = .doctype_system_identifier_single_quoted;
                    },
                    else => { // Anything else
                        //     This is a missing-quote-before-doctype-system-identifier parse error. Set the current DOCTYPE token's force-quirks flag to on. Reconsume in the bogus DOCTYPE state.
                        try self.emitError(HTMLParserErrors.MissingQuoteBeforeDoctypeSystemIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .bogus_doctype;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .after_doctype_system_keyword => {
                if (item.eof) { // EOF
                    //     This is an eof-in-doctype parse error. Set the current DOCTYPE token's force-quirks flag to on. Emit the current DOCTYPE token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInDoctype);
                    self.current_token.?.doctype.force_quirks = true;
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0009, //CHARACTER TABULATION (tab)
                    0x000A, //LINE FEED (LF)
                    0x000C, //FORM FEED (FF)
                    0x0020, //SPACE
                    => {
                        //     Switch to the before DOCTYPE system identifier state.
                        self.state = .before_doctype_system_identifier;
                    },
                    0x0022, //QUOTATION MARK (")
                    => {
                        //     This is a missing-whitespace-after-doctype-system-keyword parse error. Set the current DOCTYPE token's system identifier to the empty string (not missing), then switch to the DOCTYPE system identifier (double-quoted) state.
                        try self.emitError(HTMLParserErrors.MissingWhitespaceAfterDoctypeSystemKeyword);
                        self.current_token.?.doctype.system_id = [_]u21{};
                        self.state = .doctype_system_identifier_double_quoted;
                    },
                    0x0027, //APOSTROPHE (')
                    => {
                        //     This is a missing-whitespace-after-doctype-system-keyword parse error. Set the current DOCTYPE token's system identifier to the empty string (not missing), then switch to the DOCTYPE system identifier (single-quoted) state.
                        try self.emitError(HTMLParserErrors.MissingWhitespaceAfterDoctypeSystemKeyword);
                        self.current_token.?.doctype.system_id = [_]u21{};
                        self.state = .doctype_system_identifier_single_quoted;
                    },
                    0x003E, //GREATER-THAN SIGN (>)
                    => {
                        //     This is a missing-doctype-system-identifier parse error. Set the current DOCTYPE token's force-quirks flag to on. Switch to the data state. Emit the current DOCTYPE token.
                        try self.emitError(HTMLParserErrors.MissingDoctypeSystemIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => { // Anything else
                        //     This is a missing-quote-before-doctype-system-identifier parse error. Set the current DOCTYPE token's force-quirks flag to on. Reconsume in the bogus DOCTYPE state.
                        try self.emitError(HTMLParserErrors.MissingQuoteBeforeDoctypeSystemIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .bogus_doctype;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .before_doctype_system_identifier => {
                if (item.eof) { // EOF
                    //     This is an eof-in-doctype parse error. Set the current DOCTYPE token's force-quirks flag to on. Emit the current DOCTYPE token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInDoctype);
                    self.current_token.?.doctype.force_quirks = true;
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0009, //CHARACTER TABULATION (tab)
                    0x000A, //LINE FEED (LF)
                    0x000C, //FORM FEED (FF)
                    0x0020, //SPACE
                    => {
                        //     Ignore the character.
                    },
                    0x0022, //QUOTATION MARK (")
                    => {
                        //     Set the current DOCTYPE token's system identifier to the empty string (not missing), then switch to the DOCTYPE system identifier (double-quoted) state.
                        self.current_token.?.doctype.system_id = [_]u21{};
                        self.state = .doctype_system_identifier_double_quoted;
                    },
                    0x0027, //APOSTROPHE (')
                    => {
                        //     Set the current DOCTYPE token's system identifier to the empty string (not missing), then switch to the DOCTYPE system identifier (single-quoted) state.
                        self.current_token.?.doctype.system_id = [_]u21{};
                        self.state = .doctype_system_identifier_single_quoted;
                    },
                    0x003E, //GREATER-THAN SIGN (>)
                    => {
                        //     This is a missing-doctype-system-identifier parse error. Set the current DOCTYPE token's force-quirks flag to on. Switch to the data state. Emit the current DOCTYPE token.
                        try self.emitError(HTMLParserErrors.MissingDoctypeSystemIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => { // Anything else
                        //     This is a missing-quote-before-doctype-system-identifier parse error. Set the current DOCTYPE token's force-quirks flag to on. Reconsume in the bogus DOCTYPE state.
                        try self.emitError(HTMLParserErrors.MissingQuoteBeforeDoctypeSystemIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .bogus_doctype;

                        try self.consumeItem(item, sink);
                    },
                }
            },
            .doctype_system_identifier_double_quoted => {
                if (item.eof) { // EOF
                    //     This is an eof-in-doctype parse error. Set the current DOCTYPE token's force-quirks flag to on. Emit the current DOCTYPE token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInDoctype);
                    self.current_token.?.doctype.force_quirks = true;
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0022, //QUOTATION MARK (")
                    => {
                        //     Switch to the after DOCTYPE system identifier state.
                        self.state = .after_doctype_system_identifier;
                    },
                    0x0000, //NULL
                    => {
                        //     This is an unexpected-null-character parse error. Append a 0xFFFD REPLACEMENT CHARACTER character to the current DOCTYPE token's system identifier.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.appendCharacterToDoctypeSystemIdentifier(0xfffd);
                    },
                    0x003E, //GREATER-THAN SIGN (>)
                    => {
                        //     This is an abrupt-doctype-system-identifier parse error. Set the current DOCTYPE token's force-quirks flag to on. Switch to the data state. Emit the current DOCTYPE token.
                        try self.emitError(HTMLParserErrors.AbruptDoctypeSystemIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => { // Anything else
                        //     Append the current input character to the current DOCTYPE token's system identifier.
                        try self.appendCharacterToDoctypeSystemIdentifier(item.code_point);
                    },
                }
            },
            .doctype_system_identifier_single_quoted => {
                if (item.eof) { // EOF
                    //     This is an eof-in-doctype parse error. Set the current DOCTYPE token's force-quirks flag to on. Emit the current DOCTYPE token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInDoctype);
                    self.current_token.?.doctype.force_quirks = true;
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0027, //APOSTROPHE (')
                    => {
                        //     Switch to the after DOCTYPE system identifier state.
                        self.state = .after_doctype_system_identifier;
                    },
                    0x0000, //NULL
                    => {
                        //     This is an unexpected-null-character parse error. Append a 0xFFFD REPLACEMENT CHARACTER character to the current DOCTYPE token's system identifier.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.appendCharacterToDoctypeSystemIdentifier(0xfffd);
                    },
                    0x003E, //GREATER-THAN SIGN (>)
                    => {
                        //     This is an abrupt-doctype-system-identifier parse error. Set the current DOCTYPE token's force-quirks flag to on. Switch to the data state. Emit the current DOCTYPE token.
                        try self.emitError(HTMLParserErrors.AbruptDoctypeSystemIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => { // Anything else
                        //     Append the current input character to the current DOCTYPE token's system identifier.
                        try self.appendCharacterToDoctypeSystemIdentifier(item.code_point);
                    },
                }
            },
            .after_doctype_system_identifier => {
                if (item.eof) {
                    // EOF
                    //     This is an eof-in-doctype parse error. Set the current DOCTYPE token's force-quirks flag to on. Emit the current DOCTYPE token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInDoctype);
                    self.current_token.?.doctype.force_quirks = true;
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0009, //CHARACTER TABULATION (tab)
                    0x000A, //LINE FEED (LF)
                    0x000C, //FORM FEED (FF)
                    0x0020, //SPACE
                    => {
                        //     Ignore the character.
                    },
                    0x003E, //GREATER-THAN SIGN (>)
                    => {
                        //     Switch to the data state. Emit the current DOCTYPE token.
                        self.state = .data;
                        self.emitCurrentToken(sink);
                    },
                    else => { // Anything else
                        //     This is an unexpected-character-after-doctype-system-identifier parse error. Reconsume in the bogus DOCTYPE state. (This does not set the current DOCTYPE token's force-quirks flag to on.)
                        try self.emitError(HTMLParserErrors.UnexpectedCharacterAfterDoctypeSystemIdentifier);
                        self.state = .bogus_doctype;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .bogus_doctype => {
                if (item.eof) { // EOF
                    //     Emit the DOCTYPE token. Emit an end-of-file token.
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x003E, //GREATER-THAN SIGN (>)
                    => {
                        //     Switch to the data state. Emit the DOCTYPE token.
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    0x0000, //NULL
                    => {
                        //     This is an unexpected-null-character parse error. Ignore the character.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                    },
                    else => { // Anything else
                        //     Ignore the character.
                    },
                }
            },
            else => {
                print("current status was: {}\n", .{self.state});
                // Not implemented yet
                unreachable;
            },
        }
    }

    fn emitEOFToken(self: *Self, sink: tokenizer_types.TokenSink) !void {
        const t: tokenizer_types.Token = .{ .eof = .{
            .index = self.input_stream.index,
        } };
        try sink(t);
        try self.tokens.append(t);
    }

    fn emitToken(self: *Self, token: tokenizer_types.Token, sink: tokenizer_types.TokenSink) !void {
        try sink(token);
        try self.tokens.append(token);
    }

    fn emitCurrentToken(self: *Self, sink: tokenizer_types.TokenSink) !void {
        try sink(self.current_token.?);
        try self.tokens.append(self.current_token.?);
        self.current_token = undefined;
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
            else => {
                unreachable;
            },
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
            else => {
                unreachable;
            },
        }
        self.current_attribute = null;
    }

    fn appendCharacterToCurrentComment(self: *Self, code_point: u21) !void {
        switch (self.current_token.?) {
            .comment => {
                const new_len = self.current_token.?.comment.data.len + 1;
                var new_data = try self.allocator.realloc(self.current_token.?.comment.data, new_len);
                new_data[new_data.len - 1] = code_point;
                self.current_token.?.comment.data = new_data;
            },
            else => {
                unreachable;
            },
        }
    }

    fn appendCharacterToDoctypeName(self: *Self, code_point: u21) !void {
        switch (self.current_token.?) {
            .doctype => {
                const new_len = self.current_token.?.doctype.name.len + 1;
                var new_data = try self.allocator.realloc(self.current_token.?.doctype.name, new_len);
                new_data[new_data.len - 1] = code_point;
                self.current_token.?.doctype.name = new_data;
            },
            else => {
                unreachable;
            },
        }
    }
    fn appendCharacterToDoctypePublicIdentifier(self: *Self, code_point: u21) !void {
        switch (self.current_token.?) {
            .doctype => {
                const new_len = self.current_token.?.doctype.publid_id.len + 1;
                var new_data = try self.allocator.realloc(self.current_token.?.doctype.publid_id, new_len);
                new_data[new_data.len - 1] = code_point;
                self.current_token.?.doctype.publid_id = new_data;
            },
            else => {
                unreachable;
            },
        }
    }
    fn appendCharacterToDoctypeSystemIdentifier(self: *Self, code_point: u21) !void {
        switch (self.current_token.?) {
            .doctype => {
                const new_len = self.current_token.?.doctype.system_id.len + 1;
                var new_data = try self.allocator.realloc(self.current_token.?.doctype.system_id, new_len);
                new_data[new_data.len - 1] = code_point;
                self.current_token.?.doctype.system_id = new_data;
            },
            else => {
                unreachable;
            },
        }
    }

    fn handleIncorrectlyOpenedComment(self: *Self, sink: tokenizer_types.TokenSink) !void {
        //Create a comment token whose data is the empty string. Switch to the bogus comment state (don't consume anything in the current state).
        // TODO: emit incorrectly-opened-comment parse error.

        self.current_token = .{ .comment = .{ .data = &[_]u21{} } };
        self.state = .comment_start;
        for (self.current_open_markup.items) |code_point| {
            var new_item: parser_stream.InputStreamItem = .{ .byte = 0, .code_point = code_point, .eof = false };
            try self.consumeItem(new_item, sink);
            new_item = undefined;
        }
        self.current_open_markup.clearRetainingCapacity();
    }

    fn emitError(self: *Self, parseError: HTMLParserErrors) !void {
        //TODO: create emition system
        _ = self; // autofix
        _ = parseError; // autofix
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
