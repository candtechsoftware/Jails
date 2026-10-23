

handle_completitions :: (request: LSP_Request_Message_Completion) {
    push_allocator(temp);

    file_path := normalize_path(request.params.textDocument.uri);

    file := get_file(file_path);
    if !file {
        lsp_respond(request.id, null);
        return;
    }

    cursor_location := lsp_location_to_node_location(request.params.position, file_path);

    // We don't wanna to give completions inside comments.
    if inside_comment(cursor_location) {
        lsp_respond(request.id, null);
        return;
    }

    cursor_node := get_node_by_location(file, cursor_location);

    if cursor_node && cursor_node.kind == .IDENTIFIER && cursor_node.parent && cursor_node.parent.kind == .UNARY_OPERATION {
        unary := cast(*Unary_Operation) cursor_node.parent;
        if unary.operation == .DOT {
            cursor_node = unary;
        }
    }

    if cursor_node {
        // We don't wanna to give completions inside strings.
        if cursor_node.kind == .DIRECTIVE_STRING || (cursor_node.kind == Node.Kind.LITERAL && cursor_node.(*Literal).value_type == .STRING) {
            lsp_respond(request.id, null);
            return;
        }

        if cursor_node.kind == .DIRECTIVE_IMPORT {
            handle_completitions_import(request, xx cursor_node);
            return;
        }

        if cursor_node.kind == .DIRECTIVE_LOAD {
            handle_completitions_load(request, file, xx cursor_node);
            return;
        }
    }

    if handle_struct_literal_completions(request, file, cursor_location) return;

    if cursor_node {
        if handle_dot_completitions(request, cursor_node, cursor_location) {
            return;
        }

        if handle_procedure_argument_completions(request, cursor_node) {
            return;
        }

        if handle_assignment_completitions(request, cursor_node) {
            return;
        }

        if handle_case_completions(request, cursor_node) {
            return;
        }

        if handle_types_in_declaration(request, cursor_node) {
            return;
        }

        // if handle_completitions_procedure_call(request, file, cursor_node, *cursor_location) {
        //     return;
        // }
    }

    prefix, after_dot := get_completion_prefix(file_path, cursor_location);
    if after_dot {
        lsp_respond(request.id, null);
        return;
    }

    // General
    local_count: int;
    decls := get_declarations(file, cursor_node, *cursor_location, local_count=*local_count);
    send_completions_decls(request, decls, should_add_basic_keywords=true, prefix=prefix, local_count=local_count);
}

Literal_Completion_Frame :: struct {
    opening: int;
    entry_start: int;
}

