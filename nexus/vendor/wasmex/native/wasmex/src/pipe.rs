//! A Pipe is a file buffer hold in memory.
//! It can, for example, be used to replace stdin/stdout/stderr of a WASI module.

use rustler::{Encoder, ResourceArc, Term};
use std::any::Any;
use std::io::{self, Cursor, Read, Seek, Write};
use std::sync::{Arc, Mutex, RwLock};
use wasi_common::{file::FileType, Error, WasiFile};
use wasmtime_wasi::async_trait;

use crate::atoms;

/// For piping stdio. Stores all output / input in a byte-vector.
#[derive(Debug, Default)]
pub struct Pipe {
    buffer: Arc<RwLock<Cursor<Vec<u8>>>>,
}

// wb-8w8x: a Pipe is an in-memory Cursor<Vec<u8>> and was UNBOUNDED. A wasm command flushing stdout in a loop
// could grow it without limit — and the wasm runs to COMPLETION (filling the host pipe) before the host reads
// and caps the output, so the per-call output cap doesn't bound PEAK host memory. This hard backstop bounds
// every pipe: writes past MAX_PIPE_BYTES are DROPPED (pretend-consumed so the guest doesn't block/error; its
// stdout is simply truncated at the cap, at WRITE time). Generous vs the exec_broker functional cap (8 MiB),
// so it's a pure DoS floor that never affects legitimate output.
const MAX_PIPE_BYTES: usize = 256 * 1024 * 1024;

impl Pipe {
    pub fn new() -> Self {
        Self::default()
    }
    fn borrow(&self) -> std::sync::RwLockWriteGuard<'_, Cursor<Vec<u8>>> {
        RwLock::write(&self.buffer).unwrap()
    }

    fn size(&self) -> u64 {
        let buffer = &*(self.borrow());
        buffer.get_ref().len() as u64
    }
}

impl Clone for Pipe {
    fn clone(&self) -> Self {
        Self {
            buffer: self.buffer.clone(),
        }
    }
}

impl Read for Pipe {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let buffer = &mut *(self.borrow());
        buffer.read(buf)
    }
}

impl Write for Pipe {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let buffer = &mut *(self.borrow());
        let cur = buffer.get_ref().len();
        if cur >= MAX_PIPE_BYTES {
            // at the cap: silently drop (report full consumption so the guest's write() "succeeds")
            return Ok(buf.len());
        }
        let n = (MAX_PIPE_BYTES - cur).min(buf.len());
        let written = buffer.write(&buf[..n])?;
        // report the whole buffer consumed; bytes beyond the cap are dropped
        Ok(written + (buf.len() - n))
    }

    fn flush(&mut self) -> io::Result<()> {
        let buffer = &mut *(self.borrow());
        buffer.flush()
    }
}

impl Seek for Pipe {
    fn seek(&mut self, pos: io::SeekFrom) -> io::Result<u64> {
        let buffer = &mut *(self.borrow());
        buffer.seek(pos)
    }
}

#[async_trait]
impl WasiFile for Pipe {
    fn as_any(&self) -> &dyn Any {
        self
    }

    async fn get_filetype(&self) -> Result<FileType, Error> {
        Ok(FileType::Pipe)
    }

    async fn write_vectored<'a>(&self, bufs: &[io::IoSlice<'a>]) -> Result<u64, Error> {
        let buffer = &mut *(self.borrow());
        let cur = buffer.get_ref().len();
        let total: usize = bufs.iter().map(|b| b.len()).sum();

        // wb-8w8x backstop (same as Write::write): bound peak pipe memory; drop bytes past MAX_PIPE_BYTES.
        if cur >= MAX_PIPE_BYTES {
            return Ok(total as u64);
        }
        if cur + total <= MAX_PIPE_BYTES {
            return buffer
                .write_vectored(bufs)
                .map(|written| written as u64)
                .map_err(wasi_common::Error::from);
        }
        // partial: write up to the cap from a flattened prefix, drop the remainder
        let room = MAX_PIPE_BYTES - cur;
        let mut flat: Vec<u8> = Vec::with_capacity(room);
        for b in bufs {
            if flat.len() >= room {
                break;
            }
            let take = (room - flat.len()).min(b.len());
            flat.extend_from_slice(&b[..take]);
        }
        buffer.write_all(&flat).map_err(wasi_common::Error::from)?;
        Ok(total as u64)
    }

    async fn read_vectored<'a>(&self, bufs: &mut [io::IoSliceMut<'a>]) -> Result<u64, Error> {
        let buffer = &mut *(self.borrow());
        buffer
            .read_vectored(bufs)
            .map(|read| read as u64)
            .map_err(wasi_common::Error::from)
    }

    fn isatty(&self) -> bool {
        false
    }
}

pub struct PipeResource {
    pub pipe: Mutex<Pipe>,
}

#[rustler::resource_impl()]
impl rustler::Resource for PipeResource {}

#[rustler::nif(name = "pipe_new")]
pub fn new() -> Result<ResourceArc<PipeResource>, rustler::Error> {
    let pipe = Pipe::new();
    let pipe_resource = ResourceArc::new(PipeResource {
        pipe: Mutex::new(pipe),
    });

    Ok(pipe_resource)
}

#[rustler::nif(name = "pipe_size")]
pub fn size(pipe_resource: ResourceArc<PipeResource>) -> u64 {
    let pipe: &Pipe = &pipe_resource.pipe.lock().unwrap();
    pipe.size()
}

#[rustler::nif(name = "pipe_seek")]
pub fn seek(
    pipe_resource: ResourceArc<PipeResource>,
    pos: u64,
) -> rustler::NifResult<rustler::Atom> {
    let pipe: &mut Pipe = &mut pipe_resource.pipe.lock().unwrap();

    Seek::seek(pipe, io::SeekFrom::Start(pos))
        .map_err(|err| rustler::Error::Term(Box::new(err.to_string())))
        .map(|_| atoms::ok())
}

#[rustler::nif(name = "pipe_read_binary", schedule = "DirtyCpu")]
pub fn read_binary(pipe_resource: ResourceArc<PipeResource>) -> String {
    let mut pipe = pipe_resource.pipe.lock().unwrap();
    let mut buffer = String::new();

    (*pipe).read_to_string(&mut buffer).unwrap();
    buffer
}

#[rustler::nif(name = "pipe_write_binary", schedule = "DirtyCpu")]
pub fn write_binary(
    env: rustler::Env,
    pipe_resource: ResourceArc<PipeResource>,
    content: String,
) -> Term {
    let mut pipe = pipe_resource.pipe.lock().unwrap();

    match (*pipe).write(content.as_bytes()) {
        Ok(bytes_written) => (atoms::ok(), bytes_written).encode(env),
        _ => atoms::error().encode(env),
    }
}
