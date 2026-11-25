#ifndef T3_GZIP_H
#define T3_GZIP_H
#include <stddef.h>
#include <stdint.h>
/* malloc-owned result. Returns NULL on error. */
uint8_t *t3_gzip(const uint8_t *source, size_t count, size_t *written);
#endif
