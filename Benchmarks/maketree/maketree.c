// maketree: builds a reproducible synthetic tree shaped like a developer's
// home folder, for benchmarking disk scanners. The same seed gives the same
// tree: names, sizes, hard links, symlinks and shape. In the home shape,
// every entry's modification and access time is fixed too, derived from its
// path, between 2024-11-27 and 2026-01-01 (UTC), so verdicts that depend on
// age (a project idle for 14 days) are the same on any later day.
//
// With the default scale it makes about a million entries in under 5 GB:
//   Work/            JavaScript projects with nested node_modules, .bin
//                    symlinks and loose git objects; some installed the pnpm
//                    way, with files hard-linked from a shared store
//   .pnpm-store/     the store those hard links point to
//   .npm/_cacache/   npm's cache: two levels of hashed folders, long names
//   Library/Caches/  one flat folder of 120,000 files, one of 25,000
//   Library/Developer/Xcode/DerivedData/   build products
//   VMs/disk.img     a sparse file: 64 GiB long, 3 MiB allocated
//   datasets/        four 100 MB files
//   Work/deep/       a chain of 100 nested folders
//   Work/links/      symlinks a scanner must not follow: to /, to ., dangling
//
// Two more shapes test the extremes on their own:
//   --shape flat   one folder of 1,000,000 entries (90% empty files)
//   --shape deep   100 chains of 1,000 nested folders, deeper than PATH_MAX
//
// Usage: maketree [--shape home|flat|deep] [--seed N] [--scale F] [--dry-run] DIR
//   --scale F   multiply every count by F (0.01 makes a quick test tree)
//   --dry-run   create nothing, print what would be made
//
// Build: clang -std=c11 -O2 -Wall -Wextra -o maketree maketree.c

#define _DARWIN_C_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static bool dry_run = false;
static double scale = 1.0;
static struct { long long dirs, files, symlinks, hard_links, bytes; } made;

// MARK: Random numbers (splitmix64): the whole tree follows from the seed.

static uint64_t state;

static uint64_t mix(uint64_t x) {
    x ^= x >> 30;
    x *= 0xbf58476d1ce4e5b9ULL;
    x ^= x >> 27;
    x *= 0x94d049bb133111ebULL;
    return x ^ (x >> 31);
}

static uint64_t next(void) { return mix(state += 0x9e3779b97f4a7c15ULL); }
static uint64_t below(uint64_t n) { return next() % n; }
static double unit(void) { return (double)(next() >> 11) * 0x1.0p-53; }
static long scaled(long n) {
    long value = (long)(n * scale);
    return value < 1 ? 1 : value;
}

// A small file's size: most source and package files are under 4 KB, about
// a third of files in node_modules-like trees are empty or nearly so.
static long small_size(void) {
    double r = unit();
    if (r < 0.35) return 0;
    if (r < 0.90) return 1 + (long)below(4096);
    if (r < 0.98) return 4097 + (long)below(12288);
    return 16385 + (long)below(49152);
}

// MARK: Making things, relative to one current path

static char path[PATH_MAX];
static size_t path_length;

static void die(const char *what) {
    fprintf(stderr, "maketree: %s: %s: %s\n", what, path, strerror(errno));
    exit(1);
}

// Appends "/name" to the current path; returns the length to go back to.
static size_t push(const char *name) {
    size_t mark = path_length;
    size_t length = strlen(name);
    if (path_length + 1 + length >= sizeof(path)) {
        errno = ENAMETOOLONG;
        die("path");
    }
    path[path_length++] = '/';
    memcpy(path + path_length, name, length + 1);
    path_length += length;
    return mark;
}

static void pop(size_t mark) {
    path_length = mark;
    path[mark] = '\0';
}

// Creates folder `name` and makes it the current path. Undo with pop().
static size_t dir(const char *name) {
    size_t mark = push(name);
    if (!dry_run && mkdir(path, 0755) != 0) die("mkdir");
    made.dirs++;
    return mark;
}

