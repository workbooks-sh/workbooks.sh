# render-export — render a HyperFrames scene to a clip

# render-export — scene → clip
  Once a scene is authored (the `scene` skill), wavelet plays it back frame by
  frame and exports the clip. ffmpeg is the encode/mux tail, NOT the authoring
  surface — reach for the `ffmpeg` toolkit only for the final transcode/mux.

  1. Render: wavelet runs the scene deterministically over its duration →
     a frame sequence (or a raw clip).
  2. Encode: hand the frames to the `ffmpeg` toolkit
     (`transcode-to-h264` for browser/streaming compat; `gif-webm-export` for a
     loop; `video-audio-mux` to lay in a track).
  3. The clip is the deliverable — single file, deterministic from the scene
     source, so a re-render reproduces it exactly.

  Keep the audio-sync contract in mind if the scene is timed to a track (see the
  wavelet `audio-sync` skill).
