const std = @import("std");
const io = std.io;
const mem = std.mem;
const print = std.debug.print;
const testing = std.testing;

const parser_stream = @import("./parser.stream.zig");
const parser_tokenizer = @import("./parser.tokenizer.zig");

const HTMLParser = struct {
    allocator: mem.Allocator,
    tokenizer: parser_tokenizer.HTMLTokenizer,

    script_nesting_level: u64,
    paused: bool,

    const Self = @This();
    pub fn init(allocator: mem.Allocator, reader: io.AnyReader) Self {
        return .{
            .script_nesting_level = 0,
            .paused = false,
            .allocator = allocator,
            .tokenizer = parser_tokenizer.HTMLTokenizer.init(allocator, reader),
        };
    }
};
