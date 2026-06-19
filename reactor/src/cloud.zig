//! Thin HTTPS client for the cloud control plane. `work login` stores a token at
//! `~/.work/credentials`; `whoami`/`deploy` send it as `Authorization: Bearer …`
//! to `/api/platform/*`. One `request` helper over std.http.Client (Zig native
//! TLS — no curl dependency, the CLI stays a single binary).
const std = @import("std");

pub const Response = struct { status: u16, body: []const u8 };

/// Make an HTTPS request to the control plane. `token` (may be empty) is sent as
/// a Bearer credential; `payload` (may be null) is a JSON body. Caller owns
/// `Response.body`.
pub fn request(
    io: std.Io,
    alloc: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    token: []const u8,
    payload: ?[]const u8,
) !Response {
    var client: std.http.Client = .{ .io = io, .allocator = alloc };
    defer client.deinit();

    var auth_buf: [1024]u8 = undefined;
    const auth = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token});

    var hdrs: std.ArrayList(std.http.Header) = .empty;
    defer hdrs.deinit(alloc);
    try hdrs.append(alloc, .{ .name = "accept", .value = "application/json" });
    if (token.len > 0) try hdrs.append(alloc, .{ .name = "authorization", .value = auth });
    if (payload != null) try hdrs.append(alloc, .{ .name = "content-type", .value = "application/json" });

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .extra_headers = hdrs.items,
        .response_writer = &aw.writer,
    });

    return .{ .status = @intFromEnum(result.status), .body = try aw.toOwnedSlice() };
}

/// Pull a string field out of a flat JSON object — a tiny, dependency-free reader
/// for the few fields we surface (active_org, user.id). Returns null if absent.
pub fn jsonField(body: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, body, needle) orelse return null;
    var i = at + needle.len;
    // skip `: ` and the opening quote
    while (i < body.len and (body[i] == ':' or body[i] == ' ')) i += 1;
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < body.len and body[i] != '"') i += 1;
    return body[start..i];
}
