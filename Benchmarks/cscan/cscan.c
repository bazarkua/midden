// cscan: a minimal parallel disk-usage scanner for macOS, written as a
// yardstick for Midden's walker (Sources/MiddenCore/Walker.swift and
// DirectoryReader.swift). It does only what is needed to print the same two
// numbers Midden's walk produces: items listed and bytes allocated on disk.
//
// Same semantics as Midden's walk:
//   - Directories are listed with getattrlistbulk(2), requesting the same
//     attributes as Midden into a 128 KB buffer per thread.
//   - Sizes are bytes allocated on disk (ATTR_FILE_ALLOCSIZE for files and
//     symlinks, ATTR_DIR_ALLOCSIZE for directories, st_blocks * 512 for the
//     root itself), so a sparse file counts what it really uses.
//   - A non-directory with more than one link is counted once per
//     (device, inode).
//   - Symlinks are never followed, and a directory on another device (a mount
//     point) is not entered and not counted.
//   - Items are the entries listed; the root itself is not one.
//   - Like Midden, worker threads never materialize dataless (iCloud) files.
//
// Parallelism, also as in Midden: a fixed pool of threads shares one LIFO
// stack of directories. A thread keeps one subdirectory of each listing for
// itself and pushes the rest, so it continues depth first and takes the
// shared lock about once per directory.
//
// Directories are opened by full path, as Midden does. --openat opens each
// one relative to its parent's open descriptor instead, which spares the
// kernel a lookup of every path component; comparing the two shows what
// that lookup costs.
//
// Build: clang -std=c11 -O3 -Wall -Wextra -o cscan cscan.c
// Usage: cscan [--threads N] [--openat] PATH

#define _DARWIN_C_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/vnode.h>
#include <time.h>
#include <unistd.h>

enum { BUFFER_SIZE = 128 * 1024, SHARDS = 64 };

static bool use_openat = false;
static dev_t root_device;

// MARK: Directories to visit

// An open directory whose subdirectories are opened relative to it
// (--openat only). Closed when the last of them has been opened.
typedef struct handle {
    int fd;
    atomic_int pending;
} handle_t;

typedef struct {
    char *path;        // Full path, or with --openat the name in `parent`.
    handle_t *parent;  // --openat only; NULL for the root.
} work_t;

static void release(handle_t *handle) {
    if (handle && atomic_fetch_sub_explicit(&handle->pending, 1, memory_order_acq_rel) == 1) {
        close(handle->fd);
        free(handle);
    }
}

// A LIFO stack shared by the threads. pop() blocks while another thread may
// still push work and returns false once all of it is done.
static struct {
    pthread_mutex_t lock;
    pthread_cond_t ready;
    work_t *items;
    size_t count, capacity;
    int busy;  // Threads holding work popped from the stack.
    bool done;
} queue = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, NULL, 0, 0, 0, false};

static void push(const work_t *items, size_t count) {
    pthread_mutex_lock(&queue.lock);
    if (queue.count + count > queue.capacity) {
        queue.capacity = (queue.count + count) * 2;
        queue.items = realloc(queue.items, queue.capacity * sizeof(work_t));
        if (!queue.items) abort();
    }
    memcpy(queue.items + queue.count, items, count * sizeof(work_t));
    queue.count += count;
    pthread_mutex_unlock(&queue.lock);
    if (count == 1) pthread_cond_signal(&queue.ready);
    else pthread_cond_broadcast(&queue.ready);
}

static bool pop(work_t *out) {
    pthread_mutex_lock(&queue.lock);
    while (queue.count == 0 && !queue.done) {
        if (queue.busy == 0) {
            queue.done = true;
            pthread_cond_broadcast(&queue.ready);
            break;
        }
        pthread_cond_wait(&queue.ready, &queue.lock);
    }
    bool got = !queue.done;
    if (got) {
        queue.busy++;
        *out = queue.items[--queue.count];
    }
    pthread_mutex_unlock(&queue.lock);
    return got;
}

// The calling thread finished what it popped, including what it kept.
static void finished(void) {
    pthread_mutex_lock(&queue.lock);
    queue.busy--;
    bool idle = queue.busy == 0 && queue.count == 0;
    if (idle) queue.done = true;
    pthread_mutex_unlock(&queue.lock);
    if (idle) pthread_cond_broadcast(&queue.ready);
}

// MARK: Hard links

// (device, inode) of every non-directory with several links, so each is
// counted once. Open addressing, split into shards to keep threads apart.
typedef struct {
    uint64_t inode;  // 0 marks an empty slot; APFS and HFS+ never use inode 0.
    uint64_t device;
} link_key_t;

static struct shard {
    os_unfair_lock lock;
    size_t count, capacity;
    link_key_t *slots;
} shards[SHARDS];

static uint64_t mix(uint64_t x) {  // splitmix64's finalizer
    x ^= x >> 30;
    x *= 0xbf58476d1ce4e5b9ULL;
    x ^= x >> 27;
    x *= 0x94d049bb133111ebULL;
    return x ^ (x >> 31);
}

