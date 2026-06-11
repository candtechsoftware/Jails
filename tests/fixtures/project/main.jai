#import "Basic";

rl :: #import "fakeray";

Direction :: enum {
    NORTH;
    SOUTH;
    EAST;
    WEST;
}

take :: (d: Direction) {
}

take_named :: (label: string, d: Direction) {
}

My_Struct :: struct {
    my_value: int;
}

My_Other_Struct :: struct {
    other_value: string;
}

My_Combined :: struct {
    using other: My_Other_Struct;
    combined_value: int;
}

Entity :: struct {
    position: int;
}

My_As :: struct {
    #as using base: Entity;
    extra: int;
}

Pointer_Using :: struct {
    using base: *Entity;
    flag: bool;
}

main :: () {
    // Issue #19: implicit enum dereference in call arguments.
    take(.NORTH);
    take_named(d = .SOUTH, label = "x");

    d: Direction;
    if d == .EAST {
    }
    d = .WEST;

    if d == {
        case .NORTH;
    }

    // Issue #20a: struct-literal initialization.
    my_struct : My_Struct = .{my_value = 5};
    my_struct.my_value = 6;

    plain_struct : My_Struct;
    plain_struct.my_value = 7;

    // Issue #20b: using / #as using member forwarding.
    combined: My_Combined;
    combined.other_value = "test";

    as_struct: My_As;
    as_struct.position = 1;

    ptr_using: Pointer_Using;
    ptr_using.position = 2;

    // Issue #20b crash repro: two usings in the same block.
    a_state: My_Struct;
    b_state: My_Other_Struct;
    using a_state;
    using b_state;
    my_value = 3;

    // Issue #20c: aliased module import.
    rl.init_window(800, 600, "hi");
    color: rl.Color;
    color.r = 255;
}
