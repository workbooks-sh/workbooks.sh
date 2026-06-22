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
/// NOTE: stops at the first `"`, so a value containing an escaped quote is truncated —
/// use `jsonString` when the value may carry quotes/newlines (e.g. an agent answer).
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

const Found = struct { raw: []const u8, end: usize };

// Locate the JSON string value for `"key"` starting at `from` — `{raw, end}` where `raw` is the
// still-escaped bytes between the quotes (honoring `\"`), `end` is just past the closing quote.
fn findStringValue(body: []const u8, key: []const u8, from: usize) ?Found {
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const at = std.mem.indexOfPos(u8, body, from, needle) orelse return null;
    var i = at + needle.len;
    while (i < body.len and (body[i] == ':' or body[i] == ' ')) i += 1;
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\\') {
            i += 1;
            continue;
        }
        if (body[i] == '"') break;
    }
    return .{ .raw = body[start..i], .end = @min(i + 1, body.len) };
}

fn unescape(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            try buf.append(alloc, switch (raw[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => raw[i],
            });
        } else try buf.append(alloc, raw[i]);
    }
    return buf.toOwnedSlice(alloc);
}

/// Unescaped value of the first JSON string field `key` (handles `\"`, `\n`, …). Caller owns it.
pub fn jsonString(alloc: std.mem.Allocator, body: []const u8, key: []const u8) ?[]const u8 {
    const f = findStringValue(body, key, 0) orelse return null;
    return unescape(alloc, f.raw) catch null;
}

/// Every occurrence of string field `key`, in order — for listing parallel arrays of objects
/// (the Nth `"agent"` aligns with the Nth `"status"`, regardless of intra-object key order).
pub fn jsonStringsAll(alloc: std.mem.Allocator, body: []const u8, key: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var from: usize = 0;
    while (findStringValue(body, key, from)) |f| {
        try list.append(alloc, try unescape(alloc, f.raw));
        from = f.end;
    }
    return list.toOwnedSlice(alloc);
}

/// Escape a string for embedding as a JSON value (quotes, backslashes, control chars). Caller owns it.
pub fn jsonEscape(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(alloc, "\\\""),
        '\\' => try buf.appendSlice(alloc, "\\\\"),
        '\n' => try buf.appendSlice(alloc, "\\n"),
        '\r' => try buf.appendSlice(alloc, "\\r"),
        '\t' => try buf.appendSlice(alloc, "\\t"),
        else => try buf.append(alloc, c),
    };
    return buf.toOwnedSlice(alloc);
}
