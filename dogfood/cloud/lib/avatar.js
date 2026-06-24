// avatar.js — DiceBear lorelei-neutral avatar helper for window.WB.
// Renders a color-coded squircle tile (faint tint + subtle inner ring) with the
// avatar image inside; used by the agent/workflow cards and tabs.
(function () {
  var WB = (window.WB = window.WB || {});

  WB.AGCOLORS = ['--violet', '--sky', '--mint', '--peach', '--cream', '--sage', '--blue'];

  WB.agentColor = function (name) {
    name = String(name == null ? '' : name);
    var h = 0;
    for (var i = 0; i < name.length; i++) {
      h = (h * 31 + name.charCodeAt(i)) | 0;
    }
    var idx = Math.abs(h) % WB.AGCOLORS.length;
    return WB.AGCOLORS[idx];
  };

  var injected = false;
  function ensureCss() {
    if (injected) return;
    injected = true;
    var css =
      '.wbav { position:relative; flex:none; display:grid; place-items:center; border-radius:30%; overflow:hidden;' +
      ' background: color-mix(in srgb, var(--ac) 22%, var(--card));' +
      ' box-shadow: inset 0 0 0 1.5px color-mix(in srgb, var(--ac) 55%, transparent); }' +
      '.wbav-img { width:100%; height:100%; object-fit:cover; display:block; }' +
      // DiceBear lorelei-neutral is dark line-art on transparent — it vanishes on a dark tile. In dark mode
      // give FACE tiles a solid fill of their color (no faint tint + ring) so the dark face reads against
      // the bright pastel. Icon tiles (.wbav-icon) keep the tinted look (their glyph is the contrast color).
      '[data-theme="dark"] .wbav:not(.wbav-icon) { background: var(--ac); box-shadow: none; }' +
      // Icon variant — a glyph drawn in the CONTRAST color (a stronger blend of the tile color toward ink).
      '.wbav-icon { color: color-mix(in srgb, var(--ac) 62%, var(--ink)); }' +
      '.wbav-icon svg { width:56%; height:56%; }';
    if (typeof WB.styles === 'function') {
      WB.styles(css);
    } else {
      var s = document.createElement('style');
      s.textContent = css;
      document.head.appendChild(s);
    }
  }

  WB.avatar = function (seed, colorVar, size) {
    ensureCss();
    seed = String(seed == null ? '' : seed);
    var cv = colorVar || WB.agentColor(seed);
    var px = size || 36;
    var url =
      'https://api.dicebear.com/9.x/lorelei-neutral/svg?seed=' +
      encodeURIComponent(seed) +
      '&backgroundColor=transparent';
    return (
      '<span class="wbav" style="--ac:var(' + cv + ');width:' + px + 'px;height:' + px + 'px">' +
      '<img class="wbav-img" loading="lazy" alt="" src="' + url + '">' +
      '</span>'
    );
  };

  // Same color-coded squircle, but with an inline SVG glyph drawn in the contrast color (currentColor)
  // instead of a DiceBear face — for things an icon describes better than a face (e.g. workflows).
  WB.iconAvatar = function (iconHtml, colorVar, size) {
    ensureCss();
    var cv = colorVar || '--mint';
    var px = size || 36;
    return '<span class="wbav wbav-icon" style="--ac:var(' + cv + ');width:' + px + 'px;height:' + px + 'px">' + (iconHtml || '') + '</span>';
  };

  if (document.head) ensureCss();
})();
