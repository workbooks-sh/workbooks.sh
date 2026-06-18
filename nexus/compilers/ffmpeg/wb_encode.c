/* wb_encode: minimal in-sandbox PNG-sequence -> mp4 transcoder built on libav*.
 * Replaces the host ffmpeg CLI for the wavelet encode path. Single-threaded, wasm32-wasi.
 *
 * usage: wb_encode <in_pattern> <out.mp4> [fps] [audio.mp3] [vcodec]
 *   video only:  wb_encode /in/frame_%05d.png /out/out.mp4 30
 *   with audio:  wb_encode /in/frame_%05d.png /out/out.mp4 30 /in/audio.mp3
 *   mpeg4 fallback: wb_encode /in/frame_%05d.png /out/out.mp4 30 "" mpeg4   (or WB_VCODEC=mpeg4)
 *
 * VIDEO (default): png decoder | image2 demuxer | scale+format(yuv420p) | H.264 (libx264) | mp4 muxer
 * AUDIO (optional): mp3/aac/wav decoder | aresample+aformat filter | native AAC encoder
 *                   muxed as a second stream into the SAME mp4. NO external audio libs.
 *
 * Everything runs IN-GUEST under wasmtime — no host ffmpeg broker, no native exec.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <libavutil/imgutils.h>
#include <libavutil/channel_layout.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersrc.h>
#include <libavfilter/buffersink.h>

static void die(const char*m,int e){ char b[256]; av_strerror(e,b,sizeof b); fprintf(stderr,"ERR %s: %s\n",m,b); exit(1); }

/* ---------------- audio sub-pipeline state ---------------- */
typedef struct {
  AVFormatContext *ifmt;     /* audio input demuxer            */
  int aidx;                  /* input audio stream index       */
  AVCodecContext  *dec;      /* audio decoder                  */
  AVFilterGraph   *graph;    /* abuffer -> aformat -> abuffersink */
  AVFilterContext *src, *sink;
  AVCodecContext  *enc;      /* AAC encoder                    */
  AVStream        *ost;      /* output audio stream            */
  int             enc_idx;   /* output audio stream index      */
  int64_t         next_pts;  /* running sample pts             */
} Audio;

/* Build the audio decode->resample->AAC encode->mux pipeline. Returns 1 if audio
 * was wired, 0 if there's no usable audio stream (caller proceeds video-only). */
