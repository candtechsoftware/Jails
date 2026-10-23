SEMANTIC_TOKEN_TYPES :: string.[
    "namespace",
    "type",
    "struct",
    "enum",
    "typeParameter",
    "parameter",
    "variable",
    "property",
    "enumMember",
    "function",
    "macro",
    "keyword",
    "comment",
    "string",
    "number",
    "operator",
    "decorator",
];

SEMANTIC_TOKEN_MODIFIERS :: string.["declaration", "readonly", "deprecated", "defaultLibrary"];

Semantic_Token_Type :: enum u32 {
    NAMESPACE;
    TYPE;
    STRUCT;
    ENUM;
    TYPE_PARAMETER;
    PARAMETER;
    VARIABLE;
    PROPERTY;
    ENUM_MEMBER;
    FUNCTION;
    MACRO;
    KEYWORD;
    COMMENT;
    STRING;
    NUMBER;
    OPERATOR;
    DECORATOR;

    NONE;
}

#assert SEMANTIC_TOKEN_TYPES.count == cast(int) Semantic_Token_Type.NONE;

Semantic_Token_Modifier :: enum_flags u32 {
    NONE            :: 0x0;
    DECLARATION     :: 0x1;
    READONLY        :: 0x2;
    DEPRECATED      :: 0x4;
    DEFAULT_LIBRARY :: 0x8;
}

BUILTIN_TYPE_NAMES :: string.["void", "bool", "int", "s8", "s16", "s32", "s64", "u8", "u16", "u32",
                              "u64", "float", "float32", "float64", "string", "Any", "Type", "Code"];

Token_Emitter :: struct {
    data: [..]u32;

    previous_line: int;
    previous_character: int;

    content: string;
    line_starts: []int;
}

handle_semantic_tokens :: (id: JSON_Value, uri: string) {
    push_allocator(temp);

    file_path := normalize_path(uri);
    file := get_file(file_path);
    memory_content, found := get_memory_file(file_path);
    content := cast(string) memory_content;

    if !found || !file || file.tokens.count == 0 || content.count == 0 {
        lsp_respond(id, null);
        return;
    }

    emitter: Token_Emitter;
    emitter.content = content;
    emitter.line_starts = build_line_starts(content);
    array_reserve(*emitter.data, file.tokens.count * 5);

    nodes_at := build_nodes_at(file);
    collect_semantic_tokens(*emitter, *nodes_at, file);

    lsp_respond(id, LSP_Semantic_Tokens.{data = emitter.data});
}

build_line_starts :: (content: string) -> []int {
    starts: [..]int;
    array_add(*starts, 0);

    for index: 0..content.count-1 {
        if content[index] == #char "\n" array_add(*starts, index + 1);
    }

    return starts;
}

node_position_key :: (line: int, character: int) -> u64 {
    return ((cast(u64) line) << 32) | ((cast(u64) character) & 0xFFFF_FFFF);
}

build_nodes_at :: (file: *Program_File) -> Table(u64, *Node) {
    nodes_at: Table(u64, *Node);
    table_resize(*nodes_at, file.nodes.count);

    for node: file.nodes {
        key := node_position_key(node.location.l0, node.location.c0);

        if node.kind == .DECLARATION {
            if (cast(*Declaration) node).name.count > 0 table_set(*nodes_at, key, node);
        } else if node.kind == .IDENTIFIER {
            entry, is_new := find_or_add(*nodes_at, key);
            if is_new entry.* = node;
        }
    }

    return nodes_at;
}

