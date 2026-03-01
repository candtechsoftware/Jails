handle_hover :: (request: LSP_Request_Message_Hover) {
    push_allocator(temp);

    file_path := normalize_path(request.params.textDocument.uri);

    file := get_file(file_path);
    if !file {
        lsp_respond(request.id, null);
        return;
    }

    cursor_location := lsp_location_to_node_location(request.params.position, file_path);
    cursor_node := get_node_by_location(file, cursor_location);

    if !cursor_node {
        lsp_respond(request.id, null);
        return;
    }

    if cursor_node.kind != .IDENTIFIER {
        lsp_respond(request.id, null);
        return;
    }

    ident := cast(*Identifier) cursor_node;

    builder: String_Builder;

    // Handle dot paths (e.g., foo.bar)
    if ident.parent && ident.parent.kind == .BINARY_OPERATION {
        bin_op := cast(*Binary_Operation) ident.parent;
        if bin_op.operation == .DOT {
            path := get_dot_path(bin_op, ident);
            if path.count > 0 {
                resolved := get_path_type(path);
                if resolved {
                    ast_print(*builder, resolved);
                    lsp_respond(request.id, LSP_Hover.{ contents=builder_to_string(*builder) });
                    return;
                }
            }
        }
    }

    type := get_node_type(ident);
    if !type {
        lsp_respond(request.id, null);
        return;
    }

    ast_print(*builder, type);
    lsp_respond(request.id, LSP_Hover.{ contents=builder_to_string(*builder) });
}
