#include "medialib_crypto.h"
#include "blake2/blake2.h"

int medialib_blake2b_256(const void *input, size_t input_length, uint8_t output[32]) {
    if (output == NULL || (input == NULL && input_length != 0)) {
        return -1;
    }
    return blake2b(output, 32, input, input_length, NULL, 0);
}
