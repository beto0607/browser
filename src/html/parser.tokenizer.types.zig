const parser_errors = @import("./parser.errors.zig");
/// https://html.spec.whatwg.org/multipage/parsing.html#tokenization
pub const TokenizerState = enum {
    data,
    rcdata,
    rawtext,
    script_data,
    plaintext,
    tag_open,
    end_tag_open,
    tag_name,
    rcdata_less_than_sign,
    rcdata_end_tag_open,
    rcdata_end_tag_name,
    rawtext_less_than_sign,
    rawtext_end_tag_open,
    rawtext_end_tag_name,
    script_less_than_sign,
    script_data_end_tag_open,
    script_data_end_tag_name,
    script_data_escape_start,
    script_data_escape_start_dash,
    script_data_escaped,
    script_data_escaped_dash,
    script_data_escaped_dash_dash,
    script_data_escaped_less_than_sign,
    script_data_escaped_end_tag_open,
    script_data_escaped_end_tag_name,
    script_data_double_escape_start,
    script_data_double_escaped,
    script_data_double_escaped_dash,
    script_data_double_escaped_dash_dash,
    script_data_double_escaped_less_than_sign,
    script_data_double_escape_end,
    before_attribute_name,
    attribute_name,
    after_attribute_name,
    before_attribute_value,
    attribute_value_double_quoted,
    attribute_value_single_quoted,
    attribute_value_unquoted,
    after_attribute_value_quoted,
    self_closing_start_tag,
    bogus_comment,
    markup_declaration_open,
    comment_start,
    comment_start_dash,
    comment,
    comment_less_than_sign,
    comment_less_than_sign_bang,
    comment_less_than_sign_bang_dash,
    comment_less_than_sign_bang_dash_dash,
    comment_end_dash,
    comment_end,
    comment_end_bang,
    doctype,
    before_doctype_name,
    doctype_name,
    after_doctype_name,
    after_doctype_public_keyword,
    before_doctype_public_identifier,
    doctype_public_identifier_double_quoted,
    doctype_public_identifier_single_quoted,
    after_doctype_public_identifier,
    between_doctype_public_and_system_identifiers,
    after_doctype_system_keyword,
    before_doctype_system_identifier,
    doctype_system_identifier_double_quoted,
    doctype_system_identifier_single_quoted,
    after_doctype_system_identifier,
    bogus_doctype,
    cdata_section,
    cdata_section_bracket,
    cdata_section_end,
    character_reference,
    named_character_reference,
    ambiguous_ampersand,
    numeric_character_reference,
    hexadecimal_character_reference_start,
    decimal_character_reference_start,
    hexadecimal_character_reference,
    decimal_character_reference,
    numeric_character_reference_end,
};

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
    publid_id: []u21,
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
    doctype: DoctypeToken,
    start_tag: TagToken,
    end_tag: TagToken,
    comment: CommentToken,
    character: CharacterToken,
    eof: EOFToken,
};

pub const TokenSink = fn (token: Token) anyerror!void;
