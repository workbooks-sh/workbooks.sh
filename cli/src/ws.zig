//! Minimal WebSocket client for the nexus live channel (`GET /ws`, Nexus.Ws). Connects over TLS via
//! std.http.Client.connect, performs the RFC-6455 upgrade handshake, then frames JSON ops. `work agent
//! run` uses it to STREAM a run — the socket stays alive as events flow, so a long run never hits the
//! proxy timeout, and progress prints live. Client→server frames are masked (RFC 6455 §5.3); server
//! frames are not.
const std = @import("std");
const Io = std.Io;
const log = @import("log.zig");
const cloud = @import("cloud.zig");

const HostName = std.Io.net.HostName;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// Entropy from the Io seam (Zig 0.16 moved randomness onto std.Io). The WS mask only needs to vary
// (anti-proxy-cache), not be crypto-grade, and the link is already TLS.
fn randBytes(io: Io, buf: []u8) void {
    io.random(buf);
}

// "https://host[:port]/..." → {host, port} (default 443; the live channel is wss/TLS).
fn hostPort(url: []const u8) struct { host: []const u8, port: u16 } {
    var s = url;
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    if (std.mem.indexOfScalar(u8, s, '/')) |i| s = s[0..i];
    var port: u16 = 443;
    if (std.mem.indexOfScalar(u8, s, ':')) |i| {
        port = std.fmt.parseInt(u16, s[i + 1 ..], 10) catch 443;
        s = s[0..i];
    }
    return .{ .host = s, .port = port };
}

// ── framing ──────────────────────────────────────────────────────────────────
// Write one masked frame (FIN set). `opcode`: 0x1 text, 0x9 ping, 0xA pong.
fn writeFrame(io: Io, w: *Io.Writer, alloc: std.mem.Allocator, opcode: u8, payload: []const u8) !void {
    var hdr: [10]u8 = undefined;
    hdr[0] = 0x80 | opcode;
    const len = payload.len;
    var n: usize = 2;
    if (len < 126) {
        hdr[1] = 0x80 | @as(u8, @intCast(len));
    } else if (len < 65536) {
        hdr[1] = 0x80 | 126;
        hdr[2] = @intCast((len >> 8) & 0xff);
        hdr[3] = @intCast(len & 0xff);
        n = 4;
    } else {
        hdr[1] = 0x80 | 127;
        var i: usize = 0;
        while (i < 8) : (i += 1) hdr[2 + i] = @intCast((len >> @intCast((7 - i) * 8)) & 0xff);
        n = 10;
    }
    var mask: [4]u8 = undefined;
    randBytes(io, &mask);

    try w.writeAll(hdr[0..n]);
    try w.writeAll(&mask);

    const buf = try alloc.alloc(u8, len);
    defer alloc.free(buf);
    for (payload, 0..) |b, i| buf[i] = b ^ mask[i % 4];
    try w.writeAll(buf);
}

const Frame = struct { opcode: u8, payload: []const u8 };

// Read one frame. Server→client frames are unmasked; we tolerate masked too. Caller owns `payload`.
fn readFrame(r: *Io.Reader, alloc: std.mem.Allocator) !Frame {
    const b0 = try r.takeByte();
    const b1 = try r.takeByte();
    const opcode = b0 & 0x0f;
    const masked = (b1 & 0x80) != 0;
    var len: u64 = b1 & 0x7f;
    if (len == 126) {
        const ext = try r.take(2);
        len = (@as(u64, ext[0]) << 8) | ext[1];
    } else if (len == 127) {
        const ext = try r.take(8);
        len = 0;
        for (ext) |b| len = (len << 8) | b;
    }
    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        const m = try r.take(4);
        @memcpy(&mask, m[0..4]);
    }
    const payload = try alloc.alloc(u8, @intCast(len));
    try r.readSliceAll(payload);
    if (masked) for (payload, 0..) |*p, i| {
        p.* ^= mask[i % 4];
    };
    return .{ .opcode = opcode, .payload = payload };
}

