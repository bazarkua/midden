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
// Partial work is reported, never passed off as a complete walk, with
// Midden's rules: a folder that can't be opened or listed, or whose listing
// misses entries (an entry error, a missing required attribute, a malformed
// record, a read that fails partway), counts as one read error. A folder or
// entry that vanished meanwhile (ENOENT, ENOTDIR, EDEADLK) doesn't. EINTR
// and ENOMEM are retried as Midden retries them. The exit status is 1 when
// anything was left out, so a partial walk can't pass for the same work
// done faster.
//
// Parallelism, also as in Midden: a fixed pool of threads shares one LIFO
// stack of directories. A thread keeps one subdirectory of each listing for
// itself and pushes the rest, so it continues depth first and takes the
// shared lock about once per directory.
//
// Two switches measure other strategies, one at a time:
//   --openat    Open each directory relative to its parent's descriptor
//               instead of by full path, as Midden does. Spares the kernel a
//               lookup of every path component. Raises the descriptor limit,
//               and reports it with the most descriptors held at once.
//   --readdir   List with readdir plus one fstatat per entry, the classic way
//               and Midden's own fallback, instead of getattrlistbulk. (du
//               and find use fts, which on macOS lists with getattrlistbulk
//               too: see Benchmarks/fts-probe.sh.) Sizes come from st_blocks.
//
// Build: clang -std=c11 -O3 -Wall -Wextra -o cscan cscan.c
// Usage: cscan [--threads N] [--openat] [--readdir] PATH

#define _DARWIN_C_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
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

// Retries, as in Midden's DirectoryReader.
enum { BUFFER_SIZE = 128 * 1024, SHARDS = 64, INTERRUPT_RETRIES = 100, MEMORY_RETRIES = 3 };

static bool use_openat = false;
static bool use_readdir = false;
static dev_t root_device;

// Gone since its parent was listed, no longer a folder, or not downloaded.
static bool benign(int code) { return code == ENOENT || code == ENOTDIR || code == EDEADLK; }

// MARK: Descriptors

// Directory descriptors held right now and at most, across threads.
static atomic_long open_now, open_most;

static int counted(int fd) {
    if (fd >= 0) {
        long now = atomic_fetch_add_explicit(&open_now, 1, memory_order_relaxed) + 1;
        long most = atomic_load_explicit(&open_most, memory_order_relaxed);
        while (now > most && !atomic_compare_exchange_weak(&open_most, &most, now)) {}
    }
    return fd;
}

static void close_counted(int fd) {
    close(fd);
    atomic_fetch_sub_explicit(&open_now, 1, memory_order_relaxed);
}

static const int OPEN_FLAGS = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;

// open() or openat(), retried on EINTR. Returns -1 with errno set.
static int open_retrying(int at, const char *path) {
    int fd;
    do fd = at >= 0 ? openat(at, path, OPEN_FLAGS) : open(path, OPEN_FLAGS);
    while (fd < 0 && errno == EINTR);
    return counted(fd);
}

// Opens a directory by path, as Midden does. open() fails with ENAMETOOLONG
// for a path of PATH_MAX bytes or more, so a longer one is opened in pieces
// split at slashes, each shorter than that and opened relative to the one
// before, the same way.
static int open_path(const char *path) {
    size_t length = strlen(path);
    if (length < PATH_MAX) return open_retrying(-1, path);
    char *copy = strdup(path);
    if (!copy) abort();
    int fd = -1;
    size_t start = 0;
    while (start < length) {
        // The longest piece that fits, ending at a slash (or the end).
        size_t end = start + PATH_MAX - 1 < length ? start + PATH_MAX - 1 : length;
        if (end < length) {
            while (end > start && copy[end] != '/') end--;
            if (end == start) {
                errno = ENAMETOOLONG;  // One component longer than PATH_MAX.
                break;
            }
        }
        char saved = copy[end];
        copy[end] = '\0';
        int next = open_retrying(fd, copy + start);
        int code = errno;
        copy[end] = saved;
        if (fd >= 0) close_counted(fd);
        fd = next;
        if (fd < 0) {
            errno = code;
            break;
        }
        start = end;
        while (start < length && copy[start] == '/') start++;
    }
    free(copy);
    return fd;
}

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
        close_counted(handle->fd);
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
    int64_t failed;        // Folders that couldn't be opened or listed at all.
    int64_t incomplete;    // Folders listed, but with entries missing.
    int64_t entry_errors;  // Entries left out of those listings.
    int64_t too_long;      // Folders whose path was too long to open.
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

