defmodule Workbooks.Reclaim.LibrsvgTest do
  @moduledoc """
  RECLAIM DURABILITY TEST — librsvg (rsvg-convert), SVG→PNG core capability.

  resolved.json claim: librsvg-the-binary can't be built (Rust crates.io + cairo/pango/glib native
  stack), but its CORE capability — render an SVG to a raster PNG — is LIVE in-sandbox via nanosvg
  compiled through the clang.wasm C lane.

  This test is SELF-CONTAINED: it stages nanosvg.h + nanosvgrast.h (committed fixtures) and an inline
  main.c that #defines the IMPLEMENTATION macros, parses an SVG string, rasterizes into an RGBA buffer,
  and encodes a real PNG (stored-zlib IDAT). It compiles that through Workbooks.Compilers.compile_c
  (target wasm32-wasip1, -lm), runs the resulting wasm under wasmtime with a writable /out preopen, and
  then asserts back in Elixir that:
    * the emitted bytes are a valid PNG (8-byte signature, IHDR with the expected WxH, an IDAT chunk),
    * the decoded raster actually contains the SVG's fill color (a RED region), i.e. the renderer
      really turned vector paths into colored pixels — not a stubbed/empty image.

  HONESTY NOTE: this proves the SHAPE/PATH renderer substitute, NOT the librsvg binary and NOT
  cairo/pango font shaping. That matches the resolved.json "extent" exactly.
  """
  use ExUnit.Case, async: false

  @moduletag :build
  @moduletag timeout: 600_000

  @fixtures Path.join([__DIR__, "fixtures", "librsvg"])

  # A 64x64 SVG: white background rect + a big red circle in the middle. Pure shapes/paths — exactly
  # the class nanosvg renders well.
  @svg ~S"""
  <svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
    <rect x="0" y="0" width="64" height="64" fill="#ffffff"/>
    <circle cx="32" cy="32" r="24" fill="#ff0000"/>
  </svg>
  """

  # main.c — parse the SVG (passed on argv as a string), rasterize to a WxH RGBA buffer, encode a PNG
  # (filter-type-0 scanlines, single stored/uncompressed zlib block, CRC32 + Adler32 computed inline),
  # write it to /out/out.png. No external libs beyond -lm.
  @main_c ~S"""
  #define NANOSVG_IMPLEMENTATION
  #define NANOSVGRAST_IMPLEMENTATION
  #include "nanosvg.h"
  #include "nanosvgrast.h"
  #include <stdio.h>
  #include <stdlib.h>
  #include <string.h>
  #include <stdint.h>

  static uint32_t crc_table[256];
  static void crc_init(void){
    for (uint32_t n=0;n<256;n++){ uint32_t c=n; for(int k=0;k<8;k++) c = (c&1)?(0xedb88320u^(c>>1)):(c>>1); crc_table[n]=c; }
  }
  static uint32_t crc32_buf(uint32_t crc, const unsigned char*buf, size_t len){
    crc = crc ^ 0xffffffffu;
    for(size_t i=0;i<len;i++) crc = crc_table[(crc^buf[i])&0xff] ^ (crc>>8);
    return crc ^ 0xffffffffu;
  }
  static void put32(FILE*f, uint32_t v){ unsigned char b[4]={v>>24,v>>16,v>>8,v}; fwrite(b,1,4,f); }

  int main(int argc, char**argv){
    if(argc < 2){ fprintf(stderr,"usage: rast SVG\n"); return 2; }
    crc_init();
    // nsvgParse mutates the buffer -> dup it
    char*svg = strdup(argv[1]);
    NSVGimage* img = nsvgParse(svg, "px", 96.0f);
    if(!img){ fprintf(stderr,"parse failed\n"); return 1; }
    int W = (int)(img->width + 0.5f), H = (int)(img->height + 0.5f);
    if(W<=0||H<=0){ W=64; H=64; }
    NSVGrasterizer* rast = nsvgCreateRasterizer();
    if(!rast){ fprintf(stderr,"rast create failed\n"); return 1; }
    unsigned char* rgba = (unsigned char*)malloc((size_t)W*H*4);
    memset(rgba,0,(size_t)W*H*4);
    nsvgRasterize(rast, img, 0,0,1.0f, rgba, W, H, W*4);

    // ---- encode PNG ----
    FILE*f = fopen("/out/out.png","wb");
    if(!f){ fprintf(stderr,"open out failed\n"); return 1; }
    const unsigned char sig[8]={137,80,78,71,13,10,26,10}; fwrite(sig,1,8,f);

    // IHDR
    {
      unsigned char d[13];
      d[0]=W>>24; d[1]=W>>16; d[2]=W>>8; d[3]=W;
      d[4]=H>>24; d[5]=H>>16; d[6]=H>>8; d[7]=H;
      d[8]=8;  // bit depth
      d[9]=6;  // color type RGBA
      d[10]=0; d[11]=0; d[12]=0;
      unsigned char t[4]={'I','H','D','R'};
      unsigned char tmp[4+13]; memcpy(tmp,t,4); memcpy(tmp+4,d,13);
      put32(f,13); fwrite(t,1,4,f); fwrite(d,1,13,f);
      uint32_t c=crc32_buf(0,tmp,4+13); put32(f,c);
    }

    // raw scanlines: filter byte 0 + RGBA row
    size_t rawlen = (size_t)H*(1 + W*4);
    unsigned char* raw = (unsigned char*)malloc(rawlen);
    size_t p=0;
    for(int y=0;y<H;y++){ raw[p++]=0; memcpy(raw+p, rgba+(size_t)y*W*4, W*4); p+=W*4; }

    // zlib stream: header 0x78 0x01, then stored blocks, then adler32
    // adler32 over raw
    uint32_t a=1,b=0;
    for(size_t i=0;i<rawlen;i++){ a=(a+raw[i])%65521; b=(b+a)%65521; }
    uint32_t adler=(b<<16)|a;

    // build idat: 2-byte header + stored blocks (max 65535 each) + 4-byte adler
    size_t nblocks = (rawlen + 65534)/65535; if(nblocks==0) nblocks=1;
    size_t idatlen = 2 + nblocks*5 + rawlen + 4;
    unsigned char* idat = (unsigned char*)malloc(idatlen);
    size_t q=0; idat[q++]=0x78; idat[q++]=0x01;
    size_t off=0;
    for(size_t bi=0; bi<nblocks; bi++){
      size_t remain = rawlen-off;
      size_t blk = remain>65535?65535:remain;
      int final = (bi==nblocks-1)?1:0;
      idat[q++]=final; // BFINAL in bit0, BTYPE 00
      idat[q++]=blk & 0xff; idat[q++]=(blk>>8)&0xff;
      uint16_t nlen=~((uint16_t)blk); idat[q++]=nlen&0xff; idat[q++]=(nlen>>8)&0xff;
      memcpy(idat+q, raw+off, blk); q+=blk; off+=blk;
    }
    idat[q++]=adler>>24; idat[q++]=adler>>16; idat[q++]=adler>>8; idat[q++]=adler;

    {
      unsigned char t[4]={'I','D','A','T'};
      unsigned char* tmp=(unsigned char*)malloc(4+idatlen);
      memcpy(tmp,t,4); memcpy(tmp+4,idat,idatlen);
      put32(f,(uint32_t)idatlen); fwrite(t,1,4,f); fwrite(idat,1,idatlen,f);
      uint32_t c=crc32_buf(0,tmp,4+idatlen); put32(f,c);
      free(tmp);
    }

    // IEND
    { unsigned char t[4]={'I','E','N','D'}; put32(f,0); fwrite(t,1,4,f); uint32_t c=crc32_buf(0,t,4); put32(f,c); }

    fclose(f);
    fprintf(stderr,"WROTE %dx%d\n", W, H);
    nsvgDeleteRasterizer(rast); nsvgDelete(img); free(rgba); free(raw); free(idat); free(svg);
    return 0;
  }
  """

  setup_all do
    # require the clang C lane to be built (compilers-dist/clang or compilers/clang)
    case Workbooks.Compilers.compile_c(stage_main(), c_opts()) do
      {:error, {:not_built, _}} = e ->
        {:ok, skip: e}

      _ ->
        {:ok, skip: nil}
    end
  end

  defp tmp(name), do: Path.join(System.tmp_dir!(), "reclaim-rsvg-#{:erlang.unique_integer([:positive])}-#{name}")

  defp stage_main do
    p = tmp("main.c")
    File.write!(p, @main_c)
    p
  end

  defp c_opts do
    [
      target: "wasm32-wasip1",
      argv: ["-std=c11", "-Wno-everything"],
      aux_files: [
        {Path.join(@fixtures, "nanosvg.h"), "nanosvg.h"},
        {Path.join(@fixtures, "nanosvgrast.h"), "nanosvgrast.h"}
      ],
      link_libs: ["-lm"]
    ]
  end

  test "nanosvg C-lane renders an SVG to a real raster PNG containing the fill color (rsvg-convert core)" do
    case Workbooks.Compilers.compile_c(stage_main(), c_opts()) do
      {:error, {:not_built, sysroot}} ->
        flunk("clang C lane not built (sysroot #{sysroot}); cannot prove librsvg reclaim")

      {:ok, wasm, _logs} ->
        outdir = tmp("out")
        File.mkdir_p!(outdir)

        {out, status} =
          Workbooks.PackageManager.run(wasm, "", [String.trim(@svg)], ["#{outdir}::/out"], with_status: true)

        assert status == 0, "guest exited #{status}:\n#{out}"

        png = Path.join(outdir, "out.png")
        assert File.exists?(png), "no PNG emitted; guest output:\n#{out}"
        bytes = File.read!(png)

        # 1) PNG signature
        assert binary_part(bytes, 0, 8) == <<137, 80, 78, 71, 13, 10, 26, 10>>, "not a PNG"

        # 2) IHDR — width/height/colortype
        <<_sig::binary-size(8), _len::32, "IHDR", w::32, h::32, bd, ct, _rest::binary>> = bytes
        assert {w, h} == {64, 64}, "unexpected dims #{w}x#{h}"
        assert bd == 8 and ct == 6, "expected 8-bit RGBA"

        # 3) an IDAT chunk is present
        assert bytes =~ "IDAT", "no IDAT chunk"

        # 4) PROVE it actually rendered the red circle: decode the PNG with a tiny pure-Elixir
        #    inflate of the stored zlib stream and look for a RED pixel near the center.
        assert red_pixel_present?(bytes, w, h),
               "decoded raster has no red pixel — renderer produced an empty/blank image"
    end
  end

  # Decode the stored-zlib PNG we wrote (filter 0, RGBA, single colortype) enough to find a red center pixel.
  defp red_pixel_present?(bytes, w, h) do
    raw = inflate_stored_idat(bytes)
    stride = 1 + w * 4
    # sample center pixel
    cy = div(h, 2)
    cx = div(w, 2)
    if byte_size(raw) >= cy * stride + 1 + (cx + 1) * 4 do
      row_off = cy * stride + 1
      px_off = row_off + cx * 4
      <<r, g, b, _a>> = binary_part(raw, px_off, 4)
      r > 180 and g < 80 and b < 80
    else
      false
    end
  end

  # Concatenate IDAT chunk payloads, strip the 2-byte zlib header + trailing 4-byte adler, then walk the
  # DEFLATE stored blocks (BTYPE 00) we emitted and concatenate their literal bytes.
  defp inflate_stored_idat(bytes) do
    idat = collect_idat(bytes, 8, <<>>)
    # strip zlib header (2) and adler (4)
    body = binary_part(idat, 2, byte_size(idat) - 6)
    walk_blocks(body, <<>>)
  end

  defp collect_idat(bytes, off, acc) when off + 8 <= byte_size(bytes) do
    <<len::32, type::binary-size(4)>> = binary_part(bytes, off, 8)
    data = binary_part(bytes, off + 8, len)
    acc2 = if type == "IDAT", do: acc <> data, else: acc
    if type == "IEND", do: acc2, else: collect_idat(bytes, off + 12 + len, acc2)
  end

  defp collect_idat(_bytes, _off, acc), do: acc

  defp walk_blocks(<<_bfinal_btype, blk::little-16, _nlen::little-16, rest::binary>>, acc) do
    data = binary_part(rest, 0, blk)
    remaining = binary_part(rest, blk, byte_size(rest) - blk)
    acc2 = acc <> data
    if byte_size(remaining) < 5, do: acc2, else: walk_blocks(remaining, acc2)
  end

  defp walk_blocks(_, acc), do: acc
end