// Tokens retain the entry boundary even when the cursor is in whitespace or
// the literal has no closing brace yet. Never inspect nested expressions as
// though their identifiers were field names of the surrounding literal.
handle_struct_literal_completions :: (request: LSP_Request_Message_Completion, file: *Program_File, cursor_location: Node.Location) -> bool {
    cursor := cursor_location;

    frames: [..]Literal_Completion_Frame;
    next_index := 0;
    for token, index: file.tokens {
        if token.l0 > cursor.l0 || (token.l0 == cursor.l0 && token.c0 >= cursor.c0) break;
        next_index = index + 1;
        if token.kind == .BEGIN_STRUCT_LITERAL || token.kind == .BEGIN_ARRAY_LITERAL || token.kind == #char "{" || token.kind == #char "[" || token.kind == #char "(" {
            array_add(*frames, .{index, index + 1});
        } else if token.kind == #char "}" || token.kind == #char "]" || token.kind == #char ")" {
            if frames.count > 0 frames.count -= 1;
        } else if token.kind == #char "," && frames.count > 0 {
            frames[frames.count - 1].entry_start = index + 1;
        }
    }

    if frames.count == 0 return false;
    frame := frames[frames.count - 1];
    begin := file.tokens[frame.opening];
    if begin.kind != .BEGIN_STRUCT_LITERAL return false;

    name_token: *Token;
    for index: frame.entry_start..next_index-1 {
        token := *file.tokens[index];
        if name_token || token.kind != .IDENTIFIER return false;
        name_token = token;
    }

    // Include the complete identifier when completing at its start or middle.
    if !name_token && next_index < file.tokens.count {
        token := *file.tokens[next_index];
        if token.kind == .IDENTIFIER && token.l0 == cursor.l0 && token.c0 == cursor.c0 name_token = token;
    }
    if name_token && (name_token.l0 != cursor.l0 || name_token.l1 != cursor.l0 || cursor.c0 > name_token.c1) return false;

    begin_location := Node.Location.{l0=begin.l0, c0=begin.c0, l1=begin.l0, c1=begin.c0, file=file.path};
    literal: *Literal;
    for node: file.nodes {
        if node.kind != .LITERAL continue;
        candidate := cast(*Literal) node;
        if candidate.value_type != .STRUCT || !contains(candidate.location, begin_location) continue;
        if !literal || contains(literal.location, candidate.location) literal = candidate;
    }
    if !literal return false;

    type := get_struct_literal_type(literal);
    if !type {
        lsp_respond(request.id, null);
        return true;
    }

    prefix := "";
    edit_range: LSP_Range;
    edit_range.start = request.params.position;
    edit_range.end = request.params.position;
    lookahead := next_index;
    if name_token {
        prefix = slice(name_token.string_value, 0, min(cursor.c0 - name_token.c0, name_token.string_value.count));
        name_location := Node.Location.{l0=name_token.l0, c0=name_token.c0, l1=name_token.l1, c1=name_token.c1, file=file.path};
        edit_range = node_location_to_lsp_location(name_location).range;
        if lookahead < file.tokens.count && *file.tokens[lookahead] == name_token lookahead += 1;
    }
    has_assignment := lookahead < file.tokens.count && file.tokens[lookahead].kind == #char "=";

    excluded: Table(string, bool);
    for entry: literal.values.struct_literal_info.body {
        if entry.kind != .BINARY_OPERATION continue;
        op := cast(*Binary_Operation) entry;
        if op.operation != .ASSIGN || !op.left || op.left.kind != .IDENTIFIER continue;
        ident := cast(*Identifier) op.left;
        if name_token && ident.location.l0 == name_token.l0 && ident.location.c0 == name_token.c0 continue;
        table_set(*excluded, ident.name, true);
    }

    decls: [..]*Declaration;
    add_all_fields_of(*decls, type);
    completions: [..]LSP_Completion_Item;
    truncated := false;
    for decl: decls {
        if decl.const || (!decl.type_inst && !decl.expression) continue;
        if !begins_with(decl.name, prefix) || table_contains(*excluded, decl.name) continue;
        if completions.count >= MAX_COMPLETIONS {
            truncated = true;
            break;
        }

        item: LSP_Completion_Item;
        item.label = decl.name;
        item.kind = xx LSP_Completion_Item.Kind.Field;
        item.sortText = tprint("%", formatInt(completions.count, minimum_digits=5));
        item.insertText = ifx has_assignment then decl.name else tprint("% = ", decl.name);
        item.textEdit = New(LSP_Text_Edit);
        item.textEdit.range = edit_range;
        item.textEdit.newText = item.insertText;
        preview := ifx decl.type_inst then decl.type_inst else decl.expression;
        item.labelDetails.description = completion_description(decl, preview);
        array_add(*completions, item);
        table_set(*excluded, decl.name, true);
    }

    lsp_respond(request.id, LSP_Completion_List.{isIncomplete=truncated, items=completions});
    return true;
}

// handle_completitions_procedure_call :: (request: LSP_Request_Message_Completion, file: *Program_File, cursor_node: *Node, cursor_location: *Node.Location) -> bool {
//     proc_call := cast(*Procedure_Call) get_node_nearest_parent(cursor_node, kind => kind == .PROCEDURE_CALL);
//     if !proc_call {
//         return false;
//     }

