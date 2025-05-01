timer: std.time.Timer,
/// ns
len: u64,
loop: bool,

pub fn start(len: u64, loop: bool) @This() {
    return .{
        .timer = std.time.Timer.start() catch @panic("can't start timer"),
        .loop = loop,
        .len = len,
    };
}

pub fn reset(timer: *@This()) void {
    timer.timer.reset();
}

pub fn justFinished(timer: *@This()) bool {
    if (timer.since() > timer.len) {
        if (timer.loop) {
            timer.reset();
        }
        return true;
    }
    return false;
}

pub fn since(timer: *@This()) u64 {
    return timer.timer.read();
}

const std = @import("std");
