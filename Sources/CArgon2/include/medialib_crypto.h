#ifndef MEDIALIB_CRYPTO_H
#define MEDIALIB_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

int medialib_blake2b_256(const void *input, size_t input_length, uint8_t output[32]);

#endif