static int audio_open(Audio*A, const char*path, AVFormatContext*ofmt, int bit_rate){
  memset(A,0,sizeof *A);
  int ret;
  if((ret=avformat_open_input(&A->ifmt,path,NULL,NULL))<0) die("audio open_input",ret);
  if((ret=avformat_find_stream_info(A->ifmt,NULL))<0) die("audio stream_info",ret);
  A->aidx=-1;
  for(unsigned i=0;i<A->ifmt->nb_streams;i++)
    if(A->ifmt->streams[i]->codecpar->codec_type==AVMEDIA_TYPE_AUDIO){A->aidx=(int)i;break;}
  if(A->aidx<0){ fprintf(stderr,"audio: no audio stream in %s, skipping\n",path);
                 avformat_close_input(&A->ifmt); return 0; }

  AVCodecParameters*apar=A->ifmt->streams[A->aidx]->codecpar;
  const AVCodec*adec=avcodec_find_decoder(apar->codec_id);
  if(!adec){fprintf(stderr,"audio: no decoder for codec %d\n",apar->codec_id);
            avformat_close_input(&A->ifmt); return 0;}
  A->dec=avcodec_alloc_context3(adec);
  avcodec_parameters_to_context(A->dec,apar);
  A->dec->pkt_timebase=A->ifmt->streams[A->aidx]->time_base;
  if((ret=avcodec_open2(A->dec,adec,NULL))<0) die("audio open dec",ret);

  /* AAC encoder: 44100/stereo/fltp is the safe, universally-playable target. */
  const AVCodec*aenc=avcodec_find_encoder(AV_CODEC_ID_AAC);
  if(!aenc) die("no AAC encoder (rebuild with --enable-encoder=aac)",AVERROR_ENCODER_NOT_FOUND);
  A->enc=avcodec_alloc_context3(aenc);
  A->enc->sample_rate=44100;
  av_channel_layout_default(&A->enc->ch_layout,2);
  A->enc->sample_fmt=AV_SAMPLE_FMT_FLTP;
  A->enc->bit_rate = bit_rate>0 ? bit_rate : 128000;
  A->enc->time_base=(AVRational){1,A->enc->sample_rate};
  if(ofmt->oformat->flags&AVFMT_GLOBALHEADER) A->enc->flags|=AV_CODEC_FLAG_GLOBAL_HEADER;
  if((ret=avcodec_open2(A->enc,aenc,NULL))<0) die("audio open enc",ret);

  A->ost=avformat_new_stream(ofmt,NULL);
  avcodec_parameters_from_context(A->ost->codecpar,A->enc);
  A->ost->time_base=A->enc->time_base;
  A->enc_idx=A->ost->index;

  /* filter graph: abuffer -> aformat(target rate/fmt/layout) -> abuffersink.
   * aformat does the resample/channel-mix; abuffersink fixed-frame-size so AAC's
   * required 1024-sample frames are fed exactly. */
  A->graph=avfilter_graph_alloc();
  const AVFilter*abuf=avfilter_get_by_name("abuffer");
  const AVFilter*asink=avfilter_get_by_name("abuffersink");
  if(A->dec->ch_layout.order==AV_CHANNEL_ORDER_UNSPEC)
    av_channel_layout_default(&A->dec->ch_layout,A->dec->ch_layout.nb_channels?A->dec->ch_layout.nb_channels:2);
  char inlay[64]; av_channel_layout_describe(&A->dec->ch_layout,inlay,sizeof inlay);
  char args[256];
  snprintf(args,sizeof args,
    "time_base=1/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s",
    A->dec->sample_rate, A->dec->sample_rate,
    av_get_sample_fmt_name(A->dec->sample_fmt), inlay);
  if((ret=avfilter_graph_create_filter(&A->src,abuf,"ain",args,NULL,A->graph))<0) die("abuffer",ret);
  if((ret=avfilter_graph_create_filter(&A->sink,asink,"aout",NULL,NULL,A->graph))<0) die("abuffersink",ret);

  char outlay[64]; av_channel_layout_describe(&A->enc->ch_layout,outlay,sizeof outlay);
  char chain[256];
  snprintf(chain,sizeof chain,"aformat=sample_fmts=%s:sample_rates=%d:channel_layouts=%s",
    av_get_sample_fmt_name(A->enc->sample_fmt),A->enc->sample_rate,outlay);
  AVFilterInOut*o=avfilter_inout_alloc(),*i=avfilter_inout_alloc();
  o->name=av_strdup("in"); o->filter_ctx=A->src; o->pad_idx=0; o->next=NULL;
  i->name=av_strdup("out");i->filter_ctx=A->sink;i->pad_idx=0;i->next=NULL;
  if((ret=avfilter_graph_parse_ptr(A->graph,chain,&i,&o,NULL))<0) die("audio parse graph",ret);
  if((ret=avfilter_graph_config(A->graph,NULL))<0) die("audio config graph",ret);
  /* AAC needs a fixed frame size; pin the sink to it. */
  av_buffersink_set_frame_size(A->sink,A->enc->frame_size);

  fprintf(stderr,"audio %dHz %dch %s -> AAC 44100/stereo/128k\n",
    A->dec->sample_rate,A->dec->ch_layout.nb_channels,av_get_sample_fmt_name(A->dec->sample_fmt));
  return 1;
}

