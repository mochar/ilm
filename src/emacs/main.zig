const std = @import("std");
const Core = @import("core").Core;
const c = @cImport({
    @cInclude("emacs-module.h");
});

pub export var plugin_is_GPL_compatible: c_int = 1;

fn message(env: [*c]c.emacs_env, msg: []const u8) void {
    const q_message: c.emacs_value = env.*.intern.?(env, "message");
    const q_str: c.emacs_value = env.*.make_string.?(env, msg.ptr, @intCast(msg.len));
    var args = [_]c.emacs_value{ q_str };
    _ = env.*.funcall.?(env, q_message, 1, &args);
}

export fn emacs_module_init(rt: [*c]c.emacs_runtime) c_int {
    const env: [*c]c.emacs_env = rt.*.get_environment.?(rt);
    message(env, "wowowowwo");
    
    return 0;
}

