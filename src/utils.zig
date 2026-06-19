const std = @import("std");

pub fn MemoryMappedStruct(comptime T: type) type {
    const info = @typeInfo(T);

    if (info.@"struct".decls.len != 0) {
        @compileError("MemoryMappedStruct does not support structs with declarations (such as functions)");
    }

    const sf = info.@"struct";

    var names: [sf.fields.len][:0]const u8 = undefined;
    var types: [sf.fields.len]type = undefined;
    var attrs: [sf.fields.len]std.builtin.Type.StructField.Attributes = undefined;

    for (0..sf.fields.len) |i| {
        names[i] = sf.fields[i].name;
        types[i] = sf.fields[i].type;
        attrs[i] = .{
            .@"align" = 1,
            .default_value_ptr = sf.fields[i].default_value_ptr,
            .@"comptime" = sf.fields[i].is_comptime,
        };
    }

    return @Struct(.@"extern", null, &names, &types, &attrs);
}