/* Encode one (or flushing NULL) audio frame and interleave-mux its packets. */
static void audio_encode(Audio*A, AVFormatContext*ofmt, AVFrame*fr, AVPacket*opkt){
  int ret;
  if((ret=avcodec_send_frame(A->enc,fr))<0&&ret!=AVERROR_EOF) die("audio send_frame",ret);
  while(1){
    ret=avcodec_receive_packet(A->enc,opkt);
    if(ret==AVERROR(EAGAIN)||ret==AVERROR_EOF) break;
    if(ret<0) die("audio recv_pkt",ret);
    av_packet_rescale_ts(opkt,A->enc->time_base,A->ost->time_base);
    opkt->stream_index=A->enc_idx;
    if((ret=av_interleaved_write_frame(ofmt,opkt))<0) die("audio write_frame",ret);
    av_packet_unref(opkt);
  }
}

/* Drain the whole audio file -> resample -> AAC -> mux. Called after the video
 * stream + header are written so both streams live in the one mp4. */
static void audio_run(Audio*A, AVFormatContext*ofmt){
  AVPacket*pkt=av_packet_alloc(),*opkt=av_packet_alloc();
  AVFrame*frame=av_frame_alloc(),*filt=av_frame_alloc();
  int ret;
  while(av_read_frame(A->ifmt,pkt)>=0){
    if(pkt->stream_index==A->aidx){
      if((ret=avcodec_send_packet(A->dec,pkt))<0) die("audio send_pkt dec",ret);
      while((ret=avcodec_receive_frame(A->dec,frame))>=0){
        if((ret=av_buffersrc_add_frame_flags(A->src,frame,AV_BUFFERSRC_FLAG_KEEP_REF))<0) die("audio buffersrc",ret);
        while((ret=av_buffersink_get_frame(A->sink,filt))>=0){
          filt->pts=A->next_pts; A->next_pts+=filt->nb_samples;
          audio_encode(A,ofmt,filt,opkt); av_frame_unref(filt);
        }
        av_frame_unref(frame);
      }
    }
    av_packet_unref(pkt);
  }
  /* flush decoder */
  avcodec_send_packet(A->dec,NULL);
  while(avcodec_receive_frame(A->dec,frame)>=0){
    av_buffersrc_add_frame_flags(A->src,frame,AV_BUFFERSRC_FLAG_KEEP_REF);
    while(av_buffersink_get_frame(A->sink,filt)>=0){
      filt->pts=A->next_pts; A->next_pts+=filt->nb_samples;
      audio_encode(A,ofmt,filt,opkt); av_frame_unref(filt);
    }
    av_frame_unref(frame);
  }
  /* flush filter */
  av_buffersrc_add_frame_flags(A->src,NULL,0);
  while(av_buffersink_get_frame(A->sink,filt)>=0){
    filt->pts=A->next_pts; A->next_pts+=filt->nb_samples;
    audio_encode(A,ofmt,filt,opkt); av_frame_unref(filt);
  }
  /* flush encoder */
  audio_encode(A,ofmt,NULL,opkt);
  av_frame_free(&frame); av_frame_free(&filt);
  av_packet_free(&pkt); av_packet_free(&opkt);
  fprintf(stderr,"audio: muxed AAC track\n");
}

/* ---------------- audio-only mode -------------------------------------------
 * `wb_encode audio <in.{mp3,aac,wav,m4a}> <out.m4a> [bitrate_kbps]`
 *   decode (mp3/aac/wav/pcm) | aresample+aformat | native AAC encode | mp4 muxer
 *   into an AUDIO-ONLY .m4a — NO video stream, NO frames required. Transcode or
 *   extract (an .m4a/aac input is re-encoded to a clean AAC/mp4 track). Fully
 *   in-guest; same libav* lane as the muxed audio sub-pipeline above.
 *
 * The mp4 muxer is forced by NAME ("mp4") so the .m4a extension (which has no
 * registered guess) still selects ISO-BMFF; an audio-only mp4 is a valid .m4a. */
