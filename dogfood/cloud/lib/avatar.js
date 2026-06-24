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
      '.wbav-img { width:100%; height:100%; object-fit:cover; display:block; }';
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

  if (document.head) ensureCss();
})();