collect_semantic_tokens :: (emitter: *Token_Emitter, nodes_at: *Table(u64, *Node), file: *Program_File) {
    token_index := 0;
    comment_index := 0;

    modifier_head := Semantic_Token_Type.NONE;

    while token_index < file.tokens.count || comment_index < file.comments.count {
        take_comment := token_index >= file.tokens.count;

        if !take_comment && comment_index < file.comments.count {
            comment := file.comments[comment_index];
            token := file.tokens[token_index];
            take_comment = comment.l0 < token.l0 || (comment.l0 == token.l0 && comment.c0 < token.c0);
        }

        if take_comment {
            comment := file.comments[comment_index];
            comment_index += 1;
            emit_span(emitter, comment.l0, comment.c0, comment.l1, comment.c1, .COMMENT, .NONE);
            continue;
        }

        emit_token(emitter, nodes_at, file.tokens[token_index], *modifier_head);
        token_index += 1;
    }
}

emit_token :: (emitter: *Token_Emitter, nodes_at: *Table(u64, *Node), token: Token, modifier_head: *Semantic_Token_Type) {
    type := Semantic_Token_Type.NONE;
    modifiers: Semantic_Token_Modifier;

    character := token.c0;
    is_identifier := token.kind == .IDENTIFIER;

    if is_identifier {
        identifier_type, identifier_modifiers, resolved := classify_identifier_token(nodes_at, token);
        if resolved {
            type = identifier_type;
            modifiers = identifier_modifiers;
        } else {
            type = modifier_head.*;
        }
    } else if token.kind == .NUMBER {
        type = .NUMBER;
    } else if token.kind == .STRING {
        type = .STRING;
    } else if token.kind == .DIRECTIVE {
        type = .MACRO;
        character -= 1;
    } else if token.kind == .NOTE {
        type = .DECORATOR;
        character -= 1;
    } else if is_keyword_token(token.kind) {
        type = .KEYWORD;
    } else if is_operator_token(token.kind) {
        type = .OPERATOR;
    }

    advance_modifier_head(token, modifier_head, is_identifier && type == modifier_head.*);

    emit_span(emitter, token.l0, character, token.l1, token.c1, type, modifiers);
}

advance_modifier_head :: (token: Token, modifier_head: *Semantic_Token_Type, continues_run: bool) {
    if token.kind == .DIRECTIVE {
        modifier_head.* = .MACRO;
    } else if token.kind == .KEYWORD_CAST || token.kind == .KEYWORD_USING {
        modifier_head.* = .KEYWORD;
    } else if token.kind != #char "," && !continues_run {
        modifier_head.* = .NONE;
    }
}

emit_span :: (emitter: *Token_Emitter, l0: int, c0: int, l1: int, c1: int, type: Semantic_Token_Type, modifiers: Semantic_Token_Modifier) {
    if type == .NONE return;
    if l0 < 0 || l1 < l0 return;

    for line: l0..l1 {
        if line >= emitter.line_starts.count break;

        line_start := emitter.line_starts[line];
        line_end := ifx line + 1 < emitter.line_starts.count then emitter.line_starts[line + 1] else emitter.content.count;
        length := line_end - line_start;

        start := ifx line == l0 then c0 else 0;
        end := ifx line == l1 then c1 else length;

        if start < 0 start = 0;
        if end > length end = length;

        while end > start {
            if !is_space(emitter.content[line_start + end - 1]) break;
            end -= 1;
        }

        if end <= start continue;

        line_content := slice(emitter.content, line_start, length);
        start = byte_column_to_utf16_column(line_content, start);
        end = byte_column_to_utf16_column(line_content, end);
        delta_line := line - emitter.previous_line;
        delta_character := ifx delta_line == 0 then start - emitter.previous_character else start;

        array_add(*emitter.data, xx delta_line);
        array_add(*emitter.data, xx delta_character);
        array_add(*emitter.data, xx (end - start));
        array_add(*emitter.data, xx type);
        array_add(*emitter.data, xx modifiers);

        emitter.previous_line = line;
        emitter.previous_character = start;
    }
}

is_keyword_token :: (kind: Token.Kind) -> bool {
    value := cast(int) kind;
    return value >= cast(int) Token.Kind.KEYWORD_STRUCT && value <= cast(int) Token.Kind.KEYWORD_AUTO_CAST;
}

OPERATOR_CHARACTERS :: "+-*/%<>=&|^~!:$.";

