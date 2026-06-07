// Tiny WASI CLI under Javy: reverse each stdin line, optional argv[0] separator.
const buf = new Uint8Array(65536);
let total = 0, n;
while ((n = Javy.IO.readSync(0, buf.subarray(total))) > 0) total += n;
const text = new TextDecoder().decode(buf.subarray(0, total)).replace(/\n$/, "");
const out = text.split("\n").map((l) => l.split("").reverse().join("")).join("\n") + "\n";
Javy.IO.writeSync(1, new TextEncoder().encode(out));