// Like dir(), for a folder that may exist already.
static size_t enter(const char *name, bool *exists) {
    size_t mark = push(name);
    if (!*exists) {
        if (!dry_run && mkdir(path, 0755) != 0) die("mkdir");
        made.dirs++;
        *exists = true;
    }
    return mark;
}

static char content[1 << 20];

static void file(const char *name, long size) {
    size_t mark = push(name);
    if (!dry_run) {
        int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
        if (fd < 0) die("create");
        for (long left = size; left > 0;) {
            long chunk = left < (long)sizeof(content) ? left : (long)sizeof(content);
            ssize_t written = write(fd, content, (size_t)chunk);
            if (written <= 0) die("write");
            left -= written;
        }
        if (close(fd) != 0) die("close");
    }
    made.files++;
    made.bytes += size;
    pop(mark);
}

static void filef(long size, const char *format, ...) {
    char name[NAME_MAX + 1];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(name, sizeof(name), format, arguments);
    va_end(arguments);
    file(name, size);
}

static void symlink_to(const char *name, const char *target) {
    size_t mark = push(name);
    if (!dry_run && symlink(target, path) != 0) die("symlink");
    made.symlinks++;
    pop(mark);
}

static void hard_link(const char *name, const char *existing) {
    size_t mark = push(name);
    if (!dry_run && link(existing, path) != 0) die("link");
    made.hard_links++;
    pop(mark);
}

// 128 hex digits of a hash, as npm and pnpm name their cache files.
static void hash_name(char *out, uint64_t id, int digits) {
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < digits; i++) {
        uint64_t word = mix(id * 16 + (uint64_t)(i / 16));
        out[i] = hex[(word >> ((i % 16) * 4)) & 15];
    }
    out[digits] = '\0';
}

// MARK: Pieces of a developer's home

static const char *words[] = {
    "react", "lodash", "babel", "core", "util", "types", "parser", "loader", "plugin", "webpack",
    "eslint", "postcss", "chalk", "debug", "glob", "semver", "yargs", "rxjs", "zod", "vite",
    "jest", "acorn", "esbuild", "rollup", "tslib", "axios", "uuid", "commander", "minimatch", "ms",
};
enum { WORDS = sizeof(words) / sizeof(words[0]) };

// An npm package; depth counts node_modules levels above it.
static void package(const char *name, int depth) {
    static const double nesting[] = {0.25, 0.15, 0.08, 0.04, 0.02, 0.01};
    size_t mark = dir(name);
    file("package.json", 300 + (long)below(1700));
    if (unit() < 0.8) file("README.md", small_size());
    if (unit() < 0.7) file("LICENSE", 1000 + (long)below(200));
    file("index.js", small_size());
    if (unit() < 0.5) file("index.d.ts", small_size());
    long lib = (long)below(16);
    if (lib > 0) {
        size_t lib_mark = dir("lib");
        for (long i = 0; i < lib; i++) filef(small_size(), "file-%ld.js", i);
        if (unit() < 0.3) {
            size_t inner = dir("internal");
            long count = (long)below(8);
            for (long i = 0; i < count; i++) filef(small_size(), "helper-%ld.js", i);
            pop(inner);
        }
        pop(lib_mark);
    }
    if (unit() < 0.35) {
        size_t dist = dir("dist");
        long count = 2 + (long)below(12);
        for (long i = 0; i < count; i++) {
            filef(small_size(), "bundle-%ld.js", i);
            if (unit() < 0.5) filef(small_size(), "bundle-%ld.js.map", i);
        }
        pop(dist);
    }
    if (depth < 6 && unit() < nesting[depth]) {
        size_t modules = dir("node_modules");
        long count = 1 + (long)below(5);
        for (long i = 0; i < count; i++) {
            char child[64];
            snprintf(child, sizeof(child), "%s-%ld", words[below(WORDS)], i);
            package(child, depth + 1);
        }
        pop(modules);
    }
    pop(mark);
}