is_operator_token :: (kind: Token.Kind) -> bool {
    value := cast(int) kind;

    if value < 256 return find_index_from_left(OPERATOR_CHARACTERS, cast(u8) value) >= 0;

    if value >= cast(int) Token.Kind.PLUS_EQUAL && value <= cast(int) Token.Kind.DECLARATION_AND_ASSIGN return true;

    return kind == .QUICK_LAMBDA;
}

classify_identifier_token :: (nodes_at: *Table(u64, *Node), token: Token) -> Semantic_Token_Type, Semantic_Token_Modifier, bool {
    found, node := table_find(nodes_at, node_position_key(token.l0, token.c0));
    if !found return .NONE, .NONE, false;

    if node.kind == .DECLARATION {
        type, modifiers := classify_declaration(cast(*Declaration) node);
        return type, modifiers | .DECLARATION, true;
    }

    type, modifiers := classify_identifier(cast(*Identifier) node);
    return type, modifiers, true;
}

classify_declaration :: (decl: *Declaration) -> Semantic_Token_Type, Semantic_Token_Modifier {
    modifiers: Semantic_Token_Modifier;
    if decl.const modifiers |= .READONLY;
    if is_default_library(decl.location.file) modifiers |= .DEFAULT_LIBRARY;

    held: *Node = decl;
    parent := decl.parent;
    if parent && parent.kind == .USING {
        held = parent;
        parent = parent.parent;
    }

    if parent {
        if parent.kind == .POLYMORPHIC_CONSTANT return .TYPE_PARAMETER, modifiers;

        if parent.kind == .PROCEDURE {
            proc := cast(*Procedure) parent;

            for argument: proc.arguments {
                if argument == held return .PARAMETER, modifiers;
            }

            for return_value: proc.returns {
                if return_value.expression == decl return .PARAMETER, modifiers;
            }
        }

        if parent.kind == .STRUCT {
            for argument: (cast(*Struct) parent).polymorphic_arguments {
                if argument == held return .TYPE_PARAMETER, modifiers;
            }
        }

        if parent.kind == .UNION {
            for argument: (cast(*Union) parent).polymorphic_arguments {
                if argument == held return .TYPE_PARAMETER, modifiers;
            }
        }

        if parent.kind == .BLOCK && parent.parent {
            if parent.parent.kind == .ENUM return .ENUM_MEMBER, modifiers;

            member_of_type := parent.parent.kind == .STRUCT || parent.parent.kind == .UNION;
            if member_of_type && !decl.const return .PROPERTY, modifiers;
        }
    }

    if decl.expression {
        if decl.expression.kind == {
            case .PROCEDURE;
                proc := cast(*Procedure) decl.expression;
                if proc.deprecated_note.count > 0 modifiers |= .DEPRECATED;
                if proc.flags & .MACRO return .MACRO, modifiers;
                return .FUNCTION, modifiers;

            case .STRUCT; #through;
            case .UNION;
                return .STRUCT, modifiers;

            case .ENUM;
                return .ENUM, modifiers;

            case .DIRECTIVE_IMPORT; #through;
            case .DIRECTIVE_LOAD; #through;
            case .DIRECTIVE_LIBRARY;
                return .NAMESPACE, modifiers;

            case .DIRECTIVE_TYPE;
                return .TYPE, modifiers;
        }
    }

    return .VARIABLE, modifiers;
}

