const std = @import("std");

pub fn MemoryMappedStruct(comptime T: type) type {
    const info = @typeInfo(T);

    if (info.@"struct".decls.len != 0) {
        @compileError("MemoryMappedStruct does not support structs with declarations (such as functions)");
    }

    var fields = [_]std.builtin.Type.StructField{.{
        .name = "",
        .type = T,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = 1,
    }} ** info.@"struct".fields.len;

    for (0..info.@"struct".fields.len) |i| {
        fields[i] = .{
            .alignment = 1,
            .name = info.@"struct".fields[i].name,
            .type = info.@"struct".fields[i].type,
            .default_value_ptr = info.@"struct".fields[i].default_value_ptr,
            .is_comptime = info.@"struct".fields[i].is_comptime,
        };
    }

    return @Type(.{
        .@"struct" = .{
            .is_tuple = info.@"struct".is_tuple,
            .layout = .@"extern",
            .fields = &fields,
            .decls = &.{},
        },
    });
}
