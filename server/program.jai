Module_Import :: struct {
    module: string;
    root: string;
    target: *Program_File;
    is_using: bool;
}

Resolved_Load :: struct {
    resolved_path: string;
    target: *Program_File;
}

Parsed_Ast :: struct {
    imports: [..]Module_Import;
    loads: [..]Resolved_Load;
    usings: [..]*Using;
    add_contexts: [..]*Directive_Add_Context;
    nodes: [..]*Node;
    declarations: Table(string, *Declaration);
    comments: [..]Comment_Token;
    tokens: [..]Token;
    global_members: []*Node;
    has_syntax_errors: bool;
    nodes_at: Table(u64, *Node);
    nodes_at_built: bool;
}

Program_File :: struct {
    path: string;
    using ast: Parsed_Ast;

    global_block: Block;
    linked_files: []Linked_File; // @TODO: this is probably stupid name for this!

    global_scope: Table(string, *Declaration);
    global_scope_built: bool;

    ast_pools: [2]Pool;
    ast_pool_index: int;

    analysis_pool: Pool;

    completion_pool: Pool;
    completion_descriptions: Table(*Declaration, string);
    completion_description_bytes: int;
}

Linked_File :: struct {
    from_import: bool;
    file: *Program_File;
}

resizable_array_identifier := Identifier.{
    name = "Resizable_Array",
};

empty_identifier := Identifier.{
    name = "",
};

s64_node := Identifier.{
    name = "s64",
};

u8_node := Identifier.{
    name = "u8",
};

void_star_node := Identifier.{
    name = "*void",
};

unknown_identifier_node := Identifier.{
    name = "---",
};

array_count_declaration := Declaration.{
    name = "count",
    type_inst = xx *s64_node
};

// deinit_file :: (using file: *Program_File) {
//     deinit(*declarations);
//     array_free(nodes);
//     array_free(loads);
//     array_free(imports);
//     array_free(comments);
//     global_block.members.data = null;
//     global_block.members.count = 0;
//     release(*file.ast_pool);
//     release(*file.analysis_pool);
// }

get_file :: (path: string) -> *Program_File {
    ok, file := table_find(*server.files, path);
    if !ok return null;
    return file;
}

search_for_file :: (name: string) -> *Program_File {
    final_file: *Program_File;

    for file, file_name: server.files {
        if contains(file_name, name) {
            final_file = file;
        }
    }

    return final_file;
}

normalize_path :: (path: string) -> string {
    parsed: Path;
    {
        push_allocator(temp);
        normalized_path := decode_url(path);

        #if OS == .WINDOWS {
            normalized_path = replace(normalized_path, "file:///", "");
            path_overwrite_separators(normalized_path, #char "/");
        } else {
            normalized_path = replace(normalized_path, "file://", "");
        }

        parsed = parse_path(normalized_path, reduce=true);
    }
    return path_to_string(parsed);
}

normalize_and_copy_path :: (path: string) -> string {
    if(path.count == 0) {
        return "";
    }

    return normalize_path(path);
}

path_to_lsp_path :: (path: string) -> string {
    #if OS == .WINDOWS {
        return join("file:///", path);
    } else {
        return join("file://", path);
    }
}

pool_alloc :: (pool: *Pool) -> Allocator {
    return .{pool_allocator_proc, pool};
}

parse_into_file :: (file: *Program_File, content: string, path_without_filename: string) {
    parser: Parser(Node_Visit_Data);
    parser.user_data.allocator = context.allocator;
    parser.user_data.file = file;
    parser.user_data.path_without_filename = path_without_filename;
    parser.node_visit = node_visit;
    parser.lexer = *create_lexer(content, file.path);

    while !end(parser.lexer) {
        parse(*parser, null);
    }

    file.global_members = parser.user_data.global_members;
    file.comments = parser.lexer.comments;
    file.tokens = parser.lexer.tokens;
    file.has_syntax_errors = parser.lexer.has_syntax_errors;
}

parse_local_module_for_file :: (file_path: string) {
    for folder: server.local_modules {
        root := folder;
        if !is_absolute_path(root) root = join(server.project_root, root, separator="/",, temp);
        root = normalize_path(root,, temp);
        prefix := join(trim_right(root, "/"), "/",, temp);
        if !begins_with(file_path, prefix) continue;

        end := prefix.count;
        while end < file_path.count && file_path[end] != #char "/" end += 1;
        if end == file_path.count continue;

        module_path := join(slice(file_path, 0, end), "module.jai", separator="/",, temp);
        if file_exists(module_path) parse_file(module_path);
    }
}

parse_file :: (input_path: string, force := false, clear_if_missing := false) {
    // Reset back to default allocator, we dont want to use pool from "parent" file...
    push_allocator(context.default_allocator);

    path := normalize_path(input_path,, temp);

    ok, file := table_find(*server.files, path);
    if !force && ok {
        // log("Skipping % because it already exists", path);
        return;
    }

    // log("Parse file: %", path);

    memory_content, in_memory := get_memory_file(path);
    content := cast(string) memory_content;
    content_from_file: bool;

    if !in_memory {
        exists: bool;

        content, exists = read_entire_file(path, log_errors=false);
        if !exists {
            if !clear_if_missing || !ok return;
            content = "";
        }

        content_from_file = exists;
    }

    if !ok {
        file = New(Program_File);
        file.path = copy_string(path);
        set_allocators(*file.ast_pools[0], context.default_allocator);
        set_allocators(*file.ast_pools[1], context.default_allocator);
        set_allocators(*file.analysis_pool, context.default_allocator);
        set_allocators(*file.completion_pool, context.default_allocator);
        table_add(*server.files, file.path, file);
    }

    path_without_filename := normalize_path(trim_right(path_strip_filename(file.path), "/"),, temp);

    release(*file.completion_pool);
    file.completion_descriptions = .{};
    file.completion_descriptions.allocator = pool_alloc(*file.completion_pool);
    file.completion_description_bytes = 0;

    previous := file.ast;
    previous_index := file.ast_pool_index;

    next_index := ifx ok then 1 - previous_index else previous_index;
    next_pool := *file.ast_pools[next_index];
    release(next_pool);

    file.ast = .{};

    {
        push_allocator(pool_alloc(next_pool));
        parse_into_file(file, content, path_without_filename);
    }

    keep_previous := file.has_syntax_errors && file.nodes.count == 0 && previous.nodes.count > 0;

    if keep_previous {
        file.ast = previous;
        release(next_pool);
    } else {
        if ok release(*file.ast_pools[previous_index]);
        file.ast_pool_index = next_index;
    }

    file.global_block.members = file.global_members;

    if content_from_file free(content);
    // log("Parsed: % (nodes: %, declarations: %, pointer: %)", path, file.nodes.count, file.declarations.count, file);

    array_add_if_unique(*server.files_to_be_analyzed, file);

    // We must revalidate all files that are using this file in some way.
    files_using_this_file := get_files_that_use(file,, temp);
    for file_using_this_file: files_using_this_file {
        // if array_find(server.files_to_be_analyzed, file_using_this_file) {
        //     continue;
        // }

        array_add_if_unique(*server.files_to_be_analyzed, file_using_this_file);
    }
}

Harvested_Declaration :: struct {
    name: string;
    file: string;
    type: *Struct;
}

parse_harvested_types :: (sources: []string, context_path: string) -> Table(u64, *Struct) {
    push_allocator(context.default_allocator);

    types: Table(u64, *Struct);

    release(*server.harvest_pool);
    table_reset(*server.harvested_decls);

    if sources.count == 0 return types;

    builder: String_Builder;
    for sources {
        append(*builder, it);
        append(*builder, "\n");
    }

    push_allocator(pool_alloc(*server.harvest_pool));

    source := builder_to_string(*builder);

    harvest_file := New(Program_File);
    harvest_file.path = copy_string(context_path);

    parse_into_file(harvest_file, source, "");

    HARVEST_PREFIX :: "Jails_Harvested_";

    for node: harvest_file.nodes {
        if node.kind != .DECLARATION continue;

        decl := cast(*Declaration) node;
        if !decl.expression || decl.expression.kind != .STRUCT continue;
        if !begins_with(decl.name, HARVEST_PREFIX) continue;

        id_text := advance(decl.name, HARVEST_PREFIX.count);
        type_id, ok := parse_int(*id_text, u64);
        if !ok continue;

        table_set(*types, type_id, cast(*Struct) decl.expression);
    }

    log("Harvested % struct types from the compiler", types.count);
    return types;
}

harvested_decl_key :: (file: string, line: int, name: string) -> u64 {
    return fnv1a_hash(cast(u64) line, fnv1a_hash(name.data, name.count, fnv1a_hash(file.data, file.count)));
}

get_harvested_type :: (decl: *Declaration) -> *Node {
    if server.harvested_decls.count == 0 return null;
    if decl.name.count == 0 return null;

    found, harvested := table_find(*server.harvested_decls,
        harvested_decl_key(decl.location.file, decl.location.l0, decl.name));
    if !found return null;

    if harvested.name != decl.name return null;
    if harvested.file != decl.location.file return null;

    return harvested.type;
}

resolve_file_graph :: () {
    for file: server.files {
        for *imp: file.imports {
            imp.target = get_file(imp.root);
        }
        for *load: file.loads {
            load.target = get_file(load.resolved_path);
        }
    }
}

