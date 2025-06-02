const parser_errors = @import("./parser.errors.zig");
/// https://html.spec.whatwg.org/multipage/parsing.html#tokenization
pub const TokenizerState = enum {
    after_attribute_name,
    after_attribute_value_quoted,
    after_doctype_name,
    after_doctype_public_identifier,
    after_doctype_public_keyword,
    after_doctype_system_identifier,
    after_doctype_system_keyword,
    ambiguous_ampersand,
    attribute_name,
    attribute_value_double_quoted,
    attribute_value_single_quoted,
    attribute_value_unquoted,
    before_attribute_name,
    before_attribute_value,
    before_doctype_name,
    before_doctype_public_identifier,
    before_doctype_system_identifier,
    between_doctype_public_and_system_identifiers,
    bogus_comment,
    bogus_doctype,
    cdata_section,
    cdata_section_bracket,
    cdata_section_end,
    character_reference,
    comment,
    comment_end,
    comment_end_bang,
    comment_end_dash,
    comment_less_than_sign,
    comment_less_than_sign_bang,
    comment_less_than_sign_bang_dash,
    comment_less_than_sign_bang_dash_dash,
    comment_start,
    comment_start_dash,
    data,
    decimal_character_reference,
    decimal_character_reference_start,
    doctype,
    doctype_name,
    doctype_public_identifier_double_quoted,
    doctype_public_identifier_single_quoted,
    doctype_system_identifier_double_quoted,
    doctype_system_identifier_single_quoted,
    end_tag_open,
    hexadecimal_character_reference,
    hexadecimal_character_reference_start,
    markup_declaration_open,
    named_character_reference,
    numeric_character_reference,
    numeric_character_reference_end,
    plaintext,
    rawtext,
    rawtext_end_tag_name,
    rawtext_end_tag_open,
    rawtext_less_than_sign,
    rcdata,
    rcdata_end_tag_name,
    rcdata_end_tag_open,
    rcdata_less_than_sign,
    script_data,
    script_data_double_escape_end,
    script_data_double_escape_start,
    script_data_double_escaped,
    script_data_double_escaped_dash,
    script_data_double_escaped_dash_dash,
    script_data_double_escaped_less_than_sign,
    script_data_end_tag_name,
    script_data_end_tag_open,
    script_data_escape_start,
    script_data_escape_start_dash,
    script_data_escaped,
    script_data_escaped_dash,
    script_data_escaped_dash_dash,
    script_data_escaped_end_tag_name,
    script_data_escaped_end_tag_open,
    script_data_escaped_less_than_sign,
    script_data_less_than_sign,
    self_closing_start_tag,
    tag_name,
    tag_open,
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
