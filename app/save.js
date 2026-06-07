// Persistent save — uses @capacitor/filesystem on device, localStorage in browser.
// WKWebView localStorage/IndexedDB are OS-evictable; Filesystem (Documents dir) is not.

const KEY = 'adbuy.save'
const PATH = 'adbuy-save.json'

function isNative() {
  return !!(window.Capacitor?.isNativePlatform?.())
}

export async function readSave() {
  if (isNative()) {
    try {
      const { Filesystem, Directory } = await import('@capacitor/filesystem')
      const { data } = await Filesystem.readFile({ path: PATH, directory: Directory.Documents, encoding: 'utf8' })
      return JSON.parse(data)
    } catch (_) { return null }
  }
  try { return JSON.parse(localStorage.getItem(KEY) || 'null') } catch (_) { return null }
}

export async function writeSave(data) {
  if (isNative()) {
    const { Filesystem, Directory } = await import('@capacitor/filesystem')
    await Filesystem.writeFile({ path: PATH, directory: Directory.Documents, data: JSON.stringify(data), encoding: 'utf8' })
    return
  }
  localStorage.setItem(KEY, JSON.stringify(data))
}

export async function clearSave() {
  if (isNative()) {
    try {
      const { Filesystem, Directory } = await import('@capacitor/filesystem')
      await Filesystem.deleteFile({ path: PATH, directory: Directory.Documents })
    } catch (_) {}
    return
  }
  localStorage.removeItem(KEY)
}