analyze_files :: () {
    for file: server.files_to_be_analyzed {
        release(*file.analysis_pool);

        file.global_scope = .{};
        file.global_scope_built = false;
    }

    release(*server.context_pool);
    server.context_struct = null;
    server.context_struct_built = false;

    resolve_file_graph();

    preload_file: *Program_File;
    runtime_support_file: *Program_File;

    for file: server.files {
        if !runtime_support_file && contains(file.path, "Runtime_Support.jai") {
            runtime_support_file = file;
        }

        if !preload_file && contains(file.path, "Preload.jai") {
            preload_file = file;
        }
    }

    for file: server.files_to_be_analyzed {
        linked_files := get_file_links(file,, pool_alloc(*file.analysis_pool));

        if file != preload_file && preload_file {
            array_add(*linked_files, .{ file=preload_file, from_import=true });
        }

        if file != runtime_support_file && runtime_support_file {
            array_add(*linked_files, .{ file=runtime_support_file, from_import=true });
        }

        file.linked_files = linked_files;
    }

    array_reset(*server.files_to_be_analyzed);
}

Node_Visit_Data :: struct {
    file: *Program_File;
    global_members: [..]*Node;
    allocator: Allocator;
    path_without_filename: string;
}

node_visit :: (node: *Node, data: Node_Visit_Data) {
    if !node return;

    push_allocator(data.allocator);

    file := data.file;

    if node.kind == .COMPOUND_DECLARATION {
        compound_declaration := cast(*Compound_Declaration) node;
        for member: compound_declaration.members {
            if member.kind != .COMPOUND_DECLARATION_ITEM continue;
            item := cast(*Compound_Declaration_Item) member;
            if item.item_kind != .DECLARATION || item.expression.kind != .IDENTIFIER continue;
            decl_ident := cast(*Identifier) item.expression;

            // @TODO: is this ok? Do we really wan't to create "virtual" decl here?
            decl := New(Declaration);
            decl.parent = decl_ident.parent;
            decl.location = decl_ident.location;
            decl.name = decl_ident.name;

            table_add(*file.declarations, decl.name, decl);
        }
    }

    if node.kind == .DECLARATION {
        decl := cast(*Declaration) node;
        table_add(*file.declarations, decl.name, decl);
    }

    array_add(*file.nodes, node);

    if node.kind == .DIRECTIVE_IMPORT {
        _import := cast(*Directive_Import) node;

        path := get_module_import_path(_import, data.path_without_filename);
        if path.count > 0 path = normalize_path(path);

        parent := _import.parent;
        wrapped_in_decl := parent && parent.kind == .DECLARATION;
        wrapped_in_bare_using := parent && parent.kind == .USING;

        module_import: Module_Import;
        module_import.root = path;
        module_import.module = _import.module;
        module_import.is_using = wrapped_in_bare_using;

        if !wrapped_in_decl {
            array_add(*data.file.imports, module_import);
        }

        parse_file(path); // @TODO: Run this in another thread?
    }

    if node.kind == .DIRECTIVE_ADD_CONTEXT {
        array_add(*file.add_contexts, cast(*Directive_Add_Context) node);
    }

    if node.kind == .USING {
        _using := cast(*Using) node;
        array_add(*file.usings, _using);

        if _using.expression && _using.expression.kind == .DECLARATION {
            decl := cast(*Declaration) _using.expression;
            if decl.expression && decl.expression.kind == .DIRECTIVE_IMPORT {
                _import := cast(*Directive_Import) decl.expression;
                path := get_module_import_path(_import, data.path_without_filename);
                if path.count > 0 path = normalize_path(path);

                module_import: Module_Import;
                module_import.root = path;
                module_import.module = _import.module;
                module_import.is_using = true;

                array_add(*data.file.imports, module_import);
            }
        }
    }

    if node.kind == .DIRECTIVE_LOAD {
        _load := cast(*Directive_Load) node;

        load_relative_path := normalize_path(join(data.path_without_filename, _load.file, separator="/"));
        array_add(*data.file.loads, Resolved_Load.{ resolved_path=load_relative_path });
        parse_file(load_relative_path); // @TODO: Run this in another thread?
    }

    if !node.parent {
        array_add(*data.global_members, node);
        node.parent = *file.global_block;
    }
}

get_module_import_path :: (_import: *Directive_Import, current_path: string) -> string {

    get_module_entry :: (module: string) -> string {
        uri := join(module, "/module.jai");
        if file_exists(uri) return uri;

        uri = join(module, ".jai");
        if file_exists(uri) return uri;

        return "";
    }

    get_module :: (module_name: string) -> string {
        for local_modules_folder: server.local_modules {
            absolute_path: string;
            if is_absolute_path(local_modules_folder) {
                absolute_path = local_modules_folder;
            } else {
                absolute_path = join(server.project_root, local_modules_folder, separator="/");
            }

            absolute_path = normalize_path(absolute_path);

            entry := get_module_entry(join(absolute_path, module_name, separator="/"));
            if entry.count > 0 return entry;
        }

        jai_modules := join(server.args.jai_path, "/modules");

        entry := get_module_entry(join(jai_modules, module_name, separator="/"));
        if entry.count > 0 return entry;

        return "";
    }

    path: string;

    if _import.import_kind == {
        case .MODULE;
            path = get_module(_import.module);
            if path.count == 0 return "";
        case .FILE;
            path = sprint("%/%", current_path, _import.module);
        case .DIR;
            relative_path := sprint("%/%", current_path, _import.module);
            path = get_module_entry(relative_path);
            if path.count == 0 return "";
        case .STRING;
            return "";
            // @TODO: Do we wanna parse the string here?
    }

    return path;
}

// resolve_identifiers :: (file: *Program_File) {
//     for node: file.nodes {
//         if node.kind != .IDENTIFIER {
//             continue;
//         }

//         ident := cast(*Identifier) node;

//         // log("Resolving '%' ident at %:%:%", ident.name, ident.location.file, ident.location.l0, ident.location.c0);

//         // log("Ident: %", ident.name);
//         block := get_node_nearest_block(ident);
//         decls := get_declarations(file, block, *ident.location, ident.name);
//         if decls.count == 0 {
//             // array_add(*file.unresolved_identifiers, ident);
//             continue;
//         }

//         table_add(*file.resolved_identifiers, ident, decls);
//     }
// }

get_node_by_location :: (file: *Program_File, location: Node.Location, filter: Node.Kind = .UNINITIALIZATED) -> *Node {
    nearest_node: *Node;

    for node: file.nodes {
        if filter != .UNINITIALIZATED && node.kind != filter continue;
        if !contains(node.location, location) continue;

        // If we are not smaller than so far nearest node we skip.
        if nearest_node && !contains(nearest_node.location, node.location) continue;

        nearest_node = node;
    }

    return nearest_node;
}

get_file_links :: (file: *Program_File) -> [..]Linked_File {
    linked_files: [..]Linked_File;

    files_that_load_this_file := get_files_that_load(file);
    defer array_free(files_that_load_this_file);

    for server.files {
        from_import: bool;

        if file != it {
            is_avaiable_from_one_of_the_parents: bool;

            for file_that_load_this_file: files_that_load_this_file {
                already_checked: [..]*Program_File;
                defer array_free(already_checked);

                if file_that_load_this_file == it {
                    is_avaiable_from_one_of_the_parents = true;
                    break;
                }

                avaiable, from_import= := is_avaiable_from(file_that_load_this_file, it, *already_checked);
                if !avaiable continue;

                is_avaiable_from_one_of_the_parents = true;
                break;
            }

            already_checked: [..]*Program_File;
            defer array_free(already_checked);

            if !is_avaiable_from_one_of_the_parents {
                avaiable, from_import= := is_avaiable_from(file, it, *already_checked);
                if !avaiable continue;
            }
        }

        array_add(*linked_files, .{ file=it, from_import=from_import });
    }

    return linked_files;
}

enum_member_declaration :: (ident: *Identifier) -> *Declaration {
    decl := New(Declaration);
    decl.name = ident.name;
    decl.expression = *empty_identifier;
    decl.location = ident.location;
    decl.const = true;
    decl.parent = ident.parent;
    return decl;
}

add_all_fields_of :: (decls: *[..]*Declaration, node: *Node, filter_name: string = "") {
    if !node return;
    if !enter_resolve() return;

    block := get_block_of(node);
    if !block {
        return;
    }

    for member: block.members {
        if !member continue;

        if member.kind == {
            case .IDENTIFIER;
                ident := cast(*Identifier) member;

                decl := enum_member_declaration(ident);
                if !filter_name || filter_name == decl.name array_add(decls, decl);

            case .DECLARATION;
                decl := cast(*Declaration) member;
                if !filter_name || filter_name == decl.name array_add(decls, decl);

            case .UNION;
                add_all_fields_of(decls, member);

            case .COMPOUND_DECLARATION;
                compound_declaration_to_declarations(decls, cast(*Compound_Declaration) member, filter_name);

            case .IF;
                _if := cast(*If) member;
                if _if._then add_all_fields_of(decls, _if._then, filter_name);
                if _if._else add_all_fields_of(decls, _if._else, filter_name);

            case .DIRECTIVE_AS; #through;
            case .USING; // @TODO: handle `using` modifiers like `except`, `only` and `map`.
                used_expression := get_used_expression(member);
                if !used_expression || used_expression.kind != .DECLARATION && used_expression.kind != .IDENTIFIER {
                    continue;
                }

                used_type := get_node_type(used_expression);
                if !used_type {
                    continue;
                }

                if used_expression.kind == .DECLARATION {
                    decl := cast(*Declaration) used_expression;
                    if !filter_name || filter_name == decl.name array_add(decls, decl); // Add using expression
                }

                add_all_fields_of(decls, used_type, filter_name); // Add all fields includes with using
        }
    }
}

// @TODO: Refactor this! (stupid global variable)
USINGS_IN_PROGRESS_MAX :: 64;
usings_in_progress: [USINGS_IN_PROGRESS_MAX]*Using;
usings_in_progress_count: int;

