// This file contains code for running compiler for getting errors and warnings.

reset_diagnostics :: () {
    for server.previously_errored_files {
        lsp_send(LSP_Client_Message(LSP_Publish_Diagnostics).{
            method="textDocument/publishDiagnostics",
            params = .{
                uri = it,
                diagnostics = LSP_Diagnostic.[]
            }
        });

        free(it);
    }

    array_reset(*server.previously_errored_files);
}

DIAGNOSTICS_TIMEOUT_MS :: 2500;

run_diagnostics :: () {
    if server.build_root.count == 0 return;
    build_root_absolute := join(server.project_root, server.build_root, separator="/");
    defer free(build_root_absolute);

    log("Running diagnostics %", build_root_absolute);

    command: [..] string;
    defer array_free(command);

    // server.args.jai_exe_name is guaranteed non-empty (defaulted in main after argument parsing).
    jai_exe_path := server.args.jai_exe_name;
    if server.args.jai_path.count > 0 {
        jai_exe_path = join(server.args.jai_path, "bin", server.args.jai_exe_name, separator="/",, temp);
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

    array_add(*command, "---", "import_dir", server.diagnostics_metaprogram_path);

    reset_diagnostics();

    result, _, error := run_command(..command, working_directory=server.project_root, capture_and_return_output=true, timeout_ms=DIAGNOSTICS_TIMEOUT_MS);
    if result.type == .FAILED_TO_LAUNCH {
        log_error("Diagnostics could not launch the compiler (%)", jai_exe_path);
        return;
    }

    if result.type != .EXITED {
        log_error("Diagnostics compiler run did not finish within %ms, no diagnostics reported", DIAGNOSTICS_TIMEOUT_MS);
        return;
    }

    // Even successful compiles can emit warnings (e.g. deprecated procedures), so we always parse the output.
    // The compiler writes blocks shaped like:
    //
    //   path:line,col: Error: message       (or Warning:)
    //
    //       source excerpt
    //       ^^^^^^
    //
    //   path:line,col: Info: related note   (or "... in declaration of ...")
    //
    // Info and "..." blocks annotate the diagnostic that precedes them.

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

    // Index into `parsed` of the diagnostic still waiting for its ^^^ extent line, or -1.
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

        // Info / continuation blocks belong to the previous diagnostic; append them to its message.
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

            extent_target = -1; // The annotation's own ^^^ line must not widen the diagnostic.
            continue;
        }

        // A source-excerpt line consisting only of ^ marks the extent of the last diagnostic.
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

    // Publish diagnostics grouped per file.
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

        array_add(*server.previously_errored_files, uri);
    }
}