// Every entry must come with these, as Midden requires.
static const attrgroup_t REQUIRED_COMMON =
    ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FILEID;

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

// One folder's listing so far: the subdirectories to visit, and whether
// entries are missing.
typedef struct {
    worker_t *worker;
    const work_t *work;
    handle_t *handle;
    size_t children;
    bool incomplete;
} listing_t;

// An entry the listing couldn't describe. One that vanished is just gone.
static void left_out(listing_t *l, int code) {
    if (code == ENOENT) return;
    l->incomplete = true;
    l->worker->entry_errors++;
}

// Counts one entry. The same rules for both ways of listing.
static void count(listing_t *l, const char *name, size_t length, bool is_directory, dev_t device,
                  uint64_t inode, uint32_t links, int64_t allocated) {
    worker_t *w = l->worker;
    w->items++;
    if (is_directory) {
        if (device != root_device) return;  // A mount point: another volume.
        w->bytes += allocated;
        if (l->children == w->child_capacity) {
            w->child_capacity = w->child_capacity ? w->child_capacity * 2 : 256;
            w->children = realloc(w->children, w->child_capacity * sizeof(work_t));
            if (!w->children) abort();
        }
        w->children[l->children++] = child(l->work, l->handle, name, length);
    } else if (links <= 1 || first_link((uint64_t)device, inode)) {
        w->bytes += allocated;
    }
}

static void list_readdir(listing_t *l, int fd);

// Parses one record of `length` bytes and counts its entry. Fields are
// checked against the record. Returns 0, or why the entry was left out: an
// entry error, a missing required attribute (ENOATTR) or a field outside
// the record (EIO).
static int parse(listing_t *l, const char *record, size_t length) {
    const char *end = record + length;
    const char *field = record + sizeof(uint32_t);
    attribute_set_t returned = READ(attribute_set_t, field);
    field += sizeof(attribute_set_t);

    if (returned.commonattr & ATTR_CMN_ERROR) {
        if (field + sizeof(uint32_t) > end) return EIO;
        uint32_t error = READ(uint32_t, field);
        field += sizeof(uint32_t);
        if (error) return (int)error;
    }
    if ((returned.commonattr & REQUIRED_COMMON) != REQUIRED_COMMON) return ENOATTR;

    if (field + sizeof(attrreference_t) > end) return EIO;
    attrreference_t name_ref = READ(attrreference_t, field);
    // The offset is from the reference itself; the length counts the NUL.
    const char *name = field + name_ref.attr_dataoffset;
    if (name_ref.attr_dataoffset <= 0 || name_ref.attr_length < 1 || name + name_ref.attr_length > end
        || name[name_ref.attr_length - 1] != '\0') {
        return EIO;
    }
    size_t name_length = name_ref.attr_length - 1;
    field += sizeof(attrreference_t);

    if (field + sizeof(dev_t) + sizeof(fsobj_type_t) + sizeof(struct timespec) + sizeof(uint64_t) > end) {
        return EIO;
    }
    dev_t device = READ(dev_t, field);
    field += sizeof(dev_t);
    fsobj_type_t type = READ(fsobj_type_t, field);
    field += sizeof(fsobj_type_t);
    field += sizeof(struct timespec);  // Modification time: requested as Midden does, not needed.
    uint64_t inode = READ(uint64_t, field);
    field += sizeof(uint64_t);

    if (type == VDIR) {
        if (!(returned.dirattr & ATTR_DIR_ALLOCSIZE)) return ENOATTR;
        if (field + sizeof(off_t) > end) return EIO;
        count(l, name, name_length, true, device, inode, 1, READ(off_t, field));
    } else {
        attrgroup_t required = ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE;
        if ((returned.fileattr & required) != required) return ENOATTR;
        if (field + sizeof(uint32_t) + sizeof(off_t) > end) return EIO;
        uint32_t links = READ(uint32_t, field);
        off_t allocated = READ(off_t, field + sizeof(uint32_t));
        count(l, name, name_length, false, device, inode, links, allocated);
    }
    return 0;
}