using_filter_allows :: (_using: *Using, decl_name: string) -> bool {
    if _using.filter_type != .ONLY && _using.filter_type != .EXCEPT return true;

    listed := false;
    for filter: _using.filters {
        if filter.kind != .IDENTIFIER continue;
        if (cast(*Identifier) filter).name == decl_name {
            listed = true;
            break;
        }
    }

    return ifx _using.filter_type == .ONLY then listed else !listed;
}

add_decls_from_using :: (decls: *[..]*Declaration, _using: *Using, name: string) {
    if usings_in_progress_count >= USINGS_IN_PROGRESS_MAX return;

    for 0..usings_in_progress_count-1 {
        if usings_in_progress[it] == _using return;
    }

    used_expression := get_used_expression(_using);
    if !used_expression return;

    usings_in_progress[usings_in_progress_count] = _using;
    usings_in_progress_count += 1;
    defer usings_in_progress_count -= 1;

    if used_expression.kind == .DECLARATION {
        used_decl := cast(*Declaration) used_expression;
        if name.count == 0 || name == used_decl.name array_add(decls, used_decl);
    }

    used_type := get_node_type(used_expression);
    if !used_type return;

    filtered: [..]*Declaration;
    filtered.allocator = temp;

    add_all_fields_of(*filtered, used_type, name);

    for decl: filtered {
        if using_filter_allows(_using, decl.name) array_add(decls, decl);
    }
}

get_for_element_type :: (_for: *For) -> element_type: *Node, is_range: bool {
    if !_for.iterator return null, false;

    if _for.iterator.kind == .BINARY_OPERATION {
        binary := cast(*Binary_Operation) _for.iterator;
        if binary.operation == .RANGE return *s64_node, true;
    }

    saved_skip_node := skip_node;
    defer skip_node = saved_skip_node;
    skip_node = _for;

    iterator_type := get_node_type(_for.iterator);
    if !iterator_type return null, false;

    if iterator_type.kind == {
        case .ARRAY_TYPE;
            return (cast(*Array_Type) iterator_type).element_type, false;

        case .IDENTIFIER;
            if (cast(*Identifier) iterator_type).name == "string" return *u8_node, false;

        case .LITERAL;
            literal := cast(*Literal) iterator_type;
            if literal.value_type == .ARRAY  return literal.array_literal_info.element_type, false;
            if literal.value_type == .STRING return *u8_node, false;
    }

    return null, false;
}

get_declarations_from_for :: (decls: *[..]*Declaration, node: *Node, from_loc: *Node.Location, name := "") {
    _for := cast(*For) node;
    if !_for.iterator || !_for.body || !from_loc || !contains(_for.body.location, from_loc.*) return;

    element_type, is_range := get_for_element_type(_for);
    if !element_type {
        element_type = *unknown_identifier_node;
    }

    it_declaration := New(Declaration);
    it_declaration.name = "it";
    it_declaration.location = _for.iterator.location;

    if _for.value && _for.value.kind == .IDENTIFIER {
        value_identifier := cast(*Identifier) _for.value;
        it_declaration.name = value_identifier.name;
        it_declaration.location = value_identifier.location;
    }

    it_index_decl := New(Declaration);
    it_index_decl.name = "it_index";
    it_index_decl.location = _for.iterator.location;
    it_index_decl.type_inst = *s64_node;

    if _for.index && _for.index.kind == .IDENTIFIER {
        index_identifier := cast(*Identifier) _for.index;
        it_index_decl.name = index_identifier.name;
        it_index_decl.location = index_identifier.location;
    }

    if _for.by_pointer {
        pointer_wrapper := New(Unary_Operation);
        pointer_wrapper.operation = .POINTER;
        pointer_wrapper.expression = element_type;
        it_declaration.type_inst = pointer_wrapper;
    } else {
        it_declaration.type_inst = element_type;
    }

    if name.count == 0 || it_declaration.name == name array_add(decls, it_declaration);

    if !is_range || _for.index {
        if name.count == 0 || it_index_decl.name == name array_add(decls, it_index_decl);
    }
}

skip_node: *Node;

get_declarations_from_parent :: (decls: *[..]*Declaration, node: *Node, from_loc: *Node.Location, name := "", only_consts := false) {
    if !node return;

    if skip_node != null && node == skip_node || only_consts && node.kind != .BLOCK {
        get_declarations_from_parent(decls, node.parent, from_loc, name, only_consts);
        return;
    }

    if node.kind == {
        case .CASE;
            _case := cast(*Case) node;

            if !from_loc return;

            for _case.members {
                // We only accept `nodes` if they were declared before our cursor location.
                if it.location.l0 > from_loc.l0 || (it.location.l0 == from_loc.l0 && it.location.c0 > from_loc.c0) continue;

                if it.kind == {
                    case .USING;
                        add_decls_from_using(decls, cast(*Using) it, name);

                    case .DECLARATION;
                        decl := cast(*Declaration) it;
                        if !name || name == decl.name array_add(decls, decl);
                }

            }

        case .PROCEDURE;
            proc := cast(*Procedure) node;

            for arg: proc.arguments {
                if arg.kind == .USING {
                    add_decls_from_using(decls, cast(*Using) arg, name);
                    continue;
                }

                unwrapped := unwrap_polymorphic_constant(arg);
                if !unwrapped || unwrapped.kind != .DECLARATION continue;
                decl := cast(*Declaration) unwrapped;

                if name.count == 0 || decl.name == name array_add(decls, decl);
            }

            only_consts = true;

        case .STRUCT;
            _struct := cast(*Struct) node;

            for arg: _struct.polymorphic_arguments {
                if arg.kind != .DECLARATION continue;
                decl := cast(*Declaration) arg;

                if name.count == 0 || decl.name == name array_add(decls, decl);
            }

            only_consts = true;

        case .UNION;
            _union := cast(*Union) node;

            for arg: _union.polymorphic_arguments {
                if arg.kind != .DECLARATION continue;
                decl := cast(*Declaration) arg;

                if name.count == 0 || decl.name == name array_add(decls, decl);
            }

            only_consts = true;

        case .BLOCK;
            block := cast(*Block) node;

            // global file block we dont want that!
            if !block.parent {
                return;
            }

            if !from_loc return;

            for block.members {

                // We only accept `nodes` if they were declared before our cursor/node location.
                if it.location.l0 > from_loc.l0 || (it.location.l0 == from_loc.l0 && it.location.c0 > from_loc.c0) continue;

                if it.kind == {
                    case .USING; // @TODO: solve crash when having two using
                        add_decls_from_using(decls, cast(*Using) it, name);

                    case .COMPOUND_DECLARATION;
                        comp_decl := cast(*Compound_Declaration) it;
                        if only_consts && !comp_decl.const {
                            continue;
                        }

                        compound_declaration_to_declarations(decls, comp_decl, name);

                    case .DECLARATION;
                        decl := cast(*Declaration) it;

                        add_decl := true;

                        if only_consts && !decl.const {
                            add_decl = false;
                        }

                        if name && name != decl.name {
                            add_decl = false;
                        }

                        if add_decl array_add(decls, decl);
                }

            }

        case .FOR; get_declarations_from_for(decls, node, from_loc, name);
    }

    get_declarations_from_parent(decls, node.parent, from_loc, name, only_consts);
}

ensure_global_scope :: (file: *Program_File) -> bool {
    if file.global_scope_built return true;
    if !is_memory_file(file.path) return false;

    file.global_scope.allocator = pool_alloc(*file.analysis_pool);

    for linked_file: file.linked_files {
        for decl: linked_file.file.declarations {
            if !is_global(decl, file, linked_file.file, linked_file.from_import) continue;
            table_add(*file.global_scope, decl.name, decl);
        }
    }

    file.global_scope_built = true;
    return true;
}

get_declarations :: (file: *Program_File, from_node: *Node = null, from_loc: *Node.Location = null, name := "", only_loaded := false, as_import := false, local_count: *int = null) -> []*Declaration {
    decls: [..]*Declaration;

    if from_node {
        get_declarations_from_parent(*decls, from_node, from_loc, name, false);
    }
    if local_count local_count.* = decls.count;

    // Globals in all linked files (loaded or imported)
    if file {
        cached := !only_loaded && !as_import && ensure_global_scope(file);

        for linked_file: file.linked_files {
            // log("Linked file: %", linked_file.file.path);

            if only_loaded && linked_file.from_import {
                continue;
            }

            linked_from_import := linked_file.from_import || as_import;

            if usings_in_progress_count == 0 {
                for _using: linked_file.file.usings {
                    if !is_global(_using, file, linked_file.file, linked_from_import) continue;
                    add_decls_from_using(*decls, _using, name);
                }
            }

            if cached continue;

            // We are searching for specific decl
            if name.count > 0 {
                for decl: table_find_multiple(*linked_file.file.declarations, name) {
                    if is_global(decl, file, linked_file.file, linked_from_import) array_add(*decls, decl);
                }
            } else { // We are adding all globals decls
                for decl: linked_file.file.declarations {
                    if is_global(decl, file, linked_file.file, linked_from_import) array_add(*decls, decl);
                }
            }
        }

        if cached {
            if name.count > 0 {
                for decl: table_find_multiple(*file.global_scope, name) array_add(*decls, decl);
            } else {
                for decl: file.global_scope array_add(*decls, decl);
            }
        }
    }

    return decls;
}

get_node_nearest_parent :: (node: *Node, predicate: (Node.Kind) -> bool, limit := 15) -> *Node {
    current: *Node = node;
    i: int;

    while true {
        if predicate(current.kind) return current;

        if i >= limit break;
        i += 1;
        if !current.parent break;

        current = current.parent;
    }

    return null;
}

is_parent_of :: (parent: *Node, node: *Node, limit := 5) -> bool {
    if parent == node return true;

    current: *Node = node;
    i: int;

    while true {
        if current == parent return true;

        if i >= limit break;
        i += 1;
        if !current.parent break;

        current = current.parent;
    }

    return false;
}

