Plugin :: Metaprogram_Plugin;

Jails_Diagnostics_Plugin :: struct {
    #as using base: Plugin;
    intermediate_path: string;
    project_root: string;
    emitted_types: Table(u64, bool);
}

get_plugin :: () -> *Plugin {
    p := New(Jails_Diagnostics_Plugin);

    p.init = init;
    p.before_intercept = before_intercept;
    p.add_source = add_source;
    p.message = message;
    p.shutdown = shutdown;

    return p;
}

init :: (p: *Plugin, options: [] string) -> bool {
    my := cast(*Jails_Diagnostics_Plugin) p;

    cursor := 0;
    while cursor < options.count {
        s := options[cursor];
        if s == {
          case "-intermediate_path";
            if cursor >= options.count-1 {
                log_error("Jails_Diagnostics_Plugin: Missing argument to -intermediate_path.\n");
                return false;
            }

            my.intermediate_path = options[cursor+1];
            cursor += 2;
          case "-project_root";
            if cursor >= options.count-1 {
                log_error("Jails_Diagnostics_Plugin: Missing argument to -project_root.\n");
                return false;
            }

            my.project_root = options[cursor+1];
            cursor += 2;
          case;
            log_error("Command line for plugin Jails_Diagnostics_Plugin: Unknown argument '%'\n", s);
            return false;
        }
    }

    return true;
}

is_project_file :: (p: *Jails_Diagnostics_Plugin, node: *Code_Node) -> bool {
    if p.project_root.count == 0 return true;
    if !node || !node.enclosing_load return false;
    return begins_with(node.enclosing_load.fully_pathed_filename, p.project_root);
}

emit_struct_type :: (info: *Type_Info_Struct) {
    builder: String_Builder;
    print_to_builder(*builder, "Jails_Harvested_% :: struct {", cast(u64) info);

    emitted := 0;
    for member: info.members {
        if member.name.count == 0 continue;
        if member.flags & .CONSTANT continue;

        type_text := type_to_string(member.type);

        if type_text.count == 0 || contains(type_text, "{") || contains(type_text, ";") continue;

        print_to_builder(*builder, " %: %;", member.name, type_text);
        emitted += 1;
    }

    append(*builder, " }");

    if emitted == 0 return;

    print("JAILS_TYPE|%|%\n", cast(u64) info, builder_to_string(*builder));
}

emit_declaration_type :: (decl: *Code_Declaration) {
    if !decl || decl.name.count == 0 return;

    type_id: u64;
    if decl.type type_id = cast(u64) decl.type;
    if decl.type_inst && decl.type_inst.result type_id = cast(u64) decl.type_inst.result;
    if type_id == 0 return;

    file := "";
    if decl.enclosing_load file = decl.enclosing_load.fully_pathed_filename;
    if file.count == 0 return;

    print("JAILS_DECL|%|%|%|%\n", decl.name, file, decl.l0, type_id);
}

message :: (_p: *Plugin, msg: *Message) {
    if msg.kind != .TYPECHECKED return;

    p := cast(*Jails_Diagnostics_Plugin) _p;
    typechecked := cast(*Message_Typechecked) msg;

    for entry: typechecked.structs {
        code_struct := entry.expression;
        if !code_struct.defined_type continue;
        if code_struct.defined_type.members.count == 0 continue;
        if !is_project_file(p, code_struct) continue;

        _, is_new := find_or_add(*p.emitted_types, cast(u64) code_struct.defined_type);
        if !is_new continue;

        emit_struct_type(code_struct.defined_type);
    }

    for entry: typechecked.declarations {
        if !is_project_file(p, entry.expression) continue;
        emit_declaration_type(entry.expression);
    }

    for body: typechecked.procedure_bodies {
        if !is_project_file(p, body.expression) continue;

        for node: body.expression.block.statements {
            if node.kind == .DECLARATION emit_declaration_type(cast(*Code_Declaration) node);
        }
    }
}

add_source :: (_p: *Plugin) {
    p := cast(*Jails_Diagnostics_Plugin) _p;
    add_build_string("JAILS_DIAGNOSTICS_BUILD :: true;", p.workspace);
}

before_intercept :: (_p: *Plugin, flags: *Intercept_Flags) {
    p := cast(*Jails_Diagnostics_Plugin) _p;
    options := get_build_options(p.workspace);
    options.output_type = .NO_OUTPUT;

    if p.intermediate_path {
        options.intermediate_path = p.intermediate_path;
    }

    set_build_options(options, p.workspace);
}

shutdown :: (_p: *Plugin) {
    p := cast(*Jails_Diagnostics_Plugin) _p;
    free(p);
}

#import "Compiler";
#import "Basic";
#import "String";
#import "Hash_Table";
