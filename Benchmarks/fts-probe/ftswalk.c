// Walks a folder with fts(3) the way `du -x` does (FTS_PHYSICAL | FTS_XDEV)
// and prints how many entries and folders it saw, for
// Benchmarks/fts-probe.sh. /usr/bin/du itself can't be probed: macOS drops
// DYLD_INSERT_LIBRARIES for system binaries.
//
// Build: clang -O2 -o ftswalk ftswalk.c

#include <fts.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: ftswalk DIR\n");
        return 2;
    }
    char *paths[] = {argv[1], NULL};
    FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_XDEV, NULL);
    if (!fts) {
        perror("fts_open");
        return 1;
    }
    long entries = 0, folders = 0;
    FTSENT *entry;
    while ((entry = fts_read(fts))) {
        if (entry->fts_info == FTS_DP) continue;  // A folder's second visit, on the way out.
        entries++;
        if (entry->fts_info == FTS_D) folders++;
    }
    fts_close(fts);
    printf("fts entries (root included): %ld, folders: %ld\n", entries, folders);
    return 0;
}
