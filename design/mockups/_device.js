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
})();
