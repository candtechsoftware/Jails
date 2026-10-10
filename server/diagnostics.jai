// This file contains code for running compiler for getting errors and warning.

DIAGNOSTICS_TIMEOUT_MS :: 120_000;

Diagnostics :: struct {
    thread: Thread;
    wake: Semaphore;

    lock: Mutex;
    pending: bool;
    quit: bool;

    previously_errored_files: [..]string;

    harvest_output: string;
    harvest_context: string;
    harvest_ready: bool;
}

diagnostics: Diagnostics;

init_diagnostics :: () {
    init(*diagnostics.lock);
    init(*diagnostics.wake);
}

start_diagnostics_thread :: () {
    thread_init(*diagnostics.thread, diagnostics_thread_proc);
    thread_start(*diagnostics.thread);
}

stop_diagnostics_thread :: () {
    lock(*diagnostics.lock);
    diagnostics.quit = true;
    unlock(*diagnostics.lock);

    signal(*diagnostics.wake);
}

run_diagnostics :: () {
    if server.build_root.count == 0 return;

    lock(*diagnostics.lock);
    diagnostics.pending = true;
    unlock(*diagnostics.lock);

    signal(*diagnostics.wake);
}

apply_pending_harvest :: () {
    lock(*diagnostics.lock);
    ready := diagnostics.harvest_ready;
    output := diagnostics.harvest_output;
    context_path := diagnostics.harvest_context;
    diagnostics.harvest_ready = false;
    diagnostics.harvest_output = "";
    diagnostics.harvest_context = "";
    unlock(*diagnostics.lock);

    if !ready return;

    harvest_compiler_types(output, context_path);
    free(output);
    free(context_path);
}

#scope_file

diagnostics_thread_proc :: (thread: *Thread) -> s64 {
    context.logger = lsp_log;

    while true {
        wait_for(*diagnostics.wake);

        lock(*diagnostics.lock);
        pending := diagnostics.pending;
        quit    := diagnostics.quit;
        diagnostics.pending = false;
        unlock(*diagnostics.lock);

        if quit break;
        if !pending continue;

        run_diagnostics_now();

        reset_temporary_storage();
    }

    return 0;
}

resolve_jai_executable :: () -> string, bool {
    if server.args.jai_path.count == 0 {
        return DEFAULT_JAI_EXE_NAME, true;
    }

    candidates: [3]string;
    candidates[0] = server.args.jai_exe_name;
    candidates[1] = DEFAULT_JAI_EXE_NAME;
    candidates[2] = "jai";

    for candidate: candidates {
        if candidate.count == 0 continue;

        path := join(server.args.jai_path, "bin", candidate, separator="/",, temp);
        if file_exists(path) return path, true;
    }

    return "", false;
}

reset_diagnostics :: () {
    for diagnostics.previously_errored_files {
        lsp_send(LSP_Client_Message(LSP_Publish_Diagnostics).{
            method="textDocument/publishDiagnostics",
            params = .{
                uri = it,
                diagnostics = LSP_Diagnostic.[]
            }
        });

        free(it);
    }

    array_reset(*diagnostics.previously_errored_files);
}

stage_harvest :: (output: string, context_path: string) {
    lock(*diagnostics.lock);
    defer unlock(*diagnostics.lock);

    free(diagnostics.harvest_output);
    free(diagnostics.harvest_context);

    diagnostics.harvest_output = copy_string(output);
    diagnostics.harvest_context = copy_string(context_path);
    diagnostics.harvest_ready = true;
}

TYPE_MARKER :: "JAILS_TYPE|";
DECL_MARKER :: "JAILS_DECL|";

harvest_compiler_types :: (output: string, context_path: string) {
    sources: [..]string;
    sources.allocator = temp;

    declarations: [..]string;
    declarations.allocator = temp;

    for line: split(output, "\n",, temp) {
        if begins_with(line, TYPE_MARKER) {
            array_add(*sources, advance(line, TYPE_MARKER.count));
            continue;
        }

        if begins_with(line, DECL_MARKER) array_add(*declarations, line);
    }

    if sources.count == 0 return;

    types := parse_harvested_types(sources, context_path);

    for line: declarations {
        parts := split(line, "|",, temp);
        if parts.count < 5 continue;

        line_number, line_ok := parse_int(*parts[3], int);
        if !line_ok continue;
        line_number -= 1;

        type_id, id_ok := parse_int(*parts[4], u64);
        if !id_ok continue;

        found, harvested_type := table_find(*types, type_id);
        if !found continue;

        harvested: Harvested_Declaration;
        harvested.name = copy_string(parts[1],, pool_alloc(*server.harvest_pool));
        harvested.file = copy_string(normalize_path(parts[2],, temp),, pool_alloc(*server.harvest_pool));
        harvested.type = harvested_type;

        table_add(*server.harvested_decls,
            harvested_decl_key(harvested.file, line_number, harvested.name), harvested);
    }

    log("Harvest mapped % declarations to compiler types", server.harvested_decls.count);
}

