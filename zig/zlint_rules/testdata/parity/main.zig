const other = @import("other.zig");

const A = struct {
    b: *B,
};

const B = struct {
    a: *A,
};

fn uncalledPrivate() void {
    _ = other;
}

fn noisy(a: u32, b: u32) void {
    if (a > 0) {
        if (b > 0) {
            while (b > 0) : (b -= 1) {
                _ = a;
            }
        }
    }
    const cast: *u8 = @ptrCast(@alignCast(&a));
    _ = cast;
}