//     if !proc_call.procedure || proc_call.procedure.kind != .IDENTIFIER {
//         return false;
//     }
//     procedure_ident := cast(*Identifier) proc_call.procedure;

//     decls := get_declarations(file, procedure_ident, cursor_location, procedure_ident.name);
//     if decls.count == 0 {
//         return false;
//     }

//     procedure_decl := decls[0];
//     if !procedure_decl.expression || procedure_decl.expression.kind != .PROCEDURE {
//         return false;
//     }

//     procedure := cast(*Procedure) procedure_decl.expression;

//     completions: [..]LSP_Completion_Item;

//     for arg: procedure.arguments {
//         if arg.kind != .DECLARATION && arg.kind != .POLYMORPHIC_CONSTANT {
//             continue;
//         }

//         unwrapped := unwrap_polymorphic_constant(arg);
//         if !unwrapped {
//             continue;
//         }

//         assert(unwrapped.kind == .DECLARATION);

//         decl := cast(*Declaration) unwrapped;

//         array_add(*completions, LSP_Completion_Item.{
//             label=decl.name,
//             insertText=tprint("%=$0", decl.name),
//             kind=xx LSP_Completion_Item.Kind.Property,
//             insertTextFormat=xx LSP_Completion_Item.Insert_Text_Format.SNIPPET,
//         });
//     }

//     lsp_respond(request.id, completions);
//     return true;
// }

handle_completitions_load :: (request: LSP_Request_Message_Completion, file: *Program_File, directive_load: *Directive_Load) {
    completions: [..]LSP_Completion_Item;
    current_file_dir := path_strip_filename(file.path);

    visit_file :: (info: *File_Visit_Info, completions: *[..]LSP_Completion_Item) {
        if !info.is_directory && !contains(info.short_name, ".jai") return;

        array_add(completions, .{
            label=info.short_name,
            kind=xx (ifx info.is_directory then LSP_Completion_Item.Kind.Folder else LSP_Completion_Item.Kind.File),
            insertText=info.short_name,
            insertTextFormat=xx LSP_Completion_Item.Insert_Text_Format.SNIPPET,
            labelDetails = .{ description=info.full_name }
        });
    }

    path_to_visit := current_file_dir;
    if contains(directive_load.file, "/") {
        path_to_visit = tprint("%/%", path_to_visit, directive_load.file);
    }

    is_dir, ok := is_directory(path_to_visit);
    if !is_dir || !ok {
        lsp_respond(request.id, null);
        return;
    }

    visit_files(path_to_visit, false, *completions, visit_file, true, true);

    lsp_respond(request.id, completions);
}

handle_completitions_import :: (request: LSP_Request_Message_Completion, directive_import: *Directive_Import) {
    completions: [..]LSP_Completion_Item;

    modules_dir := sprint("%/modules", server.args.jai_path);

    visit_modules :: (info: *File_Visit_Info, completions: *[..]LSP_Completion_Item) {
        if !info.is_directory && !contains(info.short_name, ".jai") return;

        module_name := info.short_name;
        if !info.is_directory {
            module_name = replace(info.short_name, ".jai", "");
        } else {
            if !file_exists(tprint("%/module.jai", info.full_name)) return;
        }

        array_add(completions, .{
            label=module_name,
            kind=xx LSP_Completion_Item.Kind.Module,
            insertText=module_name,
            insertTextFormat=xx LSP_Completion_Item.Insert_Text_Format.SNIPPET,
            labelDetails = .{ description=info.full_name }
        });
    }

    // Compiler modules
    visit_files(modules_dir, false, *completions, visit_modules, true, true);

    // Local modules
    for local_module: server.local_modules {
        local_modules_dir := tprint("%/%", server.project_root, local_module);
        visit_files(local_modules_dir, false, *completions, visit_modules, true, true);
    }

    lsp_respond(request.id, completions);
}

