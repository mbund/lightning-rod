//! Sessions before play: login, encryption, compression, status, keepalive, configuration and payload
//! channels, and the pings a client sends in play.
const std = @import("std");
const lightning_rod = @import("lightning_rod");

pub const offline_authentication = @import("offline_authentication.zig");
pub const payload_channels = @import("payload_channels.zig");
pub const session_compression = @import("session_compression.zig");
pub const session_configuration = @import("session_configuration.zig");
pub const session_disconnect = @import("session_disconnect.zig");
pub const session_encryption = @import("session_encryption.zig");
pub const session_keepalive = @import("session_keepalive.zig");
pub const session_login_start = @import("session_login_start.zig");
pub const session_login_success = @import("session_login_success.zig");
pub const session_ping = @import("session_ping.zig");
pub const session_status = @import("session_status.zig");

const LoginStart = session_login_start.LoginStart;
const LoginEncryption = session_encryption.LoginEncryption;
const Disconnect = session_disconnect.Disconnect;
const OfflineAuthentication = offline_authentication.OfflineAuthentication;
const LoginCompression = session_compression.LoginCompression;
const LoginSuccess = session_login_success.LoginSuccess;
const Keepalive = session_keepalive.Keepalive;
const Ping = session_ping.Ping;
const Status = session_status.Status;
const PayloadChannels = payload_channels;
const SessionConfiguration = session_configuration.Plugin;

/// The plugins a session runs before play, in order. Catalog is the protocol catalog the
/// configuration phase serves.
pub fn Plugins(comptime Catalog: type) type {
    return @Tuple(&.{
        lightning_rod.plugin.Selection(LoginStart),
        lightning_rod.plugin.Selection(LoginEncryption),
        lightning_rod.plugin.Selection(Disconnect),
        lightning_rod.plugin.Selection(OfflineAuthentication),
        lightning_rod.plugin.Selection(LoginCompression),
        lightning_rod.plugin.Selection(LoginSuccess),
        lightning_rod.plugin.Selection(Keepalive),
        lightning_rod.plugin.Selection(Ping),
        lightning_rod.plugin.Selection(Status),
        lightning_rod.plugin.Selection(PayloadChannels.Session),
        lightning_rod.plugin.Selection(SessionConfiguration(Catalog)),
    });
}

pub fn plugins(protocols: anytype) Plugins(@typeInfo(@TypeOf(protocols)).pointer.child) {
    const ConfigurationPlugin = SessionConfiguration(@typeInfo(@TypeOf(protocols)).pointer.child);
    return .{
        lightning_rod.plugin.configured(LoginStart, LoginStart.Configuration{}),
        lightning_rod.plugin.configured(LoginEncryption, LoginEncryption.Configuration{}),
        lightning_rod.plugin.configured(Disconnect, Disconnect.Configuration{}),
        lightning_rod.plugin.configured(OfflineAuthentication, OfflineAuthentication.Configuration{}),
        lightning_rod.plugin.configured(LoginCompression, LoginCompression.Configuration{}),
        lightning_rod.plugin.configured(LoginSuccess, LoginSuccess.Configuration{}),
        lightning_rod.plugin.configured(Keepalive, Keepalive.Configuration{}),
        lightning_rod.plugin.configured(Ping, Ping.Configuration{}),
        lightning_rod.plugin.configured(Status, Status.Configuration{}),
        lightning_rod.plugin.configured(PayloadChannels.Session, PayloadChannels.Session.Configuration{}),
        lightning_rod.plugin.configured(ConfigurationPlugin, ConfigurationPlugin.Configuration{ .protocols = protocols }),
    };
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("configuration_test.zig");
}
