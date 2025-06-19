const std = @import("std");
const io = std.io;
const mem = std.mem;
const print = std.debug.print;
const testing = std.testing;
const unicode = std.unicode;
const ArrayList = std.ArrayList;

const html_entities = @import("html_entities");

const HTMLParserErrors = @import("./parser.errors.zig").HTMLParserErrors;
const parser_stream = @import("./parser.stream.zig");
const tokenizer_types = @import("./parser.tokenizer.types.zig");
const tokenizer_states = @import("./parser.tokenizer.states.zig");

const HTMLTokenizer = struct {
    state: tokenizer_states.TokenizerState,
    return_state: tokenizer_states.TokenizerState,
    allocator: mem.Allocator,
    input_stream: parser_stream.HTMLParserInputStream,
    tokens: ArrayList(tokenizer_types.Token),
    current_character: ?parser_stream.InputStreamItem,
    current_token: ?tokenizer_types.Token,
    current_attribute: ?*tokenizer_types.TagAttribute,
    current_open_markup: ArrayList(u21),
    after_doctype_string: ArrayList(u21),
    temp_buffer: ArrayList(u21),
    adjusted_current_node: bool,
    html_entities_map: html_entities.EntitiesTree,
    last_entity: ?html_entities.Entity,
    character_reference_code: u64,

    const Self = @This();

    pub fn init(allocator: mem.Allocator, reader: io.AnyReader) !Self {
        return .{
            .state = .data,
            .return_state = .data,
            .allocator = allocator,
            .input_stream = parser_stream.HTMLParserInputStream.init(allocator, reader),
            .current_character = null,
            .tokens = ArrayList(tokenizer_types.Token).init(allocator),
            .current_token = null,
            .current_attribute = null,
            .current_open_markup = ArrayList(u21).init(allocator),
            .after_doctype_string = ArrayList(u21).init(allocator),
            .temp_buffer = ArrayList(u21).init(allocator),
            .adjusted_current_node = false,
            .html_entities_map = try html_entities.EntitiesTree.init(allocator),
            .last_entity = null,
            .character_reference_code = 0,
        };
    }
    pub fn destroy(self: *Self) void {
        self.html_entities_map.deinit();
        self.input_stream.destroy();
        self.current_open_markup.deinit();
        self.after_doctype_string.deinit();
        self.temp_buffer.deinit();
        for (self.tokens.items) |t| {
            t.destroy(self.allocator);
        }
        self.tokens.deinit();
    }

    pub fn parseStream(self: *Self, sink: tokenizer_types.TokenSink) !void {
        while (try self.input_stream.next()) |item| {
            try self.consumeItem(item, sink);
            self.current_character = item;
        }
    }

    fn consumeItem(self: *Self, item: parser_stream.InputStreamItem, sink: tokenizer_types.TokenSink) anyerror!void {
        switch (self.state) {
            .data => {
                if (item.eof) {
                    // Emit an end-of-file token.
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0026 => { // 0x0026 AMPERSAND (&)
                        // Set the return state to the data state. Switch to the
                        // character reference state.
                        self.return_state = .data;
                        self.state = .character_reference;
                    },
                    0x003c => { // 0x003C LESS-THAN SIGN (<)
                        // Switch to the tag open state.
                        self.state = .tag_open;
                    },
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Emit the current input character as a character
                        // token.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.emitCharacterToken(item.code_point, sink);
                    },
                    else => {
                        // Emit the current input character as a character
                        // token.
                        try self.emitCharacterToken(item.code_point, sink);
                    },
                }
            },
            .rcdata => {
                if (item.eof) { // EOF
                    // Emit an end-of-file token.
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0026 => { // 0x0026 AMPERSAND (&)
                        // Set the return state to the RCDATA state. Switch to
                        // the character reference state.
                        self.return_state = .rcdata;
                        self.state = .character_reference;
                    },
                    0x003C => { // LESS-THAN SIGN (<)
                        // Switch to the RCDATA less-than sign state.
                        self.state = .rcdata_less_than_sign;
                    },
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Emit a 0xFFFD REPLACEMENT CHARACTER character token.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.emitCharacterToken(0xfffd, sink);
                    },
                    else => { // Anything else
                        // Emit the current input character as a character token.
                        try self.emitCharacterToken(item.code_point, sink);
                    },
                }
            },
            .rawtext => {
                if (item.eof) { // EOF
                    // Emit an end-of-file token.
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x003C => { // LESS-THAN SIGN (<)
                        // Switch to the RAWTEXT less-than sign state.
                        self.state = .rawtext_less_than_sign;
                    },
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Emit a 0xFFFD REPLACEMENT CHARACTER character token.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.emitCharacterToken(0xfffd, sink);
                    },
                    else => { // Anything else
                        // Emit the current input character as a character token.
                        try self.emitCharacterToken(item.code_point, sink);
                    },
                }
            },
            .script_data => {
                if (item.eof) { // EOF
                    // Emit an end-of-file token.
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x003C => { // LESS-THAN SIGN (<)
                        // Switch to the script data less-than sign state.
                        self.state = .script_data_less_than_sign;
                    },
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Emit a 0xFFFD REPLACEMENT CHARACTER character token.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.emitCharacterToken(0xfffd, sink);
                    },
                    else => { // Anything else
                        // Emit the current input character as a character
                        // token.
                        try self.emitCharacterToken(item.code_point, sink);
                    },
                }
            },
            .plaintext => {
                if (item.eof) { // EOF
                    //     Emit an end-of-file token.
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Emit a 0xFFFD REPLACEMENT CHARACTER character token.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.emitCharacterToken(0xfffd, sink);
                    },
                    else => { // Anything else
                        // Emit the current input character as a character
                        // token.
                        try self.emitCharacterToken(item.code_point, sink);
                    },
                }
            },
            .tag_open => {
                if (item.eof) {
                    // This is an eof-before-tag-name parse error. Emit a U+003C
                    // LESS-THAN SIGN character token and an end-of-file token.
                    try self.emitError(HTMLParserErrors.EofBeforeTagName);
                    try self.emitCharacterToken(0x003c, sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0021 => { // EXCLAMATION MARK (!)
                        // Switch to the markup declaration open state.
                        self.state = .markup_declaration_open;
                        try self.current_open_markup.ensureTotalCapacity(7);
                    },
                    0x002f => { // SOLIDUS (/)
                        // Switch to the end tag open state.
                        self.state = .end_tag_open;
                    },
                    0x0041...0x005a, // ASCII upper alpha
                    0x0061...0x007a, // ASCII lower alpha
                    => { // ASCII alpha
                        // Create a new start tag token, set its tag name to the
                        // empty string. Reconsume in the tag name state.
                        try self.createStartTagToken();
                        self.state = .tag_name;
                        try self.consumeItem(item, sink);
                    },
                    0x003f => { // QUESTION MARK (?)
                        // This is an
                        // unexpected-question-mark-instead-of-tag-name parse
                        // error. Create a comment token whose data is the empty
                        // string. Reconsume in the bogus comment state.
                        try self.emitError(HTMLParserErrors.UnexpectedQuestionMarkInsteadOfTagName);
                        try self.createCommentToken();
                        self.state = .bogus_comment;
                        try self.consumeItem(item, sink);
                    },
                    else => {
                        // This is an invalid-first-character-of-tag-name parse
                        // error. Emit a U+003C LESS-THAN SIGN character token.
                        // Reconsume in the data state.
                        try self.emitError(HTMLParserErrors.InvalidFirstCharacterOfTagName);
                        try self.emitCharacterToken(0x003c, sink);
                        self.state = .data;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .end_tag_open => {
                if (item.eof) {
                    // This is an eof-before-tag-name parse error. Emit a U+003C
                    // LESS-THAN SIGN character token, a U+002F SOLIDUS
                    // character token and an end-of-file token.
                    try self.emitError(HTMLParserErrors.EofBeforeTagName);
                    try self.emitCharacterToken(0x003c, sink);
                    try self.emitCharacterToken(0x002f, sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0041...0x005a, // ASCII upper alpha
                    0x0061...0x007a, // ASCII lower alpha
                    => { // ASCII alpha
                        // Create a new end tag token, set its tag name to the
                        // empty string. Reconsume in the tag name state.
                        try self.createEndTagToken();
                        self.state = .tag_name;
                        try self.consumeItem(item, sink);
                    },
                    0x003e => { // GREATER-THAN SIGN (>)
                        // This is a missing-end-tag-name parse error. Switch to
                        // the data state.
                        try self.emitError(HTMLParserErrors.MissingEndTagName);
                        self.state = .data;
                    },
                    else => {
                        // This is an invalid-first-character-of-tag-name parse
                        // error. Create a comment token whose data is the empty
                        // string. Reconsume in the bogus comment state.
                        try self.emitError(HTMLParserErrors.InvalidFirstCharacterOfTagName);
                        try self.createCommentToken();
                        self.state = .bogus_comment;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .tag_name => {
                if (item.eof) {
                    // This is an eof-in-tag parse error. Emit an end-of-file
                    // token.
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
                        // Switch to the before attribute name state.
                        self.state = .before_attribute_name;
                    },
                    0x002f => { // SOLIDUS (/)
                        // Switch to the self-closing start tag state.
                        self.state = .self_closing_start_tag;
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // Switch to the data state. Emit the current tag token.
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    0x0041...0x005a => { // ASCII upper alpha
                        // Append the lowercase version of the current input
                        // character (add 0x0020 to the character's code point)
                        // to the current tag token's tag name.
                        try self.appendCharacterToCurrentTagName(item.code_point + 0x0020);
                    },
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Append a U+FFFD REPLACEMENT CHARACTER character to
                        // the current tag token's tag name.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.appendCharacterToCurrentTagName(0xfffd);
                    },
                    else => {
                        // Append the current input character to the current tag
                        // token's tag name.
                        try self.appendCharacterToCurrentTagName(item.code_point);
                    },
                }
            },
            .rcdata_less_than_sign => {
                switch (item.code_point) {
                    0x002F => { //SOLIDUS (/)
                        // Set the temporary buffer to the empty string. Switch
                        // to the RCDATA end tag open state.
                        self.temp_buffer.clearRetainingCapacity();
                        self.state = .rcdata_end_tag_open;
                    },
                    else => { // Anything else
                        // Emit a 0x003C LESS-THAN SIGN character token.
                        // Reconsume in the RCDATA state.
                        try self.emitCharacterToken(0x003c, sink);
                        self.state = .rcdata_end_tag_open;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .rcdata_end_tag_open => {
                switch (item.code_point) {
                    0x0041...0x005a, // ASCII upper alpha
                    0x0061...0x007a, // ASCII lower alpha
                    => { // ASCII alpha
                        // Create a new end tag token, set its tag name to the
                        // empty string. Reconsume in the RCDATA end tag name
                        // state.
                        try self.createEndTagToken();
                        self.state = .rcdata_end_tag_name;
                        try self.consumeItem(item, sink);
                    },
                    else => { // Anything else
                        // Emit a 0x003C LESS-THAN SIGN character token and a
                        // 0x002F SOLIDUS character token. Reconsume in the
                        // RCDATA state.
                        try self.emitCharacterToken(0x003c, sink);
                        try self.emitCharacterToken(0x002f, sink);
                        self.state = .rcdata;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .rcdata_end_tag_name => {
                switch (item.code_point) {
                    0x0009, //CHARACTER TABULATION (tab)
                    0x000A, //LINE FEED (LF)
                    0x000C, //FORM FEED (FF)
                    0x0020, //SPACE
                    => {
                        // If the current end tag token is an appropriate end
                        // tag token, then switch to the before attribute name
                        // state. Otherwise, treat it as per the "anything else"
                        // entry below.
                        if (self.isCurrentEndTagAppropiate()) {
                            self.state = .before_attribute_name;
                            return;
                        }
                    },
                    0x002F => { //SOLIDUS (/)
                        // If the current end tag token is an appropriate end
                        // tag token, then switch to the self-closing start tag
                        // state. Otherwise, treat it as per the "anything else"
                        // entry below.
                        if (self.isCurrentEndTagAppropiate()) {
                            self.state = .self_closing_start_tag;
                            return;
                        }
                    },
                    0x003E => { //GREATER-THAN SIGN (>)
                        // If the current end tag token is an appropriate end
                        // tag token, then switch to the data state and emit the
                        // current tag token. Otherwise, treat it as per the
                        // "anything else" entry below.
                        if (self.isCurrentEndTagAppropiate()) {
                            self.state = .data;
                            try self.emitCurrentToken(sink);
                            return;
                        }
                    },
                    0x0041...0x005a => { // ASCII upper alpha
                        // Append the lowercase version of the current input
                        // character (add 0x0020 to the character's code point)
                        // to the current tag token's tag name. Append the
                        // current input character to the temporary buffer.
                        try self.appendCharacterToCurrentTagName(item.code_point + 0x0020);
                        try self.temp_buffer.append(item.code_point);
                        return;
                    },
                    0x0061...0x007a => { // ASCII lower alpha
                        // Append the current input character to the current tag
                        // token's tag name. Append the current input character
                        // to the temporary buffer.
                        try self.appendCharacterToCurrentTagName(item.code_point);
                        try self.temp_buffer.append(item.code_point);
                        return;
                    },
                    else => { // Anything else
                    },
                }
                // Anything else
                // Emit a 0x003C LESS-THAN SIGN character token, a 0x002F
                // SOLIDUS character token, and a character token for each of
                // the characters in the temporary buffer (in the order they
                // were added to the buffer). Reconsume in the RCDATA state.

                try self.emitCharacterToken(0x003c, sink);
                try self.emitCharacterToken(0x002f, sink);
                for (self.temp_buffer.items) |value| {
                    try self.emitCharacterToken(value, sink);
                }
                self.state = .rcdata;
                try self.consumeItem(item, sink);
            },
            .rawtext_less_than_sign => {
                switch (item.code_point) {
                    0x002F => { // SOLIDUS (/)
                        // Set the temporary buffer to the empty string. Switch
                        // to the RAWTEXT end tag open state.
                        self.temp_buffer.clearRetainingCapacity();
                        self.state = .rawtext_end_tag_open;
                    },
                    else => { // Anything else
                        // Emit a 0x003C LESS-THAN SIGN character token.
                        // Reconsume in the RAWTEXT state.
                        try self.emitCharacterToken(0x003c, sink);
                        self.state = .rawtext;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .rawtext_end_tag_open => {
                switch (item.code_point) {
                    0x0041...0x005a, // ASCII upper alpha
                    0x0061...0x007a, // ASCII lower alpha
                    => { // ASCII alpha
                        // Create a new end tag token, set its tag name to the
                        // empty string. Reconsume in the RAWTEXT end tag name
                        // state.
                        try self.createEndTagToken();
                        self.state = .rawtext_end_tag_name;
                        try self.consumeItem(item, sink);
                    },
                    else => { // Anything else
                        // Emit a 0x003C LESS-THAN SIGN character token and a
                        // 0x002F SOLIDUS character token. Reconsume in the
                        // RAWTEXT state.
                        try self.emitCharacterToken(0x003c, sink);
                        try self.emitCharacterToken(0x002f, sink);
                        self.state = .rawtext;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .rawtext_end_tag_name => {
                switch (item.code_point) {
                    0x0009, // CHARACTER TABULATION (tab)
                    0x000A, // LINE FEED (LF)
                    0x000C, // FORM FEED (FF)
                    0x0020, // SPACE
                    => {
                        // If the current end tag token is an appropriate end
                        // tag token, then switch to the before attribute name
                        // state. Otherwise, treat it as per the "anything else"
                        // entry below.
                        if (self.isCurrentEndTagAppropiate()) {
                            self.state = .before_attribute_name;
                            return;
                        }
                    },
                    0x002F => { // SOLIDUS (/)
                        // If the current end tag token is an appropriate end
                        // tag token, then switch to the self-closing start tag
                        // state. Otherwise, treat it as per the "anything else"
                        // entry below.
                        if (self.isCurrentEndTagAppropiate()) {
                            self.state = .self_closing_start_tag;
                            return;
                        }
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // If the current end tag token is an appropriate end
                        // tag token, then switch to the data state and emit the
                        // current tag token. Otherwise, treat it as per the
                        // "anything else" entry below.
                        if (self.isCurrentEndTagAppropiate()) {
                            self.state = .data;
                            try self.emitCurrentToken(sink);
                            return;
                        }
                    },
                    0x0041...0x005a => { // ASCII upper alpha
                        // Append the lowercase version of the current input
                        // character (add 0x0020 to the character's code point)
                        // to the current tag token's tag name. Append the
                        // current input character to the temporary buffer.
                        try self.appendCharacterToCurrentTagName(item.code_point + 0x0020);
                        try self.temp_buffer.append(item.code_point);
                        return;
                    },
                    0x0061...0x007a => { // ASCII lower alpha
                        // Append the current input character to the current tag
                        // token's tag name. Append the current input character
                        // to the temporary buffer.
                        try self.appendCharacterToCurrentTagName(item.code_point);
                        try self.temp_buffer.append(item.code_point);
                        return;
                    },
                    else => {
                        // pass
                    },
                }
                // Anything else
                // Emit a 0x003C LESS-THAN SIGN character token, a 0x002F
                // SOLIDUS character token, and a character token for each of
                // the characters in the temporary buffer (in the order they
                // were added to the buffer). Reconsume in the RAWTEXT state.
                try self.emitCharacterToken(0x003c, sink);
                try self.emitCharacterToken(0x002f, sink);
                for (self.temp_buffer.items) |value| {
                    try self.emitCharacterToken(value, sink);
                }
                self.state = .rawtext;
                try self.consumeItem(item, sink);
            },
            .script_data_less_than_sign => {
                switch (item.code_point) {
                    0x002F => { // SOLIDUS (/)
                        // Set the temporary buffer to the empty string. Switch
                        // to the script data end tag open state.
                        self.temp_buffer.clearRetainingCapacity();
                        self.state = .script_data_end_tag_open;
                    },
                    0x0021 => { // EXCLAMATION MARK (!)
                        // Switch to the script data escape start state. Emit a
                        // 0x003C LESS-THAN SIGN character token and a 0x0021
                        // EXCLAMATION MARK character token.
                        self.state = .script_data_escape_start;
                        try self.emitCharacterToken(0x003c, sink);
                        try self.emitCharacterToken(0x0021, sink);
                    },
                    else => { // Anything else
                        // Emit a 0x003C LESS-THAN SIGN character token.
                        // Reconsume in the script data state.
                        try self.emitCharacterToken(0x003c, sink);
                        self.state = .script_data;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .script_data_end_tag_open => {
                switch (item.code_point) {
                    0x0041...0x005a, // ASCII upper alpha
                    0x0061...0x007a, // ASCII lower alpha
                    => { // ASCII alpha
                        // Create a new end tag token, set its tag name to the
                        // empty string. Reconsume in the script data end tag
                        // name state.
                        try self.createEndTagToken();
                        self.state = .script_data_end_tag_open;
                        try self.consumeItem(item, sink);
                    },
                    else => { // Anything else
                        // Emit a 0x003C LESS-THAN SIGN character token and a
                        // 0x002F SOLIDUS character token. Reconsume in the
                        // script data state.
                        try self.emitCharacterToken(0x003c, sink);
                        try self.emitCharacterToken(0x002f, sink);
                        self.state = .script_data;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .script_data_end_tag_name => {
                switch (item.code_point) {
                    0x0009, // CHARACTER TABULATION (tab)
                    0x000A, // LINE FEED (LF)
                    0x000C, // FORM FEED (FF)
                    0x0020, // SPACE
                    => {
                        // If the current end tag token is an appropriate end
                        // tag token, then switch to the before attribute name
                        // state. Otherwise, treat it as per the "anything else"
                        // entry below.
                        if (self.isCurrentEndTagAppropiate()) {
                            self.state = .before_attribute_name;
                            return;
                        }
                    },
                    0x002F => { // SOLIDUS (/)
                        // If the current end tag token is an appropriate end
                        // tag token, then switch to the self-closing start tag
                        // state. Otherwise, treat it as per the "anything else"
                        // entry below.
                        if (self.isCurrentEndTagAppropiate()) {
                            self.state = .self_closing_start_tag;
                            return;
                        }
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // If the current end tag token is an appropriate end
                        // tag token, then switch to the data state and emit the
                        // current tag token. Otherwise, treat it as per the
                        // "anything else" entry below.
                        if (self.isCurrentEndTagAppropiate()) {
                            self.state = .data;
                            try self.emitCurrentToken(sink);
                            return;
                        }
                    },
                    0x0041...0x005a => { // ASCII upper alpha
                        // Append the lowercase version of the current input
                        // character (add 0x0020 to the character's code point)
                        // to the current tag token's tag name. Append the
                        // current input character to the temporary buffer.
                        try self.appendCharacterToCurrentTagName(item.code_point + 0x0020);
                        try self.temp_buffer.append(item.code_point);
                        return;
                    },
                    0x0061...0x007a => { // ASCII lower alpha
                        // Append the current input character to the current tag
                        // token's tag name. Append the current input character
                        // to the temporary buffer.
                        try self.appendCharacterToCurrentTagName(item.code_point);
                        try self.temp_buffer.append(item.code_point);
                        return;
                    },
                    else => {},
                }
                // Anything else
                // Emit a 0x003C LESS-THAN SIGN character token, a 0x002F
                // SOLIDUS character token, and a character token for each of
                // the characters in the temporary buffer (in the order they
                // were added to the buffer). Reconsume in the script data
                // state.
                try self.emitCharacterToken(0x003c, sink);
                try self.emitCharacterToken(0x002f, sink);
                for (self.temp_buffer.items) |value| {
                    try self.emitCharacterToken(value, sink);
                }
                self.state = .script_data;
                try self.consumeItem(item, sink);
            },
            .script_data_escape_start => {
                switch (item.code_point) {
                    0x002D => { // HYPHEN-MINUS (-)
                        // Switch to the script data escape start dash state.
                        // Emit a 0x002D HYPHEN-MINUS character token.
                        self.state = .script_data_escape_start_dash;
                        try self.emitCharacterToken(0x002d, sink);
                    },
                    else => { // Anything else
                        // Reconsume in the script data state.
                        self.state = .script_data;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .script_data_escape_start_dash => {
                switch (item.code_point) {
                    0x002D => { // HYPHEN-MINUS (-)
                        // Switch to the script data escaped dash dash state.
                        // Emit a 0x002D HYPHEN-MINUS character token.
                        self.state = .script_data_escaped_dash_dash;
                        try self.emitCharacterToken(0x002d, sink);
                    },
                    else => { // Anything else
                        // Reconsume in the script data state.
                        self.state = .script_data;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .script_data_escaped => {
                if (item.eof) { // EOF
                    // This is an eof-in-script-html-comment-like-text parse
                    // error. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInScriptHtmlCommentLikeText);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x002D => { // HYPHEN-MINUS (-)
                        // Switch to the script data escaped dash state. Emit a
                        // 0x002D HYPHEN-MINUS character token.
                        self.state = .script_data_escaped_dash;
                        try self.emitCharacterToken(0x002d, sink);
                    },
                    0x003C => { // LESS-THAN SIGN (<)
                        // Switch to the script data escaped less-than sign
                        // state.
                        self.state = .script_data_escaped_less_than_sign;
                    },
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Emit a 0xFFFD REPLACEMENT CHARACTER character token.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.emitCharacterToken(0xfffd, sink);
                    },
                    else => { // Anything else
                        // Emit the current input character as a character
                        // token.
                        try self.emitCharacterToken(item.code_point, sink);
                    },
                }
            },
            .script_data_escaped_dash => {
                if (item.eof) { // EOF
                    // This is an eof-in-script-html-comment-like-text parse
                    // error. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInScriptHtmlCommentLikeText);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x002D => { // HYPHEN-MINUS (-)
                        // Switch to the script data escaped dash dash state.
                        // Emit a 0x002D HYPHEN-MINUS character token.
                        self.state = .script_data_escaped_dash_dash;
                        try self.emitCharacterToken(0x002d, sink);
                    },
                    0x003C => { // LESS-THAN SIGN (<)
                        // Switch to the script data escaped less-than sign state.
                        self.state = .script_data_escaped_less_than_sign;
                    },
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Switch to the script data escaped state. Emit a
                        // 0xFFFD REPLACEMENT CHARACTER character token.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        self.state = .script_data_escaped;
                        try self.emitCharacterToken(0xfffd, sink);
                    },
                    else => { // Anything else
                        // Switch to the script data escaped state. Emit the
                        // current input character as a character token.
                        self.state = .script_data_escaped;
                        try self.emitCharacterToken(item.code_point, sink);
                    },
                }
            },
            .script_data_escaped_dash_dash => {
                if (item.eof) { // EOF
                    // This is an eof-in-script-html-comment-like-text parse
                    // error. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInScriptHtmlCommentLikeText);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x002D => { // HYPHEN-MINUS (-)
                        // Emit a 0x002D HYPHEN-MINUS character token.
                        try self.emitCharacterToken(0x002d, sink);
                    },
                    0x003C => { // LESS-THAN SIGN (<)
                        // Switch to the script data escaped less-than sign
                        // state.
                        self.state = .script_data_escaped_less_than_sign;
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // Switch to the script data state. Emit a 0x003E
                        // GREATER-THAN SIGN character token.
                        self.state = .script_data;
                        try self.emitCharacterToken(0x003e, sink);
                    },
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Switch to the script data escaped state. Emit a
                        // 0xFFFD REPLACEMENT CHARACTER character token.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        self.state = .script_data_escaped;
                        try self.emitCharacterToken(0xfffd, sink);
                    },
                    else => { // Anything else
                        // Switch to the script data escaped state. Emit the
                        // current input character as a character token.
                        self.state = .script_data_escaped;
                        try self.emitCharacterToken(item.code_point, sink);
                    },
                }
            },
            .script_data_escaped_less_than_sign => {
                switch (item.code_point) {
                    0x002F => { // SOLIDUS (/)
                        // Set the temporary buffer to the empty string. Switch
                        // to the script data escaped end tag open state.
                        self.temp_buffer.clearRetainingCapacity();
                        self.state = .script_data_escaped_end_tag_open;
                    },
                    0x0041...0x005a, // ASCII upper alpha
                    0x0061...0x007a, // ASCII lower alpha
                    => { // ASCII alpha
                        // Set the temporary buffer to the empty string. Emit a
                        // 0x003C LESS-THAN SIGN character token. Reconsume in
                        // the script data double escape start state.
                        self.temp_buffer.clearRetainingCapacity();
                        try self.emitCharacterToken(0x003c, sink);
                        self.state = .script_data_double_escape_start;
                        try self.consumeItem(item, sink);
                    },
                    else => { // Anything else
                        // Emit a 0x003C LESS-THAN SIGN character token.
                        // Reconsume in the script data escaped state.
                        try self.emitCharacterToken(0x003c, sink);
                        self.state = .script_data_escaped;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .script_data_escaped_end_tag_open => {
                switch (item.code_point) {
                    0x0041...0x005a, // ASCII upper alpha
                    0x0061...0x007a, // ASCII lower alpha
                    => { // ASCII alpha
                        // Create a new end tag token, set its tag name to the
                        // empty string. Reconsume in the script data escaped
                        // end tag name state.
                        try self.createEndTagToken();
                    },
                    else => { // Anything else
                        // Emit a 0x003C LESS-THAN SIGN character token and a
                        // 0x002F SOLIDUS character token. Reconsume in the
                        // script data escaped state.
                        try self.emitCharacterToken(0x003c, sink);
                        try self.emitCharacterToken(0x002f, sink);
                        self.state = .script_data_escaped;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .script_data_escaped_end_tag_name => {
                switch (item.code_point) {
                    0x0009, // CHARACTER TABULATION (tab)
                    0x000A, // LINE FEED (LF)
                    0x000C, // FORM FEED (FF)
                    0x0020, // SPACE
                    => {
                        // If the current end tag token is an appropriate end
                        // tag token, then switch to the before attribute name
                        // state. Otherwise, treat it as per the "anything else"
                        // entry below.
                        if (self.isCurrentEndTagAppropiate()) {
                            self.state = .before_attribute_name;
                            return;
                        }
                    },
                    0x002F => { // SOLIDUS (/)
                        // If the current end tag token is an appropriate end
                        // tag token, then switch to the self-closing start tag
                        // state. Otherwise, treat it as per the "anything else"
                        // entry below.
                        if (self.isCurrentEndTagAppropiate()) {
                            self.state = .self_closing_start_tag;
                            return;
                        }
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // If the current end tag token is an appropriate end
                        // tag token, then switch to the data state and emit the
                        // current tag token. Otherwise, treat it as per the
                        // "anything else" entry below.
                        if (self.isCurrentEndTagAppropiate()) {
                            self.state = .data;
                            try self.emitCurrentToken(sink);
                            return;
                        }
                    },
                    0x0041...0x005a => { // ASCII upper alpha
                        // Append the lowercase version of the current input
                        // character (add 0x0020 to the character's code point)
                        // to the current tag token's tag name. Append the
                        // current input character to the temporary buffer.
                        try self.appendCharacterToCurrentTagName(item.code_point + 0x0020);
                        try self.temp_buffer.append(item.code_point);
                        return;
                    },
                    0x0061...0x007a => { // ASCII lower alpha
                        // Append the current input character to the current tag
                        // token's tag name. Append the current input character
                        // to the temporary buffer.
                        try self.appendCharacterToCurrentTagName(item.code_point);
                        try self.temp_buffer.append(item.code_point);
                        return;
                    },
                    else => {},
                }
                // Anything else
                // Emit a 0x003C LESS-THAN SIGN character token, a 0x002F
                // SOLIDUS character token, and a character token for each of
                // the characters in the temporary buffer (in the order they
                // were added to the buffer). Reconsume in the script data
                // escaped state.
                try self.emitCharacterToken(0x003c, sink);
                try self.emitCharacterToken(0x002f, sink);
                for (self.temp_buffer.items) |value| {
                    try self.emitCharacterToken(value, sink);
                }
                self.state = .script_data_escaped;
                try self.consumeItem(item, sink);
            },
            .script_data_double_escape_start => {
                switch (item.code_point) {
                    0x0009, // CHARACTER TABULATION (tab)
                    0x000A, // LINE FEED (LF)
                    0x000C, // FORM FEED (FF)
                    0x0020, // SPACE
                    0x002F, // SOLIDUS (/)
                    0x003E, // GREATER-THAN SIGN (>)
                    => {
                        // If the temporary buffer is the string "script", then
                        // switch to the script data double escaped state.
                        // Otherwise, switch to the script data escaped state.
                        // Emit the current input character as a character
                        // token.
                        const script_string = [_]u21{ 0x73, 0x63, 0x72, 0x69, 0x70, 0x74 };
                        if (mem.eql(u21, self.temp_buffer.items, &script_string)) {
                            self.state = .script_data_double_escaped;
                        } else {
                            self.state = .script_data_escaped;
                        }
                        try self.emitCharacterToken(item.code_point, sink);
                    },
                    0x0041...0x005a => { // ASCII upper alpha
                        // Append the lowercase version of the current input
                        // character (add 0x0020 to the character's code point)
                        // to the temporary buffer. Emit the current input
                        // character as a character token.
                        try self.temp_buffer.append(item.code_point + 0x0020);
                        try self.emitCharacterToken(item.code_point, sink);
                    },
                    0x0061...0x007a => { // ASCII lower alpha
                        // Append the current input character to the temporary
                        // buffer. Emit the current input character as a
                        // character token.
                        try self.temp_buffer.append(item.code_point);
                        try self.emitCharacterToken(item.code_point, sink);
                    },
                    else => { // Anything else
                        // Reconsume in the script data escaped state.
                        self.state = .script_data_escaped;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .script_data_double_escaped => {
                if (item.eof) { // EOF
                    // This is an eof-in-script-html-comment-like-text parse
                    // error. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInScriptHtmlCommentLikeText);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x002D => { // HYPHEN-MINUS (-)
                        // Switch to the script data double escaped dash state.
                        // Emit a 0x002D HYPHEN-MINUS character token.
                        self.state = .script_data_double_escaped_dash;
                        try self.emitCharacterToken(0x002d, sink);
                    },
                    0x003C => { // LESS-THAN SIGN (<)
                        // Switch to the script data double escaped less-than
                        // sign state. Emit a 0x003C LESS-THAN SIGN character
                        // token.
                        self.state = .script_data_double_escaped_less_than_sign;
                        try self.emitCharacterToken(0x003c, sink);
                    },
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Emit a 0xFFFD REPLACEMENT CHARACTER character token.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.emitCharacterToken(0xfffd, sink);
                    },
                    else => { // Anything else
                        // Emit the current input character as a character token.
                        try self.emitCharacterToken(item.code_point, sink);
                    },
                }
            },
            .script_data_double_escaped_dash => {
                if (item.eof) { // EOF
                    // This is an eof-in-script-html-comment-like-text parse
                    // error. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInScriptHtmlCommentLikeText);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x002D => { // HYPHEN-MINUS (-)
                        // Switch to the script data double escaped dash dash
                        // state. Emit a 0x002D HYPHEN-MINUS character token.
                        self.state = .script_data_double_escaped_dash_dash;
                        try self.emitCharacterToken(0x002d, sink);
                    },
                    0x003C => { // LESS-THAN SIGN (<)
                        // Switch to the script data double escaped less-than
                        // sign state. Emit a 0x003C LESS-THAN SIGN character
                        // token.
                        self.state = .script_data_double_escaped_less_than_sign;
                        try self.emitCharacterToken(0x003c, sink);
                    },
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Switch to the script data double escaped state. Emit
                        // a 0xFFFD REPLACEMENT CHARACTER character token.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        self.state = .script_data_double_escaped;
                        try self.emitCharacterToken(0xfffd, sink);
                    },
                    else => { // Anything else
                        // Switch to the script data double escaped state. Emit
                        // the current input character as a character token.
                        self.state = .script_data_double_escaped;
                        try self.emitCharacterToken(item.code_point, sink);
                    },
                }
            },
            .script_data_double_escaped_dash_dash => {
                if (item.eof) { // EOF
                    // This is an eof-in-script-html-comment-like-text parse
                    // error. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInScriptHtmlCommentLikeText);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x002D => { // HYPHEN-MINUS (-)
                        // Emit a 0x002D HYPHEN-MINUS character token.
                        try self.emitCharacterToken(0x002d, sink);
                    },
                    0x003C => { // LESS-THAN SIGN (<)
                        // Switch to the script data double escaped less-than
                        // sign state. Emit a 0x003C LESS-THAN SIGN character
                        // token.
                        self.state = .script_data_escaped_less_than_sign;
                        try self.emitCharacterToken(0x003c, sink);
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // Switch to the script data state. Emit a 0x003E
                        // GREATER-THAN SIGN character token.
                        self.state = .script_data;
                        try self.emitCharacterToken(0x003e, sink);
                    },
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Switch to the script data double escaped state. Emit
                        // a 0xFFFD REPLACEMENT CHARACTER character token.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        self.state = .script_data_double_escaped;
                        try self.emitCharacterToken(0xfffd, sink);
                    },
                    else => { // Anything else
                        // Switch to the script data double escaped state. Emit
                        // the current input character as a character token.
                        self.state = .script_data_double_escaped;
                        try self.emitCharacterToken(item.code_point, sink);
                    },
                }
            },
            .script_data_double_escaped_less_than_sign => {
                switch (item.code_point) {
                    0x002F => { // SOLIDUS (/)
                        // Set the temporary buffer to the empty string. Switch
                        // to the script data double escape end state. Emit a
                        // 0x002F SOLIDUS character token.
                        self.temp_buffer.clearRetainingCapacity();
                        self.state = .script_data_double_escape_end;
                        try self.emitCharacterToken(0x002f, sink);
                    },
                    else => { // Anything else
                        // Reconsume in the script data double escaped state.
                        self.state = .script_data_double_escaped;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .script_data_double_escape_end => {
                switch (item.code_point) {
                    0x0009, // CHARACTER TABULATION (tab)
                    0x000A, // LINE FEED (LF)
                    0x000C, // FORM FEED (FF)
                    0x0020, // SPACE
                    0x002F, // SOLIDUS (/)
                    0x003E, // GREATER-THAN SIGN (>)
                    => {
                        // If the temporary buffer is the string "script", then
                        // switch to the script data escaped state. Otherwise,
                        // switch to the script data double escaped state. Emit
                        // the current input character as a character token.
                        const script_string = [_]u21{ 0x73, 0x63, 0x72, 0x69, 0x70, 0x74 };
                        if (mem.eql(u21, self.temp_buffer.items, &script_string)) {
                            self.state = .script_data_escaped;
                        } else {
                            self.state = .script_data_double_escaped;
                        }
                        try self.emitCharacterToken(item.code_point, sink);
                    },
                    0x0041...0x005a => { // ASCII upper alpha
                        // Append the lowercase version of the current input
                        // character (add 0x0020 to the character's code point)
                        // to the temporary buffer. Emit the current input
                        // character as a character token.
                        try self.temp_buffer.append(item.code_point + 0x0020);
                        try self.emitCharacterToken(item.code_point, sink);
                    },
                    0x0061...0x007a => { // ASCII lower alpha
                        // Append the current input character to the temporary
                        // buffer. Emit the current input character as a
                        // character token.
                        try self.temp_buffer.append(item.code_point);
                        try self.emitCharacterToken(item.code_point, sink);
                    },
                    else => { // Anything else
                        // Reconsume in the script data double escaped state.
                        self.state = .script_data_double_escaped;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .before_attribute_name => {
                if (item.eof) {
                    // Reconsume in the after attribute name state.
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
                        // Ignore the character.
                        return;
                    },
                    0x002f, // SOLIDUS (/)
                    0x003E, // GREATER-THAN SIGN (>)
                    => {
                        // Reconsume in the after attribute name state.
                        self.state = .after_attribute_name;
                        try self.consumeItem(item, sink);
                    },
                    0x003d => { // EQUALS SIGN (=)
                        // This is an
                        // unexpected-equals-sign-before-attribute-name parse
                        // error. Start a new attribute in the current tag
                        // token. Set that attribute's name to the current input
                        // character, and its value to the empty string. Switch
                        // to the attribute name state.
                        try self.emitError(HTMLParserErrors.UnexpectedEqualsSignBeforeAttributeName);

                        try self.createAttribute();
                        try self.appendCharacterToCurrentAttributeName(item.code_point);
                        self.state = .attribute_name;
                    },
                    else => {
                        // Start a new attribute in the current tag token. Set
                        // that attribute name and value to the empty string.
                        // Reconsume in the attribute name state.
                        try self.createAttribute();
                        self.state = .attribute_name;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .attribute_name => {
                // TODO: check for duplicates
                if (item.eof) {
                    // Reconsume in the after attribute name state.
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
                        // Reconsume in the after attribute name state.
                        try self.appendAttributeToCurrentTag();
                        self.state = .after_attribute_name;
                        try self.consumeItem(item, sink);
                    },
                    0x003d => { // EQUALS SIGN (=)
                        // Switch to the before attribute value state.
                        self.state = .before_attribute_value;
                    },
                    0x0041...0x005a => { // ASCII upper alpha
                        // Append the lowercase version of the current input
                        // character (add 0x0020 to the character's code point)
                        // to the current attribute's name.
                        const lowercase_code_point = item.code_point + 0x0020;
                        try self.appendCharacterToCurrentAttributeName(lowercase_code_point);
                    },
                    0x0000 => {
                        // This is an unexpected-null-character parse error.
                        // Append a U+FFFD REPLACEMENT CHARACTER character to
                        // the current attribute's name.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.appendCharacterToCurrentAttributeName(0xfffd);
                    },
                    0x0022, // QUOTATION MARK (")
                    0x0027, //APOSTROPHE (')
                    0x003C, //LESS-THAN SIGN (<
                    => {
                        // This is an unexpected-character-in-attribute-name
                        // parse error. Treat it as per the "anything else"
                        // entry below.
                        try self.emitError(HTMLParserErrors.UnexpectedCharacterInAttributeName);
                        try self.appendCharacterToCurrentAttributeName(item.code_point);
                    },
                    else => {
                        // Append the current input character to the current attribute's name.
                        try self.appendCharacterToCurrentAttributeName(item.code_point);
                    },
                }
            },
            .after_attribute_name => {
                if (item.eof) {
                    // This is an eof-in-tag parse error. Emit an end-of-file
                    // token.
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
                        // Ignore the character.
                    },
                    0x002f => { // SOLIDUS (/)
                        // Switch to the self-closing start tag state.
                        self.state = .self_closing_start_tag;
                    },
                    0x003d => { // EQUALS SIGN (=)
                        // Switch to the before attribute value state.
                        self.state = .before_attribute_value;
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // Switch to the data state. Emit the current tag token.
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => {
                        // Start a new attribute in the current tag token. Set
                        // that attribute name and value to the empty string.
                        // Reconsume in the attribute name state.
                        try self.createAttribute();
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
                        // Ignore the character.
                    },
                    0x0022 => { // QUOTATION MARK (")
                        // Switch to the attribute value (double-quoted) state.
                        self.state = .attribute_value_double_quoted;
                    },
                    0x0027 => { // APOSTROPHE (')
                        // Switch to the attribute value (single-quoted) state.
                        self.state = .attribute_value_single_quoted;
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // This is a missing-attribute-value parse error.
                        // Switch to the data state. Emit the current tag token.
                        try self.emitError(HTMLParserErrors.MissingAttributeValue);
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => {
                        // Reconsume in the attribute value (unquoted) state.
                        self.state = .attribute_value_unquoted;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .attribute_value_double_quoted => {
                if (item.eof) {
                    // This is an eof-in-tag parse error. Emit an end-of-file
                    // token.
                    try self.emitError(HTMLParserErrors.EOFInTag);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0022 => { // QUOTATION MARK (")
                        // Switch to the after attribute value (quoted) state.
                        self.state = .after_attribute_value_quoted;
                    },
                    0x0026 => { // AMPERSAND (&)
                        // Set the return state to the attribute value
                        // (double-quoted) state. Switch to the character
                        // reference state.
                        self.return_state = .attribute_value_double_quoted;
                        self.state = .character_reference;
                    },
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Append a U+FFFD REPLACEMENT CHARACTER character to
                        // the current attribute's value.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.appendCharacterToCurrentAttributeValue(0xfffd);
                    },
                    else => {
                        // Append the current input character to the current
                        // attribute's value.
                        try self.appendCharacterToCurrentAttributeValue(item.code_point);
                    },
                }
            },
            .attribute_value_single_quoted => {
                if (item.eof) {
                    // This is an eof-in-tag parse error. Emit an end-of-file
                    // token.
                    try self.emitError(HTMLParserErrors.EOFInTag);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0027 => { // APOSTROPHE (')
                        // Switch to the after attribute value (quoted) state.
                        self.state = .after_attribute_value_quoted;
                    },
                    0x0026 => { // AMPERSAND (&)
                        // Set the return state to the attribute value
                        // (single-quoted) state. Switch to the character
                        // reference state.
                        self.return_state = .attribute_value_single_quoted;
                        self.state = .character_reference;
                    },
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Append a U+FFFD REPLACEMENT CHARACTER character to
                        // the current attribute's value.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.appendCharacterToCurrentAttributeValue(0xfffd);
                    },
                    else => {
                        // Append the current input character to the current
                        // attribute's value.
                        try self.appendCharacterToCurrentAttributeValue(item.code_point);
                    },
                }
            },
            .attribute_value_unquoted => {
                if (item.eof) {
                    // This is an eof-in-tag parse error. Emit an end-of-file
                    // token.
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
                        // Switch to the before attribute name state.
                        self.state = .before_attribute_name;
                    },
                    0x0026 => { // AMPERSAND (&)
                        // Set the return state to the attribute value
                        // (unquoted) state. Switch to the character reference
                        // state.
                        self.return_state = .attribute_value_unquoted;
                        self.state = .character_reference;
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // Switch to the data state. Emit the current tag token.
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Append a U+FFFD REPLACEMENT CHARACTER character to
                        // the current attribute's value.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.appendCharacterToCurrentAttributeValue(0xfffd);
                    },
                    0x0022, //QUOTATION MARK (")
                    0x0027, //APOSTROPHE (')
                    0x003C, //LESS-THAN SIGN (<)
                    0x003D, //EQUALS SIGN (=)
                    0x0060, //GRAVE ACCENT (`)
                    => {
                        // This is an
                        // unexpected-character-in-unquoted-attribute-value
                        // parse error. Treat it as per the "anything else"
                        // entry below.
                        try self.emitError(HTMLParserErrors.UnexpectedCharacterInUnquotedAttributeValue);
                        try self.appendCharacterToCurrentAttributeValue(item.code_point);
                    },
                    else => {
                        // Append the current input character to the current
                        // attribute's value.
                        try self.appendCharacterToCurrentAttributeValue(item.code_point);
                    },
                }
            },
            .after_attribute_value_quoted => {
                if (item.eof) {
                    // This is an eof-in-tag parse error. Emit an end-of-file
                    // token.
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
                        // Switch to the before attribute name state.
                        self.state = .before_attribute_name;
                    },
                    0x002F => { // SOLIDUS (/)
                        // Switch to the self-closing start tag state.
                        self.state = .self_closing_start_tag;
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // Switch to the data state. Emit the current tag token.
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => {
                        // This is a missing-whitespace-between-attributes parse
                        // error. Reconsume in the before attribute name state.
                        try self.emitError(HTMLParserErrors.MissingWhitespaceBetweenAttributes);
                        self.state = .before_attribute_name;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .self_closing_start_tag => {
                if (item.eof) {
                    // This is an eof-in-tag parse error. Emit an end-of-file
                    // token.
                    try self.emitError(HTMLParserErrors.EOFInTag);
                    try self.emitEOFToken(sink);
                    return;
                }

                switch (item.code_point) {
                    0x003E => { // GREATER-THAN SIGN (>)
                        // Set the self-closing flag of the current tag token.
                        // Switch to the data state. Emit the current tag token.
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
                        // This is an unexpected-solidus-in-tag parse error.
                        // Reconsume in the before attribute name state.
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
                    0x003E => { // GREATER-THAN SIGN (>)
                        // Switch to the data state. Emit the current comment
                        // token.
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    0x0000 => { // NULL
                        // Append a 0xFFFD REPLACEMENT CHARACTER character to
                        // the comment token's data.
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
                    // This is an incorrectly-opened-comment parse error. Create
                    // a comment token whose data is the empty string. Switch to
                    // the bogus comment state (don't consume anything in the
                    // current state).
                    try self.handleIncorrectlyOpenedComment(sink);
                    return;
                }
                try self.current_open_markup.append(item.code_point);
                switch (self.current_open_markup.items[0]) {
                    0x002D => { // HYPHEN-MINUS (-)
                        // Consume those two characters, create a comment token
                        // whose data is the empty string, and switch to the
                        // comment start state.
                        if (self.current_open_markup.items.len == 1) {
                            // wait for 2nd char
                            return;
                        }
                        if (self.current_open_markup.items.len == 2 and
                            self.current_open_markup.items[1] == 0x002D)
                        {
                            self.current_open_markup.clearRetainingCapacity();
                            try self.createCommentToken();
                            self.state = .comment_start;
                            return;
                        }
                        try self.handleIncorrectlyOpenedComment(sink);
                    },
                    // ASCII case-insensitive match for the word "DOCTYPE"
                    0x0044, 0x0064 => { // d or D character. pointing to DOCTYPE
                        // Consume those characters and switch to the DOCTYPE
                        // state.
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
                    // The string "[CDATA[" (the five uppercase letters "CDATA"
                    // with a 0x005B LEFT SQUARE BRACKET character before and
                    // after)
                    0x005B => {
                        // Consume those characters. If there is an adjusted
                        // current node and it is not an element in the HTML
                        // namespace, then switch to the CDATA section state.
                        // Otherwise, this is a cdata-in-html-content parse
                        // error. Create a comment token whose data is the
                        // "[CDATA[" string. Switch to the bogus comment state.
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

                        try self.createCommentToken();
                        self.current_token.?.comment.data = try self.allocator.dupe(u21, &cdata);

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
                        // This is an abrupt-closing-of-empty-comment parse
                        // error. Switch to the data state. Emit the current
                        // comment token.
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
                    // This is an eof-in-comment parse error. Emit the current
                    // comment token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInComment);
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x002d => { // HYPHEN-MINUS (-)
                        // Switch to the comment end state.
                        self.state = .comment_end_dash;
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // This is an abrupt-closing-of-empty-comment parse
                        // error. Switch to the data state. Emit the current
                        // comment token.
                        try self.emitError(HTMLParserErrors.AbruptClosingOfEmptyComment);
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => { // Anything else
                        // Append a 0x002D HYPHEN-MINUS character (-) to the
                        // comment token's data. Reconsume in the comment state.
                        try self.appendCharacterToCurrentComment(0x002d);
                        self.state = .comment;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .comment => {
                if (item.eof) {
                    // This is an eof-in-comment parse error. Emit the current
                    // comment token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInComment);
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x003C => { // LESS-THAN SIGN (<)
                        // Append the current input character to the comment
                        // token's data. Switch to the comment less-than sign
                        // state.
                        try self.appendCharacterToCurrentComment(self.current_character.?.code_point);
                        self.state = .comment_less_than_sign;
                    },
                    0x002D => { // HYPHEN-MINUS (-)
                        // Switch to the comment end dash state.
                        self.state = .comment_end_dash;
                    },
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Append a U+FFFD REPLACEMENT CHARACTER character to
                        // the comment token's data.
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
                        // Append the current input character to the comment
                        // token's data. Switch to the comment less-than sign
                        // bang state.
                        try self.appendCharacterToCurrentComment(self.current_character.?.code_point);
                        self.state = .comment_less_than_sign_bang;
                    },
                    0x003C => { // LESS-THAN SIGN (<)
                        // Append the current input character to the comment
                        // token's data.
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
                        // Switch to the comment less-than sign bang dash dash
                        // state.
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
                        // This is a nested-comment parse error. Reconsume in
                        // the comment end state.
                        try self.emitError(HTMLParserErrors.NestedComment);
                        self.state = .comment_end;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .comment_end_dash => {
                if (item.eof) { // EOF
                    // This is an eof-in-comment parse error. Emit the current
                    // comment token. Emit an end-of-file token.
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
                        // Append a 0x002D HYPHEN-MINUS character (-) to the
                        // comment token's data. Reconsume in the comment state.
                        try self.appendCharacterToCurrentComment(0x002d);
                        self.state = .comment;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .comment_end => {
                if (item.eof) { // EOF
                    // This is an eof-in-comment parse error. Emit the current
                    // comment token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInComment);

                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x003E => { // GREATER-THAN SIGN (>)
                        // Switch to the data state. Emit the current comment
                        // token.
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    0x0021 => { //EXCLAMATION MARK (!)
                        // Switch to the comment end bang state.
                        self.state = .comment_end_bang;
                    },
                    0x002D => { //HYPHEN-MINUS (-)
                        // Append a 0x002D HYPHEN-MINUS character (-) to the
                        // comment token's data.
                        try self.appendCharacterToCurrentComment(0x002d);
                    },
                    else => { // Anything else
                        // Append two 0x002D HYPHEN-MINUS characters (-) to the
                        // comment token's data. Reconsume in the comment state.
                        try self.appendCharacterToCurrentComment(0x002d);
                        try self.appendCharacterToCurrentComment(0x002d);
                        self.state = .comment;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .comment_end_bang => {
                if (item.eof) { // EOF
                    // This is an eof-in-comment parse error. Emit the current
                    // comment token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInComment);
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x002d => { // 0x002D HYPHEN-MINUS (-)
                        // Append two 0x002D HYPHEN-MINUS characters (-) and a
                        // 0x0021 EXCLAMATION MARK character (!) to the comment
                        // token's data. Switch to the comment end dash state.
                        try self.appendCharacterToCurrentComment(0x002d);
                        try self.appendCharacterToCurrentComment(0x002d);
                        try self.appendCharacterToCurrentComment(0x0021);
                        self.state = .comment_end_dash;
                    },
                    0x003e => { // 0x003E GREATER-THAN SIGN (>)
                        // Switch to the data state. Emit the current comment
                        // token.
                        try self.emitError(HTMLParserErrors.IncorrectlyClosedComment);
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => { // Anything else
                        // Append two 0x002D HYPHEN-MINUS characters (-) and a
                        // 0x0021 EXCLAMATION MARK character (!) to the comment
                        // token's data. Reconsume in the comment state.
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
                    // This is an eof-in-doctype parse error. Create a new
                    // DOCTYPE token. Set its force-quirks flag to on. Emit the
                    // current token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInDoctype);
                    try self.createDoctypeToken(true);
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
                        // Switch to the before DOCTYPE name state.
                        self.state = .before_doctype_name;
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // Reconsume in the before DOCTYPE name state.
                        self.state = .before_doctype_name;
                        try self.consumeItem(item, sink);
                    },
                    else => { // Anything else
                        // This is a missing-whitespace-before-doctype-name
                        // parse error. Reconsume in the before DOCTYPE name
                        // state.
                        try self.emitError(HTMLParserErrors.MissingWhitespaceBeforeDoctypeName);
                        self.state = .before_doctype_name;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .before_doctype_name => {
                if (item.eof) { // EOF
                    // This is an eof-in-doctype parse error. Create a new
                    // DOCTYPE token. Set its force-quirks flag to on. Emit the
                    // current token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInDoctype);
                    try self.createDoctypeToken(true);
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
                    0x0041...0x005a => { // ASCII upper alpha
                        // Create a new DOCTYPE token. Set the token's name to
                        // the lowercase version of the current input character
                        // (add 0x0020 to the character's code point). Switch to
                        // the DOCTYPE name state.
                        try self.createDoctypeToken(false);
                        try self.appendCharacterToDoctypeName(item.code_point + 0x0020);
                        self.state = .doctype_name;
                    },
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Create a new DOCTYPE token. Set the token's name to a
                        // 0xFFFD REPLACEMENT CHARACTER character. Switch to the
                        // DOCTYPE name state.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.createDoctypeToken(false);
                        try self.appendCharacterToDoctypeName(0xfffd);
                        self.state = .doctype_name;
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // This is a missing-doctype-name parse error. Create a
                        // new DOCTYPE token. Set its force-quirks flag to on.
                        // Switch to the data state. Emit the current token.
                        try self.emitError(HTMLParserErrors.MissingDoctypeName);
                        try self.createDoctypeToken(false);
                        try self.appendCharacterToDoctypeName(0xfffd);
                        try self.emitCurrentToken(sink);
                        self.state = .data;
                    },
                    else => { // Anything else
                        // Create a new DOCTYPE token. Set the token's name to
                        // the current input character. Switch to the DOCTYPE
                        // name state.
                        try self.createDoctypeToken(false);
                        try self.appendCharacterToDoctypeName(item.code_point);
                        self.state = .doctype_name;
                    },
                }
            },
            .doctype_name => {
                if (item.eof) { // EOF
                    // This is an eof-in-doctype parse error. Set the current
                    // DOCTYPE token's force-quirks flag to on. Emit the current
                    // DOCTYPE token. Emit an end-of-file token.
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
                    0x003E => { // GREATER-THAN SIGN (>)
                        // Switch to the data state. Emit the current DOCTYPE
                        // token.
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    0x0041...0x005a => { // ASCII upper alpha
                        // Append the lowercase version of the current input
                        // character (add 0x0020 to the character's code point)
                        // to the current DOCTYPE token's name.
                        try self.appendCharacterToDoctypeName(item.code_point + 0x0020);
                    },
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Append a 0xFFFD REPLACEMENT CHARACTER character to
                        // the current DOCTYPE token's name.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.appendCharacterToDoctypeName(0xfffd);
                    },
                    else => { // Anything else
                        // Append the current input character to the current
                        // DOCTYPE token's name.
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
                            var input_item = try self.allocator.create(parser_stream.InputStreamItem);
                            input_item.code_point = char;
                            input_item.eof = index == self.after_doctype_string.items.len - 1;
                            try self.consumeItem(input_item.*, sink);
                        }
                        self.after_doctype_string.clearRetainingCapacity();
                        return;
                    }
                    // This is an eof-in-doctype parse error. Set the current
                    // DOCTYPE token's force-quirks flag to on. Emit the current
                    // DOCTYPE token. Emit an end-of-file token.
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
                        // If the six characters starting from the current input
                        // character are an ASCII case-insensitive match for the
                        // word "PUBLIC", then consume those characters and
                        // switch to the after DOCTYPE public keyword state.
                        //
                        // Otherwise, if the six characters starting from the
                        // current input character are an ASCII case-insensitive
                        // match for the word "SYSTEM", then consume those
                        // characters and switch to the after DOCTYPE system
                        // keyword state.
                        //
                        // Otherwise, this is an
                        // invalid-character-sequence-after-doctype-name parse
                        // error. Set the current DOCTYPE token's force-quirks
                        // flag to on. Reconsume in the bogus DOCTYPE state.

                        try self.after_doctype_string.append(item.code_point);
                        const index = self.after_doctype_string.items.len - 1;
                        // "PUBLIC"
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

                        // "SYSTEM"
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
                        // Otherwise
                        try self.emitError(HTMLParserErrors.InvalidCharacterSequenceAfterDoctypeName);
                        self.current_token.?.doctype.force_quirks = true;

                        self.state = .bogus_doctype;
                        for (self.after_doctype_string.items) |char| {
                            var input_item = try self.allocator.create(parser_stream.InputStreamItem);
                            input_item.code_point = char;
                            input_item.eof = false;
                            try self.consumeItem(input_item.*, sink);
                        }
                        self.after_doctype_string.clearRetainingCapacity();
                    },
                }
            },
            .after_doctype_public_keyword => {
                if (item.eof) { // EOF
                    // This is an eof-in-doctype parse error. Set the current
                    // DOCTYPE token's force-quirks flag to on. Emit the current
                    // DOCTYPE token. Emit an end-of-file token.
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
                        // Switch to the before DOCTYPE public identifier state.
                        self.state = .before_doctype_public_identifier;
                    },
                    0x0022 => { // QUOTATION MARK (")
                        // This is a
                        // missing-whitespace-after-doctype-public-keyword parse
                        // error. Set the current DOCTYPE token's public
                        // identifier to the empty string (not missing), then
                        // switch to the DOCTYPE public identifier
                        // (double-quoted) state.
                        try self.emitError(HTMLParserErrors.MissingWhitespaceAfterDoctypePublicKeyword);
                        if (self.current_token.?.doctype.public_id.len > 0) {
                            self.allocator.free(self.current_token.?.doctype.public_id);
                            self.current_token.?.doctype.public_id = try self.allocator.alloc(u21, 0);
                        }

                        self.state = .doctype_public_identifier_double_quoted;
                    },
                    0x0027 => { // APOSTROPHE (')
                        // This is a
                        // missing-whitespace-after-doctype-public-keyword parse
                        // error. Set the current DOCTYPE token's public
                        // identifier to the empty string (not missing), then
                        // switch to the DOCTYPE public identifier
                        // (single-quoted) state.
                        try self.emitError(HTMLParserErrors.MissingWhitespaceAfterDoctypePublicKeyword);
                        if (self.current_token.?.doctype.public_id.len > 0) {
                            self.allocator.free(self.current_token.?.doctype.public_id);
                            self.current_token.?.doctype.public_id = try self.allocator.alloc(u21, 0);
                        }
                        self.state = .doctype_public_identifier_single_quoted;
                    },
                    0x003E => { //GREATER-THAN SIGN (>)
                        // This is a missing-doctype-public-identifier parse
                        // error. Set the current DOCTYPE token's force-quirks
                        // flag to on. Switch to the data state. Emit the
                        // current DOCTYPE token.
                        try self.emitError(HTMLParserErrors.MissingDoctypePublicIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => {
                        // This is a
                        // missing-quote-before-doctype-public-identifier parse
                        // error. Set the current DOCTYPE token's force-quirks
                        // flag to on. Reconsume in the bogus DOCTYPE state.
                        try self.emitError(HTMLParserErrors.MissingQuoteBeforeDoctypePublicIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .bogus_doctype;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .before_doctype_public_identifier => {
                if (item.eof) { // EOF
                    // This is an eof-in-doctype parse error. Set the current
                    // DOCTYPE token's force-quirks flag to on. Emit the current
                    // DOCTYPE token. Emit an end-of-file token.
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
                    0x0022 => { // QUOTATION MARK (")
                        // Set the current DOCTYPE token's public identifier to
                        // the empty string (not missing), then switch to the
                        // DOCTYPE public identifier (double-quoted) state.
                        if (self.current_token.?.doctype.public_id.len > 0) {
                            self.allocator.free(self.current_token.?.doctype.public_id);
                            self.current_token.?.doctype.public_id = try self.allocator.alloc(u21, 0);
                        }
                        self.state = .doctype_public_identifier_double_quoted;
                    },
                    0x0027 => { // APOSTROPHE (')
                        // Set the current DOCTYPE token's public identifier to
                        // the empty string (not missing), then switch to the
                        // DOCTYPE public identifier (single-quoted)
                        //     state.
                        if (self.current_token.?.doctype.public_id.len > 0) {
                            self.allocator.free(self.current_token.?.doctype.public_id);
                            self.current_token.?.doctype.public_id = try self.allocator.alloc(u21, 0);
                        }
                        self.state = .doctype_public_identifier_single_quoted;
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // This is a missing-doctype-public-identifier parse
                        // error. Set the current DOCTYPE token's force-quirks
                        // flag to on. Switch to the data state. Emit the
                        // current DOCTYPE token.
                        try self.emitError(HTMLParserErrors.MissingDoctypePublicIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => { // Anything else
                        // This is a
                        // missing-quote-before-doctype-public-identifier parse
                        // error. Set the current DOCTYPE token's force-quirks
                        // flag to on. Reconsume in the bogus DOCTYPE state.
                        try self.emitError(HTMLParserErrors.MissingQuoteBeforeDoctypePublicIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .bogus_doctype;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .doctype_public_identifier_double_quoted => {
                if (item.eof) { // EOF
                    // This is an eof-in-doctype parse error. Set the current
                    // DOCTYPE token's force-quirks flag to on. Emit the current
                    // DOCTYPE token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInDoctype);
                    self.current_token.?.doctype.force_quirks = true;
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0022 => { // QUOTATION MARK (")
                        // Switch to the after DOCTYPE public identifier state.
                        self.state = .after_doctype_public_identifier;
                    },
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Append a 0xFFFD REPLACEMENT CHARACTER character to
                        // the current DOCTYPE token's public identifier.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.appendCharacterToDoctypePublicIdentifier(0xfffd);
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // This is an abrupt-doctype-public-identifier parse
                        // error. Set the current DOCTYPE token's force-quirks
                        // flag to on. Switch to the data state. Emit the
                        // current DOCTYPE token.
                        try self.emitError(HTMLParserErrors.AbruptDoctypePublicIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => { // Anything else
                        // Append the current input character to the current
                        // DOCTYPE token's public identifier.
                        try self.appendCharacterToDoctypePublicIdentifier(item.code_point);
                    },
                }
            },
            .doctype_public_identifier_single_quoted => {
                if (item.eof) { // EOF
                    // This is an eof-in-doctype parse error. Set the current
                    // DOCTYPE token's force-quirks flag to on. Emit the current
                    // DOCTYPE token. Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInDoctype);
                    self.current_token.?.doctype.force_quirks = true;
                    try self.emitCurrentToken(sink);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x0027 => { // APOSTROPHE (')
                        // Switch to the after DOCTYPE public identifier state.
                        self.state = .after_doctype_public_identifier;
                    },
                    0x0000 => { // NULL
                        // This is an unexpected-null-character parse error.
                        // Append a 0xFFFD REPLACEMENT CHARACTER character to
                        // the current DOCTYPE token's public identifier.
                        try self.emitError(HTMLParserErrors.UnexpectedNullCharacter);
                        try self.appendCharacterToDoctypePublicIdentifier(0xfffd);
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // This is an abrupt-doctype-public-identifier parse
                        // error. Set the current DOCTYPE token's force-quirks
                        // flag to on. Switch to the data state. Emit the
                        // current DOCTYPE token.
                        try self.emitError(HTMLParserErrors.AbruptDoctypePublicIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => { // Anything else
                        // Append the current input character to the current
                        // DOCTYPE token's public identifier.
                        try self.appendCharacterToDoctypePublicIdentifier(item.code_point);
                    },
                }
            },
            .after_doctype_public_identifier => {
                if (item.eof) { // EOF
                    // This is an eof-in-doctype parse error. Set the current
                    // DOCTYPE token's force-quirks flag to on. Emit the current
                    // DOCTYPE token. Emit an end-of-file token.
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
                        // Switch to the between DOCTYPE public and system
                        // identifiers state.
                        self.state = .between_doctype_public_and_system_identifiers;
                    },
                    0x003E => { // GREATER-THAN SIGN (>)
                        // Switch to the data state. Emit the current DOCTYPE
                        // token.
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    0x0022 => { // QUOTATION MARK (")
                        // This is a
                        // missing-whitespace-between-doctype-public-and-system-identifiers
                        // parse error. Set the current DOCTYPE token's system
                        // identifier to the empty string (not missing), then
                        // switch to the DOCTYPE system identifier
                        // (double-quoted) state.
                        try self.emitError(HTMLParserErrors.MissingWhitespaceBetweenDoctypePublicAndSystemIdentifiers);
                        if (self.current_token.?.doctype.system_id.len > 0) {
                            self.allocator.free(self.current_token.?.doctype.system_id);
                            self.current_token.?.doctype.system_id = try self.allocator.alloc(u21, 0);
                        }

                        self.state = .doctype_system_identifier_double_quoted;
                    },
                    0x0027 => { // APOSTROPHE (')
                        // This is a
                        // missing-whitespace-between-doctype-public-and-system-identifiers
                        // parse error. Set the current DOCTYPE token's system
                        // identifier to the empty string (not missing), then
                        // switch to the DOCTYPE system identifier
                        // (single-quoted) state.
                        try self.emitError(HTMLParserErrors.MissingWhitespaceBetweenDoctypePublicAndSystemIdentifiers);
                        if (self.current_token.?.doctype.system_id.len > 0) {
                            self.allocator.free(self.current_token.?.doctype.system_id);
                            self.current_token.?.doctype.system_id = try self.allocator.alloc(u21, 0);
                        }
                        self.state = .doctype_system_identifier_single_quoted;
                    },
                    else => { // Anything else
                        // This is a
                        // missing-quote-before-doctype-system-identifier parse
                        // error. Set the current DOCTYPE token's force-quirks
                        // flag to on. Reconsume in the bogus DOCTYPE state.,
                        try self.emitError(HTMLParserErrors.MissingQuoteBeforeDoctypeSystemIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .bogus_doctype;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .between_doctype_public_and_system_identifiers => {
                if (item.eof) { // EOF
                    // This is an eof-in-doctype parse error. Set the current
                    // DOCTYPE token's force-quirks flag to on. Emit the current
                    // DOCTYPE token. Emit an end-of-file token.
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
                        // Ignore the character.
                    },
                    0x003E, //GREATER-THAN SIGN (>)
                    => {
                        // Switch to the data state. Emit the current DOCTYPE token.
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    0x0022, //QUOTATION MARK (")
                    => {
                        // Set the current DOCTYPE token's system identifier to
                        // the empty string (not missing), then switch to the
                        // DOCTYPE system identifier (double-quoted) state.
                        if (self.current_token.?.doctype.system_id.len > 0) {
                            self.allocator.free(self.current_token.?.doctype.system_id);
                            self.current_token.?.doctype.system_id = try self.allocator.alloc(u21, 0);
                        }

                        self.state = .doctype_system_identifier_double_quoted;
                    },
                    0x0027, //APOSTROPHE (')
                    => {
                        // Set the current DOCTYPE token's system identifier to
                        // the empty string (not missing), then switch to the
                        // DOCTYPE system identifier (single-quoted) state.
                        if (self.current_token.?.doctype.system_id.len > 0) {
                            self.allocator.free(self.current_token.?.doctype.system_id);
                            self.current_token.?.doctype.system_id = try self.allocator.alloc(u21, 0);
                        }
                        self.state = .doctype_system_identifier_single_quoted;
                    },
                    else => { // Anything else
                        // This is a
                        // missing-quote-before-doctype-system-identifier parse
                        // error. Set the current DOCTYPE token's force-quirks
                        // flag to on. Reconsume in the bogus DOCTYPE state.
                        try self.emitError(HTMLParserErrors.MissingQuoteBeforeDoctypeSystemIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .bogus_doctype;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .after_doctype_system_keyword => {
                if (item.eof) { // EOF
                    // This is an eof-in-doctype parse error. Set the current
                    // DOCTYPE token's force-quirks flag to on. Emit the current
                    // DOCTYPE token. Emit an end-of-file token.
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
                        // Switch to the before DOCTYPE system identifier state.
                        self.state = .before_doctype_system_identifier;
                    },
                    0x0022, //QUOTATION MARK (")
                    => {
                        // This is a
                        // missing-whitespace-after-doctype-system-keyword parse
                        // error. Set the current DOCTYPE token's system
                        // identifier to the empty string (not missing), then
                        // switch to the DOCTYPE system identifier
                        // (double-quoted) state.
                        try self.emitError(HTMLParserErrors.MissingWhitespaceAfterDoctypeSystemKeyword);
                        if (self.current_token.?.doctype.system_id.len > 0) {
                            self.allocator.free(self.current_token.?.doctype.system_id);
                            self.current_token.?.doctype.system_id = try self.allocator.alloc(u21, 0);
                        }

                        self.state = .doctype_system_identifier_double_quoted;
                    },
                    0x0027, //APOSTROPHE (')
                    => {
                        // This is a
                        // missing-whitespace-after-doctype-system-keyword parse
                        // error. Set the current DOCTYPE token's system
                        // identifier to the empty string (not missing), then
                        // switch to the DOCTYPE system identifier
                        // (single-quoted) state.
                        try self.emitError(HTMLParserErrors.MissingWhitespaceAfterDoctypeSystemKeyword);
                        if (self.current_token.?.doctype.system_id.len > 0) {
                            self.allocator.free(self.current_token.?.doctype.system_id);
                            self.current_token.?.doctype.system_id = try self.allocator.alloc(u21, 0);
                        }
                        self.state = .doctype_system_identifier_single_quoted;
                    },
                    0x003E, //GREATER-THAN SIGN (>)
                    => {
                        //     This is a missing-doctype-system-identifier parse
                        //     error. Set the current DOCTYPE token's
                        //     force-quirks flag to on. Switch to the data
                        //     state. Emit the current DOCTYPE token.
                        try self.emitError(HTMLParserErrors.MissingDoctypeSystemIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .data;
                        try self.emitCurrentToken(sink);
                    },
                    else => { // Anything else
                        //     This is a
                        //     missing-quote-before-doctype-system-identifier
                        //     parse error. Set the current DOCTYPE token's
                        //     force-quirks flag to on. Reconsume in the bogus
                        //     DOCTYPE state.
                        try self.emitError(HTMLParserErrors.MissingQuoteBeforeDoctypeSystemIdentifier);
                        self.current_token.?.doctype.force_quirks = true;
                        self.state = .bogus_doctype;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .before_doctype_system_identifier => {
                if (item.eof) { // EOF
                    // This is an eof-in-doctype parse error. Set the current
                    // DOCTYPE token's force-quirks flag to on. Emit the current
                    // DOCTYPE token. Emit an end-of-file token.
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
                        //     Set the current DOCTYPE token's system identifier
                        //     to the empty string (not missing), then switch to
                        //     the DOCTYPE system identifier (double-quoted)
                        //     state.
                        if (self.current_token.?.doctype.system_id.len > 0) {
                            self.allocator.free(self.current_token.?.doctype.system_id);
                            self.current_token.?.doctype.system_id = try self.allocator.alloc(u21, 0);
                        }

                        self.state = .doctype_system_identifier_double_quoted;
                    },
                    0x0027, //APOSTROPHE (')
                    => {
                        //     Set the current DOCTYPE token's system identifier to the empty string (not missing), then switch to the DOCTYPE system identifier (single-quoted) state.
                        if (self.current_token.?.doctype.system_id.len > 0) {
                            self.allocator.free(self.current_token.?.doctype.system_id);
                            self.current_token.?.doctype.system_id = try self.allocator.alloc(u21, 0);
                        }
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
                        try self.emitCurrentToken(sink);
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
            .cdata_section => {
                if (item.eof) { // EOF
                    //     This is an eof-in-cdata parse error.
                    //     Emit an end-of-file token.
                    try self.emitError(HTMLParserErrors.EOFInCdata);
                    try self.emitEOFToken(sink);
                    return;
                }
                switch (item.code_point) {
                    0x005D, // RIGHT SQUARE BRACKET (])
                    => {
                        //     Switch to the CDATA section bracket state.
                        self.state = .cdata_section_bracket;
                    },
                    else => { // Anything else
                        //     Emit the current input character as a character token
                        try self.emitCharacterToken(item.code_point, sink);
                    },
                }
            },
            .cdata_section_bracket => {
                switch (item.code_point) {
                    0x005D, // RIGHT SQUARE BRACKET (])
                    => {
                        //     Switch to the CDATA section end state.
                        self.state = .cdata_section_end;
                    },
                    else => { // Anything else
                        //     Emit a 0x005D RIGHT SQUARE BRACKET character
                        //     token. Reconsume in the CDATA section state.
                        try self.emitCharacterToken(0x005d, sink);
                        self.state = .cdata_section;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .cdata_section_end => {
                switch (item.code_point) {
                    0x005D, // RIGHT SQUARE BRACKET (])
                    => {
                        //     Emit a 0x005D RIGHT SQUARE BRACKET character
                        //     token.
                        try self.emitCharacterToken(0x005d, sink);
                    },
                    0x003E, // GREATER-THAN SIGN (>)
                    => {
                        //     Switch to the data state.
                        self.state = .data;
                    },
                    else => { // Anything else
                        //     Emit two 0x005D RIGHT SQUARE BRACKET character
                        //     tokens. Reconsume in the CDATA section state.
                        try self.emitCharacterToken(0x005d, sink);
                        try self.emitCharacterToken(0x005d, sink);
                        self.state = .cdata_section;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .character_reference => {
                // Set the temporary buffer to the empty string. Append a 0x0026
                // AMPERSAND (&) character to the temporary buffer. Consume the
                // next input character:
                self.temp_buffer.clearRetainingCapacity();
                try self.temp_buffer.append(0x0026);

                switch (item.code_point) {
                    0x0041...0x005a, // ASCII upper alpha
                    0x0061...0x007a, // ASCII lower alpha
                    0x0030...0x0039, // ASCII digit
                    => { // ASCII alphanumeric
                        //     Reconsume in the named character reference state.
                        self.state = .named_character_reference;
                        try self.consumeItem(item, sink);
                    },
                    0x0023, // NUMBER SIGN (#)
                    => {
                        //     Append the current input character to the
                        //     temporary buffer. Switch to the numeric character
                        //     reference state.
                        try self.temp_buffer.append(item.code_point);
                        self.state = .numeric_character_reference;
                    },
                    else => { // Anything else
                        //     Flush code points consumed as a character
                        //     reference. Reconsume in the return state.
                        try self.flushCodePoints(sink);
                        self.state = self.return_state;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            // TODO: test this shit
            .named_character_reference => {
                // Consume the maximum number of characters possible, where the
                // consumed characters are one of the identifiers in the first
                // column of the named character references table. Append each
                // character to the temporary buffer when it's consumed.
                try self.temp_buffer.append(item.code_point);
                const entity_name = try self.tempBufferToString();
                defer self.allocator.free(entity_name);

                if (self.html_entities_map.getNamedEntity(entity_name)) |node| {
                    self.last_entity = node.value;
                    return;
                } else if (self.html_entities_map.getNamedEntity(entity_name[0 .. entity_name.len - 1])) |node| {
                    // If there is a match
                    //
                    //     If the character reference was consumed as part of an
                    //     attribute, and the last character matched is not a 0x003B
                    //     SEMICOLON character (;), and the next input character is
                    //     either a 0x003D EQUALS SIGN character (=) or an ASCII
                    //     alphanumeric, then, for historical reasons, flush code
                    //     points consumed as a character reference and switch to
                    //     the return state.
                    const consumed_as_part_of_attribute = switch (self.return_state) {
                        .attribute_value_double_quoted,
                        .attribute_value_single_quoted,
                        .attribute_value_unquoted,
                        => true,
                        else => false,
                    };
                    const is_last_char_semicolon = self.temp_buffer.items[self.temp_buffer.items.len - 1] == 0x003B;
                    const next_input_is_equals_or_alpha = switch (item.code_point) {
                        0x0041...0x005a, // ASCII upper alpha
                        0x0061...0x007a, // ASCII lower alpha
                        0x0030...0x0039, // ASCII digit
                        0x003D, // EQUALS SIGN (=)
                        => true,

                        else => false,
                    };
                    if (consumed_as_part_of_attribute and
                        !is_last_char_semicolon and
                        next_input_is_equals_or_alpha)
                    {
                        //     ...then, for historical reasons, flush code
                        //     points consumed as a character reference and
                        //     switch to the return state.
                        try self.flushCodePoints(sink);
                        self.state = self.return_state;
                        return;
                    }
                    //     Otherwise:
                    //         If the last character matched is not a 0x003B
                    //         SEMICOLON character (;), then this is a
                    //         missing-semicolon-after-character-reference parse
                    //         error.
                    if (!is_last_char_semicolon) {
                        try self.emitError(HTMLParserErrors.MissingSemicolonAfterCharacterReference);
                    }
                    //         Set the temporary buffer to the empty string.
                    //         Append one or two characters corresponding to the
                    //         character reference name (as given by the second
                    //         column of the named character references table)
                    //         to the temporary buffer.
                    self.temp_buffer.clearRetainingCapacity();
                    for (node.value.?.codepoints) |codepoints| {
                        try self.temp_buffer.append(@intCast(codepoints & 0x10ffff));
                    }
                    //         Flush code points consumed as a character
                    //         reference. Switch to the return state.
                    try self.flushCodePoints(sink);
                    self.state = self.return_state;
                } else {
                    // Otherwise
                    //     Flush code points consumed as a character reference.
                    //     Switch to the ambiguous ampersand state.
                    try self.flushCodePoints(sink);
                    self.state = .ambiguous_ampersand;
                }
            },
            .ambiguous_ampersand => {
                switch (item.code_point) {
                    0x0041...0x005a, // ASCII upper alpha
                    0x0061...0x007a, // ASCII lower alpha
                    0x0030...0x0039, // ASCII digit
                    => { // ASCII alphanumeric
                        //     If the character reference was consumed as part
                        //     of an attribute, then append the current input
                        //     character to the current attribute's value.
                        //     Otherwise, emit the current input character as a
                        //     character token.
                        switch (self.return_state) {
                            // consumed as part of an attribute
                            .attribute_value_double_quoted,
                            .attribute_value_single_quoted,
                            .attribute_value_unquoted,
                            => {
                                try self.appendCharacterToCurrentAttributeValue(self.current_character.?.code_point);
                            },
                            else => {
                                try self.emitCharacterToken(self.current_character.?.code_point, sink);
                            },
                        }
                    },
                    0x003B, // 0x003B SEMICOLON (;)
                    => {
                        //     This is an unknown-named-character-reference
                        //     parse error. Reconsume in the return state.
                        try self.emitError(HTMLParserErrors.UnknownNamedCharacterReference);
                        self.state = self.return_state;
                        try self.consumeItem(item, sink);
                    },
                    else => { // Anything else
                        //     Reconsume in the return state.
                        self.state = self.return_state;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .numeric_character_reference => {
                // Set the character reference code to zero (0).
                self.character_reference_code = 0;
                switch (item.code_point) {
                    0x0078, // 0x0078 LATIN SMALL LETTER X
                    0x0058, // 0x0058 LATIN CAPITAL LETTER X
                    => {
                        //     Append the current input character to the
                        //     temporary buffer. Switch to the hexadecimal
                        //     character reference start state.
                        try self.temp_buffer.append(self.current_character.?.code_point);
                        self.state = .hexadecimal_character_reference_start;
                    },
                    else => { // Anything else
                        //     Reconsume in the decimal character reference start
                        //     state.
                        self.state = .decimal_character_reference_start;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .hexadecimal_character_reference_start => {
                switch (item.code_point) {
                    0x0041...0x0046, // ASCII upper hex digit
                    0x0061...0x0066, // ASCII lower hex digit
                    0x0030...0x0039, // ASCII digit
                    => { // ASCII hex digit
                        //     Reconsume in the hexadecimal character reference
                        //     state.
                        self.state = .hexadecimal_character_reference;
                        try self.consumeItem(item, sink);
                    },
                    else => {
                        // Anything else
                        //     This is an
                        //     absence-of-digits-in-numeric-character-reference
                        //     parse error. Flush code points consumed as a
                        //     character reference. Reconsume in the return
                        //     state.
                        try self.emitError(HTMLParserErrors.AbsenceOfDigitsInNumericCharacterReference);
                        try self.flushCodePoints(sink);
                        self.state = self.return_state;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .decimal_character_reference_start => {
                switch (item.code_point) {
                    0x0030...0x0039, // ASCII digit
                    => {
                        //     Reconsume in the decimal character reference
                        //     state.
                        self.state = .decimal_character_reference;
                        try self.consumeItem(item, sink);
                    },
                    else => {
                        // Anything else
                        //     This is an
                        //     absence-of-digits-in-numeric-character-reference
                        //     parse error. Flush code points consumed as a
                        //     character reference. Reconsume in the return
                        //     state.
                        try self.emitError(HTMLParserErrors.AbsenceOfDigitsInNumericCharacterReference);
                        try self.flushCodePoints(sink);
                        self.state = self.return_state;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .hexadecimal_character_reference => {
                switch (item.code_point) {
                    0x0030...0x0039, // ASCII digit
                    => {
                        //     Multiply the character reference code by 16. Add
                        //     a numeric version of the current input character
                        //     (subtract 0x0030 from the character's code point)
                        //     to the character reference code.
                        self.character_reference_code *= 16;
                        self.character_reference_code += item.code_point - 0x0030;
                    },
                    0x0041...0x0046, // ASCII upper hex digit
                    => {
                        //     Multiply the character reference code by 16. Add
                        //     a numeric version of the current input character
                        //     as a hexadecimal digit (subtract 0x0037 from the
                        //     character's code point) to the character
                        //     reference code.
                        self.character_reference_code *= 16;
                        self.character_reference_code += item.code_point - 0x0037;
                    },
                    0x0061...0x0066, // ASCII lower hex digit
                    => {
                        //     Multiply the character reference code by 16. Add
                        //     a numeric version of the current input character
                        //     as a hexadecimal digit (subtract 0x0057 from the
                        //     character's code point) to the character
                        //     reference code.
                        self.character_reference_code *= 16;
                        self.character_reference_code += item.code_point - 0x0057;
                    },
                    0x003B, // 0x003B SEMICOLON (;)
                    => {
                        //     Switch to the numeric character reference end state.
                        self.state = .numeric_character_reference_end;
                    },
                    else => { // Anything else
                        //     This is a
                        //     missing-semicolon-after-character-reference parse
                        //     error. Reconsume in the numeric character
                        //     reference end state.
                        try self.emitError(HTMLParserErrors.MissingSemicolonAfterCharacterReference);
                        self.state = .numeric_character_reference_end;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .decimal_character_reference => {
                switch (item.code_point) {
                    0x0030...0x0039, // ASCII digit
                    => {
                        //     Multiply the character reference code by 10. Add
                        //     a numeric version of the current input character
                        //     (subtract 0x0030 from the character's code point)
                        //     to the character reference code.
                        self.character_reference_code *= 10;
                        self.character_reference_code += item.code_point - 0x0030;
                    },
                    0x003B => {
                        // 0x003B SEMICOLON (;)
                        //     Switch to the numeric character reference end state.
                        self.state = .numeric_character_reference_end;
                    },
                    else => {
                        // Anything else
                        //     This is a
                        //     missing-semicolon-after-character-reference
                        //     parse error. Reconsume in the numeric character
                        //     reference end state.
                        try self.emitError(HTMLParserErrors.MissingSemicolonAfterCharacterReference);
                        self.state = .numeric_character_reference_end;
                        try self.consumeItem(item, sink);
                    },
                }
            },
            .numeric_character_reference_end => {
                // Check the character reference code:
                switch (self.character_reference_code) {
                    0x00 => {
                        //     If the number is 0x00, then this is a
                        //     null-character-reference parse error. Set the
                        //     character reference code to 0xFFFD.
                        try self.emitError(HTMLParserErrors.NullCharacterReference);
                        self.character_reference_code = 0xfffd;
                    },
                    0x110000...0xFFFFFFFFFFFFFFFF => {
                        //     If the number is greater than 0x10FFFF, then this
                        //     is a character-reference-outside-unicode-range
                        //     parse error. Set the character reference code
                        //     to 0xFFFD.
                        try self.emitError(HTMLParserErrors.CharacterReferenceOutsideUnicodeRange);
                        self.character_reference_code = 0xfffd;
                    },
                    0xd800...0xdbff, // leading surrogate
                    0xdc00...0xdfff, // trailing surrogate
                    => {
                        //     If the number is a surrogate, then this is a
                        //     surrogate-character-reference parse error. Set
                        //     the character reference code to 0xFFFD.
                        try self.emitError(HTMLParserErrors.SurrogateCharacterReference);
                        self.character_reference_code = 0xfffd;
                    },
                    0xfdd0...0xfdef,
                    0xFFFE,
                    0xFFFF,
                    0x1FFFE,
                    0x1FFFF,
                    0x2FFFE,
                    0x2FFFF,
                    0x3FFFE,
                    0x3FFFF,
                    0x4FFFE,
                    0x4FFFF,
                    0x5FFFE,
                    0x5FFFF,
                    0x6FFFE,
                    0x6FFFF,
                    0x7FFFE,
                    0x7FFFF,
                    0x8FFFE,
                    0x8FFFF,
                    0x9FFFE,
                    0x9FFFF,
                    0xAFFFE,
                    0xAFFFF,
                    0xBFFFE,
                    0xBFFFF,
                    0xCFFFE,
                    0xCFFFF,
                    0xDFFFE,
                    0xDFFFF,
                    0xEFFFE,
                    0xEFFFF,
                    0xFFFFE,
                    0xFFFFF,
                    0x10FFFE,
                    0x10FFFF,
                    => { // noncharacter
                        //     If the number is a noncharacter, then this is a
                        //     noncharacter-character-reference parse error.
                        try self.emitError(HTMLParserErrors.NoncharacterCharacterReference);
                    },
                    0x007F...0x009F, // c0 control
                    0x0001...0x0009, // control - no whitespace
                    0x0b, // control - no whitespace
                    0x0c...0x001F, // control - no whitespace
                    => {
                        //     If the number is 0x0D, or a control that's not
                        //     ASCII whitespace, then this is a
                        //     control-character-reference parse error. If the
                        //     number is one of the numbers in the first column
                        //     of the following table, then find the row with
                        //     that number in the first column, and set the
                        //     character reference code to the number in the
                        //     second column of that row.
                        try self.emitError(HTMLParserErrors.ControlCharacterReference);
                        const table_column_1 = [_]u64{ 0x80, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8E, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0x9B, 0x9C, 0x9E, 0x9F };
                        const table_column_2 = [_]u21{
                            0x20AC, // EURO SIGN (€)
                            0x201A, // SINGLE LOW-9 QUOTATION MARK (‚)
                            0x0192, // LATIN SMALL LETTER F WITH HOOK (ƒ)
                            0x201E, // DOUBLE LOW-9 QUOTATION MARK („)
                            0x2026, // HORIZONTAL ELLIPSIS (…)
                            0x2020, // DAGGER (†)
                            0x2021, // DOUBLE DAGGER (‡)
                            0x02C6, // MODIFIER LETTER CIRCUMFLEX ACCENT (ˆ)
                            0x2030, // PER MILLE SIGN (‰)
                            0x0160, // LATIN CAPITAL LETTER S WITH CARON (Š)
                            0x2039, // SINGLE LEFT-POINTING ANGLE QUOTATION MARK (‹)
                            0x0152, // LATIN CAPITAL LIGATURE OE (Œ)
                            0x017D, // LATIN CAPITAL LETTER Z WITH CARON (Ž)
                            0x2018, // LEFT SINGLE QUOTATION MARK (‘)
                            0x2019, // RIGHT SINGLE QUOTATION MARK (’)
                            0x201C, // LEFT DOUBLE QUOTATION MARK (“)
                            0x201D, // RIGHT DOUBLE QUOTATION MARK (”)
                            0x2022, // BULLET (•)
                            0x2013, // EN DASH (–)
                            0x2014, // EM DASH (—)
                            0x02DC, // SMALL TILDE (˜)
                            0x2122, // TRADE MARK SIGN (™)
                            0x0161, // LATIN SMALL LETTER S WITH CARON (š)
                            0x203A, // SINGLE RIGHT-POINTING ANGLE QUOTATION MARK (›)
                            0x0153, // LATIN SMALL LIGATURE OE (œ)
                            0x017E, // LATIN SMALL LETTER Z WITH CARON (ž)
                            0x0178, // LATIN CAPITAL LETTER Y WITH DIAERESIS (Ÿ)
                        };
                        inline for (table_column_1, 0..) |table_entry, index| {
                            if (table_entry == self.character_reference_code) {
                                self.character_reference_code = table_column_2[index];
                                break;
                            }
                        }
                    },
                    else => {},
                }
                // Set the temporary buffer to the empty string. Append a code
                // point equal to the character reference code to the temporary
                // buffer. Flush code points consumed as a character reference.
                // Switch to the return state.
                self.temp_buffer.clearRetainingCapacity();
                try self.temp_buffer.append(@intCast(self.character_reference_code & 0x10ffff));
                try self.flushCodePoints(sink);
                self.state = self.return_state;
            },
        }
    }

    fn emitEOFToken(self: *Self, sink: tokenizer_types.TokenSink) !void {
        var token = try tokenizer_types.Token.create(self.allocator, .eof);
        token.eof.index = self.input_stream.index;
        try sink(token);
        try self.tokens.append(token);
    }

    fn emitCharacterToken(self: *Self, character: u21, sink: tokenizer_types.TokenSink) !void {
        var token = try tokenizer_types.Token.create(self.allocator, .character);
        token.character.data = character;
        try self.emitToken(token, sink);
        // try self.emitToken(.{ .character = .{ .data = character } }, sink);
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
        if (self.current_attribute) |attr| {
            const new_len = attr.name.len + 1;
            var new_name = try self.allocator.realloc(attr.name, new_len);
            new_name[new_name.len - 1] = code_point;
            attr.name = new_name;
        } else {
            unreachable;
        }
    }

    fn appendCharacterToCurrentAttributeValue(self: *Self, code_point: u21) !void {
        const new_len = self.current_attribute.?.value.len + 1;
        var new_name = try self.allocator.realloc(self.current_attribute.?.value, new_len);
        new_name[new_name.len - 1] = code_point;
        self.current_attribute.?.value = new_name;
    }

    fn appendAttributeToCurrentTag(self: *Self) !void {
        print("appendAttributeToCurrentTag\n", .{});
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
                const new_len = self.current_token.?.doctype.public_id.len + 1;
                var new_data = try self.allocator.realloc(self.current_token.?.doctype.public_id, new_len);
                new_data[new_data.len - 1] = code_point;
                self.current_token.?.doctype.public_id = new_data;
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

    fn flushCodePoints(self: *Self, sink: tokenizer_types.TokenSink) !void {
        switch (self.return_state) {
            // consumed as part of an attribute
            .attribute_value_double_quoted,
            .attribute_value_single_quoted,
            .attribute_value_unquoted,
            => {
                for (self.temp_buffer.items) |value| {
                    try self.appendCharacterToCurrentAttributeValue(value);
                }
            },
            else => {
                for (self.temp_buffer.items) |value| {
                    try self.emitCharacterToken(value, sink);
                }
            },
        }
    }

    fn handleIncorrectlyOpenedComment(self: *Self, sink: tokenizer_types.TokenSink) !void {
        // Create a comment token whose data is the empty string. Switch to the
        // bogus comment state (don't consume anything in the current state).
        try self.emitError(HTMLParserErrors.IncorrectlyOpenedComment);
        try self.createCommentToken();
        self.state = .comment_start;
        for (self.current_open_markup.items) |code_point| {
            var new_item = try self.allocator.create(parser_stream.InputStreamItem);
            new_item.code_point = code_point;
            new_item.eof = false;

            try self.consumeItem(new_item.*, sink);
            new_item = undefined;
        }
        self.current_open_markup.clearRetainingCapacity();
    }

    fn emitError(self: *Self, parseError: HTMLParserErrors) !void {
        //TODO: create emition system
        _ = self; // autofix
        print("{any}", .{parseError});
    }

    fn isCurrentEndTagAppropiate(self: *Self) bool {
        switch (self.current_token.?) {
            .end_tag => |end_tag| {
                var i = self.tokens.items.len;

                while (i > 0) : (i -= 1) {
                    const item = self.tokens.items[i - 1];

                    switch (item) {
                        .start_tag => |start_tag| {
                            if (start_tag.self_closing) {
                                continue;
                            }
                            return mem.eql(u21, item.start_tag.name, end_tag.name);
                        },
                        else => {},
                    }
                }

                return false;
            },
            else => {
                return false;
            },
        }
    }

    fn tempBufferToString(self: *Self) ![]const u8 {
        var buff = ArrayList(u8).init(self.allocator);
        defer buff.deinit();
        try buff.ensureTotalCapacityPrecise(self.temp_buffer.items.len);

        for (self.temp_buffer.items) |item| {
            try buff.append(@intCast(item & 0xff));
        }
        return try buff.toOwnedSlice();
    }

    fn createCommentToken(self: *Self) !void {
        const token = try tokenizer_types.Token.create(self.allocator, .comment);
        self.current_token = token;
    }

    fn createStartTagToken(self: *Self) !void {
        var token = try tokenizer_types.Token.create(self.allocator, .start_tag);
        token.start_tag.self_closing = false;
        self.current_token = token;
    }

    fn createEndTagToken(self: *Self) !void {
        var token = try tokenizer_types.Token.create(self.allocator, .end_tag);
        token.end_tag.self_closing = false;
        self.current_token = token;
    }

    fn createDoctypeToken(self: *Self, force_quirks: bool) !void {
        var token = try tokenizer_types.Token.create(self.allocator, .doctype);
        token.doctype.force_quirks = force_quirks;
        self.current_token = token;
    }

    fn createAttribute(self: *Self) !void {
        var attribute = try self.allocator.create(tokenizer_types.TagAttribute);
        attribute.name = try self.allocator.alloc(u21, 0);
        attribute.value = try self.allocator.alloc(u21, 0);
        self.current_attribute = attribute;
        try self.appendAttributeToCurrentTag();
    }
};

test "tokenizer" {
    const input =
        "<!DOCTYPE html>\r" ++
        "<html>\n" ++
        "<head><title>Test2</title></head>\r\n" ++
        "<body>\n" ++
        "Hello, world!\r" ++
        "<hr/>" ++
        "<div class='bananas'>Ahh</div>" ++
        "</body>\n" ++
        "</html>";
    const allocator = testing.allocator;
    var stream = io.fixedBufferStream(input);
    const reader = stream.reader().any();
    var parser = try HTMLTokenizer.init(allocator, reader);
    defer parser.destroy();
    try parser.parseStream(testSink);
}

test "tokenizer - spacejam-1996" {
    const allocator = testing.allocator;
    const dir = std.fs.cwd();
    var file = try dir.openFile("examples/html/spacejam_1996.html", .{
        .mode = std.fs.File.OpenMode.read_only,
    });
    defer file.close();

    const buf = try allocator.alloc(u8, 60000);
    defer allocator.free(buf);
    const readChars = try file.readAll(buf);
    var stream = io.fixedBufferStream(buf[0..readChars]);
    const reader = stream.reader().any();
    var parser = try HTMLTokenizer.init(allocator, reader);
    defer parser.destroy();
    try parser.parseStream(testSink);
}

test "tokenizer - test url with query params" {
    const input =
        "<!DOCTYPE html>\r" ++
        "<html>\n" ++
        "<head><title>Test2</title></head>\r\n" ++
        "<body>\n" ++
        "<a href='https://example.com/?my-test=1&mytest=testing-ampersand&mytest2=2'>my test</a>\r" ++
        "</body>\n" ++
        "</html>";
    const allocator = testing.allocator;
    var stream = io.fixedBufferStream(input);
    const reader = stream.reader().any();
    var parser = try HTMLTokenizer.init(allocator, reader);
    defer parser.destroy();
    try parser.parseStream(testSink);
}

fn testSink(token: tokenizer_types.Token) !void {
    // print("sink...\n", .{});
    switch (token) {
        .character => {
            print("character: {u}\n", .{token.character.data});
        },
        .comment => {
            print("comment: {u}\n", .{token.comment.data});
        },
        .doctype => {
            print("doctype: {u}\n", .{token.doctype.name});
        },
        .eof => {
            print("eof: {d}\n", .{token.eof.index});
        },
        .start_tag, .end_tag => |tag| {
            print("tag: {u} - self closing: {} - #attributes: {}\n", .{ tag.name, tag.self_closing, tag.attributes.len });
            for (tag.attributes) |attribute| {
                print("attribute: {u} - {u} \n", .{ attribute.name, attribute.value });
            }
        },
    }
}
