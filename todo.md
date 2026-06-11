# TODO

## 0.3.0
- [ ] support for context
- [x] goto and autocomplete for struct literals (dotless `.{...}` literals infer their type from declaration/assignment/call-site)
- [ ] improve context based autocomplete
- [ ] polymorphic types
- [x] Implicit `.VALUE` enum completions in procedure call arguments, positional and named (issue #19)
- [x] Aliased module completions (`rl.`) no longer fall back to generic scope completions and no longer leak `#scope_file` symbols (issue #20)
- [x] Diagnostics: fix compiler invocation when `-jai_path` is given without `-jai_exe_name`; report warnings (e.g. deprecated) as well as errors; multiple diagnostics across files; attach `Info:`/`...` lines to the diagnostic message
- [x] LSP integration test harness (`scripts/lsp_test.py` + `tests/fixtures/project/`) and parser corpus runner (`scripts/run_parser_tests.sh`)
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
    - [ ] Global scope
    - [-] Local scope
    - [ ] Modifiers (`except`, `only`, `map`)
    - [x] Unwrap #as
    - [ ] Modules (`using Math :: #import "Math";`)
- [ ] Make root detection more robust - it should work quite well even without `jails.json` and it also should work with multiple entry points.
- [ ] Implement basic procedure overload resolution
- [ ] Autocomplete deref on pointer (`entity.*`)
- [ ] Support for compound declaration (`x,y,z: float;`)
- [ ] Autocomplete buildin procedures (`size_of`, `type_of` ...)
- [ ] Mason registry (nvim)
- [ ] Implement "fake" methods completions for types that are taken as the first argument of some procedures
- [ ] Improve Linux and nvim support
- [ ] Auto complet do completion for loops etierh it. or for n: ...} the n needs autocoeplt n.
