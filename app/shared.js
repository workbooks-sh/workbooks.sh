import './styles/shared.css'
import '@fontsource-variable/nunito'
import '@fontsource-variable/baloo-2'
import '@phosphor-icons/web/fill'
import '@phosphor-icons/web/bold'

// Apply reduce-motion body class early (before first paint) from stored pref or OS setting.
if (localStorage.getItem('adbuy.reduce-motion') === 'true'
    || window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
  document.body.classList.add('reduce-motion');
}