// Loose objects of a git repository: objects/xx/<38 hex digits>.
static void git_folder(uint64_t project) {
    size_t mark = dir(".git");
    file("HEAD", 21);
    file("config", 300);
    file("description", 73);
    file("index", 20000 + (long)below(200000));
    size_t refs = dir("refs");
    size_t heads = dir("heads");
    file("main", 41);
    pop(heads);
    pop(refs);
    size_t objects = dir("objects");
    bool fanout[256] = {false};
    long loose = 200 + (long)below((uint64_t)scaled(3000));
    for (long i = 0; i < loose; i++) {
        char name[64];
        uint64_t id = project << 32 | (uint64_t)i;
        int slot = (int)(mix(id) & 255);
        char folder[3];
        snprintf(folder, sizeof(folder), "%02x", slot);
        size_t inner = enter(folder, &fanout[slot]);
        hash_name(name, id, 38);
        file(name, 100 + (long)below(4000));
        pop(inner);
    }
    size_t pack = dir("pack");
    file("pack-1.idx", 50000 + (long)below(500000));
    file("pack-1.pack", 1000000 + (long)below(3000000));
    pop(pack);
    pop(objects);
    pop(mark);
}

// Source files: a few levels of folders.
static void sources(int depth) {
    long count = 3 + (long)below(15);
    for (long i = 0; i < count; i++) filef(small_size(), "module-%ld.ts", i);
    if (depth >= 3) return;
    long folders = (long)below(5);
    for (long i = 0; i < folders; i++) {
        char name[32];
        snprintf(name, sizeof(name), "%s-%ld", words[below(WORDS)], i);
        size_t mark = dir(name);
        sources(depth + 1);
        pop(mark);
    }
}

// pnpm's store: every file of a package once, named by its hash.
enum { POOL = 600 };
static long pool_files[POOL];
static long pool_first[POOL];
static char store[PATH_MAX];

static void store_path(char *out, long index) {
    char name[40];
    hash_name(name, 0x5000000000ULL + (uint64_t)index, 30);
    snprintf(out, PATH_MAX, "%s/%02lx/%s", store, index & 255, name);
}

static void pnpm_store(void) {
    size_t mark = dir(".pnpm-store");
    size_t v3 = dir("v3");
    size_t files = dir("files");
    snprintf(store, sizeof(store), "%s", path);
    long total = 0;
    for (int p = 0; p < POOL; p++) {
        pool_first[p] = total;
        pool_files[p] = 5 + (long)below(16);
        total += pool_files[p];
    }
    for (int slot = 0; slot < 256; slot++) {
        char folder[3];
        snprintf(folder, sizeof(folder), "%02x", slot);
        size_t inner = dir(folder);
        for (long index = slot; index < total; index += 256) {
            char name[40];
            hash_name(name, 0x5000000000ULL + (uint64_t)index, 30);
            file(name, small_size());
        }
        pop(inner);
    }
    pop(files);
    pop(v3);
    pop(mark);
}

// node_modules the pnpm way: .pnpm/<name>@<version>/node_modules/<name>
// holds hard links into the store, and node_modules/<name> is a symlink.
static void pnpm_modules(void) {
    size_t mark = dir("node_modules");
    long count = 150 + (long)below(250);
    int order[POOL];
    for (int i = 0; i < POOL; i++) order[i] = i;
    for (long i = 0; i < count; i++) {  // The first `count` of a shuffle.
        long j = i + (long)below((uint64_t)(POOL - i));
        int swap = order[i];
        order[i] = order[j];
        order[j] = swap;
    }
    size_t virtual_store = dir(".pnpm");
    for (long i = 0; i < count; i++) {
        int p = order[i];
        char name[64], versioned[96];
        snprintf(name, sizeof(name), "%s-%d", words[p % WORDS], p);
        snprintf(versioned, sizeof(versioned), "%s@1.0.%d", name, p);
        size_t outer = dir(versioned);
        size_t modules = dir("node_modules");
        size_t inner = dir(name);
        for (long f = 0; f < pool_files[p]; f++) {
            char existing[PATH_MAX], file_name[32];
            store_path(existing, pool_first[p] + f);
            snprintf(file_name, sizeof(file_name), f == 0 ? "package.json" : "file-%ld.js", f);
            hard_link(file_name, existing);
        }
        pop(inner);
        pop(modules);
        pop(outer);
    }
    pop(virtual_store);
    for (long i = 0; i < count; i++) {
        int p = order[i];
        char name[64], target[200];
        snprintf(name, sizeof(name), "%s-%d", words[p % WORDS], p);
        snprintf(target, sizeof(target), ".pnpm/%s@1.0.%d/node_modules/%s", name, p, name);
        symlink_to(name, target);
    }
    pop(mark);
}

