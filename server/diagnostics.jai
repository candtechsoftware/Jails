// This file contains code for running compiler for getting errors and warning.

reset_diagnostics :: () {
    if server.previously_errored_file {
        lsp_send(LSP_Client_Message(LSP_Publish_Diagnostics).{
            method="textDocument/publishDiagnostics",
            params = .{
                uri = server.previously_errored_file,
                diagnostics = LSP_Diagnostic.[]
            }
        });
    }

    for errored_file: server.previously_errored_files {
        if errored_file == server.previously_errored_file continue;
        lsp_send(LSP_Client_Message(LSP_Publish_Diagnostics).{
            method="textDocument/publishDiagnostics",
            params = .{
                uri = errored_file,
                diagnostics = LSP_Diagnostic.[]
            }
        });
        free(errored_file);
    }
    array_reset(*server.previously_errored_files);
}

Parsed_Diagnostic :: struct {
    file: string;
    diagnostic: LSP_Diagnostic;
}

parse_error_line :: (output_line: string) -> (ok: bool, file: string, diagnostic: LSP_Diagnostic) {
    ERROR_MARKER :: ": Error:";
    WARNING_MARKER :: ": Warning:";

    marker: string;
    severity: LSP_Diagnostic_Severity;

    if contains(output_line, ERROR_MARKER) {
        marker = ERROR_MARKER;
        severity = .ERROR;
    } else if contains(output_line, WARNING_MARKER) {
        marker = WARNING_MARKER;
        severity = .WARNING;
    } else {
        return false, "", .{};
    }

    message_index := find_index_from_right(output_line, marker);
    message := slice(output_line, message_index + marker.count, output_line.count - message_index);
    rest := slice(output_line, 0, message_index);

    split_ok: bool;
    file: string;
    location: string;
    split_ok, file, location = split_from_right(rest, ":");
    file = replace(file, "//", "/",, temp);
    if !split_ok return false, "", .{};

    line_and_character := split(location, ",");
    if line_and_character.count < 2 return false, "", .{};

    line, l_ok := parse_int(*line_and_character[0], u32);
    if !l_ok return false, "", .{};

    character, c_ok := parse_int(*line_and_character[1], u32);
    if !c_ok return false, "", .{};

    diag: LSP_Diagnostic;
    diag.message = message;
    diag.severity = xx severity;
    diag.range.start.line = line-1;
    diag.range.start.character = character-1;
    diag.range.end.line = line-1;
    diag.range.end.character = character-1;

    return true, file, diag;
}

run_diagnostics :: () {
    if server.build_root.count == 0 return;
    build_root_absolute := join(server.project_root, server.build_root, separator="/");
    defer free(build_root_absolute);

    log("Running diagnostics %", build_root_absolute);

    command: [..] string;
    defer array_free(command);

    jai_exe_path := DEFAULT_JAI_EXE_NAME;
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

    result, _, error := run_command(..command, working_directory=server.project_root, capture_and_return_output=true, timeout_ms=2500);
    if result.exit_code == 0 {
        return;
    }

    lines := split(error, "\n");
    defer array_free(lines);

    // Parse all errors and warnings from compiler output
    parsed_diagnostics: [..]Parsed_Diagnostic;
    defer array_free(parsed_diagnostics);

    for i: 0..lines.count-1 {
        output_line := lines[i];
        ok, file, diagnostic := parse_error_line(output_line);
        if !ok continue;

        // Look ahead for highlight carets (^^^^^) to determine error range width
        highlighted_chars: u32;
        for j: i+1..lines.count-1 {
            caret_line := lines[j];
            if !contains(caret_line, #char "^") continue;

            for char: cast([]u8) caret_line {
                if char == #char "^" highlighted_chars += 1;
            }
            break;
        }

        if highlighted_chars > 0 {
            diagnostic.range.end.character = diagnostic.range.start.character + highlighted_chars;
        }

        array_add(*parsed_diagnostics, .{ file=file, diagnostic=diagnostic });
    }

    if parsed_diagnostics.count == 0 return;

    // Group diagnostics by file and publish
    // Use a simple approach: collect unique files, then gather diagnostics for each
    published_files: [..]string;
    defer array_free(published_files);

    for pd: parsed_diagnostics {
        already_published := false;
        for pf: published_files {
            if pf == pd.file { already_published = true; break; }
        }
        if already_published continue;

        // Collect all diagnostics for this file
        file_diagnostics: [..]LSP_Diagnostic;
        defer array_free(file_diagnostics);

        for pd2: parsed_diagnostics {
            if pd2.file == pd.file {
                array_add(*file_diagnostics, pd2.diagnostic);
            }
        }

        file_uri := path_to_lsp_path(normalize_path(pd.file,, temp));

        lsp_send(LSP_Client_Message(LSP_Publish_Diagnostics).{
            method="textDocument/publishDiagnostics",
            params = .{
                uri = file_uri,
                diagnostics = file_diagnostics
            }
        });

        array_add(*published_files, file_uri);
        array_add(*server.previously_errored_files, copy_string(file_uri));
    }

    // Update legacy single-file tracking for backwards compat with reset_diagnostics
    if server.previously_errored_files.count > 0 {
        if server.previously_errored_file.count > 0 {
            free(server.previously_errored_file);
        }
        server.previously_errored_file = copy_string(server.previously_errored_files[0]);
    }
}