is_global :: (node: *Node, from_file: *Program_File, it_file: *Program_File, from_import: bool) -> bool {
    if !node.parent return true;

    if node.parent.kind == .BLOCK {
        return is_global(node.parent, from_file, it_file, from_import);
    }

    // @TODO: Make this more robust!
    if node.parent.kind == .IF {
        _if := cast(*If) node.parent;
        if !_if.compile_time return false;
        return is_global(_if, from_file, it_file, from_import);
    }

    if node.parent.kind == .DIRECTIVE_SCOPE {
        directive_scope := cast(*Directive_Scope) node.parent;

        if directive_scope.scope_kind == .MODULE && !from_import return true;
        if directive_scope.scope_kind == .EXPORT return true;
        if directive_scope.scope_kind == .FILE && from_file == it_file && !from_import return true;
    }

    return false;
}

get_files_that_use :: (target_file: *Program_File) -> []*Program_File {
    files: [..]*Program_File;

    for file: server.files {
        already_checked: [..]*Program_File;
        defer array_free(already_checked);
        if !is_avaiable_from(file, target_file, *already_checked) continue;
        array_add(*files, file);
    }

    return files;
}

get_files_that_load :: (target_file: *Program_File) -> []*Program_File {
    files: [..]*Program_File;

    for file: server.files {
        already_checked: [..]*Program_File;
        defer array_free(already_checked);
        if !is_avaiable_from(file, target_file, *already_checked, true) continue;
        array_add(*files, file);
    }

    return files;
}

is_avaiable_from :: (file: *Program_File, target: *Program_File, already_checked: *[..]*Program_File, $loads_only := false) -> bool, bool {
    from_import: bool;
    loaded: bool;

    #if !loads_only {
        for file.imports {
            if !it.target continue;
            if array_find(already_checked.*, it.target) continue;
            array_add(already_checked, it.target);

            if it.target == target {
                from_import = true;
                loaded = true;
                break;
            }

            found: bool;
            if it.is_using {
                found = is_avaiable_from(it.target, target, already_checked, false);
            } else {
                found = is_avaiable_from(it.target, target, already_checked, true);
            }

            if found {
                from_import = true;
                loaded = true;
                break;
            }
        }
    }

    for file.loads {
        if !it.target continue;
        if array_find(already_checked.*, it.target) continue;
        array_add(already_checked, it.target);

        if it.target == target {
            loaded = true;
            break;
        }

        found, found_from_import := is_avaiable_from(it.target, target, already_checked, loads_only);
        if found {
            loaded = true;
            from_import = found_from_import;
            break;
        }
    }

    return loaded, from_import;
}

get_node_nearest_block :: (node: *Node) -> *Block {
    current_node := node;

    while current_node.parent {
        current_node = current_node.parent;
        if current_node.kind == .BLOCK {
            return cast(*Block) current_node;
        }
    }

    return null;
}

is_child_of_block :: (block: *Block, node: *Node, ignore_scoping := false) -> bool {
    if !block || !node return false;

    current_node := node;

    if current_node == block return true;

    while current_node.parent {
        current_node = current_node.parent;

        if !ignore_scoping && current_node.kind != .BLOCK && current_node.kind != .IF && current_node.kind != .CASE && current_node.kind != .FOR && current_node.kind != .WHILE {
            return false;
        }

        if current_node == block return true;
    }

    return true;
}

contains :: (a: Node.Location, b: Node.Location) -> bool {
    if a.l0 > b.l0 return false;
    if a.l1 < b.l1 return false;

    if a.l0 == b.l0 && a.c0 > b.c0 return false;
    if a.l1 == b.l1 && a.c1 < b.c1 return false;

    return true;
}

is_after :: (a: Node.Location, b: Node.Location) -> bool {
    if b.l0 > a.l1 return true;
    if b.c0 > a.c1 return true;
    return false;
}

lsp_location_to_node_location :: (location: LSP_Position, file := "") -> Node.Location {
    node_location: Node.Location;
    node_location.file = file;
    node_location.l0 = location.line;
    node_location.c0 = location.character;
    node_location.l1 = location.line;
    node_location.c1 = location.character;
    if is_memory_file(file) {
        line := find_line_in_memory_file(file, location);
        node_location.c0 = utf16_column_to_byte_column(line, location.character);
        node_location.c1 = node_location.c0;
    }
    return node_location;
}

node_location_to_lsp_location :: (location: Node.Location) -> LSP_Location {
    lsp_location: LSP_Location;
    lsp_location.uri = path_to_lsp_path(location.file);
    lsp_location.range.start.line = xx location.l0;
    lsp_location.range.start.character = xx location.c0;
    lsp_location.range.end.line = xx location.l1;
    lsp_location.range.end.character = xx location.c1;
    if is_memory_file(location.file) {
        start_line := find_line_in_memory_file(location.file, lsp_location.range.start);
        end_line := find_line_in_memory_file(location.file, lsp_location.range.end);
        lsp_location.range.start.character = xx byte_column_to_utf16_column(start_line, location.c0);
        lsp_location.range.end.character = xx byte_column_to_utf16_column(end_line, location.c1);
    }
    return lsp_location;
}

get_identifier_decls :: (ident: *Identifier) -> []*Declaration {
    file := get_file(ident.location.file);
    if !file {
        return .[];
    }

    return get_declarations(file, ident, *ident.location, ident.name);
}

resolve_dot_member :: (ident: *Identifier) -> decl: *Declaration, is_path: bool {
    if !ident || !ident.parent return null, false;

    leaf_node: *Node = ident;
    op: *Binary_Operation;
    parent := leaf_node.parent;
    while parent {
        if parent.kind == {
            case .BINARY_OPERATION;
                binary := cast(*Binary_Operation) parent;
                if binary.operation == .DOT {
                    if binary.right == leaf_node {
                        op = binary;
                        break;
                    }
                }
                if binary.left != leaf_node break;

            case .ARRAY_SUBSCRIPT;
                if (cast(*Array_Subscript) parent).expression != leaf_node break;

            case .PROCEDURE_CALL;
                if (cast(*Procedure_Call) parent).procedure != leaf_node break;

            case .UNARY_OPERATION;
                unary := cast(*Unary_Operation) parent;
                if unary.operation != .POINTER_DEREFERENCE || unary.expression != leaf_node break;

            case .LITERAL;
                literal := cast(*Literal) parent;
                if literal.value_type != .STRUCT || literal.values.struct_literal_info.type != leaf_node break;

            case; break;
        }
        leaf_node = parent;
        parent = parent.parent;
    }

    if !op return null, false;

    receivers: [..]*Node;
    child: *Node = op;
    parent = op.parent;
    while parent && parent.kind == .BINARY_OPERATION {
        binary := cast(*Binary_Operation) parent;
        if binary.operation == .DOT {
            if binary.right != child break;
            array_add(*receivers, binary.left);
        } else if binary.left != child {
            break;
        }
        child = parent;
        parent = parent.parent;
    }

    path: [..]*Node;
    for i: 0..receivers.count-1 append_completion_receiver_path(*path, receivers[receivers.count-1-i]);
    append_completion_receiver_path(*path, op.left);

    type := get_path_type(path);
    if !type return null, true;

    return get_member_in(type, ident), true;
}

resolve_enum_member_declaration :: (ident: *Identifier) -> *Declaration {
    if !ident.parent || ident.parent.kind != .BLOCK return null;
    if !ident.parent.parent || ident.parent.parent.kind != .ENUM return null;

    return enum_member_declaration(ident);
}

resolve_named_member :: (ident: *Identifier) -> *Declaration {
    if !ident.parent || ident.parent.kind != .BINARY_OPERATION return null;

    binary_op := cast(*Binary_Operation) ident.parent;
    if binary_op.operation != .ASSIGN || binary_op.left != ident || !binary_op.parent return null;

    if binary_op.parent.kind == .PROCEDURE_CALL {
        call := cast(*Procedure_Call) binary_op.parent;
        procedures := get_procedures_for_call(call);
        defer array_free(procedures);
        if procedures.count == 0 return null;
        best := get_best_overload_for_procedure_call(procedures, call);
        return get_procedure_argument(procedures[best], -1, ident.name);
    }

    if binary_op.parent.kind == .LITERAL {
        literal_type := get_struct_literal_type(cast(*Literal) binary_op.parent);
        if literal_type return get_member_in(literal_type, ident);
    }

    return null;
}

resolve_implicit_member :: (ident: *Identifier) -> *Declaration {
    if !ident.parent || ident.parent.kind != .UNARY_OPERATION return null;

    unary_op := cast(*Unary_Operation) ident.parent;
    if unary_op.operation != .DOT || !unary_op.parent return null;

    type := get_expected_type(unary_op);
    if !type && unary_op.parent.kind == .BINARY_OPERATION {
        op := cast(*Binary_Operation) unary_op.parent;
        // A literal field must never fall back to a same-named scope variable.
        if !op.parent || op.parent.kind != .LITERAL type = get_node_type(op, 1);
    }
    if !type return null;

    return get_member_in(type, ident);
}

resolve_procedure_call :: (ident: *Identifier) -> *Declaration {
    if !ident.parent || ident.parent.kind != .PROCEDURE_CALL return null;

    proc_call := cast(*Procedure_Call) ident.parent;
    if proc_call.procedure != ident return null;

    decls := get_identifier_decls(ident);
    if decls.count == 0 return null;

    procedures: [..]*Procedure;
    procedures.allocator = temp;

    for proc_decl: decls {
        type := get_node_type(proc_decl, stop_at_procedure=true);
        if !type || type.kind != .PROCEDURE {
            remove proc_decl;
            continue;
        }

        array_add(*procedures, cast(*Procedure) type);
    }

    if procedures.count == 0 return null;

    best := get_best_overload_for_procedure_call(procedures, proc_call);

    return decls[best];
}

