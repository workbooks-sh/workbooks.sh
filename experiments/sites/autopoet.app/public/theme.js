/* autopoet.app — manual light/dark toggle.
   Default is light (paper-first); dark is opt-in and persisted in localStorage.
   The no-FOUC guard (inline in each <head>) sets <html data-theme> BEFORE paint;
   this file (deferred) wires the nav button, syncs <meta theme-color>, and fires
   a `themechange` event that graph.js listens for to re-read its CSS-var palette. */
(function () {
  var root = document.documentElement;
  var PAGE_DARK = "#0e0f11";   // must track --page in [data-theme="dark"]
  var PAGE_LIGHT = "#ffffff";

  var current = function () { return root.getAttribute("data-theme") === "dark" ? "dark" : "light"; };

  var metaThemeColor = function () {
    var m = document.querySelector('meta[name="theme-color"]');
    if (!m) { m = document.createElement("meta"); m.setAttribute("name", "theme-color"); document.head.appendChild(m); }
    return m;
  };

  var SUN = "☀";   // ☀ shown while dark (click → light)
  var MOON = "☾";  // ☾ shown while light (click → dark)

  var syncChrome = function (theme) {
    metaThemeColor().setAttribute("content", theme === "dark" ? PAGE_DARK : PAGE_LIGHT);
    var btns = document.querySelectorAll(".theme-toggle");
    for (var i = 0; i < btns.length; i++) {
      var b = btns[i];
      b.textContent = theme === "dark" ? SUN : MOON;
      b.setAttribute("aria-label", theme === "dark" ? "Switch to light theme" : "Switch to dark theme");
      b.setAttribute("aria-pressed", theme === "dark" ? "true" : "false");
      b.setAttribute("title", theme === "dark" ? "Light mode" : "Dark mode");
    }
  };

  var apply = function (theme) {
    if (theme === "dark") root.setAttribute("data-theme", "dark");
    else root.removeAttribute("data-theme");
    try { localStorage.setItem("theme", theme); } catch (e) {}
    syncChrome(theme);
    window.dispatchEvent(new CustomEvent("themechange", { detail: { theme: theme } }));
  };

  var toggle = function () { apply(current() === "dark" ? "light" : "dark"); };

  // Inject a toggle button into every primary nav.
  var navs = document.querySelectorAll(".site-nav ul");
  for (var i = 0; i < navs.length; i++) {
    var li = document.createElement("li");
    li.className = "nav-toggle";
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "theme-toggle";
    btn.addEventListener("click", toggle);
    li.appendChild(btn);
    navs[i].appendChild(li);
  }

  // Match chrome to whatever the FOUC guard already applied.
  syncChrome(current());
})();
