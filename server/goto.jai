handle_goto_load :: (request: LSP_Request_Message_Definition, file: *Program_File, _load: *Directive_Load) {
    file_path_without_filename := trim_right(path_strip_filename(file.path), "/");
    load_absolute_path := join(file_path_without_filename, _load.file, separator="/");

    lsp_location: LSP_Location_Link;
    lsp_location.originSelectionRange = .{
        start=.{line=xx _load.location.l0, character=xx(_load.location.c1 - _load.file.count-1)},
        end=.{line=xx _load.location.l0, character=xx(_load.location.c1-1)}
    };
    lsp_location.targetUri = path_to_lsp_path(load_absolute_path);

    lsp_respond(request.id, lsp_location);
}

handle_goto_import :: (request: LSP_Request_Message_Definition, file: *Program_File, _import: *Directive_Import) {
    push_allocator(temp);

    file_path_without_filename := trim_right(path_strip_filename(file.path), "/");
    module_absolute_path := get_module_import_path(_import, file_path_without_filename);

    lsp_location: LSP_Location_Link;
    lsp_location.originSelectionRange = .{
        start=.{line=xx _import.location.l0, character=xx(_import.location.c1 - _import.module.count-1)},
        end=.{line=xx _import.location.l0, character=xx(_import.location.c1-1)}
    };
    lsp_location.targetUri = path_to_lsp_path(module_absolute_path);

    lsp_respond(request.id, lsp_location);
}

handle_goto :: (request: LSP_Request_Message_Definition) {
    push_allocator(temp);

    file_path := normalize_path(request.params.textDocument.uri);

    file := get_file(file_path);
    if !file {
        log_error("File does not exists or has not been parser yet! (%)", file_path);
        lsp_respond(request.id, null);
        return;
    }

    cursor_location := lsp_location_to_node_location(request.params.position, file_path);

    cursor_node := get_node_by_location(file, cursor_location);
    if !cursor_node {
        lsp_respond(request.id, null);
        return;
    }

    if cursor_node.kind == .DIRECTIVE_LOAD {
        handle_goto_load(request, file, xx cursor_node);
        return;
    }

    if cursor_node.kind == .DIRECTIVE_IMPORT {
        handle_goto_import(request, file, xx cursor_node);
        return;
    }

    if cursor_node.kind != .IDENTIFIER {
        lsp_respond(request.id, null);
        return;
    }

    ident := cast(*Identifier) cursor_node;

    decl, handled := resolve_cursor_declaration(ident);
    if handled {
        if !decl {
            lsp_respond(request.id, null);
            return;
        }

        lsp_respond(request.id, node_location_to_lsp_location(decl.location));
        return;
    }

    decls := get_identifier_decls(ident);
    if decls.count == 0 {
        lsp_respond(request.id, null);
        return;
    }

    locations := NewArray(decls.count, LSP_Location);
    defer array_free(locations);

    for decls locations[it_index] = node_location_to_lsp_location(it.location);

    lsp_respond(request.id, locations);
}