classify_identifier :: (ident: *Identifier) -> Semantic_Token_Type, Semantic_Token_Modifier {
    if ident.name == "null" return .KEYWORD, .NONE;
    if ident.name == "context" return .KEYWORD, .NONE;

    parent := ident.parent;

    if parent {
        if parent.kind == .FOR {
            _for := cast(*For) parent;
            if _for.value == ident || _for.index == ident return .VARIABLE, .DECLARATION;
        }

        if parent.kind == .COMPOUND_DECLARATION_ITEM {
            if (cast(*Compound_Declaration_Item) parent).item_kind == .DECLARATION return .VARIABLE, .DECLARATION;
        }

        if parent.kind == .BLOCK && parent.parent && parent.parent.kind == .ENUM {
            return .ENUM_MEMBER, .DECLARATION;
        }

        if parent.kind == .POLYMORPHIC_CONSTANT {
            if (cast(*Polymorphic_Constant) parent).expression == ident return .TYPE_PARAMETER, .DECLARATION;
        }

        if parent.kind == .UNARY_OPERATION {
            unary := cast(*Unary_Operation) parent;
            if unary.operation == .DOT && unary.expression == ident return .ENUM_MEMBER, .NONE;
        }

        if parent.kind == .BINARY_OPERATION {
            binary := cast(*Binary_Operation) parent;

            if binary.operation == .ASSIGN && binary.left == ident && binary.parent {
                if binary.parent.kind == .PROCEDURE_CALL return .PARAMETER, .NONE;
                if binary.parent.kind == .LITERAL return .PROPERTY, .NONE;
            }
        }
    }

    in_type_position := is_in_type_position(ident);

    if !in_type_position && parent && parent.kind == .BINARY_OPERATION {
        binary := cast(*Binary_Operation) parent;
        if binary.operation == .DOT && binary.right == ident {
            if is_enum_reference(binary.left) return .ENUM_MEMBER, .NONE;
            return .PROPERTY, .NONE;
        }
    }

    type := Semantic_Token_Type.NONE;
    modifiers: Semantic_Token_Modifier;

    decl := resolve_identifier(ident);
    if decl type, modifiers = classify_declaration(decl);

    if in_type_position {
        if !decl || type == .VARIABLE || type == .FUNCTION return .TYPE, .NONE;
        return type, modifiers & .DEFAULT_LIBRARY;
    }

    if parent && parent.kind == .PROCEDURE_CALL && (cast(*Procedure_Call) parent).procedure == ident {
        if type == .STRUCT || type == .ENUM || type == .MACRO return type, modifiers;
        return .FUNCTION, modifiers;
    }

    if decl return type, modifiers;
    if array_find(BUILTIN_TYPE_NAMES, ident.name) return .TYPE, .NONE;

    return .VARIABLE, .NONE;
}

is_in_type_position :: (node: *Node) -> bool {
    child := node;
    parent := node.parent;

    depth := 0;
    while parent && depth < 16 {
        depth += 1;

        if parent.kind == {
            case .DECLARATION;
                return (cast(*Declaration) parent).type_inst == child;

            case .PROCEDURE;
                for return_value: (cast(*Procedure) parent).returns {
                    if return_value.expression == child return true;
                }
                return false;

            case .RETURN_VALUE;
                return (cast(*Return_Value) parent).expression == child;

            case .CAST;
                return (cast(*Cast) parent).cast_expression == child;

            case .ARRAY_TYPE;
                return (cast(*Array_Type) parent).element_type == child;

            case .ENUM;
                return (cast(*Enum) parent).type == child;

            case .DIRECTIVE_TYPE;
                return true;

            case .LITERAL;
                literal := cast(*Literal) parent;
                if literal.value_type == .STRUCT return literal.values.struct_literal_info.type == child;
                if literal.value_type == .ARRAY  return literal.values.array_literal_info.element_type == child;
                return false;

            case .UNARY_OPERATION;
                if (cast(*Unary_Operation) parent).operation != .POINTER return false;

            case .PROCEDURE_CALL; #through;
            case .BINARY_OPERATION;

            case;
                return false;
        }

        child = parent;
        parent = parent.parent;
    }

    return false;
}

is_enum_reference :: (node: *Node) -> bool {
    if !node || node.kind != .IDENTIFIER return false;

    decl := resolve_identifier(cast(*Identifier) node);
    if !decl || !decl.expression return false;

    return decl.expression.kind == .ENUM;
}

is_default_library :: (path: string) -> bool {
    if server.args.jai_path.count == 0 return false;
    return begins_with(path, server.args.jai_path);
}
