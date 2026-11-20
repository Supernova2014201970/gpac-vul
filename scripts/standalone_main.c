/* Single-input driver: feed one file to the OSS-Fuzz entry point once, so a PoC
 * can be run without the libFuzzer runtime.  Same idea as hand_repro.c in the
 * sibling datasets.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

static int read_file(const char *path, uint8_t **buf, size_t *len) {
    FILE *f = fopen(path, "rb");
    long n;
    if (!f) return 0;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return 0; }
    n = ftell(f);
    if (n < 0) { fclose(f); return 0; }
    rewind(f);
    *buf = (uint8_t *)malloc((size_t)n + 1);
    if (!*buf) { fclose(f); return 0; }
    *len = fread(*buf, 1, (size_t)n, f);
    fclose(f);
    return 1;
}

int main(int argc, char **argv) {
    int i;
    if (argc < 2) {
        fprintf(stderr, "usage: %s <input>...\n", argv[0]);
        return 2;
    }
    for (i = 1; i < argc; i++) {
        uint8_t *buf = NULL;
        size_t len = 0;
        if (!read_file(argv[i], &buf, &len)) {
            fprintf(stderr, "cannot read %s\n", argv[i]);
            return 2;
        }
        LLVMFuzzerTestOneInput(buf, len);
        free(buf);
    }
    return 0;
}
