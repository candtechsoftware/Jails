# TODO

## 0.3.0
- [x] support for context (`context.` completion, chaining and goto: Context_Base members plus every `#add_context` in the program, and `#Context` in type position)
- [x] goto and autocomplete for struct literals (dotless `.{...}` literals infer their type from declaration/assignment/call-site)
- [ ] improve context based autocomplete
- [x] Hover (signature, doc comment, origin file) built on the shared identifier resolver
- [x] One identifier resolver: semantic tokens now uses `get_declarations` instead of its own
      name-table heuristic, so shadowed names resolve correctly everywhere
- [x] Locals shadow globals (`get_declarations` returns nearest scope first)
- [x] Unknown requests answer `METHOD_NOT_FOUND` instead of never replying
- [x] Diagnostics run on a worker thread: startup and every save no longer freeze the editor for
      the length of a compiler run, and a run that times out keeps the previous diagnostics instead
      of blanking them
- [x] Harvested compiler types are keyed by (file, line, name) instead of line alone: the old key
      collided across every file and made `get_node_type` do an allocating multi-find per declaration
- [x] Keep the last good AST: a half-typed line no longer costs goto/hover/completion the answers
      the last complete version could give
- [x] Hover, goto and semantic tokens share one cursor resolver (`resolve_cursor_declaration`), so
      named arguments, implicit enum values, struct literal members and enum member declarations
      all answer the same way everywhere
- [x] polymorphic types (struct parameters substituted into member types: `T`, `*T`, `[]T`, `[..]T`)
- [x] Semantic tokens provider
- [x] Autocomplete for generated types (`#insert`, `#bake_arguments`, polymorphic instantiations) harvested from the compiler on save
- [x] Keyword, directive and compiler builtin completions; completion item kinds (field, enum member, constant, module, type parameter)
- [x] Subscripted values keep their element type (`t := *arr[it]; t.`)
- [x] Implicit `.VALUE` enum completions in procedure call arguments, positional and named (issue #19)
- [x] Aliased module completions (`rl.`) no longer fall back to generic scope completions and no longer leak `#scope_file` symbols (issue #20)
- [x] Diagnostics: fix compiler invocation when `-jai_path` is given without `-jai_exe_name`; report warnings (e.g. deprecated) as well as errors; multiple diagnostics across files; attach `Info:`/`...` lines to the diagnostic message
- [ ] ...

## 0.2.0
- [x] Array, String completions (data, count)
- [x] Do not autocomplete when the full path was not resolved
- [x] Array Subscript
- [x] Deprecated procedures
- [x] Port stuff from completions to go to definition
- [x] Fix enums completions
- [x] Aliased/prefixed modules (`Math :: #import "Math";`)
- [x] Fix goto and completions for procedure calls inside aliased module (`Math.make_matrix4().`)
- [x] Fix signature help with procedures in aliased module or struct
- [x] Autocomplete `it`, `it_index` in loops
- [x] Autocomplete custom loops values (`for name, name_index: names`)
- [x] Support for infered enum values (Go To Definition and autocomplete)
- [-] Fix the problem with incomplete binary operation joining with content on next line (is this even solvable?)
- [-] Fix broken completions for local variables across some boundaries like if-switch
- [-] Using
    - [-] Structs, Enums, Unions
    - [x] Global scope (file-scope `using var;` of a struct/enum, also through imports and aliases, e.g. GL's `using gl;`)
    - [x] Local scope (declarations, member paths and `#as` wrappers, not just bare identifiers)
    - [x] Procedure parameters (`f :: (using self: *Entity)`)
    - [x] Modifiers (`except`, `only`; `map` is still ignored)
    - [x] Unwrap #as
    - [x] Modules (`using Math :: #import "Math";` and bare `using #import "Math";`)
- [ ] Make root detection more robust - it should work quite well even without `jails.json` and it also should work with multiple entry points.
- [ ] Implement basic procedure overload resolution
- [ ] Autocomplete deref on pointer (`entity.*`)
- [ ] Support for compound declaration (`x,y,z: float;`)
- [x] Autocomplete buildin procedures (`size_of`, `type_of` ...)
- [ ] Mason registry (nvim)
- [ ] Implement "fake" methods completions for types that are taken as the first argument of some procedures
- [ ] Improve Linux and nvim support
- [x] `it` and `it_index` in every loop shape, including ranges, strings and custom names (`for n: ...`)