resolve_cursor_declaration :: (ident: *Identifier) -> decl: *Declaration, handled: bool {
    if ident.parent && ident.parent.kind == .UNARY_OPERATION {
        unary := cast(*Unary_Operation) ident.parent;
        if unary.operation == .DOT return resolve_implicit_member(ident), true;
    }

    if ident.parent && ident.parent.kind == .BINARY_OPERATION {
        op := cast(*Binary_Operation) ident.parent;
        if op.operation == .ASSIGN && op.left == ident && op.parent {
            if op.parent.kind == .PROCEDURE_CALL return resolve_named_member(ident), true;
            if op.parent.kind == .LITERAL {
                literal := cast(*Literal) op.parent;
                if literal.value_type == .STRUCT return resolve_named_member(ident), true;
            }
        }
    }

    decl := resolve_enum_member_declaration(ident);
    if decl return decl, true;

    dot_member, is_dot_path := resolve_dot_member(ident);
    if is_dot_path return dot_member, true;

    decl = resolve_procedure_call(ident);
    return decl, decl != null;
}

resolve_identifier :: (ident: *Identifier) -> *Declaration {
    return select_first_decl(get_identifier_decls(ident), 0);
}

select_first_decl :: (decls: []*Declaration, level: int) -> *Declaration {
    if decls.count == 0 {
        return null;
    }

    return decls[0];
}

MAX_RESOLVE_DEPTH :: 256;
resolve_depth: int;

MAX_TYPE_CHAIN_LENGTH :: 64;