// ── agent-run streaming ──────────────────────────────────────────────────────
// Connect to <url>/ws, subscribe to the agent_run source with `params_json` (the {"op":"subscribe",...}
// body), and print the streamed events until `done`/`error`/close. Returns the process exit code.
pub fn streamAgentRun(io: Io, alloc: std.mem.Allocator, url: []const u8, token: []const u8, sub_json: []const u8) !u8 {
    const hp = hostPort(url);
    const host = HostName.init(hp.host) catch {
        log.err("bad nexus host");
        return 1;
    };

    var client: std.http.Client = .{ .io = io, .allocator = alloc };
    defer client.deinit();

    // TLS needs the CA bundle + a "now" for cert validity — `fetch` sets these, but the low-level
    // `connect` does not, so replicate it (otherwise connect panics on client.now.?).
    const now = std.Io.Clock.real.now(io);
    client.ca_bundle.rescan(alloc, io, now) catch {
        log.err("could not load the system CA bundle");
        return 1;
    };
    client.now = now;

    const conn = client.connect(host, hp.port, .tls) catch |e| {
        log.err(try std.fmt.allocPrint(alloc, "ws connect failed ({s})", .{@errorName(e)}));
        return 1;
    };
    // Release the (hijacked-for-WS) connection before client.deinit, marked closing so it's destroyed
    // (not pooled for reuse — it's a WebSocket now, not a clean HTTP conn). Runs before the outer
    // client.deinit (LIFO), so deinit's "no active requests" assert holds.
    defer {
        conn.closing = true;
        client.connection_pool.release(conn, io);
    }

    // Handshake: a bare upgrade GET (the bearer authenticates the socket; the nexus tenant-scopes it).
    var keyb: [16]u8 = undefined;
    randBytes(io, &keyb);
    var keyenc: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&keyenc, &keyb);

    const w = conn.writer();
    try w.print("GET /ws HTTP/1.1\r\nhost: {s}\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-version: 13\r\nsec-websocket-key: {s}\r\n", .{ hp.host, keyenc });
    if (token.len > 0) try w.print("authorization: Bearer {s}\r\n", .{token});
    try w.writeAll("\r\n");
    try conn.flush();

    const r = conn.reader();
    var ok101 = false;
    while (true) {
        const line = r.takeDelimiterInclusive('\n') catch {
            log.err("ws handshake: no response");
            return 1;
        };
        const t = std.mem.trimEnd(u8, line, "\r\n");
        if (t.len == 0) break; // end of headers
        if (std.mem.indexOf(u8, t, " 101 ") != null) ok101 = true;
    }
    if (!ok101) {
        log.err("ws upgrade rejected (is the nexus on a build with /ws? RCP transports.ws)");
        return 1;
    }

    // Subscribe, then stream.
    try writeFrame(io, w, alloc, 0x1, sub_json);
    try conn.flush();

    while (true) {
        const f = readFrame(r, alloc) catch return 0; // closed/EOF → end of stream
        switch (f.opcode) {
            0x0, 0x1 => if (!handleEvent(alloc, f.payload)) return 0,
            0x8 => return 0, // close
            0x9 => {
                try writeFrame(io, w, alloc, 0xA, f.payload); // ping → pong
                try conn.flush();
            },
            else => {},
        }
        alloc.free(f.payload);
    }
}

// Indentation for a nested (sub-)agent event, from its `depth` field (4 spaces per level, capped).
fn indentFor(payload: []const u8) []const u8 {
    const pad = "                    "; // 20 spaces = 5 levels
    const d = cloud.jsonField(payload, "depth") orelse return "";
    const n = std.fmt.parseInt(usize, d, 10) catch 0;
    const w = @min(n * 4, pad.len);
    return pad[0..w];
}

// Print one streamed run event. Returns false to stop (done/error). Event shapes mirror the agent loop:
// token{content} | text{content} | tools{commands} | agent_start{agent,task} | agent_end{agent,ok} |
// final{answer} | error{error} | done{status,turns}. Events carry agent+depth for nesting.
fn handleEvent(alloc: std.mem.Allocator, payload: []const u8) bool {
    const t = cloud.jsonField(payload, "type") orelse return true;

    if (eql(t, "token")) {
        // Streamed LLM delta — print inline as it arrives (this is the live token stream).
        if (cloud.jsonString(alloc, payload, "content")) |c| log.print("{s}", .{c});
    } else if (eql(t, "text")) {
        if (cloud.jsonString(alloc, payload, "content")) |c| {
            log.print("{s}{s}{s}", .{ log.dim_c, c, log.reset });
        }
    } else if (eql(t, "agent_start")) {
        const a = cloud.jsonField(payload, "agent") orelse "agent";
        log.print("\n{s}{s}\u{250C}\u{2500} {s}{s}\n", .{ indentFor(payload), log.path_c, a, log.reset });
    } else if (eql(t, "agent_end")) {
        const a = cloud.jsonField(payload, "agent") orelse "agent";
        const ok = cloud.jsonField(payload, "ok") orelse "true";
        log.print("{s}{s}\u{2514}\u{2500} {s} ({s}){s}\n", .{ indentFor(payload), log.dim_c, a, ok, log.reset });
    } else if (eql(t, "flow_start")) {
        const f = cloud.jsonField(payload, "flow") orelse "flow";
        const n = cloud.jsonField(payload, "steps") orelse "?";
        log.print("\n{s}\u{25C6} flow {s} ({s} steps){s}\n", .{ log.path_c, f, n, log.reset });
    } else if (eql(t, "step_start")) {
        const s = cloud.jsonField(payload, "step") orelse "step";
        const i = cloud.jsonField(payload, "index") orelse "?";
        const of = cloud.jsonField(payload, "of") orelse "?";
        log.print("  {s}[{s}/{s}] {s}{s}\n", .{ log.dim_c, i, of, s, log.reset });
    } else if (eql(t, "flow_end") or eql(t, "step_end")) {
        // lifecycle close — no extra line (kept quiet; the next start/final shows progress)
    } else if (eql(t, "tools")) {
        if (cloud.jsonString(alloc, payload, "commands")) |c| {
            log.print("{s}  {s}\u{21B3} {s}{s}\n", .{ indentFor(payload), log.path_c, c, log.reset });
        } else {
            log.print("{s}  \u{21B3} (running tools)\n", .{indentFor(payload)});
        }
    } else if (eql(t, "final")) {
        if (cloud.jsonString(alloc, payload, "answer")) |a| {
            log.out("\n");
            log.out(a);
            log.out("\n");
        }
    } else if (eql(t, "error")) {
        log.err(cloud.jsonString(alloc, payload, "error") orelse "run error");
        return false;
    } else if (eql(t, "done")) {
        const st = cloud.jsonField(payload, "status") orelse "ok";
        log.ok(std.fmt.allocPrint(alloc, "done \u{b7} {s}", .{st}) catch "done");
        return false;
    }
    return true;
}
