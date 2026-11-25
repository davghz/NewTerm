#include "T3Gzip.h"
#include <limits.h>
#include <stdlib.h>
#include <zlib.h>

uint8_t *t3_gzip(const uint8_t *source, size_t count, size_t *written) {
    if (!source || !written || count > UINT_MAX) return NULL;
    z_stream stream = {0};
    if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8,
                     Z_DEFAULT_STRATEGY) != Z_OK) return NULL;
    uLong capacity = deflateBound(&stream, count);
    uint8_t *output = capacity <= UINT_MAX ? malloc(capacity) : NULL;
    if (output) {
        stream.next_in = (Bytef *)source;
        stream.avail_in = (uInt)count;
        stream.next_out = output;
        stream.avail_out = (uInt)capacity;
        if (deflate(&stream, Z_FINISH) == Z_STREAM_END) {
            *written = stream.total_out;
        } else {
            free(output);
            output = NULL;
        }
    }
    deflateEnd(&stream);
    return output;
}
