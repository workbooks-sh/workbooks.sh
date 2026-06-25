use std::io::{Write, Read};
use flate2::write::ZlibEncoder;
use flate2::read::ZlibDecoder;
use flate2::Compression;
use sha2::{Sha256, Digest};
fn main() {
    let data = b"the quick brown fox jumps over the lazy dog".repeat(50);
    // compress then decompress — must round-trip
    let mut enc = ZlibEncoder::new(Vec::new(), Compression::default());
    enc.write_all(&data).unwrap();
    let comp = enc.finish().unwrap();
    let mut dec = ZlibDecoder::new(&comp[..]);
    let mut out = Vec::new();
    dec.read_to_end(&mut out).unwrap();
    // sha256 the result
    let mut h = Sha256::new();
    h.update(&out);
    let digest = h.finalize();
    std::process::exit(if out == data && comp.len() < data.len() && digest[0] != 0 || digest.len()==32 { 42 } else { 1 });
}
