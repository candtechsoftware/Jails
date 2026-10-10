declaration_markdown :: (decl: *Declaration) -> string {
    builder: String_Builder;

    append(*builder, "```jai\n");
    ast_print(*builder, decl);
    append(*builder, "\n```");

    doc := doc_comment_for(decl);
    if doc.count > 0 {
        append(*builder, "\n\n");
        append(*builder, doc);
    }

    origin := origin_of(decl.location.file);
    if origin.count > 0 {
        append(*builder, "\n\n*");
        append(*builder, origin);
        append(*builder, "*");
    }

    return builder_to_string(*builder);
}

handle_hover :: (request: LSP_Request_Message_Hover) {
    push_allocator(temp);

    file_path := normalize_path(request.params.textDocument.uri);

    file := get_file(file_path);
    if !file {
        lsp_respond(request.id, null);
        return;
    }

    cursor_location := lsp_location_to_node_location(request.params.position, file_path);

    decl: *Declaration;

    ident_node := get_node_by_location(file, cursor_location, .IDENTIFIER);
    if ident_node {
        ident := cast(*Identifier) ident_node;

        handled: bool;
        decl, handled = resolve_cursor_declaration(ident);
        if !handled decl = resolve_identifier(ident);
    } else {
        decl = cast(*Declaration) get_node_by_location(file, cursor_location, .DECLARATION);
    }

    if !decl {
        lsp_respond(request.id, null);
        return;
    }

    lsp_respond(request.id, LSP_Hover.{ contents = .{ value = declaration_markdown(decl) } });
}

#scope_file

comment_end_line :: (comment: Comment_Token) -> int {
    if comment.multiline return comment.l1;
    return comment.l1 - 1;
}

doc_comment_for :: (decl: *Declaration) -> string {
    file := get_file(decl.location.file);
    if !file return "";

    last := -1;
    for comment, index: file.comments {
        if comment.l0 > decl.location.l0 break;
        if comment_end_line(comment) == decl.location.l0 - 1 last = index;
    }

    if last < 0 return "";

    first := last;
    while first > 0 && comment_end_line(file.comments[first-1]) == file.comments[first].l0 - 1 {
        first -= 1;
    }

    builder: String_Builder;
    for index: first..last {
        if index > first append(*builder, "\n");
        append(*builder, trim(file.comments[index].string_value));
    }

    return builder_to_string(*builder);
}

origin_of :: (path: string) -> string {
    for root: string.[server.args.jai_path, server.project_root] {
        if root.count > 0 && begins_with(path, root) return trim_left(advance(path, root.count), "/");
    }

    return path;
}