static void place(struct shard *shard, link_key_t key, uint64_t hash) {
    size_t mask = shard->capacity - 1;
    size_t i = (size_t)(hash >> 8) & mask;
    while (shard->slots[i].inode) i = (i + 1) & mask;
    shard->slots[i] = key;
}

// True the first time (device, inode) is seen.
static bool first_link(uint64_t device, uint64_t inode) {
    uint64_t hash = mix(inode ^ (device << 40));
    struct shard *shard = &shards[hash % SHARDS];
    os_unfair_lock_lock(&shard->lock);
    if ((shard->count + 1) * 2 > shard->capacity) {
        link_key_t *old = shard->slots;
        size_t old_capacity = shard->capacity;
        shard->capacity = old_capacity ? old_capacity * 2 : 1024;
        shard->slots = calloc(shard->capacity, sizeof(link_key_t));
        if (!shard->slots) abort();
        for (size_t i = 0; i < old_capacity; i++) {
            if (old[i].inode) place(shard, old[i], mix(old[i].inode ^ (old[i].device << 40)));
        }
        free(old);
    }
    size_t mask = shard->capacity - 1;
    size_t i = (size_t)(hash >> 8) & mask;
    bool inserted = true;
    for (; shard->slots[i].inode; i = (i + 1) & mask) {
        if (shard->slots[i].inode == inode && shard->slots[i].device == device) {
            inserted = false;
            break;
        }
    }
    if (inserted) {
        shard->slots[i] = (link_key_t){inode, device};
        shard->count++;
    }
    os_unfair_lock_unlock(&shard->lock);
    return inserted;
}

// MARK: Listing

typedef struct {
    // Totals of this thread, added up at the end. Padded to a 128-byte
    // cache line so threads don't share one.
    _Alignas(128) int64_t items;
    int64_t bytes;
    int64_t directories;
    int64_t errors;
    char *buffer;
    work_t *children;
    size_t child_capacity;
} worker_t;

static struct attrlist request = {
    .bitmapcount = ATTR_BIT_MAP_COUNT,
    .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID
        | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FILEID,
    .dirattr = ATTR_DIR_ALLOCSIZE,
    .fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE,
};

// Records are 4-byte aligned, so 8-byte fields may not be.
#define READ(type, pointer) ({ type value_; memcpy(&value_, (pointer), sizeof(type)); value_; })

// The work item for subdirectory `name` (NUL-terminated) of `parent`.
static work_t child(const work_t *parent, handle_t *handle, const char *name, size_t length) {
    char *path;
    if (use_openat) {
        path = malloc(length + 1);
        if (!path) abort();
        memcpy(path, name, length + 1);
    } else {
        size_t base = strlen(parent->path);
        path = malloc(base + 1 + length + 1);
        if (!path) abort();
        memcpy(path, parent->path, base);
        path[base] = '/';
        memcpy(path + base + 1, name, length + 1);
    }
    return (work_t){path, handle};
}

// Lists one directory, adds its entries to the thread's totals and queues
// its subdirectories. Returns true with one of them in *next for the calling
// thread to continue with.
static bool list(worker_t *w, work_t *work, work_t *next) {
    int flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
    int fd = work->parent ? openat(work->parent->fd, work->path, flags) : open(work->path, flags);
    release(work->parent);
    if (fd < 0) {
        if (errno != ENOENT && errno != ENOTDIR) w->errors++;
        free(work->path);
        return false;
    }

    handle_t *handle = NULL;
    if (use_openat) {
        handle = malloc(sizeof(handle_t));
        if (!handle) abort();
        handle->fd = fd;
    }
    size_t children = 0;
    bool first_call = true;
    for (;;) {
        int count = getattrlistbulk(fd, &request, w->buffer, BUFFER_SIZE, 0);
        if (count < 0) {
            // Midden falls back to readdir for file systems without
            // getattrlistbulk; this yardstick is meant for APFS and says so.
            if (errno == ENOTSUP && first_call) fprintf(stderr, "cscan: %s: getattrlistbulk not supported\n", work->path);
            w->errors++;
            break;
        }
        first_call = false;
        if (count == 0) break;
        const char *record = w->buffer;
        for (int i = 0; i < count; i++) {
            uint32_t length = READ(uint32_t, record);
            const char *field = record + sizeof(uint32_t);
            attribute_set_t returned = READ(attribute_set_t, field);
            field += sizeof(attribute_set_t);
            record += length;

            if (returned.commonattr & ATTR_CMN_ERROR) {
                uint32_t error = READ(uint32_t, field);
                field += sizeof(uint32_t);
                if (error) continue;
            }
            if (!(returned.commonattr & ATTR_CMN_NAME)) continue;
            attrreference_t name_ref = READ(attrreference_t, field);
            const char *name = field + name_ref.attr_dataoffset;
            size_t name_length = name_ref.attr_length ? name_ref.attr_length - 1 : 0;
            field += sizeof(attrreference_t);

            dev_t device = 0;
            fsobj_type_t type = VNON;
            uint64_t inode = 0;
            uint32_t links = 1;
            off_t allocated = 0;
            if (returned.commonattr & ATTR_CMN_DEVID) {
                device = READ(dev_t, field);
                field += sizeof(dev_t);
            }
            if (returned.commonattr & ATTR_CMN_OBJTYPE) {
                type = READ(fsobj_type_t, field);
                field += sizeof(fsobj_type_t);
            }
            if (returned.commonattr & ATTR_CMN_MODTIME) field += sizeof(struct timespec);
            if (returned.commonattr & ATTR_CMN_FILEID) {
                inode = READ(uint64_t, field);
                field += sizeof(uint64_t);
            }
            if (returned.dirattr & ATTR_DIR_ALLOCSIZE) {
                allocated = READ(off_t, field);
                field += sizeof(off_t);
            }
            if (returned.fileattr & ATTR_FILE_LINKCOUNT) {
                links = READ(uint32_t, field);
                field += sizeof(uint32_t);
            }
            if (returned.fileattr & ATTR_FILE_ALLOCSIZE) {
                allocated = READ(off_t, field);
                field += sizeof(off_t);
            }

            w->items++;
            if (type == VDIR) {
                if (device != root_device) continue;  // A mount point: another volume.
                w->bytes += allocated;
                if (children == w->child_capacity) {
                    w->child_capacity = w->child_capacity ? w->child_capacity * 2 : 256;
                    w->children = realloc(w->children, w->child_capacity * sizeof(work_t));
                    if (!w->children) abort();
                }
                w->children[children++] = child(work, handle, name, name_length);
            } else if (links <= 1 || first_link((uint64_t)device, inode)) {
                w->bytes += allocated;
            }
        }
    }
    free(work->path);

    if (handle) {
        if (children == 0) {
            close(fd);
            free(handle);
        } else {
            atomic_init(&handle->pending, (int)children);
        }
    } else {
        close(fd);
    }
    if (children == 0) return false;
    *next = w->children[children - 1];
    if (children > 1) push(w->children, children - 1);
    return true;
}