static int audio_only(int argc,char**argv){
  if(argc<4){ fprintf(stderr,"usage: %s audio <in.{mp3,aac,wav,m4a}> <out.m4a> [bitrate_kbps]\n",argv[0]); return 2; }
  const char*inpath=argv[2]; const char*outpath=argv[3];
  int br_kbps = argc>4 && argv[4][0] ? atoi(argv[4]) : 128; if(br_kbps<=0) br_kbps=128;
  int ret;

  /* mp4 muxer forced by name so .m4a (no extension-guess) resolves to ISO-BMFF. */
  AVFormatContext*ofmt=NULL;
  if((ret=avformat_alloc_output_context2(&ofmt,NULL,"mp4",outpath))<0) die("audio-only alloc out",ret);

  Audio A;
  if(!audio_open(&A,inpath,ofmt,br_kbps*1000)){ fprintf(stderr,"audio-only: no usable audio stream in %s\n",inpath); return 1; }

  if(!(ofmt->oformat->flags&AVFMT_NOFILE))
    if((ret=avio_open(&ofmt->pb,outpath,AVIO_FLAG_WRITE))<0) die("audio-only avio_open",ret);
  if((ret=avformat_write_header(ofmt,NULL))<0) die("audio-only write_header",ret);

  audio_run(&A,ofmt);
  av_write_trailer(ofmt);
  fprintf(stderr,"DONE audio-only AAC %dk -> %s\n",br_kbps,outpath);
  return 0;
}