handle_dot_completitions :: (request: LSP_Request_Message_Completion, cursor_node: *Node, cursor_location: Node.Location) -> bool {
    if !cursor_node {
        return false;
    }

    op: *Binary_Operation;
    search_node := cursor_node;
    while search_node {
        if search_node.kind == .PROCEDURE_CALL {
            call := cast(*Procedure_Call) search_node;
            if !call.procedure || !contains(call.procedure.location, cursor_location) return false;
        }

        if search_node == cursor_node && is_dot_binary_op(search_node) {
            op = cast(*Binary_Operation) search_node;
            break;
        }

        if search_node.parent && is_dot_binary_op(search_node.parent) {
            parent_dot := cast(*Binary_Operation) search_node.parent;
            if search_node == parent_dot.right {
                op = parent_dot;
                break;
            }
        }

        search_node = search_node.parent;
    }

    if !op return false;

    path: [..]*Node;
    ancestor_receivers: [..]*Node;
    child: *Node = op;
    parent := op.parent;
    while parent && is_dot_binary_op(parent) {
        parent_dot := cast(*Binary_Operation) parent;
        if child != parent_dot.right break;
        array_add(*ancestor_receivers, parent_dot.left);
        child = parent;
        parent = parent.parent;
    }

    i := ancestor_receivers.count - 1;
    while i >= 0 {
        append_completion_receiver_path(*path, ancestor_receivers[i]);
        i -= 1;
    }
    append_completion_receiver_path(*path, op.left);

    type := get_path_type(path);
    if !type {
        lsp_respond(request.id, null);
        return true;
    }

    return handle_completitions_for_node(request, type);
}

append_completion_receiver_path :: (path: *[..]*Node, node: *Node) {
    if !node return;

    if is_dot_binary_op(node) {
        dot := cast(*Binary_Operation) node;
        append_completion_receiver_path(path, dot.left);
        append_completion_receiver_path(path, dot.right);
        return;
    }

    array_add(path, node);
}

handle_procedure_argument_completions :: (request: LSP_Request_Message_Completion, cursor_node: *Node) -> bool {
    if cursor_node.kind != .UNARY_OPERATION return false;

    unary := cast(*Unary_Operation) cursor_node;

    call, argument_node, argument_name := get_call_argument_context(unary);
    if !call return false;

    argument_type := get_argument_type_for_call(call, argument_node, argument_name);
    if !argument_type || (argument_type.kind != .ENUM && argument_type.kind != .STRUCT && argument_type.kind != .UNION) {
        lsp_respond(request.id, null);
        return true;
    }

    if !handle_completitions_for_node(request, argument_type) {
        lsp_respond(request.id, null);
    }

    return true;
}

handle_types_in_declaration :: (request: LSP_Request_Message_Completion, cursor_node: *Node) -> bool {
    if cursor_node.kind == .UNARY_OPERATION && cursor_node.parent && cursor_node.parent.kind == .DECLARATION {
        node_type := get_node_type(cursor_node.parent);
        if !node_type {
            return false;
        }

        return handle_completitions_for_node(request, node_type);
    }

    return false;
}

handle_case_completions :: (request: LSP_Request_Message_Completion, cursor_node: *Node) -> bool {
    if cursor_node.kind == .UNARY_OPERATION && cursor_node.parent && cursor_node.parent.kind == .CASE {
        case_node := cast(*Case)cursor_node.parent;

        if case_node.parent && case_node.parent.kind == .BLOCK && case_node.parent.parent && case_node.parent.parent.kind == .IF {
            if_node := cast(*If)case_node.parent.parent;

            case_type := get_node_type(if_node.condition, 1);
            if !case_type {
                return false;
            }

            return handle_completitions_for_node(request, case_type);
        }
    }

    return false;
}

