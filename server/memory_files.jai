Memory_File :: struct {
    path: string;
    content: [..]u8;
    line_starts: [..]int;
    line_starts_valid: bool;
}

init_memory_files :: () {
    init(*server.memory_files_lock);
    server.memory_files.allocator = context.default_allocator;
}

deinit_memory_files :: () {
    push_allocator(context.default_allocator);
    for file: server.memory_files {
        array_free(file.content);
        array_free(file.line_starts);
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
        if replace_range(*file.content, 0, file.content.count, content) file.line_starts_valid = false;
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
        edited: bool;
        if !change.range {
            // Full document sync: the client sent the whole new text.
            edited = replace_range(*file.content, 0, file.content.count, change.text);
        } else {
            edited = apply_change(file, change.range.start, change.range.end, change.text);
        }
        if edited file.line_starts_valid = false;
        changed = edited || changed;
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
    array_free(file.line_starts);
    free(file.path);
}

find_line_in_memory_file :: (file: string, position: LSP_Position) -> string {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);

    memory_file := table_find_pointer(*server.memory_files, file);
    if !memory_file return "";
    ensure_line_starts(memory_file);
    content := memory_file.content;
    if position.line >= memory_file.line_starts.count return "";
    start := memory_file.line_starts[position.line];
    stop := ifx position.line + 1 < memory_file.line_starts.count then memory_file.line_starts[position.line + 1] - 1 else content.count;
    return slice(cast(string) content, start, stop - start);
}

// Borrowed until the next document mutation, like get_memory_file's content.
get_memory_file_line_starts :: (name: string) -> []int {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);

    file := table_find_pointer(*server.memory_files, name);
    if !file return .[];
    ensure_line_starts(file);
    return file.line_starts;
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

ensure_line_starts :: (file: *Memory_File) {
    if file.line_starts_valid return;
    push_allocator(context.default_allocator);
    array_reset(*file.line_starts);
    array_add(*file.line_starts, 0);
    for byte, index: file.content {
        if byte == #char "\n" array_add(*file.line_starts, index + 1);
    }
    file.line_starts_valid = true;
}

position_to_offset :: (file: *Memory_File, position: LSP_Position) -> int {
    ensure_line_starts(file);
    if position.line >= file.line_starts.count return file.content.count;
    offset := file.line_starts[position.line];
    return offset + utf16_column_to_byte_column(slice(cast(string) file.content, offset, file.content.count - offset), position.character);
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

apply_change :: (file: *Memory_File, from: LSP_Position, to: LSP_Position, text: string) -> bool {
    start_index := position_to_offset(file, from);
    end_index   := position_to_offset(file, to);

    if end_index < start_index {
        tmp := start_index;
        start_index = end_index;
        end_index = tmp;
    }

    return replace_range(*file.content, start_index, end_index, text);
}