int main(int argc,char**argv){
  /* audio-only subcommand: `wb_encode audio <in> <out.m4a> [bitrate_kbps]` */
  if(argc>=2 && strcmp(argv[1],"audio")==0) return audio_only(argc,argv);

  if(argc<3){ fprintf(stderr,"usage: %s <in_%%05d.png> <out.mp4> [fps] [audio.mp3] [vcodec]\n"
                              "       %s audio <in.{mp3,aac,wav,m4a}> <out.m4a> [bitrate_kbps]\n",argv[0],argv[0]); return 2; }
  const char*inpat=argv[1]; const char*outpath=argv[2];
  int fps = argc>3?atoi(argv[3]):30; if(fps<=0)fps=30;
  const char*audiopath = argc>4 && argv[4][0] ? argv[4] : NULL;
  int ret;

  /* ---- input: image2 demuxer + png decoder ---- */
  AVFormatContext*ifmt=NULL;
  const AVInputFormat*img2=av_find_input_format("image2");
  AVDictionary*iopt=NULL; char fr[16]; snprintf(fr,sizeof fr,"%d",fps);
  av_dict_set(&iopt,"framerate",fr,0);
  if((ret=avformat_open_input(&ifmt,inpat,img2,&iopt))<0) die("open_input",ret);
  if((ret=avformat_find_stream_info(ifmt,NULL))<0) die("stream_info",ret);
  int vidx=-1; for(unsigned i=0;i<ifmt->nb_streams;i++) if(ifmt->streams[i]->codecpar->codec_type==AVMEDIA_TYPE_VIDEO){vidx=i;break;}
  if(vidx<0){fprintf(stderr,"no video stream\n");return 1;}
  AVCodecParameters*ipar=ifmt->streams[vidx]->codecpar;
  const AVCodec*dec=avcodec_find_decoder(ipar->codec_id);
  if(!dec){fprintf(stderr,"no png decoder\n");return 1;}
  AVCodecContext*dctx=avcodec_alloc_context3(dec);
  avcodec_parameters_to_context(dctx,ipar);
  if((ret=avcodec_open2(dctx,dec,NULL))<0) die("open dec",ret);
  int W=dctx->width,H=dctx->height;
  fprintf(stderr,"input %dx%d fps=%d%s\n",W,H,fps,audiopath?" +audio":"");

  /* ---- filter graph: buffer -> format=yuv420p -> buffersink ---- */
  AVFilterGraph*graph=avfilter_graph_alloc();
  const AVFilter*bsrc=avfilter_get_by_name("buffer");
  const AVFilter*bsink=avfilter_get_by_name("buffersink");
  char args[256];
  snprintf(args,sizeof args,"video_size=%dx%d:pix_fmt=%d:time_base=1/%d:pixel_aspect=1/1",
           W,H,(int)(dctx->pix_fmt==AV_PIX_FMT_NONE?AV_PIX_FMT_RGBA:dctx->pix_fmt),fps);
  AVFilterContext*srcctx=NULL,*sinkctx=NULL;
  if((ret=avfilter_graph_create_filter(&srcctx,bsrc,"in",args,NULL,graph))<0) die("buffer",ret);
  if((ret=avfilter_graph_create_filter(&sinkctx,bsink,"out",NULL,NULL,graph))<0) die("buffersink",ret);
  enum AVPixelFormat pf[]={AV_PIX_FMT_YUV420P,AV_PIX_FMT_NONE};
  av_opt_set_int_list(sinkctx,"pix_fmts",pf,AV_PIX_FMT_NONE,AV_OPT_SEARCH_CHILDREN);
  AVFilterInOut*outs=avfilter_inout_alloc(),*ins=avfilter_inout_alloc();
  outs->name=av_strdup("in");outs->filter_ctx=srcctx;outs->pad_idx=0;outs->next=NULL;
  ins->name=av_strdup("out");ins->filter_ctx=sinkctx;ins->pad_idx=0;ins->next=NULL;
  if((ret=avfilter_graph_parse_ptr(graph,"format=yuv420p",&ins,&outs,NULL))<0) die("parse graph",ret);
  if((ret=avfilter_graph_config(graph,NULL))<0) die("config graph",ret);

  /* ---- output: mp4 muxer + H.264 (libx264) encoder ----
   * Default = H.264 via libx264 (GPL), yuv420p, CRF/preset for broadcast-quality output that
   * matches the host broker — so the broker is no longer needed for quality. Set WB_VCODEC=mpeg4
   * (env, or pass "mpeg4" as a 5th argv) to fall back to the dependency-free mpeg4 encoder. */
  AVFormatContext*ofmt=NULL;
  if((ret=avformat_alloc_output_context2(&ofmt,NULL,"mp4",outpath))<0) die("alloc out",ret);
  const char*vcodec = (argc>5 && argv[5][0]) ? argv[5] : (getenv("WB_VCODEC")?getenv("WB_VCODEC"):"h264");
  int use_x264 = !(strcmp(vcodec,"mpeg4")==0);
  const AVCodec*enc = use_x264 ? avcodec_find_encoder_by_name("libx264")
                               : avcodec_find_encoder(AV_CODEC_ID_MPEG4);
  if(!enc && use_x264){ fprintf(stderr,"libx264 unavailable, falling back to mpeg4\n");
                        enc=avcodec_find_encoder(AV_CODEC_ID_MPEG4); use_x264=0; }
  if(!enc){fprintf(stderr,"no video encoder\n");return 1;}
  AVStream*ost=avformat_new_stream(ofmt,NULL);
  AVCodecContext*ectx=avcodec_alloc_context3(enc);
  ectx->width=W;ectx->height=H;ectx->pix_fmt=AV_PIX_FMT_YUV420P;
  ectx->time_base=(AVRational){1,fps};ectx->framerate=(AVRational){fps,1};
  if(use_x264){
    /* H.264: CRF 18 (visually lossless), medium preset, GOP ~= 2s of frames, B-frames on.
     * libx264 options go through its private AVOptions (set BEFORE avcodec_open2). */
    ectx->gop_size=fps*2; ectx->max_b_frames=2;
    av_opt_set(ectx->priv_data,"preset","medium",0);
    av_opt_set(ectx->priv_data,"crf","18",0);
    av_opt_set(ectx->priv_data,"profile","high",0);
  } else {
    ectx->gop_size=12; ectx->max_b_frames=0; ectx->bit_rate=2000000;
  }
  if(ofmt->oformat->flags&AVFMT_GLOBALHEADER) ectx->flags|=AV_CODEC_FLAG_GLOBAL_HEADER;
  if((ret=avcodec_open2(ectx,enc,NULL))<0) die("open enc",ret);
  fprintf(stderr,"video codec: %s\n",use_x264?"libx264 (H.264) crf18/medium/high":"mpeg4");
  avcodec_parameters_from_context(ost->codecpar,ectx);
  ost->time_base=ectx->time_base;

  /* ---- optional audio: wire decoder/resampler/AAC encoder + 2nd output stream
   *      BEFORE write_header so the mp4 declares both streams up front. ---- */
  Audio A; int have_audio=0;
  if(audiopath) have_audio=audio_open(&A,audiopath,ofmt,0);

  if(!(ofmt->oformat->flags&AVFMT_NOFILE))
    if((ret=avio_open(&ofmt->pb,outpath,AVIO_FLAG_WRITE))<0) die("avio_open",ret);
  if((ret=avformat_write_header(ofmt,NULL))<0) die("write_header",ret);

  /* ---- pump video ---- */
  AVPacket*pkt=av_packet_alloc(),*opkt=av_packet_alloc();
  AVFrame*frame=av_frame_alloc(),*filt=av_frame_alloc();
  int64_t pts=0; long nframes=0;
  #define ENCODE(fr_) do{ \
    if((ret=avcodec_send_frame(ectx,fr_))<0&&ret!=AVERROR_EOF) die("send_frame",ret); \
    while(1){ ret=avcodec_receive_packet(ectx,opkt); if(ret==AVERROR(EAGAIN)||ret==AVERROR_EOF)break; if(ret<0)die("recv_pkt",ret); \
      av_packet_rescale_ts(opkt,ectx->time_base,ost->time_base); opkt->stream_index=ost->index; \
      if((ret=av_interleaved_write_frame(ofmt,opkt))<0)die("write_frame",ret); av_packet_unref(opkt);} }while(0)

  while(av_read_frame(ifmt,pkt)>=0){
    if(pkt->stream_index==vidx){
      if((ret=avcodec_send_packet(dctx,pkt))<0) die("send_pkt dec",ret);
      while((ret=avcodec_receive_frame(dctx,frame))>=0){
        if((ret=av_buffersrc_add_frame_flags(srcctx,frame,AV_BUFFERSRC_FLAG_KEEP_REF))<0) die("buffersrc",ret);
        while((ret=av_buffersink_get_frame(sinkctx,filt))>=0){
          filt->pts=pts++; ENCODE(filt); nframes++; av_frame_unref(filt);
        }
        av_frame_unref(frame);
      }
    }
    av_packet_unref(pkt);
  }
  /* flush decoder */
  avcodec_send_packet(dctx,NULL);
  while(avcodec_receive_frame(dctx,frame)>=0){
    av_buffersrc_add_frame_flags(srcctx,frame,AV_BUFFERSRC_FLAG_KEEP_REF);
    while(av_buffersink_get_frame(sinkctx,filt)>=0){ filt->pts=pts++; ENCODE(filt); nframes++; av_frame_unref(filt);}
    av_frame_unref(frame);
  }
  /* flush filter + encoder */
  av_buffersrc_add_frame_flags(srcctx,NULL,0);
  while(av_buffersink_get_frame(sinkctx,filt)>=0){ filt->pts=pts++; ENCODE(filt); nframes++; av_frame_unref(filt);}
  ENCODE(NULL);

  /* ---- audio (after video so both streams are interleaved into the mp4) ---- */
  if(have_audio) audio_run(&A,ofmt);

  av_write_trailer(ofmt);
  fprintf(stderr,"DONE encoded %ld frames%s -> %s\n",nframes,have_audio?" + audio":"",outpath);
  return 0;
}
