/* Node 'path' shim (wb-spy.T2.1) — POSIX path ops, pure JS. */
"use strict";
function normalizeArray(parts, allowAbove) {
  var res = [];
  for (var i = 0; i < parts.length; i++) {
    var p = parts[i];
    if (!p || p === ".") continue;
    if (p === "..") { if (res.length && res[res.length - 1] !== "..") res.pop(); else if (allowAbove) res.push(".."); }
    else res.push(p);
  }
  return res;
}
var path = {
  sep: "/",
  delimiter: ":",
  normalize: function (p) {
    var abs = p.charAt(0) === "/", trail = p.length > 1 && p.charAt(p.length - 1) === "/";
    var r = normalizeArray(p.split("/"), !abs).join("/");
    if (!r && !abs) r = ".";
    if (r && trail) r += "/";
    return (abs ? "/" : "") + r;
  },
  join: function () {
    var parts = Array.prototype.filter.call(arguments, function (a) { return a && typeof a === "string"; });
    return parts.length ? path.normalize(parts.join("/")) : ".";
  },
  resolve: function () {
    var resolved = "", abs = false;
    for (var i = arguments.length - 1; i >= 0 && !abs; i--) {
      var p = arguments[i];
      if (!p) continue;
      resolved = p + "/" + resolved;
      abs = p.charAt(0) === "/";
    }
    var r = normalizeArray(resolved.split("/"), !abs).join("/");
    return abs ? "/" + r : (r || ".");
  },
  isAbsolute: function (p) { return p.charAt(0) === "/"; },
  dirname: function (p) {
    if (!p) return ".";
    var s = p.replace(/\/+$/, ""); var i = s.lastIndexOf("/");
    if (i < 0) return "."; if (i === 0) return "/";
    return s.slice(0, i);
  },
  basename: function (p, ext) {
    var b = p.replace(/\/+$/, "").replace(/^.*\//, "");
    if (ext && b.slice(-ext.length) === ext) b = b.slice(0, -ext.length);
    return b;
  },
  extname: function (p) {
    var b = path.basename(p); var i = b.lastIndexOf(".");
    return i > 0 ? b.slice(i) : "";
  },
  relative: function (from, to) {
    var f = path.resolve(from).split("/"), t = path.resolve(to).split("/");
    var i = 0; while (i < f.length && i < t.length && f[i] === t[i]) i++;
    var up = []; for (var j = i; j < f.length; j++) if (f[j]) up.push("..");
    return up.concat(t.slice(i)).join("/");
  },
  parse: function (p) {
    var root = p.charAt(0) === "/" ? "/" : "";
    var base = path.basename(p), ext = path.extname(p);
    return { root: root, dir: path.dirname(p), base: base, ext: ext, name: ext ? base.slice(0, -ext.length) : base };
  }
};
path.posix = path;
module.exports = path;