run_diagnostics_now :: () {
    if server.build_root.count == 0 return;
    build_root_absolute := join(server.project_root, server.build_root, separator="/");
    defer free(build_root_absolute);

    log("Running diagnostics %", build_root_absolute);

    command: [..] string;
    defer array_free(command);

    jai_exe_path, found := resolve_jai_executable();
    if !found {
        log_error("Diagnostics: could not find the Jai compiler executable in '%/bin' (tried '%', '%' and 'jai').", server.args.jai_path, server.args.jai_exe_name, DEFAULT_JAI_EXE_NAME);
        return;
    }

    array_add(*command, jai_exe_path);
    array_add(*command, build_root_absolute, "-quiet", "-no_color");

    // Use fast x64 backend on supported CPUs.
    if CPU == .X64 {
        array_add(*command, "-x64");
    }

    for local_module_folder: server.local_modules {
        array_add(*command, "-import_dir", local_module_folder);
    }

    array_add(*command, "+jails_diagnostics");

    if server.intermediate_path.count > 0 {
        joined := join(server.project_root, server.intermediate_path, separator="/",, temp);
        normalised := normalize_path(joined,, temp);
        array_add(*command, "-intermediate_path", normalised);
    }

    array_add(*command, "-project_root", server.project_root);

    array_add(*command, "---", "import_dir", server.diagnostics_metaprogram_path);

    result, output, error := run_command(..command, working_directory=server.project_root, capture_and_return_output=true, timeout_ms=DIAGNOSTICS_TIMEOUT_MS);
    defer free(output);
    defer free(error);

    if result.type == .FAILED_TO_LAUNCH {
        log_error("Diagnostics could not launch the compiler (%)", jai_exe_path);
        return;
    }

    if result.type != .EXITED {
        log_error("Diagnostics compiler run did not finish within %ms, keeping the previous diagnostics", DIAGNOSTICS_TIMEOUT_MS);
        return;
    }

    reset_diagnostics();

    stage_harvest(output, normalize_path(build_root_absolute,, temp));

    File_Diagnostic :: struct {
        file: string;
        diagnostic: LSP_Diagnostic;
        published: bool;
    }

    parsed: [..]File_Diagnostic;
    parsed.allocator = temp;

    lines := split(error, "\n");
    defer array_free(lines);

    ERROR_MARKER   :: ": Error:";
    WARNING_MARKER :: ": Warning:";
    INFO_MARKER    :: ": Info:";
    CONTINUATION_MARKER :: ": ...";

    parse_location :: (rest: string) -> (ok: bool, file: string, line: u32, character: u32) {
        ok, file, location := split_from_right(rest, ":");
        if !ok return false, "", 0, 0;
        file = replace(file, "//", "/",, temp);

        line_and_character := split(location, ",");
        if line_and_character.count < 2 return false, "", 0, 0;

        line, l_ok := parse_int(*line_and_character[0], u32);
        if !l_ok return false, "", 0, 0;

        character, c_ok := parse_int(*line_and_character[1], u32);
        if !c_ok return false, "", 0, 0;

        return true, file, line, character;
    }

    extent_target := -1;

    for output_line: lines {
        marker := "";
        severity: LSP_Diagnostic_Severity;

        if contains(output_line, ERROR_MARKER) {
            marker = ERROR_MARKER;
            severity = .ERROR;
        } else if contains(output_line, WARNING_MARKER) {
            marker = WARNING_MARKER;
            severity = .WARNING;
        }

        if marker {
            message_index := find_index_from_right(output_line, marker);
            message := slice(output_line, message_index + marker.count, output_line.count - message_index);
            ok, file, line, character := parse_location(slice(output_line, 0, message_index));
            if !ok continue;

            diagnostic: LSP_Diagnostic;
            diagnostic.message = trim(message);
            diagnostic.severity = xx severity;
            diagnostic.range.start.line = line-1;
            diagnostic.range.start.character = character-1;
            diagnostic.range.end = diagnostic.range.start;

            array_add(*parsed, .{file=file, diagnostic=diagnostic});
            extent_target = parsed.count-1;
            continue;
        }

        annotation_index := find_index_from_left(output_line, INFO_MARKER);
        if annotation_index < 0 {
            annotation_index = find_index_from_left(output_line, CONTINUATION_MARKER);
        }

        if annotation_index >= 0 {
            ok := parse_location(slice(output_line, 0, annotation_index));
            if ok && parsed.count > 0 {
                last := *parsed[parsed.count-1];
                last.diagnostic.message = tprint("%\n%", last.diagnostic.message, trim(output_line));
            }

            extent_target = -1;
            continue;
        }

        if extent_target >= 0 {
            trimmed := trim(output_line);
            if trimmed.count > 0 {
                only_carets := true;
                for char: cast([]u8) trimmed {
                    if char != #char "^" {
                        only_carets = false;
                        break;
                    }
                }

                if only_carets {
                    target := *parsed[extent_target].diagnostic;
                    target.range.end.character = target.range.start.character + cast(u32) trimmed.count;
                    extent_target = -1;
                }
            }
        }
    }

    if parsed.count == 0 {
        if result.exit_code != 0 {
            log_error("Diagnostics compile failed (exit code %) but no errors could be parsed from the output", result.exit_code);
        }
        return;
    }

    for i: 0..parsed.count-1 {
        if parsed[i].published continue;

        file_diagnostics: [..]LSP_Diagnostic;
        file_diagnostics.allocator = temp;

        for j: i..parsed.count-1 {
            if parsed[j].file != parsed[i].file continue;
            array_add(*file_diagnostics, parsed[j].diagnostic);
            parsed[j].published = true;
        }

        uri := path_to_lsp_path(normalize_path(parsed[i].file,, temp));

        lsp_send(LSP_Client_Message(LSP_Publish_Diagnostics).{
            method="textDocument/publishDiagnostics",
            params = .{
                uri = uri,
                diagnostics = file_diagnostics
            }
        });

        array_add(*diagnostics.previously_errored_files, uri);
    }
}
