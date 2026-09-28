/* The FFmpeg interface the platform decodes the game's movies with (`video.zig`), translated to Zig
 * by the build: the codecs' decoding calls, the frames and memory they hand back, and the errno
 * values FFmpeg's errors are made of. */
#include <errno.h>
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/frame.h>
#include <libavutil/log.h>
#include <libavutil/mem.h>
