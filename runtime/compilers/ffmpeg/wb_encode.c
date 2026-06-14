/* wb_encode: minimal in-sandbox PNG-sequence -> mp4 (mpeg4) transcoder built on libav*.
 * Replaces the host ffmpeg CLI for the wavelet encode path. Single-threaded, wasm32-wasi.
 * usage: wb_encode <in_pattern> <out.mp4> <fps>
 *   e.g. wb_encode /in/frame_%05d.png /out/out.mp4 30
 * Decoder: png | Demuxer: image2 | Filter: scale+format(yuv420p) | Encoder: mpeg4 | Muxer: mp4
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <libavutil/imgutils.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersrc.h>
#include <libavfilter/buffersink.h>

static void die(const char*m,int e){ char b[256]; av_strerror(e,b,sizeof b); fprintf(stderr,"ERR %s: %s\n",m,b); exit(1); }

int main(int argc,char**argv){
  if(argc<3){ fprintf(stderr,"usage: %s <in_%%05d.png> <out.mp4> [fps]\n",argv[0]); return 2; }
  const char*inpat=argv[1]; const char*outpath=argv[2];
  int fps = argc>3?atoi(argv[3]):30; if(fps<=0)fps=30;
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
  fprintf(stderr,"input %dx%d fps=%d\n",W,H,fps);

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

  /* ---- output: mp4 muxer + mpeg4 encoder ---- */
  AVFormatContext*ofmt=NULL;
  if((ret=avformat_alloc_output_context2(&ofmt,NULL,"mp4",outpath))<0) die("alloc out",ret);
  const AVCodec*enc=avcodec_find_encoder(AV_CODEC_ID_MPEG4);
  if(!enc){fprintf(stderr,"no mpeg4 encoder\n");return 1;}
  AVStream*ost=avformat_new_stream(ofmt,NULL);
  AVCodecContext*ectx=avcodec_alloc_context3(enc);
  ectx->width=W;ectx->height=H;ectx->pix_fmt=AV_PIX_FMT_YUV420P;
  ectx->time_base=(AVRational){1,fps};ectx->framerate=(AVRational){fps,1};
  ectx->gop_size=12;ectx->max_b_frames=0;ectx->bit_rate=2000000;
  if(ofmt->oformat->flags&AVFMT_GLOBALHEADER) ectx->flags|=AV_CODEC_FLAG_GLOBAL_HEADER;
  if((ret=avcodec_open2(ectx,enc,NULL))<0) die("open enc",ret);
  avcodec_parameters_from_context(ost->codecpar,ectx);
  ost->time_base=ectx->time_base;
  if(!(ofmt->oformat->flags&AVFMT_NOFILE))
    if((ret=avio_open(&ofmt->pb,outpath,AVIO_FLAG_WRITE))<0) die("avio_open",ret);
  if((ret=avformat_write_header(ofmt,NULL))<0) die("write_header",ret);

  /* ---- pump ---- */
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
  av_write_trailer(ofmt);
  fprintf(stderr,"DONE encoded %ld frames -> %s\n",nframes,outpath);
  return 0;
}
