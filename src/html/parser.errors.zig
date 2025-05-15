/// https://html.spec.whatwg.org/multipage/parsing.html#parse-errors
pub const HTMLParserErrors = error{
    ControlCharacterInInputStream,
    EOFInCdata,
    EOFInComment,
    EOFInDoctype,
    EOFInScriptHtmlCommentLikeText,
    EOFInTag,
    NoncharacterInInputStream,
    SurrogateInInputStream,
};
