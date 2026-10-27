const sessions = @import("sessions");
const Catalog = @import("catalog.zig").Catalog;

pub const Router = struct {
    pub const Destination = u128;
    catalog: *Catalog,

    pub fn route(self: *Router, player: sessions.Profile) sessions.Route(Destination) {
        return .{ .destination = self.catalog.ids[self.catalog.destination(player.uuid)] };
    }
};
