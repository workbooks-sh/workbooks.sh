// Fit the fixed 852×393 canvas into its .device — scaling BOTH axes so it
// fills a real device viewport (or the framed desktop mockup) without overflow.
(function () {
  function fit() {
    document.querySelectorAll('.device').forEach(function (d) {
      var f = d.querySelector('.frame');
      if (!f) return;
      var portrait = d.classList.contains('portrait');
      var cw = portrait ? 393 : 852, ch = portrait ? 852 : 393;
      var s = Math.min(d.clientWidth / cw, d.clientHeight / ch);
      f.style.setProperty('--scale', s.toFixed(4));
    });
  }
  window.addEventListener('resize', fit);
  window.addEventListener('orientationchange', fit);
  window.addEventListener('load', fit);
  if (document.readyState !== 'loading') fit();
  else document.addEventListener('DOMContentLoaded', fit);

  // Portrait-mode rotate hint — injected once, shown/hidden via CSS media query.
  function injectRotateHint() {
    if (document.getElementById('rotate-hint')) return;
    var el = document.createElement('div');
    el.id = 'rotate-hint';
    el.innerHTML = '<div class="rh-icon">&#8635;</div><p>Rotate your phone to play</p>';
    document.body.appendChild(el);
  }
  if (document.readyState !== 'loading') injectRotateHint();
  else document.addEventListener('DOMContentLoaded', injectRotateHint);
})();