handle_assignment_completitions :: (request: LSP_Request_Message_Completion, cursor_node: *Node) -> bool {
    op: *Binary_Operation;
    if cursor_node.kind == .BINARY_OPERATION {
        op = cast(*Binary_Operation, cursor_node);
    } else if cursor_node.parent && cursor_node.parent.kind == .BINARY_OPERATION {
        op = cast(*Binary_Operation, cursor_node.parent);
    } else {
        return false;
    }

    if op.operation != .ASSIGN && op.operation != .IS_EQUAL && op.operation != .IS_NOT_EQUAL {
        return false;
    }

    // @TODO: support more types!
    if cursor_node.kind != .UNARY_OPERATION {
        return false;
    }

    left_type: *Node;
    if op.parent && op.parent.kind == .LITERAL {
        left_type = get_expected_type(cursor_node);
    } else {
        left_type = get_node_type(op, 1);
    }
    if !left_type {
        return false;
    }

    return handle_completitions_for_node(request, left_type);
}

handle_completitions_for_node :: (request: LSP_Request_Message_Completion, node: *Node) -> bool {
    decls: [..]*Declaration;
    defer array_free(decls);

    // This is a macro so the declaration survive until parent scope.
    add_decls_from_internal_array_struct :: (decls: *[..]*Declaration, resizable: bool, type: *Node) #expand {
        internal_array_struct := get_internal_array_struct(resizable);
        if !internal_array_struct {
            return;
        }

        for member: internal_array_struct.block.members {
            if member.kind != .DECLARATION {
                continue;
            }

            decl := cast(*Declaration) member;
            if decl.name == "data" && type {
                data_decl := Declaration.{
                    name = "data",
                    type_inst = *(Unary_Operation.{
                        operation=.POINTER,
                        expression=type
                    }),
                };

                array_add(decls, *data_decl);
                continue;
            }

            array_add(decls, decl);
        }
    }

    if node.kind == {
        case .UNION; #through;
        case .ENUM; #through;
        case .STRUCT;
            add_all_fields_of(*decls, node);

        case .ARRAY_TYPE;
            array_type := cast(*Array_Type, node);
            add_decls_from_internal_array_struct(*decls, array_type.resizable, array_type.element_type);

        case .IDENTIFIER;
            identifier := cast(*Identifier, node);

            if identifier.name == {
                case "string";
                    internal_string_struct := get_internal_string_struct();
                    if internal_string_struct {
                        return handle_completitions_for_node(request, internal_string_struct);
                    }
            }

        case .LITERAL;
            literal := cast(*Literal, node);

            if literal.value_type == {
                case .STRING;
                    internal_string_struct := get_internal_string_struct();
                    if internal_string_struct {
                        return handle_completitions_for_node(request, internal_string_struct);
                    }

                case .ARRAY;
                    array_literal_info := literal.values.array_literal_info;
                    add_decls_from_internal_array_struct(*decls, false, array_literal_info.element_type);
            }

        case .DIRECTIVE_IMPORT;
            import := cast(*Directive_Import) node;

            module_file := get_import_file(import);

            if !module_file {
                lsp_respond(request.id, null);
                return true;
            }

            for get_declarations(module_file, only_loaded=true, as_import=true) {
                array_add(*decls, it);
            }
    }

    // if decls.count == 0 {
    //     return false;
    // }

    file_path := normalize_path(request.params.textDocument.uri);
    cursor_location := lsp_location_to_node_location(request.params.position, file_path);
    prefix := get_completion_prefix(file_path, cursor_location);
    send_completions_decls(request, decls, prefix=prefix, members=true);

    return true;
}

BUILTIN_KEYWORDS :: string.[
    "struct", "union", "enum", "enum_flags", "if", "ifx", "else", "then", "for", "while", "case",
    "break", "continue", "remove", "return", "defer", "using", "cast", "xx", "inline", "no_inline",
    "push_context", "operator", "interface", "context", "null", "true", "false", "it", "it_index",
];

BUILTIN_PROCEDURES :: string.[
    "size_of", "type_of", "type_info", "is_constant", "enum_names", "enum_values", "initializer_of",
    "cast_no_check",
];