static void project(uint64_t index, bool pnpm) {
    char name[32];
    snprintf(name, sizeof(name), "%s-app-%llu", words[index % WORDS], (unsigned long long)index);
    size_t mark = dir(name);
    file("package.json", 400 + (long)below(2000));
    file("README.md", small_size());
    file("tsconfig.json", 600);
    file(".gitignore", 120);
    size_t src = dir("src");
    sources(0);
    pop(src);
    git_folder(index);
    if (pnpm) {
        pnpm_modules();
    } else {
        // Skewed: a few projects have far more dependencies than most.
        double r = unit();
        long top = scaled((long)(60 + 900 * r * r * r));
        size_t modules = dir("node_modules");
        size_t bin = dir(".bin");
        long tools = 5 + (long)below(40);
        for (long i = 0; i < tools; i++) {
            char tool[48], target[96];
            snprintf(tool, sizeof(tool), "tool-%ld", i);
            snprintf(target, sizeof(target), "../%s-%ld/bin/cli.js", words[below(WORDS)], i);
            symlink_to(tool, target);
        }
        pop(bin);
        for (long i = 0; i < top; i++) {
            char package_name[64];
            snprintf(package_name, sizeof(package_name), "%s-%ld", words[below(WORDS)], i);
            package(package_name, 0);
        }
        pop(modules);
    }
    pop(mark);
}

static void flat(const char *name, long count, const char *format) {
    size_t mark = dir(name);
    for (long i = 0; i < count; i++) filef(1 + (long)below(4000), format, i);
    pop(mark);
}

// npm's cache: content-v2/sha512/xx/yy/<124 hex digits>, and an index.
static void npm_cache(void) {
    size_t mark = dir(".npm");
    size_t cacache = dir("_cacache");
    for (int k = 0; k < 2; k++) {
        size_t kind = k == 0 ? dir("content-v2") : dir("index-v5");
        size_t sha = k == 0 ? dir("sha512") : path_length;
        static bool level1[256];
        static bool level2[256 * 256];
        memset(level1, 0, sizeof(level1));
        memset(level2, 0, sizeof(level2));
        long count = scaled(40000);
        for (long i = 0; i < count; i++) {
            uint64_t id = ((uint64_t)k << 40) | (uint64_t)i;
            char name[130], a[3], b[3];
            hash_name(name, id, 128);
            memcpy(a, name, 2);
            a[2] = '\0';
            memcpy(b, name + 2, 2);
            b[2] = '\0';
            int first = (int)strtol(a, NULL, 16), second = (int)strtol(b, NULL, 16);
            size_t outer = enter(a, &level1[first]);
            size_t inner = enter(b, &level2[first * 256 + second]);
            file(name + 4, k == 0 ? small_size() : 200 + (long)below(600));
            pop(inner);
            pop(outer);
        }
        if (k == 0) pop(sha);
        pop(kind);
    }
    pop(cacache);
    pop(mark);
}

