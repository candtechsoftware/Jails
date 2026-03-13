handle_references :: (request: LSP_Request_Message_References) {
    push_allocator(temp);

    file_path := normalize_path(request.params.textDocument.uri);

    file := get_file(file_path);
    if !file {
        lsp_respond(request.id, null);
        return;
    }

    cursor_location := lsp_location_to_node_location(request.params.position, file_path);
    cursor_node := get_node_by_location(file, cursor_location);

    if !cursor_node || cursor_node.kind != .IDENTIFIER {
        lsp_respond(request.id, null);
        return;
    }

    ident := cast(*Identifier) cursor_node;
    target_name := ident.name;

    // Find the declaration(s) this identifier refers to
    target_decls := get_identifier_decls(ident);

    include_declaration := request.params._context.includeDeclaration;

    locations: [..]LSP_Location;

    // Search all files for identifiers matching this name that resolve to the same declaration
    for search_file: server.files {
        for node: search_file.nodes {
            if node.kind == .IDENTIFIER {
                found_ident := cast(*Identifier) node;
                if found_ident.name != target_name continue;

                // Check if this identifier resolves to the same declaration
                found_decls := get_identifier_decls(found_ident);
                if found_decls.count == 0 continue;

                matches := false;
                for found_decl: found_decls {
                    for target_decl: target_decls {
                        if found_decl == target_decl {
                            matches = true;
                            break found_decl;
                        }
                    }
                }

                if !matches continue;

                array_add(*locations, node_location_to_lsp_location(found_ident.location));
            }

            // Include the declaration itself if requested
            if include_declaration && node.kind == .DECLARATION {
                decl := cast(*Declaration) node;
                if decl.name != target_name continue;

                is_target := false;
                for target_decl: target_decls {
                    if decl == target_decl {
                        is_target = true;
                        break;
                    }
                }

                if is_target {
                    array_add(*locations, node_location_to_lsp_location(decl.location));
                }
            }
        }
    }

    if locations.count == 0 {
        lsp_respond(request.id, null);
        return;
    }

    lsp_respond(request.id, locations);
}