BUILTIN_DIRECTIVES :: string.[
    "#if", "#ifx", "#run", "#insert", "#code", "#compile_time", "#modify", "#placeholder",
    "#bake_arguments", "#bake_constants", "#expand", "#no_reset", "#assert", "#compiler", "#exists",
    "#procedure_name", "#procedure_of_call", "#location", "#caller_location", "#caller_code",
    "#file", "#filepath", "#line", "#dump", "#import", "#load", "#module_parameters",
    "#program_export", "#scope_file", "#scope_module", "#scope_export", "#add_context", "#Context",
    "#context", "#foreign", "#elsewhere", "#library", "#system_library", "#c_call", "#cpp_method",
    "#cpp_return_type_is_non_pod", "#intrinsic", "#no_context", "#type", "#as", "#align",
    "#overlay", "#place", "#no_padding", "#this", "#specified", "#complete", "#must",
    "#deprecated", "#symmetric", "#through", "#char", "#string", "#bytes", "#asm", "#no_abc",
    "#no_aoc", "#no_debug", "#poke_name", "#dynamic_specialize", "#discard", "#type_info_none",
    "#type_info_procedures_are_void_pointers", "#type_info_no_size_complaint",
];

get_completion_prefix :: (file_path: string, cursor_location: Node.Location) -> prefix: string, after_dot: bool {
    line := find_line_in_memory_file(file_path, .{line = xx cursor_location.l0});

    end := clamp(cursor_location.c0, 0, line.count);
    start := end;
    while start > 0 && is_alnum(line[start-1]) start -= 1;

    after_dot := start > 0 && line[start-1] == #char ".";
    if start > 0 && line[start-1] == #char "#" start -= 1;

    return slice(line, start, end - start), after_dot;
}

add_builtin_completions :: (completions: *[..]LSP_Completion_Item, prefix: string, seen: *Table(string, *Declaration), filter_by_prefix: bool) -> truncated: bool {
    add :: (completions: *[..]LSP_Completion_Item, names: []string, kind: LSP_Completion_Item.Kind, prefix: string, seen: *Table(string, *Declaration), filter_by_prefix: bool) -> bool {
        for names {
            if table_contains(seen, it) continue;
            if filter_by_prefix && !begins_with(it, prefix) continue;
            if completions.count >= MAX_COMPLETIONS return true;
            array_add(completions, .{label=it, sortText=tprint("3_%", it), insertText=it, kind=xx kind});
            table_set(seen, it, null);
        }
        return false;
    }

    if prefix.count > 0 && prefix[0] == #char "#" {
        return add(completions, BUILTIN_DIRECTIVES, .Keyword, prefix, seen, filter_by_prefix);
    }

    if add(completions, BUILTIN_TYPE_NAMES, .Keyword, prefix, seen, filter_by_prefix) return true;
    if add(completions, BUILTIN_KEYWORDS, .Keyword, prefix, seen, filter_by_prefix) return true;
    return add(completions, BUILTIN_PROCEDURES, .Function, prefix, seen, filter_by_prefix);
}

completion_kind_for_declaration :: (decl: *Declaration) -> LSP_Completion_Item.Kind {
    type, modifiers := classify_declaration(decl);

    if type == {
        case .NAMESPACE;      return .Module;
        case .STRUCT;         return .Struct;
        case .ENUM;           return .Enum;
        case .ENUM_MEMBER;    return .EnumMember;
        case .FUNCTION;       return .Function;
        case .MACRO;          return .Function;
        case .PROPERTY;       return .Field;
        case .TYPE_PARAMETER; return .TypeParameter;
        case .TYPE;           return .Struct;
        case .PARAMETER;      return .Variable;
    }

    if decl.const return .Constant;
    return .Variable;
}

MAX_COMPLETION_DESCRIPTION_ENTRIES :: 128;
MAX_COMPLETION_DESCRIPTION_BYTES :: 64 * 1024;

