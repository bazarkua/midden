// Counts the getattrlistbulk(2) calls a process makes, for
// Benchmarks/fts-probe.sh. Loaded with DYLD_INSERT_LIBRARIES, it replaces
// the libc symbol through dyld's __interpose section and prints the count
// to stderr when the process exits.
//
// Build: clang -dynamiclib -O2 -o count.dylib count.c

#include <stdatomic.h>
#include <stdio.h>
#include <sys/attr.h>
#include <unistd.h>

static atomic_long calls;

static int counted_getattrlistbulk(int fd, void *request, void *buffer, size_t size, uint64_t options) {
    atomic_fetch_add_explicit(&calls, 1, memory_order_relaxed);
    return getattrlistbulk(fd, request, buffer, size, options);
}

__attribute__((used)) static const struct {
    const void *replacement;
    const void *original;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)counted_getattrlistbulk, (const void *)getattrlistbulk},
};

__attribute__((destructor)) static void report(void) {
    fprintf(stderr, "getattrlistbulk calls: %ld\n", atomic_load(&calls));
}
