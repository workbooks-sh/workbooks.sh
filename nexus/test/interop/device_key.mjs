// Headless mirror of the browser device-key path in dogfood/cloud/views/profile.js, exercising the
// SAME WebCrypto Ed25519 + base58 + did:key construction a browser (or StarlingMonkey, the runtime's
// in-wasm JS engine) runs. Emits three lines — uid, did, sig(hex) — for the Elixir side to verify, so
// the cross-stack proof-of-possession is covered without a real browser. Run by authorship_interop_test.exs.
const B58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
function base58(bytes) {
  let z = 0; while (z < bytes.length && bytes[z] === 0) z++;
  const d = [0];
  for (let i = z; i < bytes.length; i++) { let c = bytes[i]; for (let j = 0; j < d.length; j++) { c += d[j] << 8; d[j] = c % 58; c = (c / 58) | 0; } while (c) { d.push(c % 58); c = (c / 58) | 0; } }
  let o = '1'.repeat(z); for (let k = d.length - 1; k >= 0; k--) o += B58[d[k]]; return o;
}
const hex = (b) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, '0')).join('');

const uid = (process.argv[2] || 'shane@x.com').toLowerCase();
const kp = await crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']);
const rawPub = new Uint8Array(await crypto.subtle.exportKey('raw', kp.publicKey));
// re-import the private as NON-extractable (exactly as the browser does), then sign with it
const pkcs8 = await crypto.subtle.exportKey('pkcs8', kp.privateKey);
const priv = await crypto.subtle.importKey('pkcs8', pkcs8, { name: 'Ed25519' }, false, ['sign']);
const did = 'did:key:z' + base58(Uint8Array.from([0xed, 0x01, ...rawPub]));
const msg = 'wb-author-key\nuid=' + uid + '\ndid=' + did;
const sig = await crypto.subtle.sign({ name: 'Ed25519' }, priv, new TextEncoder().encode(msg));
process.stdout.write(uid + '\n' + did + '\n' + hex(sig) + '\n');