// Lists with getattrlistbulk: one call returns a batch of entries with
// their attributes. Returns 0, or the error when nothing could be read.
static int list_bulk(listing_t *l, int fd) {
    worker_t *w = l->worker;
    bool first_call = true;
    int interrupted = 0, out_of_memory = 0;
    for (;;) {
        int entries = getattrlistbulk(fd, &request, w->buffer, BUFFER_SIZE, 0);
        if (entries < 0) {
            int code = errno;
            if (code == EINTR && interrupted < INTERRUPT_RETRIES) {
                interrupted++;
                continue;
            }
            if (code == ENOMEM && out_of_memory < MEMORY_RETRIES) {
                out_of_memory++;
                usleep(1000 * (useconds_t)out_of_memory);
                continue;
            }
            // A file system without getattrlistbulk fails at once; Midden
            // falls back to readdir for that folder, and so does this.
            if (code == ENOTSUP && first_call) {
                int copy = counted(dup(fd));
                if (copy < 0) return errno;
                list_readdir(l, copy);
                return 0;
            }
            if (first_call) return code;  // Nothing read: the folder failed.
            l->incomplete = true;         // Keep what was read.
            return 0;
        }
        first_call = false;
        interrupted = out_of_memory = 0;
        if (entries == 0) return 0;
        const char *record = w->buffer, *buffer_end = w->buffer + BUFFER_SIZE;
        for (int i = 0; i < entries; i++) {
            // A malformed record means the rest of the batch can't be trusted.
            if (record + sizeof(uint32_t) + sizeof(attribute_set_t) > buffer_end) {
                l->incomplete = true;
                return 0;
            }
            uint32_t length = READ(uint32_t, record);
            if (length < sizeof(uint32_t) + sizeof(attribute_set_t) || record + length > buffer_end) {
                l->incomplete = true;
                return 0;
            }
            int code = parse(l, record, length);
            if (code) left_out(l, code);
            record += length;
        }
    }
}

// Lists the classic way: readdir, then one fstatat per entry. Same rules as
// Midden's readdir fallback. Takes ownership of `fd`.
static void list_readdir(listing_t *l, int fd) {
    DIR *dir = fdopendir(fd);
    if (!dir) {
        int code = errno;
        close_counted(fd);
        if (!benign(code)) l->incomplete = true;
        return;
    }
    int interrupted = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) {
            int code = errno;
            if (code == EINTR && interrupted < INTERRUPT_RETRIES) {
                interrupted++;
                continue;
            }
            if (code != 0) l->incomplete = true;  // An error, not the end.
            break;
        }
        const char *name = entry->d_name;
        if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) continue;
        struct stat info;
        int result, attempts = 0;
        do result = fstatat(dirfd(dir), name, &info, AT_SYMLINK_NOFOLLOW);
        while (result != 0 && errno == EINTR && ++attempts < INTERRUPT_RETRIES);
        if (result != 0) {
            left_out(l, errno);
            continue;
        }
        count(l, name, entry->d_namlen, S_ISDIR(info.st_mode), info.st_dev, info.st_ino,
              (uint32_t)info.st_nlink, (int64_t)info.st_blocks * 512);
    }
    closedir(dir);
    atomic_fetch_sub_explicit(&open_now, 1, memory_order_relaxed);
}

