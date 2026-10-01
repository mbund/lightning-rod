pub const wire = @import("wire");
pub const catalog = @import("catalog");
pub const registry = @import("registry");
pub const support = @import("support");
pub const nbt = @import("nbt");
const java = @import("minecraft_java");
const std = @import("std");
const sessions = @import("sessions");

pub const Handshake = java.Handshake;
pub const implementations = catalog.entries;
comptime {
    for (implementations) |Version|
        if (Version.Bootstrap != implementations[0].Bootstrap)
            @compileError("The standard protocol aggregate requires a shared bootstrap. Compose a custom Sessions endpoint for distinct handshakes.");
}
pub const Default: type = java.RegistryCatalog(implementations);
pub const Endpoint: type = sessions.Endpoint(implementations, implementations[0].Bootstrap, Default);
pub const Input = sessions.Inputs(implementations);

pub fn version(comptime release: []const u8) type {
    for (implementations) |Implementation| {
        for (Implementation.releases) |name| {
            if (std.mem.eql(u8, name, release)) return Implementation;
        }
    }
    @compileError("Minecraft release is not selected in the protocol build: " ++ release);
}