static void derived_data(uint64_t index) {
    char name[64];
    snprintf(name, sizeof(name), "App%llu-%s", (unsigned long long)index,
             index ? "bqzkxwmtjdrhcfeagnvlpyiuso" : "gdkvhrmxwqepzanbtlcufyjiso");
    size_t mark = dir(name);
    file("info.plist", 400);
    size_t build = dir("Build");
    size_t intermediates = dir("Intermediates.noindex");
    size_t target = dir("App.build");
    size_t config = dir("Debug-iphonesimulator");
    size_t objects = dir("Objects-normal");
    size_t arch = dir("arm64");
    long sources_count = scaled(3000);
    for (long i = 0; i < sources_count; i++) {
        filef(2000 + (long)below(60000), "Source%ld.o", i);
        filef(small_size(), "Source%ld.d", i);
        filef(small_size(), "Source%ld.swiftdeps", i);
    }
    pop(arch);
    pop(objects);
    pop(config);
    pop(target);
    pop(intermediates);
    pop(build);
    size_t index_store = dir("Index.noindex");
    size_t records = dir("DataStore");
    bool folders[256] = {false};
    long record_count = scaled(3000);
    for (long i = 0; i < record_count; i++) {
        char folder[3];
        int slot = (int)below(256);
        snprintf(folder, sizeof(folder), "%02X", slot);
        size_t inner = enter(folder, &folders[slot]);
        filef(small_size(), "Source%ld.swift-%llX", i, (unsigned long long)next());
        pop(inner);
    }
    pop(records);
    pop(index_store);
    pop(mark);
}

static void sparse_file(const char *name) {
    const off_t length = 64LL << 30, chunk = 1 << 20;
    size_t mark = push(name);
    if (!dry_run) {
        int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
        if (fd < 0) die("create");
        if (ftruncate(fd, length) != 0) die("ftruncate");
        off_t offsets[] = {0, length / 2, length - chunk};
        for (int i = 0; i < 3; i++) {
            if (pwrite(fd, content, (size_t)chunk, offsets[i]) != chunk) die("pwrite");
        }
        if (close(fd) != 0) die("close");
    }
    made.files++;
    made.bytes += 3 * chunk;
    pop(mark);
}

// MARK: The three shapes

// --shape flat: one folder with a million entries, 90% of them empty files.
static void flat_tree(void) {
    size_t mark = dir("flat");
    long count = scaled(1000000);
    for (long i = 0; i < count; i++) filef(unit() < 0.9 ? 0 : 1 + (long)below(4000), "item-%07ld", i);
    pop(mark);
}