completion_description :: (decl: *Declaration, preview_node: *Node) -> string {
    push_allocator(temp);

    file := get_file(decl.location.file);
    if file {
        found, description := table_find(*file.completion_descriptions, decl);
        if found return description;
    }

    builder: String_Builder;
    ast_print(*builder, preview_node);
    description := builder_to_string(*builder);

    if !file || file.completion_descriptions.count >= MAX_COMPLETION_DESCRIPTION_ENTRIES return description;
    if description.count > MAX_COMPLETION_DESCRIPTION_BYTES - file.completion_description_bytes return description;

    owned := false;
    for candidate: table_find_multiple(*file.declarations, decl.name) {
        if candidate == decl {
            owned = true;
            break;
        }
    }
    if !owned return description;

    push_allocator(pool_alloc(*file.completion_pool));
    stored := copy_string(description);
    table_add(*file.completion_descriptions, decl, stored);
    file.completion_description_bytes += stored.count;
    return stored;
}

completion_declarations_are_overloads :: (a: *Declaration, b: *Declaration) -> bool {
    if !a || !b || a == b return false;
    if a.parent != b.parent || a.location.file != b.location.file return false;
    if !a.const || !b.const || !a.expression || !b.expression return false;
    return a.expression.kind == .PROCEDURE && b.expression.kind == .PROCEDURE;
}

send_completions_decls :: (request: LSP_Request_Message_Completion, decls: []*Declaration, should_add_basic_keywords := false, prefix := "", members := false, local_count := 0) {
    completions: [..]LSP_Completion_Item;
    defer array_free(completions);
    seen: Table(string, *Declaration);
    file_path := normalize_path(request.params.textDocument.uri);
    filter_by_prefix := prefix.count > 0 && (members || decls.count > MAX_COMPLETIONS);
    truncated := false;

    // Keep lexical scope order for locals, then current-file declarations,
    // then linked files. Member completion keeps its existing declaration order.
    for scope_rank: 0..2 {
        if members && scope_rank > 0 break;
        for decl, decl_index: decls {
            if !members {
                rank := ifx decl_index < local_count then 0 else ifx decl.location.file == file_path then 1 else 2;
                if rank != scope_rank continue;
                found, nearest := table_find(*seen, decl.name);
                if found && !completion_declarations_are_overloads(nearest, decl) continue;
            }
            if !decl.expression && !decl.type_inst continue;
            if filter_by_prefix && !begins_with(decl.name, prefix) continue;

            if completions.count >= MAX_COMPLETIONS {
                truncated = true;
                break;
            }

            preview_node: *Node;
            if decl.expression {
                preview_node = decl.expression;
            } else {
                preview_node = decl.type_inst;
            }

            item: LSP_Completion_Item;
            item.label = decl.name;
            if members {
                item.sortText = tprint("%", formatInt(completions.count, minimum_digits=5));
            } else if scope_rank == 0 {
                item.sortText = tprint("0_%", formatInt(decl_index, minimum_digits=10));
            } else {
                item.sortText = tprint("%_%", scope_rank, decl.name);
            }
            item.insertText = decl.name;
            item.insertTextFormat = xx LSP_Completion_Item.Insert_Text_Format.SNIPPET;
            item.kind = xx completion_kind_for_declaration(decl);

            if preview_node.kind == {
                case .PROCEDURE;
                    procedure := cast(*Procedure) preview_node;
                    item.deprecated = procedure.deprecated_note.count > 0;

                    if server.user_options.auto_insert_parentheses {
                        item.insertText = sprint("%($0)", decl.name);
                    }

                    item.labelDetails.description = completion_description(decl, preview_node);

                case .STRUCT;
                    item.labelDetails.description = "struct";

                case .UNION;
                    item.labelDetails.description = "union";

                case .ENUM;
                    item.labelDetails.description = "enum";

                case;
                    item.labelDetails.description = completion_description(decl, preview_node);
            }

            array_add(*completions, item);
            table_set(*seen, decl.name, decl);
        }
        if truncated break;
    }

    if should_add_basic_keywords {
        builtins_truncated := add_builtin_completions(*completions, prefix, *seen, filter_by_prefix);
        truncated = truncated || builtins_truncated;
    }

    lsp_respond(request.id, LSP_Completion_List.{
        isIncomplete = truncated || (filter_by_prefix && !members),
        items = completions,
    });
}
