Memory_File :: struct {
    path: string;
    content: [..]u8;
}

init_memory_files :: () {
    init(*server.memory_files_lock);
    server.memory_files.allocator = context.default_allocator;
}

deinit_memory_files :: () {
    push_allocator(context.default_allocator);
    for file: server.memory_files {
        array_free(file.content);
        free(file.path);
    }
    deinit(*server.memory_files);
    destroy(*server.memory_files_lock);
}

create_memory_file :: (file_path: string, content: string) {
    push_allocator(context.default_allocator);
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);

    file := table_find_pointer(*server.memory_files, file_path);
    if file {
        replace_range(*file.content, 0, file.content.count, content);
        return;
    }

    new_file: Memory_File;
    new_file.path = copy_string(file_path);
    array_copy(*new_file.content, cast([]u8) content);
    table_add(*server.memory_files, new_file.path, new_file);
}

edit_memory_file :: (file_path: string, changes: []LSP_Content_Change) -> bool {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);

    file := table_find_pointer(*server.memory_files, file_path);
    if !file {
        log_error("File is not in the cache %", file_path);
        return false;
    }

    changed := false;
    for change: changes {
        if !change.range {
            // Full document sync: the client sent the whole new text.
            changed = replace_range(*file.content, 0, file.content.count, change.text) || changed;
            continue;
        }

        changed = apply_change(*file.content, change.range.start, change.range.end, change.text) || changed;
    }
    return changed;
}

remove_memory_file :: (file_path: string) {
    push_allocator(context.default_allocator);
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);

    found, file := table_remove(*server.memory_files, file_path);
    if !found return;
    array_free(file.content);
    free(file.path);
}

find_line_in_memory_file :: (file: string, position: LSP_Position) -> string {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);

    ok, memory_file := table_find(*server.memory_files, file);
    if !ok return "";
    content := memory_file.content;

    start := position_to_offset(content, .{line = position.line, character = 0});

    stop := start;
    while stop < content.count && content[stop] != #char "\n" stop += 1;

    return to_string(content.data + start, stop - start);
}

is_memory_file :: (name: string) -> bool {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);

    return table_contains(*server.memory_files, name);
}

get_memory_file :: (name: string) -> content: []u8, found: bool {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);

    ok, file := table_find(*server.memory_files, name);
    if !ok {
        return .[], false;
    }

    return file.content, true;
}

// The parser uses byte columns, while LSP uses UTF-16 code units.
utf16_column_to_byte_column :: (line: string, column: int) -> int {
    offset := 0;
    units := 0;
    while offset < line.count && units < column && line[offset] != #char "\n" {
        byte := line[offset];
        width := ifx byte >= 0xF0 then 4 else ifx byte >= 0xE0 then 3 else ifx byte >= 0xC0 then 2 else 1;
        units += ifx width == 4 then 2 else 1;
        offset += width;
    }
    return min(offset, line.count);
}

byte_column_to_utf16_column :: (line: string, column: int) -> int {
    units := 0;
    for index: 0..clamp(column, 0, line.count)-1 {
        byte := line[index];
        if (byte & 0xC0) == 0x80 continue;
        units += ifx byte >= 0xF0 then 2 else 1;
    }
    return units;
}

#scope_file

position_to_offset :: (content: []u8, position: LSP_Position) -> int {
    offset := 0;
    line := 0;

    while line < position.line && offset < content.count {
        if content[offset] == #char "\n" line += 1;
        offset += 1;
    }

    if line < position.line {
        return content.count; // The document has fewer lines than requested.
    }

    return offset + utf16_column_to_byte_column(slice(cast(string) content, offset, content.count - offset), position.character);
}

replace_range :: (content: *[..]u8, start: int, end: int, text: string) -> bool {
    if start < 0 || start > end || end > content.count {
        log_error("replace_range: invalid range [%, %) for a document of % bytes, ignoring the edit.", start, end, content.count);
        return false;
    }

    if end - start == text.count && slice(cast(string) content.*, start, text.count) == text return false;

    old_count := content.count;
    removed   := end - start;
    tail      := old_count - end;
    new_count := old_count - removed + text.count;

    if new_count > content.allocated {
        array_reserve(content, new_count);
    }

    if tail > 0 && text.count != removed {
        source := content.data + end;
        dest   := content.data + start + text.count;

        if dest < source {
            for 0..tail-1 dest[it] = source[it];
        } else {
            for < 0..tail-1 dest[it] = source[it];
        }
    }

    if text.count > 0 {
        memcpy(content.data + start, text.data, text.count);
    }

    content.count = new_count;
    return true;
}

apply_change :: (content: *[..]u8, from: LSP_Position, to: LSP_Position, text: string) -> bool {
    start_index := position_to_offset(content.*, from);
    end_index   := position_to_offset(content.*, to);

    if end_index < start_index {
        tmp := start_index;
        start_index = end_index;
        end_index = tmp;
    }

    return replace_range(content, start_index, end_index, text);
}