// --shape deep: 100 chains of 1,000 nested folders, a small file every 10
// levels. Past about 500 levels a chain's path is longer than PATH_MAX
// (1,024 bytes), which open() by path can't reach; mkdirat and openat can.
static void deep_tree(void) {
    size_t mark = dir("deep");
    int top = dry_run ? -1 : open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (!dry_run && top < 0) die("open");
    long chains = scaled(100);
    for (long chain = 0; chain < chains; chain++) {
        char name[32];
        snprintf(name, sizeof(name), "chain-%03ld", chain);
        int fd = top;
        bool owned = false;
        for (int level = 0; level <= 1000; level++) {
            const char *folder = level == 0 ? name : "d";
            if (!dry_run) {
                if (mkdirat(fd, folder, 0755) != 0) die("mkdirat");
                int inner = openat(fd, folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
                if (inner < 0) die("openat");
                if (owned) close(fd);
                fd = inner;
                owned = true;
            }
            made.dirs++;
            if (level % 10 == 0) {
                long size = 1 + (long)below(4000);
                if (!dry_run) {
                    int file = openat(fd, "f.txt", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
                    if (file < 0 || write(file, content, (size_t)size) != size || close(file) != 0) {
                        die("write in a chain");
                    }
                }
                made.files++;
                made.bytes += size;
            }
        }
        if (owned) close(fd);
    }
    if (top >= 0) close(top);
    pop(mark);
}

// --shape home (the default): the developer's home folder described above.
static void home_tree(void) {
    pnpm_store();

    size_t work = dir("Work");
    long projects = scaled(62);
    for (long i = 0; i < projects; i++) project((uint64_t)i, i % 5 == 0);
    size_t deep = dir("deep");
    for (int level = 0; level < 100; level++) {
        dir("d");
        filef(small_size(), "level-%d.txt", level);
    }
    pop(deep);
    size_t links = dir("links");
    symlink_to("to-root", "/");
    symlink_to("to-self", ".");
    symlink_to("dangling", "does-not-exist");
    pop(links);
    pop(work);

    npm_cache();

    size_t library = dir("Library");
    size_t caches = dir("Caches");
    flat("com.example.thumbnails", scaled(120000), "thumb-%07ld.jpg");
    size_t browser = dir("com.example.browser");
    flat("Cache_Data", scaled(25000), "f_%06lx");
    pop(browser);
    pop(caches);
    size_t developer = dir("Developer");
    size_t xcode = dir("Xcode");
    size_t derived = dir("DerivedData");
    derived_data(0);
    derived_data(1);
    pop(derived);
    pop(xcode);
    pop(developer);
    pop(library);

    size_t vms = dir("VMs");
    sparse_file("disk.img");
    pop(vms);
    size_t datasets = dir("datasets");
    for (int i = 0; i < 4; i++) filef(scaled(100000000), "sample-%d.bin", i);
    pop(datasets);
}

// MARK: Fixed timestamps

// 2026-01-01T00:00:00Z, and how far before it an entry's time may fall.
enum { NEWEST = 1767225600, SPREAD = 400 * 86400 };
static size_t root_length;

// Sets an entry's times from its path below the root, so they don't depend
// on when or in what order the tree was made. A file with several links
// gets one fixed time, since all its names share it.
static int fix_time(const char *entry, const struct stat *info, int kind, struct FTW *where) {
    (void)kind;
    (void)where;
    uint64_t hash = 1469598103934665603ULL;  // FNV-1a
    for (const char *c = entry + root_length; *c; c++) hash = (hash ^ (uint8_t)*c) * 1099511628211ULL;
    time_t when = NEWEST - (time_t)(S_ISDIR(info->st_mode) || info->st_nlink <= 1 ? mix(hash) % SPREAD
                                                                                 : SPREAD / 2);
    struct timespec times[2] = {{when, 0}, {when, 0}};
    if (utimensat(AT_FDCWD, entry, times, AT_SYMLINK_NOFOLLOW) != 0) {
        perror(entry);
        return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    uint64_t seed = 20261101;
    const char *root = NULL, *shape = "home";
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--seed") == 0 && i + 1 < argc) {
            seed = strtoull(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--scale") == 0 && i + 1 < argc) {
            scale = strtod(argv[++i], NULL);
        } else if (strcmp(argv[i], "--shape") == 0 && i + 1 < argc) {
            shape = argv[++i];
        } else if (strcmp(argv[i], "--dry-run") == 0) {
            dry_run = true;
        } else if (argv[i][0] != '-' && !root) {
            root = argv[i];
        } else {
            root = NULL;
            break;
        }
    }
    bool known = !strcmp(shape, "home") || !strcmp(shape, "flat") || !strcmp(shape, "deep");
    if (!root || scale <= 0 || !known) {
        fprintf(stderr, "usage: maketree [--shape home|flat|deep] [--seed N] [--scale F] [--dry-run] DIR\n");
        return 2;
    }
    state = seed;
    for (size_t i = 0; i < sizeof(content); i++) content[i] = (char)(next() & 0x7f);

    // The root itself isn't counted: scanners report what is inside it.
    snprintf(path, sizeof(path), "%s", root);
    path_length = strlen(path);
    if (!dry_run && mkdir(path, 0755) != 0) die("mkdir (it must not exist yet)");

    if (!strcmp(shape, "flat")) flat_tree();
    else if (!strcmp(shape, "deep")) deep_tree();
    else home_tree();

    // Children first (FTW_DEPTH), since adding an entry changes its
    // folder's time. Symlinks get their own time, not their target's.
    if (!dry_run && !strcmp(shape, "home")) {
        root_length = strlen(root);
        if (nftw(root, fix_time, 64, FTW_DEPTH | FTW_PHYS) != 0) {
            snprintf(path, sizeof(path), "%s", root);
            die("fixing timestamps");
        }
    }

    long long entries = made.dirs + made.files + made.symlinks + made.hard_links;
    printf("%s%lld entries: %lld folders, %lld files, %lld symlinks, %lld hard links; "
           "%.2f GB of file content written\n",
           dry_run ? "would make " : "", entries, made.dirs, made.files, made.symlinks,
           made.hard_links, (double)made.bytes / 1e9);
    return 0;
}