// Lists one directory, adds its entries to the thread's totals and queues
// its subdirectories. Returns true with one of them in *next for the calling
// thread to continue with.
static bool list(worker_t *w, work_t *work, work_t *next) {
    int fd = work->parent ? open_retrying(work->parent->fd, work->path) : open_path(work->path);
    int code = errno;  // Before releasing the parent, which may close a descriptor.
    release(work->parent);
    if (fd < 0) {
        if (!benign(code)) w->failed++;
        if (code == ENAMETOOLONG) w->too_long++;
        free(work->path);
        return false;
    }

    listing_t l = {w, work, NULL, 0, false};
    if (use_openat) {
        l.handle = malloc(sizeof(handle_t));
        if (!l.handle) abort();
        l.handle->fd = fd;
    }
    int failure = 0;
    if (use_readdir) {
        // readdir owns the descriptor it reads; subdirectories opened
        // relative to this one need their own.
        int copy = use_openat ? counted(dup(fd)) : fd;
        if (copy < 0) failure = errno;
        else list_readdir(&l, copy);
    } else {
        failure = list_bulk(&l, fd);
    }
    free(work->path);
    if (failure) {
        if (!benign(failure)) w->failed++;
    } else if (l.incomplete) {
        w->incomplete++;
    }

    size_t children = l.children;
    if (use_openat && children > 0) {
        atomic_init(&l.handle->pending, (int)children);
    } else {
        if (!use_readdir || use_openat) close_counted(fd);
        free(l.handle);
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
        } else if (strcmp(argv[i], "--readdir") == 0) {
            use_readdir = true;
        } else if (argv[i][0] != '-' && !root) {
            root = argv[i];
        } else {
            root = NULL;
            break;
        }
    }
    if (!root || threads < 1) {
        fprintf(stderr, "usage: cscan [--threads N] [--openat] [--readdir] PATH\n");
        return 2;
    }
    struct rlimit limit = {0, 0};
    getrlimit(RLIMIT_NOFILE, &limit);
    rlim_t wanted = limit.rlim_max < OPEN_MAX ? limit.rlim_max : OPEN_MAX;
    if (use_openat && limit.rlim_cur < wanted) {
        // Each directory with subdirectories still to open holds a
        // descriptor. Raise the limit, never lower it.
        limit.rlim_cur = wanted;
        if (setrlimit(RLIMIT_NOFILE, &limit) != 0) getrlimit(RLIMIT_NOFILE, &limit);
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
    for (int i = 0; i < threads; i++) {
        int code = pthread_create(&ids[i], NULL, work, &workers[i]);
        if (code != 0) {
            fprintf(stderr, "cscan: can't start thread %d of %d: %s\n", i + 1, threads, strerror(code));
            return 1;
        }
    }

    int64_t items = 0, bytes = (int64_t)info.st_blocks * 512, directories = 0;
    int64_t failed = 0, incomplete = 0, entry_errors = 0, too_long = 0;
    for (int i = 0; i < threads; i++) {
        pthread_join(ids[i], NULL);
        items += workers[i].items;
        bytes += workers[i].bytes;
        directories += workers[i].directories;
        failed += workers[i].failed;
        incomplete += workers[i].incomplete;
        entry_errors += workers[i].entry_errors;
        too_long += workers[i].too_long;
    }
    clock_gettime(CLOCK_MONOTONIC, &end);
    double seconds = (double)(end.tv_sec - start.tv_sec) + (double)(end.tv_nsec - start.tv_nsec) / 1e9;
    // errors: folders not fully read, as Midden counts read errors.
    int64_t errors = failed + incomplete;
    printf("items=%lld bytes=%lld directories=%lld errors=%lld failed=%lld incomplete=%lld"
           " entry_errors=%lld too_long=%lld threads=%d open=%s list=%s fd_limit=%llu"
           " fd_high_water=%ld seconds=%.3f\n",
           (long long)items, (long long)bytes, (long long)directories, (long long)errors,
           (long long)failed, (long long)incomplete, (long long)entry_errors, (long long)too_long,
           threads, use_openat ? "openat" : "path", use_readdir ? "readdir" : "bulk",
           (unsigned long long)limit.rlim_cur, atomic_load(&open_most), seconds);
    return errors > 0 ? 1 : 0;
}
