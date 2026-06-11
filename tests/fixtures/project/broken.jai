// Deliberately broken file for diagnostics tests.
// The Jai compiler stops at the first error, so the multi-diagnostic case is
// a deprecation warning followed by a type error.

old_proc :: () #deprecated "use new_proc instead" {
}

main :: () {
    old_proc();
    x: int = "not an int";
}