static void *work(void *argument) {
    worker_t *w = argument;
    setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                   IOPOL_MATERIALIZE_DATALESS_FILES_OFF);
    w->buffer = aligned_alloc(8, BUFFER_SIZE);
    if (!w->buffer) abort();
    work_t item;
    while (pop(&item)) {
        // Depth first: continue with the subdirectory list() kept.
        do w->directories++;
        while (list(w, &item, &item));
        finished();
    }
    free(w->buffer);
    free(w->children);
    return NULL;
}

// Midden's default: the core count, clamped between 4 and 12.
static int default_threads(void) {
    int cores = 0;
    size_t size = sizeof(cores);
    if (sysctlbyname("hw.activecpu", &cores, &size, NULL, 0) != 0) cores = 4;
    return cores < 4 ? 4 : cores > 12 ? 12 : cores;
}

int main(int argc, char **argv) {
    int threads = default_threads();
    const char *root = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--threads") == 0 && i + 1 < argc) {
            threads = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--openat") == 0) {
            use_openat = true;
        } else if (argv[i][0] != '-' && !root) {
            root = argv[i];
        } else {
            fprintf(stderr, "usage: cscan [--threads N] [--openat] PATH\n");
            return 2;
        }
    }
    if (!root || threads < 1) {
        fprintf(stderr, "usage: cscan [--threads N] [--openat] PATH\n");
        return 2;
    }
    if (use_openat) {
        // Each directory with subdirectories still to open holds a descriptor.
        struct rlimit limit;
        if (getrlimit(RLIMIT_NOFILE, &limit) == 0) {
            limit.rlim_cur = limit.rlim_max < OPEN_MAX ? limit.rlim_max : OPEN_MAX;
            setrlimit(RLIMIT_NOFILE, &limit);
        }
    }

    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    struct stat info;
    if (lstat(root, &info) != 0 || !S_ISDIR(info.st_mode)) {
        fprintf(stderr, "cscan: %s: not a directory\n", root);
        return 1;
    }
    root_device = info.st_dev;
    work_t first = {strdup(root), NULL};
    push(&first, 1);

    worker_t *workers = aligned_alloc(128, sizeof(worker_t) * (size_t)threads);
    pthread_t *ids = calloc((size_t)threads, sizeof(pthread_t));
    if (!workers || !ids) abort();
    memset(workers, 0, sizeof(worker_t) * (size_t)threads);
    for (int i = 0; i < threads; i++) pthread_create(&ids[i], NULL, work, &workers[i]);

    int64_t items = 0, bytes = (int64_t)info.st_blocks * 512, directories = 0, errors = 0;
    for (int i = 0; i < threads; i++) {
        pthread_join(ids[i], NULL);
        items += workers[i].items;
        bytes += workers[i].bytes;
        directories += workers[i].directories;
        errors += workers[i].errors;
    }
    clock_gettime(CLOCK_MONOTONIC, &end);
    double seconds = (double)(end.tv_sec - start.tv_sec) + (double)(end.tv_nsec - start.tv_nsec) / 1e9;
    printf("items=%lld bytes=%lld directories=%lld errors=%lld threads=%d mode=%s seconds=%.3f\n",
           (long long)items, (long long)bytes, (long long)directories, (long long)errors, threads,
           use_openat ? "openat" : "paths", seconds);
    return 0;
}