enter_resolve :: () -> bool #expand {
    resolve_depth += 1;
    `defer resolve_depth -= 1;

    if resolve_depth > MAX_RESOLVE_DEPTH {
        log_error("Type resolution depth limit reached (cyclic declarations?), giving up.");
        return false;
    }

    return true;
}

Poly_Binding :: struct {
    name: string;
    node: *Node;
}

specialize_polymorphic_procedure :: (proc: *Procedure, call: *Procedure_Call) -> *Node {
    if proc.returns.count == 0 return null;

    bindings: [..]Poly_Binding;
    bindings.allocator = temp;

    for parameter, index: proc.arguments {
        if index >= call.arguments.count break;

        if parameter.kind == .POLYMORPHIC_CONSTANT {
            bind_parameter_name(parameter, call.arguments[index], *bindings);
            continue;
        }

        if parameter.kind != .DECLARATION continue;

        parameter_type := (cast(*Declaration) parameter).type_inst;
        if !mentions_polymorph(parameter_type) continue;

        argument_type := get_node_type(call.arguments[index]);
        if !argument_type continue;

        unify_polymorph(parameter_type, argument_type, *bindings);
    }

    if bindings.count == 0 return null;

    return_node := proc.returns[0].expression;
    if return_node && return_node.kind == .DECLARATION return_node = (cast(*Declaration) return_node).type_inst;
    if !return_node return null;

    return substitute_type(return_node, bindings);
}

mentions_polymorph :: (node: *Node) -> bool {
    if !node return false;

    if node.kind == .POLYMORPHIC_CONSTANT return true;
    if node.kind == .ARRAY_TYPE return mentions_polymorph((cast(*Array_Type) node).element_type);
    if node.kind == .UNARY_OPERATION return mentions_polymorph((cast(*Unary_Operation) node).expression);

    return false;
}

unify_polymorph :: (parameter_type: *Node, argument_type: *Node, bindings: *[..]Poly_Binding) {
    if !parameter_type || !argument_type return;

    if parameter_type.kind == .POLYMORPHIC_CONSTANT {
        name_node := (cast(*Polymorphic_Constant) parameter_type).expression;
        if name_node && name_node.kind == .IDENTIFIER {
            array_add(bindings, .{(cast(*Identifier) name_node).name, argument_type});
        }
    } else if parameter_type.kind == .ARRAY_TYPE && argument_type.kind == .ARRAY_TYPE {
        unify_polymorph((cast(*Array_Type) parameter_type).element_type, (cast(*Array_Type) argument_type).element_type, bindings);
    } else if parameter_type.kind == .UNARY_OPERATION && argument_type.kind == .UNARY_OPERATION {
        unify_polymorph((cast(*Unary_Operation) parameter_type).expression, (cast(*Unary_Operation) argument_type).expression, bindings);
    }
}

make_poly_bindings :: (parameters: []*Node, arguments: []*Node) -> []Poly_Binding {
    bindings: [..]Poly_Binding;
    bindings.allocator = temp;

    for parameter, index: parameters {
        if index >= arguments.count break;
        bind_parameter_name(parameter, arguments[index], *bindings);
    }

    return bindings;
}

bind_parameter_name :: (parameter: *Node, argument: *Node, bindings: *[..]Poly_Binding) {
    unwrapped := unwrap_polymorphic_constant(parameter);
    if !unwrapped || unwrapped.kind != .DECLARATION return;

    array_add(bindings, .{(cast(*Declaration) unwrapped).name, argument});
}

substitute_in_struct :: (_struct: *Struct, bindings: []Poly_Binding) -> *Node {
    if !_struct.block return _struct;

    members: [..]*Node;
    substituted_any := false;

    for member: _struct.block.members {
        if member.kind != .DECLARATION {
            array_add(*members, member);
            continue;
        }

        decl := cast(*Declaration) member;
        new_type := substitute_type(decl.type_inst, bindings);

        if new_type == decl.type_inst {
            array_add(*members, member);
            continue;
        }

        copy := New(Declaration);
        copy.* = decl.*;
        copy.type_inst = new_type;

        array_add(*members, copy);
        substituted_any = true;
    }

    if !substituted_any return _struct;

    block_copy := New(Block);
    block_copy.* = _struct.block.*;
    block_copy.members = members;

    struct_copy := New(Struct);
    struct_copy.* = _struct.*;
    struct_copy.block = block_copy;

    return struct_copy;
}

substitute_type :: (node: *Node, bindings: []Poly_Binding) -> *Node {
    if !node return node;

    if node.kind == .IDENTIFIER {
        name := (cast(*Identifier) node).name;
        for binding: bindings {
            if binding.name == name return binding.node;
        }

        return node;
    }

    if node.kind == .ARRAY_TYPE {
        array_type := cast(*Array_Type) node;

        element := substitute_type(array_type.element_type, bindings);
        if element == array_type.element_type return node;

        copy := New(Array_Type);
        copy.* = array_type.*;
        copy.element_type = element;
        return copy;
    }

    if node.kind == .UNARY_OPERATION {
        unary := cast(*Unary_Operation) node;
        if unary.operation != .POINTER return node;

        expression := substitute_type(unary.expression, bindings);
        if expression == unary.expression return node;

        copy := New(Unary_Operation);
        copy.* = unary.*;
        copy.expression = expression;
        return copy;
    }

    if node.kind == .PROCEDURE_CALL {
        call := cast(*Procedure_Call) node;

        arguments: [..]*Node;
        substituted_any := false;

        for argument: call.arguments {
            new_argument := substitute_type(argument, bindings);
            if new_argument != argument substituted_any = true;

            array_add(*arguments, new_argument);
        }

        if !substituted_any return node;

        copy := New(Procedure_Call);
        copy.* = call.*;
        copy.arguments = arguments;
        return copy;
    }

    return node;
}

get_node_type :: (root: *Node, array_depth := 0, select_decl := select_first_decl, stop_at_procedure := false) -> *Node {
    current_node: *Node = root;

    pending_call: *Procedure_Call;

    level: int;
    while true {
        defer level += 1;
        if !current_node break;

        if level > MAX_TYPE_CHAIN_LENGTH {
            log_error("Type chain too long while resolving % (self-referential declaration?), giving up.", root.kind);
            return null;
        }

        // log("Resolving type: % (%:%:%)", current_node.kind, current_node.location.file, current_node.location.l0, current_node.location.c0);

        if current_node.kind == .DIRECTIVE_CONTEXT {
            return get_context_struct();
        }

        if current_node.kind == .IDENTIFIER {
            ident := cast(*Identifier, current_node);

            if ident.name == "context" {
                context_struct := get_context_struct();
                if context_struct return context_struct;
            }

            ident_decls := get_identifier_decls(ident);

            if ident_decls.count == 0 {
                // log("Does not find anything for '%'...", ident.name);
                return current_node;
            }

            current_node = select_decl(ident_decls, level);

            continue;
        }

        if current_node.kind == .STRUCT {
            _struct := cast(*Struct) current_node;

            if pending_call && _struct.polymorphic_arguments.count > 0 {
                bindings := make_poly_bindings(_struct.polymorphic_arguments, pending_call.arguments);
                pending_call = null;

                if bindings.count > 0 return substitute_in_struct(_struct, bindings);
            }

            return current_node;
        }

        if current_node.kind == .UNION {
            return current_node;
        }

        if current_node.kind == .ENUM {
            return current_node;
        }

        if current_node.kind == .DIRECTIVE_IMPORT {
            return current_node;
        }

        if current_node.kind == .ARRAY_SUBSCRIPT {
            array_subscript := cast(*Array_Subscript) current_node;
            array_depth += 1;
            current_node = array_subscript.expression;
            continue;
        }

        if current_node.kind == .ARRAY_TYPE {
            array_type := cast(*Array_Type, current_node);

            if array_depth > 0 && array_type.element_type {
                array_depth -= 1;
                current_node = array_type.element_type;
                continue;
            }

            return array_type;
        }

        if current_node.kind == .LITERAL {
            literal := cast(*Literal) current_node;

            if literal.value_type == {
                case .STRUCT;
                    return get_struct_literal_type(literal);

                case .ARRAY;
                    array_literal_info := literal.values.array_literal_info;

                    if array_depth > 0 && array_literal_info.element_type {
                        array_depth -= 1;
                        current_node = array_literal_info.element_type;
                        continue;
                    } else {
                        return current_node;
                    }

                case;
                    return current_node;
            }
        }

        if current_node.kind == .DECLARATION {
            decl := cast(*Declaration) current_node;

            harvested := get_harvested_type(decl);
            if harvested {
                current_node = harvested;
                continue;
            }

            if decl.type_inst {
                current_node = decl.type_inst;
                continue;
            }

            if decl.expression {
                current_node = decl.expression;
                continue;
            }

        }

        if current_node.kind == .RETURN_VALUE {
            return_value := cast(*Return_Value) current_node;
            current_node = return_value.expression;
            continue;
        }

        if current_node.kind == .BINARY_OPERATION {
            bin_op := cast(*Binary_Operation)current_node;

            if bin_op.operation == {
                case .IS_NOT_EQUAL;
                    #through;
                case .IS_EQUAL;
                    #through;
                case .ASSIGN;
                    if bin_op.left.kind == .BINARY_OPERATION {
                        path := get_dot_path(xx bin_op.left, null);
                        current_node = get_path_type(path);
                    } else {
                        current_node = get_path_type(.[bin_op.left]);
                    }
                case;
                    path := get_dot_path(bin_op, null);
                    current_node = get_path_type(path);
            }

            continue;
        }

        if current_node.kind == .PROCEDURE_CALL {
            proc_call := cast(*Procedure_Call) current_node;

            if proc_call.arguments.count > 0 pending_call = proc_call;

            current_node = proc_call.procedure;
            continue;
        }

        if current_node.kind == .PROCEDURE {
            proc := cast(*Procedure) current_node;

            if stop_at_procedure {
                return proc;
            }

            if pending_call {
                specialized := specialize_polymorphic_procedure(proc, pending_call);
                pending_call = null;

                if specialized {
                    current_node = specialized;
                    continue;
                }
            }

            if proc.returns.count > 0 {
                current_node = proc.returns[0].expression;
                continue;
            }
        }

        if current_node.kind == .DIRECTIVE_TYPE {
            dt := cast(*Directive_Type) current_node;
            if dt.expression && dt.expression.kind == .PROCEDURE {
                current_node = dt.expression;
                continue;
            }

            break;
        }

        if current_node.kind == .DIRECTIVE_BAKE_ARGUMENTS {
            directive_bake_arguments := cast(*Directive_Bake_Arguments) current_node;
            if directive_bake_arguments.expression && directive_bake_arguments.expression.kind == .PROCEDURE {
                current_node = directive_bake_arguments.expression;
                continue;
            }

            break;
        }

        if current_node.kind == .UNARY_OPERATION {
            unary_op := cast(*Unary_Operation) current_node;
            if unary_op.operation == .POINTER {
                current_node = unwrap_pointer(xx current_node);
                continue;
            }

            if unary_op.operation == .POINTER_DEREFERENCE {
                if !unary_op.expression {
                    break;
                }

                current_node = unary_op.expression;
                continue;
            }

            if unary_op.operation == .ELLIPSIS {
                if !unary_op.expression {
                    break;
                }

                if array_depth > 0 {
                    array_depth -= 1;
                    current_node = unary_op.expression;
                    continue;
                }

                varargs_array := New(Array_Type);
                varargs_array.element_type = unary_op.expression;
                varargs_array.location = unary_op.location;

                return varargs_array;
            }

            break;
        }

        if current_node.kind == .CAST {
            _cast := cast(*Cast) current_node;
            current_node = _cast.cast_expression;
            continue;
        }

        break;
    }

    return null;
}

unwrap_polymorphic_constant :: (node: *Node) -> *Node {
    if !node return null;

    if node.kind != .POLYMORPHIC_CONSTANT {
        return node;
    }

    const := cast(*Polymorphic_Constant) node;

    return const.expression;
}

unwrap_pointer :: (unary_op: *Unary_Operation) -> *Node {
    if unary_op.operation != .POINTER return unary_op;

    if !unary_op.expression return null;

    // nested pointers
    if unary_op.expression.kind == .UNARY_OPERATION {
        return unwrap_pointer(xx unary_op.expression);
    }

    return unary_op.expression;
}

get_block_of :: (node: *Node) -> *Block {
    if !node return null;
    if node.kind == .BLOCK return cast(*Block) node;

    if node.kind == {
        case .STRUCT; return (cast(*Struct) node).block;
        case .ENUM;   return (cast(*Enum) node).block;
        case .UNION;  return (cast(*Union) node).block;
    }

    return null;
}

// This depends on Preload having this type. We need to keep this in sync with the compiler.
get_context_struct :: () -> *Struct {
    if server.context_struct_built return server.context_struct;

    server.context_struct_built = true;

    runtime_support := search_for_file("modules/Runtime_Support.jai");
    if !runtime_support return null;

    ok, base_decl := table_find(*runtime_support.declarations, "Context_Base");
    if !ok || !base_decl.expression || base_decl.expression.kind != .STRUCT return null;

    base := cast(*Struct) base_decl.expression;
    if !base.block return null;

    push_allocator(pool_alloc(*server.context_pool));

    members: [..]*Node;
    array_add(*members, ..base.block.members);

    for file: server.files {
        for add_context: file.add_contexts {
            if add_context.expression array_add(*members, add_context.expression);
        }
    }

    block := New(Block);
    block.members = members;
    block.location = base.location;

    _struct := New(Struct);
    _struct.block = block;
    _struct.location = base_decl.location;

    server.context_struct = _struct;
    return _struct;
}

get_internal_array_struct :: (resizable: bool) -> *Struct {
    preload := search_for_file("modules/Preload.jai");
    if !preload {
        return null;
    }

    // @TODO: Array_View_64 is actually not correct type because data in it is type of *u8 and it should be *void.
    // Currently there is no plain Array_View with *void in Preload so we will keep it this way for now.
    // In the future we can put this builtins inside some "virtual" file.
    search_for := ifx resizable then "Resizable_Array" else "Array_View_64";

    ok, decl := table_find(*preload.declarations, search_for);
    if !ok || !decl.expression || decl.expression.kind != .STRUCT {
        return null;
    }

    return cast(*Struct) decl.expression;
}

// This depends on Preload having this type. We need to keep this in sync with the compiler.
get_internal_string_struct :: () -> *Struct {
    preload := search_for_file("modules/Preload.jai");
    if !preload {
        return null;
    }

    ok, decl := table_find(*preload.declarations, "Newstring");
    if !ok || !decl.expression || decl.expression.kind != .STRUCT {
        return null;
    }

    return cast(*Struct) decl.expression;
}

get_member_in :: (parent: *Node, ident: *Identifier) -> *Declaration {
    decls := get_members_in(parent, ident);
    if decls.count == 0 {
        return null;
    }

    return decls[0];
}

// The expected type of an initializer or value expression, independent of its
// own inferred type. In particular, a field name is not a lexical identifier.
get_expected_type :: (node: *Node) -> *Node {
    if !node || !node.parent return null;
    if !enter_resolve() return null;

    parent := node.parent;
    if parent.kind == {
        case .DECLARATION;
            decl := cast(*Declaration) parent;
            if decl.expression == node && decl.type_inst && decl.type_inst != node return get_node_type(decl.type_inst);

        case .PROCEDURE_CALL;
            return get_argument_type_for_call(cast(*Procedure_Call) parent, node);

        case .BINARY_OPERATION;
            op := cast(*Binary_Operation) parent;
            if op.operation == .ASSIGN && op.right == node {
                if op.parent && op.parent.kind == .PROCEDURE_CALL && op.left && op.left.kind == .IDENTIFIER {
                    return get_argument_type_for_call(cast(*Procedure_Call) op.parent, op, cast(*Identifier, op.left).name);
                }

                if op.parent && op.parent.kind == .LITERAL {
                    literal := cast(*Literal) op.parent;
                    if literal.value_type != .STRUCT || !op.left || op.left.kind != .IDENTIFIER return null;
                    type := get_struct_literal_type(literal);
                    if !type return null;
                    field := get_member_in(type, cast(*Identifier) op.left);
                    if !field return null;
                    return get_node_type(field);
                }

                if op.left {
                    return get_node_type(op.left);
                }
            }
    }

    return null;
}

get_struct_literal_type :: (literal: *Literal) -> *Node {
    if literal.value_type != .STRUCT return null;
    if !enter_resolve() return null;

    type_node := literal.values.struct_literal_info.type;
    if type_node {
        if is_dot_binary_op(literal.parent) {
            dot := cast(*Binary_Operation) literal.parent;
            if dot.right == literal {
                path := get_dot_path(dot, literal);
                path[path.count - 1] = type_node;
                return get_path_type(path);
            }
        }
        return get_node_type(type_node);
    }
    return get_expected_type(literal);
}

get_import_file :: (import: *Directive_Import) -> *Program_File {
    path_without_filename := trim_right(path_strip_filename(import.location.file), "/");
    path := get_module_import_path(import, path_without_filename);
    if path.count == 0 {
        return null;
    }

    return get_file(normalize_path(path,, temp));
}

get_members_in :: (parent: *Node, ident: *Identifier) -> []*Declaration {
    decls: [..]*Declaration;

    if parent.kind == .DIRECTIVE_IMPORT {
        import := cast(*Directive_Import) parent;

        module_file := get_import_file(import);
        if !module_file {
            return decls;
        }

        return get_declarations(module_file, only_loaded=true, name=ident.name, as_import=true);
    }

    // Special case for array
    if parent.kind == .ARRAY_TYPE {
        parent_array_type := cast(*Array_Type) parent;
        internal_array_struct := get_internal_array_struct(parent_array_type.resizable);
        if internal_array_struct {
            parent = internal_array_struct;
        }
    }

    // Special case for string
    parent_base_type := get_base_type_from_ident_or_literal(parent);
    if parent_base_type == .STRING {
        internal_string_struct := get_internal_string_struct();
        if internal_string_struct {
            parent = internal_string_struct;
        }
    }

    block := get_block_of(parent);
    if !block {
        return decls;
    }

    block_member := get_block_member(block, ident);
    if !block_member {
        return decls;
    }

    array_add(*decls, block_member);

    return decls;
}

get_block_member_type :: (block: *Block, ident: *Identifier, array_depth := 0) -> *Node {
    decl := get_block_member(block, ident);
    if !decl {
        return null;
    }

    return get_node_type(decl, array_depth);
}

get_block_member :: (block: *Block, ident: *Identifier) -> *Declaration {
    if !block return null;
    if !enter_resolve() return null;

    for member: block.members {
        if member.kind == {
            case .UNION;
                found := get_block_member((cast(*Union) member).block, ident);
                if found return found;

            case .IF;
                _if := cast(*If) member;

                found := get_block_member(get_block_of(_if._then), ident);
                if !found found = get_block_member(get_block_of(_if._else), ident);
                if found return found;
            case .IDENTIFIER;
                _ident := cast(*Identifier) member;
                if _ident.name == ident.name return enum_member_declaration(_ident);
            case .DECLARATION;
                decl := cast(*Declaration) member;
                if decl.name == ident.name return xx member;

            case .COMPOUND_DECLARATION;
                decls: [..]*Declaration;
                compound_declaration_to_declarations(*decls, cast(*Compound_Declaration) member, ident.name);
                if decls.count > 0 return decls[0];

            case .DIRECTIVE_AS; #through;
            case .USING;
                used_expression := get_used_expression(member);
                if !used_expression || used_expression.kind != .DECLARATION && used_expression.kind != .IDENTIFIER {
                    continue;
                }

                used_type := get_node_type(used_expression);
                if used_type {
                    decl := get_member_in(used_type, ident);
                    if decl && decl.name == ident.name {
                        return decl;
                    }
                }

                if used_expression.kind == .DECLARATION {
                    used_decl := cast(*Declaration) used_expression;
                    if used_decl.name == ident.name {
                        return used_decl;
                    }
                }
        }
    }

    return null;
}

unwrap_as :: (node: *Node) -> *Node {
    if !node return null;

    if node.kind == .DIRECTIVE_AS {
        directive_as := cast(*Directive_As) node;

        if directive_as.expression && directive_as.expression.kind == .DIRECTIVE_AS {
            return unwrap_as(directive_as.expression);
        }

        return directive_as.expression;
    }

    return node;
}

// get type of `using`
get_used_expression :: (node: *Node) -> *Node {
    unwrapped_node := unwrap_as(node);

    if !unwrapped_node || unwrapped_node.kind != .USING return null;

    _using := cast(*Using) unwrapped_node;
    return unwrap_as(_using.expression);
}

get_last_binary_op :: (first: *Binary_Operation) -> *Binary_Operation {
    current := first;

    while current.right && current.right.kind == .BINARY_OPERATION {
        current = cast(*Binary_Operation) current.right;
    }

    return current;
}

// !!! Can return null as last node !!!
// This procedure is designed to walk binary op from right to left.
// Its currently using `get_last_binary_op` to get the most right (ending) binary op.
get_dot_path :: (binary_op: *Binary_Operation, from: *Node) -> []*Node {
    path: [..]*Node;

    if binary_op.operation != .DOT {
        // log("binary_op.operation != .DOT -> %", to_string(binary_op));
        return path;
    }

    root_binary_op := ifx from == null then get_last_binary_op(binary_op) else binary_op;

    if root_binary_op.operation != .DOT {
        // log("root_binary_op.operation != .DOT -> %", to_string(root_binary_op));
        return path;
    }

    if !from {
        // Append even null nodes so we know we have empty "." entry (monster.items[0].)
        array_add(*path, root_binary_op.right);
        array_add(*path, root_binary_op.left);
    } else {
        if root_binary_op.right == from {
            array_add(*path, root_binary_op.right);
            array_add(*path, root_binary_op.left); // this cannot be null?
        } else if root_binary_op.left == from {
            array_add(*path, root_binary_op.left);
        } else {
            // log_error("left nor right is from"); // is this correct? Should we assert?
            return path;
        }
    }

    current_op: *Binary_Operation = root_binary_op;
    while current_op.parent && current_op.parent.kind == .BINARY_OPERATION {
        current_op = cast(*Binary_Operation, current_op.parent);

        if current_op.operation != .DOT {
            break;
        }

        if current_op.left array_add(*path, current_op.left);
    }

    array_reverse(path);

    return path;
}

get_path_type :: (path: []*Node, recursion_limit: s16 = 64) -> *Node {
    current_type: *Node;
    resolved_nodes: int;

    if recursion_limit <= 0 {
        // Enforce some kind of limit to the recursive search, else we run the risk
        // of exhausting our stack and getting killed. A good way to test this is to do
        // a goto definition search on a context's field.
        log_error("Recurisve search limit reached, quitting search");
        return null;
    }

    if !enter_resolve() {
        return null;
    }

    for node: path {
        if !node break;

        if node.kind == {
            case .PROCEDURE_CALL; #through;
            case .ARRAY_SUBSCRIPT; #through;
            case .IDENTIFIER;
                identifier: *Identifier;
                array_depth: int = 0;

                if node.kind == .IDENTIFIER {
                    identifier = cast(*Identifier) node;
                } else if node.kind == .ARRAY_SUBSCRIPT {
                    array_subscript := cast(*Array_Subscript, node);
                    if !array_subscript.expression || array_subscript.expression.kind != .IDENTIFIER {
                        return null;
                    }

                    identifier = cast(*Identifier) array_subscript.expression;
                    array_depth = 1;
                } else if node.kind == .PROCEDURE_CALL {
                    proc_call := cast(*Procedure_Call) node;
                    if !proc_call.procedure || proc_call.procedure.kind != .IDENTIFIER {
                        return null;
                    }

                    identifier = cast(*Identifier) proc_call.procedure;
                }

                if !current_type {
                    select_first_non_procedure_decl :: (decls: []*Declaration, level: int) -> *Declaration {
                        if level > 0 {
                            return select_first_decl(decls, level);
                        }

                        for decl: decls {
                            if decl.expression && decl.expression.kind == .PROCEDURE continue;

                            return decl;
                        }

                        return null;
                    }

                    if node.kind == .PROCEDURE_CALL {
                        current_type = get_node_type(node);
                    } else {
                        current_type = get_node_type(identifier, array_depth, select_first_non_procedure_decl);
                    }

                    if !current_type {
                        break;
                    }

                    resolved_nodes += 1;
                    continue;
                }

                if current_type.kind == .DIRECTIVE_IMPORT {
                    decl := get_member_in(current_type, identifier);
                    if !decl {
                        break;
                    }

                    current_type = get_node_type(decl, array_depth);
                    resolved_nodes += 1;
                    continue;
                }

                if current_type.kind == .ARRAY_TYPE && identifier.name == "data" {
                    array_type := cast(*Array_Type) current_type;
                    current_type = get_node_type(array_type.element_type, max(0, array_depth - 1));
                } else {
                    decl := get_member_in(current_type, identifier);
                    if !decl break;
                    current_type = get_node_type(decl, array_depth);
                }

                if !current_type break;
                resolved_nodes += 1;
                continue;

            case .LITERAL;
                current_type = node;
                resolved_nodes += 1;

            case .UNARY_OPERATION;
                _unary_op := cast(*Unary_Operation) node;
                if _unary_op.operation == .POINTER_DEREFERENCE {
                    if !_unary_op.expression {
                        break;
                    }

                    current_type = get_node_type(_unary_op.expression, 1);
                    if !current_type {
                        break;
                    }

                    resolved_nodes += 1;
                }

            case .CAST;
                _cast := cast(*Cast) node;

                cast_type := _cast.cast_expression;
                if cast_type && cast_type.kind == .UNARY_OPERATION {
                    cast_type = unwrap_pointer(cast(*Unary_Operation) _cast.cast_expression);
                }

                if !cast_type {
                    break;
                }

                current_type = get_node_type(cast_type, 1);
                if !current_type {
                    return null;
                }

                resolved_nodes += 1;
            case; // abort!
                return null;
        }
    }

    if current_type && current_type.kind == .IDENTIFIER && current_type.location.file.data != null && get_base_type_from_ident_or_literal(current_type) == .UNKNOWN {
        if path.count == 1 && path[0] == current_type {
            return null;
        }

        return get_path_type(.[current_type], recursion_limit - 1);
    }

    // We are unable to resolve whole path so the final type would be invalid.
    if path.count > resolved_nodes  {
        return null;
    }

    return current_type;
}

Base_Type :: enum {
    UNKNOWN;

    STRING;

    INT;
    S64;
    S32;
    S16;
    S8;
    U64;
    U32;
    U16;
    U8;

    FLOAT;
    FLOAT32;
    FLOAT64;

    BOOL;

    VOID;
}

get_base_type_from_ident_or_literal :: (node: *Node) -> Base_Type {
    if node.kind == .IDENTIFIER {
        ident := cast(*Identifier) node;

        if ident.name == {
            case "string";  return .STRING;

            case "int";     return .INT;
            case "s64";     return .S64;
            case "s32";     return .S32;
            case "s16";     return .S16;
            case "s8";      return .S8;
            case "u64";     return .U64;
            case "u32";     return .U32;
            case "u16";     return .U16;
            case "u8";      return .U8;

            case "float";     return .FLOAT;
            case "float32";   return .FLOAT32;
            case "float64";   return .FLOAT64;

            case "bool";      return .BOOL;

            case "void";      return .VOID;
        }

        return .UNKNOWN;
    }

    if node.kind == .LITERAL {
        literal := cast(*Literal) node;

        if literal.value_type == {
            case .INT;      return .INT;
            case .FLOAT;    return .FLOAT;
            case .STRING;   return .STRING;
            case .BOOL;     return .BOOL;
            case;           return .UNKNOWN;
        }
    }

    return .UNKNOWN;
}

is_same_type :: (a: *Node, b: *Node) -> bool {
    if !a || !b {
        return false;
    }

    // complex types (user defined) as Entity, Monster, Player...
    if a.kind != .IDENTIFIER && a.kind != .LITERAL || b.kind != .IDENTIFIER && b.kind != .LITERAL  {
        return a == b;
    }

    // likely base type as string, int...
    a_base_type := get_base_type_from_ident_or_literal(a);
    b_base_type := get_base_type_from_ident_or_literal(b);

    if a_base_type == .UNKNOWN || b_base_type == .UNKNOWN {
        return false;
    }

    return a_base_type == b_base_type;
}

// @TODO: vargs, polymorphic types
get_best_overload_for_procedure_call :: (procedures: []*Procedure, call: *Procedure_Call) -> int {
    if procedures.count < 2 {
        return 0;
    }

    current_best := 0;
    current_best_matched_args: u16 = 0;

    call_arg_types := NewArray(call.arguments.count, *Node,, temp);
    for call_arg, call_arg_index: call.arguments {
        value := call_arg;
        if value.kind == .BINARY_OPERATION {
            op := cast(*Binary_Operation) value;
            if op.operation == .ASSIGN && op.right value = op.right;
        }
        if value.kind == .LITERAL {
            literal := cast(*Literal) value;
            // Its type depends on choosing the overload. Inferring it here
            // would recursively select this same overload using its own result.
            if literal.value_type == .STRUCT && !literal.values.struct_literal_info.type continue;
        }
        call_arg_types[call_arg_index] = get_node_type(value);
    }

    for procedure: procedures {
        matched_args: u16;

        if call.arguments.count > procedure.arguments.count {
            continue;
        }

        for call_arg, call_arg_index: call.arguments {
            call_arg_type := call_arg_types[call_arg_index];
            name := "";
            if call_arg.kind == .BINARY_OPERATION {
                op := cast(*Binary_Operation) call_arg;
                if op.operation == .ASSIGN && op.left && op.left.kind == .IDENTIFIER name = (cast(*Identifier) op.left).name;
            }
            arg := get_procedure_argument(procedure, call_arg_index, name);
            if !arg {
                matched_args = 0;
                break call_arg;
            }
            // A contextual literal has no independent type to score. Other
            // arguments can still distinguish the overload, regardless of order.
            if !call_arg_type continue;
            arg_type := get_node_type(arg);

            if !is_same_type(arg_type, call_arg_type) {
                matched_args = 0;
                break call_arg;
            }

            matched_args += 1;
        }

        if matched_args > current_best_matched_args {
            current_best = it_index;
            current_best_matched_args = matched_args;
        }
    }

    return current_best;
}

get_procedures_for_call :: (call: *Procedure_Call) -> []*Procedure {
    procedures: [..]*Procedure;

    if !call.procedure || call.procedure.kind != .IDENTIFIER {
        return procedures;
    }

    proc_ident := cast(*Identifier) call.procedure;

    proc_decls: [..]*Declaration;
    defer array_free(proc_decls);

    if call.parent && is_dot_binary_op(call.parent) {
        path := get_dot_path(cast(*Binary_Operation) call.parent, call);
        if path.count > 1 {
            path = array_view(path, 0, path.count-1);
            type := get_path_type(path);
            if type {
                array_add(*proc_decls, ..get_members_in(type, proc_ident));
            }
        }
    } else {
        array_add(*proc_decls, ..get_identifier_decls(proc_ident));
    }

    for proc_decl: proc_decls {
        if !proc_decl continue;

        type := get_node_type(proc_decl, stop_at_procedure=true);
        if !type || type.kind != .PROCEDURE continue;

        array_add(*procedures, cast(*Procedure) type);
    }

    return procedures;
}

get_procedure_argument :: (procedure: *Procedure, index: int, name := "") -> *Declaration {
    if name.count > 0 {
        for arg: procedure.arguments {
            unwrapped := unwrap_polymorphic_constant(arg);
            if !unwrapped || unwrapped.kind != .DECLARATION continue;

            decl := cast(*Declaration) unwrapped;
            if decl.name == name return decl;
        }

        return null;
    }

    if index < 0 || index >= procedure.arguments.count return null;

    unwrapped := unwrap_polymorphic_constant(procedure.arguments[index]);
    if !unwrapped || unwrapped.kind != .DECLARATION return null;

    return cast(*Declaration) unwrapped;
}

get_call_argument_context :: (unary: *Unary_Operation) -> (call: *Procedure_Call, argument_node: *Node, argument_name: string) {
    if unary.operation != .DOT || !unary.parent {
        return null, null, "";
    }

    if unary.parent.kind == .PROCEDURE_CALL {
        return cast(*Procedure_Call) unary.parent, unary, "";
    }

    if unary.parent.kind == .BINARY_OPERATION {
        assign := cast(*Binary_Operation) unary.parent;
        if assign.operation != .ASSIGN return null, null, "";
        if !assign.left || assign.left.kind != .IDENTIFIER return null, null, "";
        if !assign.parent || assign.parent.kind != .PROCEDURE_CALL return null, null, "";

        return cast(*Procedure_Call) assign.parent, assign, cast(*Identifier, assign.left).name;
    }

    return null, null, "";
}

get_argument_type_for_call :: (call: *Procedure_Call, argument_node: *Node, argument_name := "") -> *Node {
    procedures := get_procedures_for_call(call);
    defer array_free(procedures);

    if procedures.count == 0 {
        return null;
    }

    argument_index := -1;
    if argument_name.count == 0 {
        for call.arguments {
            if it == argument_node {
                argument_index = it_index;
                break;
            }
        }

        if argument_index < 0 return null;
    }

    best := get_best_overload_for_procedure_call(procedures, call);
    procedures[0], procedures[best] = procedures[best], procedures[0];

    for procedures {
        arg_decl := get_procedure_argument(it, argument_index, argument_name);
        if !arg_decl continue;

        type := get_node_type(arg_decl);
        if type return type;
    }

    return null;
}

inside_comment :: (location: Node.Location) -> bool {
    file := get_file(location.file);
    if !file {
        return false;
    }

    for comment: file.comments {
        // location start >= comment start
        if (location.l0 < comment.l1 || (location.l0 == comment.l1 && location.c0 < comment.c1)) {
              // location.end > comment.start
              if (location.l1 > comment.l0 || (location.l1 == comment.l0 && location.c1 > comment.c0)) {
                  return true;
              }
          }
    }

    return false;
}

is_dot_binary_op :: (node: *Node) -> bool {
    if !node {
        return false;
    }

    if node.kind != .BINARY_OPERATION {
        return false;
    }

    binary_op := cast(*Binary_Operation) node;
    if binary_op.operation != .DOT {
        return false;
    }

    return true;
}

compound_declaration_to_declarations :: (decls: *[..]*Declaration, comp_decl: *Compound_Declaration, filter_name: string = "") {
    type_or_value_expr: *Node;
    if comp_decl.type_inst {
        if comp_decl.type_inst.expression {
            type_or_value_expr = comp_decl.type_inst.expression;
        } else if comp_decl.type_inst.type_inst {
            type_or_value_expr = comp_decl.type_inst.type_inst;
        }
    }

    for comp_member: comp_decl.members {
        if comp_member.kind != .COMPOUND_DECLARATION_ITEM {
            continue;
        }

        comp_item := cast(*Compound_Declaration_Item) comp_member;
        if comp_item.item_kind != .DECLARATION || !comp_item.expression || comp_item.expression.kind != .IDENTIFIER {
            continue;
        }

        comp_item_ident := cast(*Identifier) comp_item.expression;

        if filter_name && filter_name != comp_item_ident.name {
            continue;
        }

        item_expr: *Node = *unknown_identifier_node;
        if type_or_value_expr {
            if type_or_value_expr.kind == .IDENTIFIER {
                item_expr = type_or_value_expr;
            }

            if type_or_value_expr.kind == .COMMA_SEPARATED_EXPRESSION {
                comma_sep_expr := cast(*Comma_Separated_Expression) type_or_value_expr;

                if comma_sep_expr.members.count > it_index {
                    item_expr = comma_sep_expr.members[it_index];
                }
            }

            if type_or_value_expr.kind == .PROCEDURE_CALL {
                proc_call := cast(*Procedure_Call) type_or_value_expr;

                proc_node := get_node_type(proc_call, stop_at_procedure = true);

                if proc_node && proc_node.kind == .PROCEDURE {
                    proc := cast(*Procedure) proc_node;

                    if it_index < proc.returns.count {
                        item_expr = proc.returns[it_index];
                    }
                }
            }
        }

        // @TODO: is this ok? Do we really wan't to create "virtual" decl here?
        decl := New(Declaration);
        decl.parent = comp_item_ident.parent;
        decl.location = comp_item_ident.location;
        decl.name = comp_item_ident.name;
        if comp_decl.type_inst && comp_decl.type_inst.type_inst && !comp_decl.type_inst.expression {
            decl.type_inst = item_expr;
        } else {
            decl.expression = item_expr;
        }
        if comp_decl.type_inst decl.const = comp_decl.type_inst.const;

        array_add(decls, decl);
    }
}
