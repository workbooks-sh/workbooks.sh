// tabs.js — a reusable persistent "open tabs" strip shared by surfaces (Studio
// sessions, Apps, etc.), backed by localStorage and rendering into
// `#openTabs-<surface>`. Click a tab to re-open it, ✕ to close (close ≠ delete).
// Wires into WB's global click registry (window.WB._clicks). Augments window.WB only.
(function () {
  var WB = (window.WB = window.WB || {});

  var CSS = [
    ".tabshd { font:700 10px var(--mono, monospace); letter-spacing:.12em; text-transform:uppercase; color:var(--dim); padding:10px 10px 5px; }",
    ".tabrow { position:relative; display:flex; align-items:center; gap:8px; padding:6px 8px; margin:0 4px; border-radius:9px; cursor:pointer; color:var(--ink); }",
    ".tabrow:hover { background:color-mix(in srgb, var(--ink) 7%, transparent); }",
    ".tabname { flex:1; min-width:0; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; font:500 13px var(--read, sans-serif); }",
    ".tabdot { flex:none; width:10px; height:10px; border-radius:50%; }",
    ".tabclose { flex:none; width:20px; height:20px; border:none; background:none; color:var(--dim); cursor:pointer; border-radius:6px; font:600 15px var(--read, sans-serif); line-height:1; opacity:0; display:grid; place-items:center; }",
    ".tabrow:hover .tabclose { opacity:1; } .tabclose:hover { color:var(--ink); background:color-mix(in srgb, var(--ink) 10%, transparent); }"
  ].join("\n");

  var injected = false;
  function ensureCss() {
    if (injected) return;
    injected = true;
    if (WB.styles) {
      WB.styles(CSS);
    } else {
      var s = document.createElement("style");
      s.textContent = CSS;
      document.head.appendChild(s);
    }
  }

  function esc(s) {
    return (WB.esc || function (x) { return String(x); })(s);
  }

  var cache = {};   // surface -> array of items
  var openers = {}; // surface -> fn(item)

  function key(surface) { return "wb-tabs-" + surface; }

  function persist(surface) {
    try {
      window.localStorage.setItem(key(surface), JSON.stringify(cache[surface] || []));
    } catch (e) { /* private mode */ }
  }

  var tabs = {
    list: function (surface) {
      if (cache[surface]) return cache[surface];
      var items = [];
      try {
        var raw = window.localStorage.getItem(key(surface));
        if (raw) {
          var parsed = JSON.parse(raw);
          if (Array.isArray(parsed)) items = parsed;
        }
      } catch (e) { /* private mode / bad json */ }
      cache[surface] = items;
      return items;
    },

    open: function (surface, item) {
      if (!item || !item.id) return;
      var items = tabs.list(surface);
      items = items.filter(function (x) { return x.id !== item.id; });
      items.unshift(item);
      if (items.length > 12) items = items.slice(0, 12);
      cache[surface] = items;
      persist(surface);
      tabs.paint(surface);
    },

    close: function (surface, id) {
      var items = tabs.list(surface).filter(function (x) { return x.id !== id; });
      cache[surface] = items;
      persist(surface);
      tabs.paint(surface);
    },

    onOpen: function (surface, fn) {
      openers[surface] = fn;
    },

    paint: function (surface) {
      ensureCss();
      var host = document.getElementById("openTabs-" + surface);
      if (!host) return;
      var items = tabs.list(surface);
      if (!items.length) { host.innerHTML = ""; return; }

      var html = '<div class="tabshd">Open</div>';
      var i, item, media;
      for (i = 0; i < items.length; i++) {
        item = items[i];
        if (item.seed && WB.avatar) {
          media = WB.avatar(item.seed, item.color, 22);
        } else {
          media = '<span class="tabdot" style="background:var(' + (item.color || "--mint") + ')"></span>';
        }
        html +=
          '<div class="tabrow" data-tab="' + esc(item.id) + '" data-tabsurface="' + esc(surface) + '" title="' + esc(item.label || "") + '">' +
          media +
          '<span class="tabname">' + esc(item.label || "") + "</span>" +
          '<button class="tabclose" data-tabclose="' + esc(item.id) + '" data-tabsurface="' + esc(surface) + '" title="Close" aria-label="Close">×</button>' +
          "</div>";
      }
      host.innerHTML = html;
    }
  };

  WB.tabs = tabs;

  // Global click registry — close entry first so ✕ wins over the row.
  WB._clicks = WB._clicks || [];
  WB._clicks.push({
    sel: "[data-tabclose]",
    fn: function (el, e) {
      e.preventDefault();
      WB.tabs.close(el.getAttribute("data-tabsurface"), el.getAttribute("data-tabclose"));
      return true;
    }
  });
  WB._clicks.push({
    sel: "[data-tab]",
    fn: function (el, e) {
      e.preventDefault();
      var surface = el.getAttribute("data-tabsurface");
      var id = el.getAttribute("data-tab");
      var item = (WB.tabs.list(surface) || []).filter(function (x) { return x.id === id; })[0];
      if (!item) return true;
      var opener = openers[surface];
      if (opener) opener(item);
      else if (item.route) WB.nav(item.route);
      return true;
    }
  });
})();
