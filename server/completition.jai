

// Extract the partial identifier the user has typed so far at the cursor position.
// Returns the text from the start of the current word to the cursor.
get_completion_prefix :: (file_path: string, position: LSP_Position) -> string {
    content := cast(string) get_memory_file(file_path);
    if content.count == 0 return "";

    // Find the byte offset of the start of the cursor's line
    current_line: u32 = 0;
    line_start := 0;

    for i: 0..content.count-1 {
        if current_line == position.line break;
        if content[i] == #char "\n" {
            current_line += 1;
            line_start = i + 1;
        }
    }

    // Cursor byte offset within the file
    cursor_offset := line_start + cast(int) position.character;
    if cursor_offset > content.count cursor_offset = content.count;

    // Walk backward from cursor to find identifier start
    start := cursor_offset;
    while start > line_start {
        c := content[start - 1];
        is_ident := (c >= #char "a" && c <= #char "z")
                 || (c >= #char "A" && c <= #char "Z")
                 || (c >= #char "0" && c <= #char "9")
                 || c == #char "_";
        if !is_ident break;
        start -= 1;
    }

    if start == cursor_offset return "";

    result: string;
    result.data = content.data + start;
    result.count = cursor_offset - start;
    return result;
}

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

    if cursor_node {
        // We don't wanna to give completions inside strings.
        if cursor_node.kind == .DIRECTIVE_STRING || (cursor_node.kind == Node.Kind.LITERAL && cursor_node.(*Literal).value_type == .STRING) {
            lsp_respond(request.id, null);
            return;
        }
        
        if cursor_node.kind == .LITERAL {
            handle_completions_struct(request, cursor_node);
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

        if handle_dot_completitions(request, cursor_node, cursor_location) {
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

    // Dot completion fallback: when cursor is right after "expr." and the AST didn't
    // produce a DOT binary op node at this position, look up the node before the dot
    // and resolve its type for member completions.
    {
        content := cast(string) get_memory_file(file_path);
        pos := request.params.position;
        if content.count > 0 && pos.character > 0 {
            // Find byte offset of cursor position
            current_line: u32 = 0;
            line_start := 0;
            for i: 0..content.count-1 {
                if current_line == pos.line break;
                if content[i] == #char "\n" {
                    current_line += 1;
                    line_start = i + 1;
                }
            }
            cursor_byte := line_start + cast(int) pos.character;
            if cursor_byte > 0 && cursor_byte <= content.count && content[cursor_byte - 1] == #char "." {
                // Character before cursor is a dot — try to resolve the expression before it
                pre_dot_pos := LSP_Position.{ line = pos.line, character = pos.character - 1 };
                pre_dot_location := lsp_location_to_node_location(pre_dot_pos, file_path);
                pre_dot_node := get_node_by_location(file, pre_dot_location);
                if pre_dot_node {
                    node_type := get_node_type(pre_dot_node);
                    if node_type && handle_completitions_for_node(request, node_type) {
                        return;
                    }
                }
            }
        }
    }

    // Text-based fallback for #import/#load completion when parser fails to produce AST nodes
    {
        content := cast(string) get_memory_file(file_path);
        pos := request.params.position;
        if content.count > 0 {
            // Find the current line text up to cursor
            current_line: u32 = 0;
            line_start := 0;
            for i: 0..content.count-1 {
                if current_line == pos.line break;
                if content[i] == #char "\n" {
                    current_line += 1;
                    line_start = i + 1;
                }
            }
            cursor_byte := line_start + cast(int) pos.character;
            if cursor_byte > content.count cursor_byte = content.count;

            line_up_to_cursor: string;
            line_up_to_cursor.data = content.data + line_start;
            line_up_to_cursor.count = cursor_byte - line_start;

            trimmed := trim_left(line_up_to_cursor);

            if contains(trimmed, "#import \"") {
                handle_completitions_import(request, null);
                return;
            }

            if contains(trimmed, "#load \"") {
                // Extract partial path after #load "
                partial_path := "";
                load_quote_idx := find_index_from_right(trimmed, "\"");
                if load_quote_idx >= 0 && load_quote_idx + 1 < trimmed.count {
                    partial_path = slice(trimmed, load_quote_idx + 1, trimmed.count - load_quote_idx - 1);
                }

                temp_load: Directive_Load;
                temp_load.file = partial_path;

                handle_completitions_load(request, file, *temp_load);
                return;
            }
        }
    }

    // General
    prefix := get_completion_prefix(file_path, request.params.position);
    decls := get_declarations(file, cursor_node, *cursor_location);
    send_completions_decls(request, decls, should_add_basic_keywords=true, prefix=prefix);
}

handle_completions_struct::(request:LSP_Request_Message_Completion, node:*Node) -> bool {
    literal := cast(*Literal)node;
    if literal.value_type == .STRUCT {
        // TODO: Infer the type for .{} structs literals... right now, assume struct_literal_info.type == null as undeterminable for completions.
        if !literal.struct_literal_info.type || literal.struct_literal_info.type.kind != .IDENTIFIER {
            return false;
        }

        identifier_decls := get_identifier_decls(cast(*Identifier) literal.struct_literal_info.type);
        if identifier_decls.count == 0 {
            return false;
        }
        
        struct_decl := identifier_decls[0];
        
        if struct_decl.expression == null {
            return false;
        }

        _struct := cast(*Struct) struct_decl.expression;

        block := get_block_of(_struct);

        if block == null {
            return false;
        }

        decls := get_block_member_declarations(block);
        
        send_completions_decls(request, decls);

        return true;
    }

    return false;
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
    if is_dot_binary_op(cursor_node) {
        op = cast(*Binary_Operation) cursor_node;
    } else if is_dot_binary_op(cursor_node.parent) {
        op = cast(*Binary_Operation) cursor_node.parent;
    } else {
        return false;
    }

    root_binary_op := op;
    while root_binary_op.right && root_binary_op.right.kind == .BINARY_OPERATION {
        right := cast(*Binary_Operation) root_binary_op.right;
        if right.operation != .DOT || is_after(cursor_location, right.location) {
            break;
        }

        root_binary_op = right;
    }

    if root_binary_op.operation != .DOT {
        return false;
    }

    path: [..]*Node;

    array_add(*path, root_binary_op.left);

    current := root_binary_op.parent;
    while current && current.kind == .BINARY_OPERATION {
        current_op := cast(*Binary_Operation) current;
        if current_op.operation != .DOT {
            break;
        }

        if current_op.left {
            array_add(*path, current_op.left);
        }

        current = current.parent;
    }

    array_reverse(path);

    type := get_path_type(path);
    if !type {
        lsp_respond(request.id, null);
        return true;
    }

    return handle_completitions_for_node(request, type);
}

handle_types_in_declaration :: (request: LSP_Request_Message_Completion, cursor_node: *Node) -> bool {
    if cursor_node.kind == .UNARY_OPERATION && cursor_node.parent && cursor_node.parent.kind == .DECLARATION {
        node_type := get_node_type(cursor_node.parent);

        return handle_completitions_for_node(request, node_type);
    }


    return false;
}

handle_case_completions :: (request: LSP_Request_Message_Completion, cursor_node: *Node) -> bool {
    if cursor_node.kind == .UNARY_OPERATION && cursor_node.parent && cursor_node.parent.kind == .CASE {
        case_node := cast(*Case)cursor_node.parent;

        if case_node.parent && case_node.parent.kind == .BLOCK && case_node.parent.parent && case_node.parent.parent.kind == .IF {
            if_node := cast(*If)case_node.parent.parent;

            case_type := get_node_type(if_node.condition, true);
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

    left_type := get_node_type(op, true);
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

            module_file_path := get_module_import_path(import, node.location.file);
            module_file := get_file(module_file_path);

            if !module_file {
                return false;
            }

            for get_declarations(module_file, only_loaded=true) {
                array_add(*decls, it);
            }
    }

    // if decls.count == 0 {
    //     return false;
    // }

    send_completions_decls(request, decls);

    return true;
}

add_basic_keywords :: (completions: *[..]LSP_Completion_Item, prefix := "") {
    keywords :: string.[
        "string", "bool", "int",
        "s64", "s32", "s16", "s8",
        "u8", "u16", "u32", "u64",
        "float", "float32", "float64",
        "Any",
        "struct", "enum", "enum_flags",
        "return", "break", "case", "remove", "continue",
        "if", "else", "for", "then", "using",
    ];

    for kw: keywords {
        if prefix.count > 0 && !begins_with(kw, prefix) continue;
        array_add(completions, .{label=kw, insertText=kw, kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    }
}

send_completions_decls :: (request: LSP_Request_Message_Completion, decls: []*Declaration, should_add_basic_keywords := false, prefix := "") {
    completions: [..]LSP_Completion_Item;
    defer array_free(completions);

    if should_add_basic_keywords {
        add_basic_keywords(*completions, prefix);
    }

    ast_print_to_string :: (node: *Node) -> string {
        builder: String_Builder;
        ast_print(*builder, node); // @Memory @TODO: we need to free this afterwards!!
        return builder_to_string(*builder);
    }

    for decl: decls {
        if !decl.expression && !decl.type_inst continue;

        // Filter by prefix if one was provided
        if prefix.count > 0 && !begins_with(decl.name, prefix) continue;

        preview_node: *Node;
        if decl.expression {
            preview_node = decl.expression;
        } else {
            preview_node = decl.type_inst;
        }

        item: LSP_Completion_Item;
        item.label = decl.name;
        item.insertText = decl.name;
        item.insertTextFormat=xx LSP_Completion_Item.Insert_Text_Format.SNIPPET;
        item.labelDetails.description = "---";

        if preview_node.kind == {
            case .PROCEDURE;
                item.kind = xx LSP_Completion_Item.Kind.Function;
                procedure := cast(*Procedure) preview_node;
                item.deprecated = procedure.deprecated_note.count > 0;

                if server.user_options.auto_insert_parentheses {
                    item.insertText = sprint("%($0)", decl.name);
                } else {
                    item.insertText = decl.name;
                }

                item.labelDetails.description = ast_print_to_string(preview_node);

            case .STRUCT;
                item.kind = xx LSP_Completion_Item.Kind.Struct;
                item.labelDetails.description = "struct";

            case .ENUM;
                item.kind = xx LSP_Completion_Item.Kind.Enum;
                item.labelDetails.description = "enum";

            case;
                item.kind = xx LSP_Completion_Item.Kind.Variable;
                item.labelDetails.description = ast_print_to_string(preview_node);
        }

        array_add(*completions, item);
    }

    lsp_respond(request.id, completions);
}
