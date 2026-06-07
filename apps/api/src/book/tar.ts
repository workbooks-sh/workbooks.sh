// Minimal USTAR-format tar builder for Cloudflare Workers.
//
// Workers cannot use Node's `tar` or `tar-stream` modules. This implements the
// POSIX 1003.1-1988 (USTAR) tar format — enough for bundling brand-book files
// in a portable .tar.gz without any npm dependency.
//
// USTAR header layout (512 bytes):
//   0-99   name (file path, NUL-padded)
//   100-7  file mode (octal ASCII)
//   108-7  uid (octal ASCII)
//   116-7  gid (octal ASCII)
//   124-11 file size (octal ASCII)
//   136-11 last-modification time (octal ASCII)
//   148-7  header checksum (octal ASCII, space-padded to 6+NUL+space)
//   156    type flag ('0' = regular file)
//   157-99 link name (empty for regular files)
//   257-5  "ustar" magic
//   263-2  version "00"
//   + user/group name, device major/minor (all zeroed)
//
// Content follows the header, padded to the next 512-byte boundary.
// The archive is terminated by two consecutive all-zero 512-byte blocks.

export interface TarFile {
  path: string;
  bytes: Uint8Array;
}

const BLOCK = 512;

function writeStr(buf: Uint8Array, offset: number, maxLen: number, value: string): void {
  const enc = new TextEncoder();
  const encoded = enc.encode(value);
  const len = Math.min(encoded.length, maxLen);
  buf.set(encoded.subarray(0, len), offset);
}

function writeOctal(buf: Uint8Array, offset: number, width: number, value: number): void {
  const s = value.toString(8).padStart(width - 1, "0");
  writeStr(buf, offset, width, `${s}\0`);
}

function computeChecksum(header: Uint8Array): number {
  // Treat checksum field (bytes 148–155) as spaces for the computation.
  let sum = 0;
  for (let i = 0; i < BLOCK; i++) {
    sum += i >= 148 && i < 156 ? 0x20 : (header[i] ?? 0);
  }
  return sum;
}

/**
 * Build a USTAR tar archive from an array of files.
 *
 * Returns raw tar bytes (no gzip). Callers must pipe through
 * `CompressionStream('gzip')` to produce a .tar.gz.
 */
export function tar(files: TarFile[]): Uint8Array {
  const blocks: Uint8Array[] = [];

  for (const file of files) {
    const header = new Uint8Array(BLOCK); // zero-initialised

    // name
    writeStr(header, 0, 100, file.path);
    // mode: 0644 = 0o644
    writeStr(header, 100, 8, "0000644\0");
    // uid, gid: 0
    writeStr(header, 108, 8, "0000000\0");
    writeStr(header, 116, 8, "0000000\0");
    // file size (octal)
    writeOctal(header, 124, 12, file.bytes.length);
    // mtime: seconds since epoch
    writeOctal(header, 136, 12, Math.floor(Date.now() / 1000));
    // type: '0' = regular file
    header[156] = 0x30;
    // ustar magic + version
    writeStr(header, 257, 6, "ustar");
    writeStr(header, 263, 2, "00");

    // checksum — placed in bytes 148–155 as 6 octal digits + NUL + space
    const checksum = computeChecksum(header);
    const checksumStr = checksum.toString(8).padStart(6, "0");
    writeStr(header, 148, 8, `${checksumStr}\0 `);

    blocks.push(header);

    // File content, padded to 512-byte boundary
    const padded = Math.ceil(file.bytes.length / BLOCK) * BLOCK;
    const contentBlock = new Uint8Array(padded);
    contentBlock.set(file.bytes);
    blocks.push(contentBlock);
  }

  // Two empty 512-byte blocks as end-of-archive marker
  blocks.push(new Uint8Array(BLOCK));
  blocks.push(new Uint8Array(BLOCK));

  // Concatenate all blocks
  const totalLen = blocks.reduce((acc, b) => acc + b.length, 0);
  const result = new Uint8Array(totalLen);
  let offset = 0;
  for (const block of blocks) {
    result.set(block, offset);
    offset += block.length;
  }
  return result;
}

/**
 * Wrap a tar buffer in gzip compression.
 *
 * Returns a Response whose body is the .tar.gz stream. The caller can
 * either consume it as a stream (arrayBuffer()) or pipe it directly as
 * a Response body.
 */
export async function tarGz(files: TarFile[]): Promise<Uint8Array> {
  const tarBytes = tar(files);
  const stream = new Response(
    new Blob([tarBytes]).stream().pipeThrough(new CompressionStream("gzip")),
  );
  return new Uint8Array(await stream.arrayBuffer());
}
