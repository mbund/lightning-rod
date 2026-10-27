const std = @import("std");
const output = @import("output.zig");

test "socket retention reserves progress across fanout and every release order" {
    for (1..9) |frames| {
        for (0..8) |first| {
            var budget: output.SocketBudget = .init(frames);
            var loans: [8]output.Loan = @splat(.{ .payload = "packet", .references = 1 });
            for (loans[0 .. frames - 1]) |*loan| {
                try std.testing.expect(loan.retainSocket(&budget));
                try std.testing.expect(loan.retainSocket(&budget));
                loan.release();
            }
            try std.testing.expectEqual(frames - 1, budget.used);
            try std.testing.expect(!loans[frames - 1].retainSocket(&budget));
            for (0..loans.len) |offset| {
                const index = (first + offset) % loans.len;
                if (index >= frames - 1) continue;
                const loan = &loans[index];
                const before = budget.used;
                loan.releaseSocket();
                try std.testing.expectEqual(before, budget.used);
                loan.releaseSocket();
                try std.testing.expectEqual(before - 1, budget.used);
                try std.testing.expectEqual(@as(usize, 0), loan.references);
                try std.testing.expectEqual(null, loan.budget);
            }
            try std.testing.expectEqual(@as(usize, 0), budget.used);
            if (frames > 1) {
                try std.testing.expect(loans[frames - 1].retainSocket(&budget));
                loans[frames - 1].releaseSocket();
            }
            for (loans[frames - 1 ..]) |*loan| loan.release();
        }
    }
}

test "owned headers copy correctly across every output wrap after source reuse" {
    const expected = "header-payload";
    for (0..expected.len + 1) |prefix| {
        var source = expected.*;
        var loan: output.Loan = .framed(&source, source[prefix..]);
        @memset(source[0..prefix], 255);
        const packet = loan.fragments();
        try std.testing.expectEqual(expected.len, packet.length());
        try std.testing.expect(packet.payload.ptr == source[prefix..].ptr);
        for (0..expected.len + 1) |wrap| {
            var actual: [expected.len]u8 = undefined;
            packet.copyTo(actual[0..wrap], actual[wrap..]);
            try std.testing.expectEqualSlices(u8, expected, &actual);
        }
    }
}
