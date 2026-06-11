#import "Basic";

#scope_export

init_window :: (width: int, height: int, title: string) {
    internal_helper();
}

Color :: struct {
    r: u8;
    g: u8;
    b: u8;
    a: u8;
}

Window_Flag :: enum {
    FULLSCREEN;
    RESIZABLE;
    HIDDEN;
}

#scope_file

internal_helper :: () {
}
