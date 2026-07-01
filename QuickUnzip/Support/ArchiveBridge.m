//
//  ArchiveBridge.m
//  QuickUnzip
//
//  Implementation note: libarchive is shipped by macOS (bsdtar links it) but
//  its C header is not part of the public SDK. We declare the subset of the
//  libarchive C API we use here and link the system libarchive.tbd. The ABI
//  matches libarchive 3.x (the system install-name is /usr/lib/libarchive.2.dylib,
//  current-version 9.x, which is the 3.x ABI).
//
//  Password handling: the system stub does NOT export the convenience
//  `archive_read_set_passphrase(a, pw)` function; it only exports the
//  callback variant `archive_read_set_passphrase_callback`. We use that and
//  retain the password NSString for the archive's lifetime.
//

#import "ArchiveBridge.h"
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <sys/time.h>
#import <os/log.h>

#define QU_LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "QuickUnzip: " fmt, ##__VA_ARGS__)

#pragma mark - libarchive declarations (subset; header not in SDK)

struct archive;
struct archive_entry;

extern struct archive *archive_read_new(void);
extern int archive_read_support_format_all(struct archive *);
extern int archive_read_support_filter_all(struct archive *);
extern int archive_read_open_filename(struct archive *, const char *_filename, size_t block_size);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern int archive_read_free(struct archive *);
extern int archive_read_data_skip(struct archive *);
// Thread-safe data read: pulls the next chunk of the current entry's payload.
// We write chunks ourselves instead of using archive_read_extract (which writes
// relative to process CWD) so concurrent extractions and sandboxed extensions
// both work without CWD gymnastics.
extern int archive_read_data_block(struct archive *, const void **_buffer,
                                   size_t *_size, int64_t *_offset);
extern const char *archive_entry_pathname(struct archive_entry *);
extern int64_t archive_entry_size(struct archive_entry *);
extern time_t archive_entry_mtime(struct archive_entry *);
extern mode_t archive_entry_filetype(struct archive_entry *);
extern mode_t archive_entry_mode(struct archive_entry *);
extern const char *archive_entry_symlink(struct archive_entry *);
extern int archive_entry_is_encrypted(struct archive_entry *);
extern const char *archive_error_string(struct archive *);

// Passphrase callback API (the convenience `archive_read_set_passphrase` is
// not exported by the system stub, but this callback variant is).
typedef const char *(*archive_passphrase_callback)(struct archive *, void *_client_data);
extern int archive_read_set_passphrase_callback(struct archive *,
                                                void *_client_data,
                                                archive_passphrase_callback);

// libarchive extract flags (stable values from archive.h) — referenced by
// archive_read_extract, which we no longer use; kept for reference only.
// #define QU_EXTRACT_SECURE_SYMLINKS       0x0100
// #define QU_EXTRACT_SECURE_NODOTDOT       0x0200
// #define QU_EXTRACT_SECURE_NOABSOLUTEPATHS 0x1000

// libarchive return codes.
#define QU_ARCHIVE_OK     0
#define QU_ARCHIVE_EOF    1

#pragma mark - Handle

typedef struct {
    struct archive *a;
    CFTypeRef pwRef;   // CF-retained NSString *, or NULL
} QUArchiveHandle;

static const char *qu_passphrase_cb(struct archive *a, void *client_data) {
    if (client_data == NULL) return NULL;
    NSString *pw = (__bridge NSString *)client_data;
    // Valid as long as `pw` (the CF-retained string) is alive, i.e. until close.
    return [pw UTF8String];
}

#pragma mark - QUArchiveEntry

@implementation QUArchiveEntry
@end

#pragma mark - QUArchiveReader

@interface QUArchiveReader ()
@property (nonatomic, strong) NSURL *fileURL;
@end

@implementation QUArchiveReader

- (instancetype)initWithFileURL:(NSURL *)fileURL {
    self = [super init];
    if (self) {
        _fileURL = fileURL;
    }
    return self;
}

/// Configures a fresh read archive handle. On failure, error is set and the
/// returned handle has a NULL `a`.
static QUArchiveHandle QUOpenArchive(NSURL *fileURL, NSString *password, NSError **error) {
    QUArchiveHandle h = { .a = NULL, .pwRef = NULL };

    // Validate readability up front so we can produce a clear error before
    // handing off to libarchive (whose open errors are less user-friendly).
    NSNumber *isReadable = nil;
    [fileURL getResourceValue:&isReadable forKey:NSURLIsReadableKey error:nil];
    if (![fileURL checkResourceIsReachableAndReturnError:nil] ||
        (isReadable && ![isReadable boolValue])) {
        if (error) {
            *error = [NSError errorWithDomain:@"QUArchive" code:1
                                     userInfo:@{ NSLocalizedDescriptionKey: @"文件不可读或不存在" }];
        }
        return h;
    }

    struct archive *a = archive_read_new();
    if (a == NULL) {
        if (error) *error = [NSError errorWithDomain:@"QUArchive" code:2
                                            userInfo:@{ NSLocalizedDescriptionKey: @"无法创建 archive 句柄" }];
        return h;
    }
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);

    if (password.length > 0) {
        NSString *pwStr = [password copy];
        // Move the +1 retain into CF so the string lives until QUCloseArchive.
        h.pwRef = CFBridgingRetain(pwStr);
        archive_read_set_passphrase_callback(a, (void *)h.pwRef, qu_passphrase_cb);
    }

    NSString *path = fileURL.path;
    int r = archive_read_open_filename(a, [path UTF8String], 65536);
    if (r != QU_ARCHIVE_OK) {
        const char *msg = archive_error_string(a);
        if (error) {
            *error = [NSError errorWithDomain:@"QUArchive" code:3
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                                 [NSString stringWithFormat:@"打开压缩包失败: %s", msg ?: "unknown"] }];
        }
        archive_read_free(a);
        if (h.pwRef) { CFRelease(h.pwRef); h.pwRef = NULL; }
        return h;
    }
    h.a = a;
    return h;
}

static void QUCloseArchive(QUArchiveHandle h) {
    if (h.a) archive_read_free(h.a);
    if (h.pwRef) CFRelease(h.pwRef);
}

- (NSArray<QUArchiveEntry *> *)listEntries:(NSError **)error {
    QUArchiveHandle h = QUOpenArchive(self.fileURL, nil, error);
    if (h.a == NULL) return nil;

    NSMutableArray<QUArchiveEntry *> *out = [NSMutableArray array];
    struct archive_entry *entry = NULL;
    int r;
    while ((r = archive_read_next_header(h.a, &entry)) == QU_ARCHIVE_OK) {
        QUArchiveEntry *e = [QUArchiveEntry new];
        const char *p = archive_entry_pathname(entry);
        e.pathname = p ? [NSString stringWithUTF8String:p] : @"";
        e.size = archive_entry_size(entry);
        e.mtime = (int64_t)archive_entry_mtime(entry);
        mode_t ft = archive_entry_filetype(entry);
        e.isDirectory = ((ft & S_IFMT) == S_IFDIR);
        e.isEncrypted = (archive_entry_is_encrypted(entry) != 0);
        [out addObject:e];
        archive_read_data_skip(h.a);
    }
    if (r != QU_ARCHIVE_EOF) {
        const char *msg = archive_error_string(h.a);
        if (error) {
            *error = [NSError errorWithDomain:@"QUArchive" code:4
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                                 [NSString stringWithFormat:@"读取条目失败: %s", msg ?: "unknown"] }];
        }
        QUCloseArchive(h);
        return nil;
    }
    QUCloseArchive(h);
    return out;
}

- (BOOL)extractAllToDirectory:(NSURL *)destDir
                     password:(NSString *)password
                     progress:(BOOL (^)(double, NSString *))progress
                        error:(NSError **)error {
    // Ensure destination exists.
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *mkErr = nil;
    if (![destDir checkResourceIsReachableAndReturnError:nil]) {
        if (![fm createDirectoryAtURL:destDir withIntermediateDirectories:YES attributes:nil error:&mkErr]) {
            if (error) *error = mkErr;
            return NO;
        }
    }

    // Pass 1: count entries for progress fraction.
    NSUInteger total = 0;
    {
        QUArchiveHandle h = QUOpenArchive(self.fileURL, password, error);
        if (h.a == NULL) return NO;
        struct archive_entry *entry = NULL;
        int r;
        while ((r = archive_read_next_header(h.a, &entry)) == QU_ARCHIVE_OK) {
            total++;
            archive_read_data_skip(h.a);
        }
        QUCloseArchive(h);
        if (r != QU_ARCHIVE_EOF) {
            // Treat a soft read error during count as non-fatal; pass 2 will report it.
            QU_LOG("count pass ended with code %d", r);
        }
    }

    // Pass 2: extract.
    // Manual extraction via archive_read_data_block. We avoid archive_read_extract
    // because it writes relative to the process CWD and the system stub does not
    // export archive_read_extract_set_dest_dir; chdir-based approaches mutate
    // process-global state and would race under concurrent extractions. Doing the
    // write ourselves keeps each extraction fully self-contained and thread-safe.
    QUArchiveHandle h = QUOpenArchive(self.fileURL, password, error);
    if (h.a == NULL) return NO;

    NSString *destPath = destDir.path;
    struct archive_entry *entry = NULL;
    NSUInteger done = 0;
    int r;
    while ((r = archive_read_next_header(h.a, &entry)) == QU_ARCHIVE_OK) {
        const char *p = archive_entry_pathname(entry);
        NSString *relPath = p ? [NSString stringWithUTF8String:p] : @"";
        if (progress) {
            double frac = (total > 0) ? (double)done / (double)total : 0.0;
            if (!progress(frac, relPath)) {
                // Caller requested cancellation. Clean up and report code 6.
                QUCloseArchive(h);
                if (error) {
                    *error = [NSError errorWithDomain:@"QUArchive" code:6
                                             userInfo:@{ NSLocalizedDescriptionKey: @"已取消" }];
                }
                return NO;
            }
        }

        // Path sanitization: reject empty, absolute, and parent-traversal paths.
        // (libarchive's SECURE_* flags would have done this for archive_read_extract;
        // we replicate the essential checks here.)
        if (relPath.length == 0 ||
            [relPath hasPrefix:@"/"] ||
            [relPath isEqualToString:@".."] ||
            [relPath hasPrefix:@"../"] ||
            [relPath containsString:@"/../"] ||
            [relPath hasSuffix:@"/.."]) {
            QU_LOG("skipping unsafe path: %s", p ?: "");
            archive_read_data_skip(h.a);
            done++;
            continue;
        }

        // Encrypted entry without a usable password -> prompt upstream (code 5).
        // We check this before attempting data read so that "needs password" is
        // reported cleanly rather than surfacing as a data-block error.
        if (archive_entry_is_encrypted(entry) && password.length == 0) {
            if (error) {
                *error = [NSError errorWithDomain:@"QUArchive" code:5
                                         userInfo:@{ NSLocalizedDescriptionKey: @"压缩包已加密，需要密码" }];
            }
            QUCloseArchive(h);
            return NO;
        }

        NSString *fullPath = [destPath stringByAppendingPathComponent:relPath];
        mode_t mode = archive_entry_mode(entry);
        mode_t ft = mode & S_IFMT;

        if (ft == S_IFDIR) {
            NSError *mkErr = nil;
            if (![fm createDirectoryAtPath:fullPath
                       withIntermediateDirectories:YES
                                        attributes:nil
                                             error:&mkErr]) {
                QU_LOG("mkdir failed for '%s': %s",
                       fullPath.UTF8String, mkErr.localizedDescription.UTF8String);
            }
            // Directories have no data payload; advance anyway (harmless).
            archive_read_data_skip(h.a);
        } else if (ft == S_IFREG || ft == 0) {
            // Regular file (treat unknown type bits as regular, matching
            // libarchive's own fallback behavior for malformed headers).
            NSString *parent = [fullPath stringByDeletingLastPathComponent];
            if (parent.length > 0 && ![fm fileExistsAtPath:parent]) {
                [fm createDirectoryAtPath:parent
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
            }

            int fd = open(fullPath.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd < 0) {
                QU_LOG("open failed for '%s': %s", fullPath.UTF8String, strerror(errno));
                archive_read_data_skip(h.a);
                done++;
                continue;
            }

            const void *buff = NULL;
            size_t sz = 0;
            int64_t off = 0;
            int br;
            BOOL dataError = NO;
            while ((br = archive_read_data_block(h.a, &buff, &sz, &off)) == QU_ARCHIVE_OK) {
                if (sz == 0) continue;
                ssize_t w = write(fd, buff, sz);
                if (w < 0 || (size_t)w != sz) {
                    QU_LOG("write failed for '%s': %s",
                           fullPath.UTF8String, strerror(errno));
                    dataError = YES;
                    break;
                }
            }
            if (br != QU_ARCHIVE_EOF) {
                // Non-EOF terminations (e.g. ARCHIVE_FATAL) usually mean the
                // password was wrong for an encrypted entry, or the archive is
                // corrupt mid-stream. For encrypted entries, surface code 5 so
                // the UI re-prompts for the password.
                dataError = YES;
                if (archive_entry_is_encrypted(entry)) {
                    close(fd);
                    if (error) {
                        *error = [NSError errorWithDomain:@"QUArchive" code:5
                                                 userInfo:@{ NSLocalizedDescriptionKey: @"压缩包已加密，密码错误" }];
                    }
                    QUCloseArchive(h);
                    return NO;
                }
                const char *msg = archive_error_string(h.a);
                QU_LOG("data read failed for '%s': %s", p ?: "", msg ?: "unknown");
            }

            // Best-effort mtime restoration.
            time_t mt = archive_entry_mtime(entry);
            if (mt != 0) {
                struct timeval times[2] = {
                    { .tv_sec = mt, .tv_usec = 0 },
                    { .tv_sec = mt, .tv_usec = 0 }
                };
                futimes(fd, times);
            }
            close(fd);

            // Best-effort permission restoration (after close, via path).
            mode_t perm = mode & 0777;
            if (perm != 0 && perm != 0644) {
                chmod(fullPath.UTF8String, perm);
            }
            (void)dataError;  // logged; extraction continues with next entry
        } else if (ft == S_IFLNK) {
            // Skip symlinks for security: a symlink target escaping destDir
            // could let a malicious archive clobber arbitrary user files.
            const char *target = archive_entry_symlink(entry);
            QU_LOG("skipping symlink '%s' -> '%s'", p ?: "", target ?: "");
            archive_read_data_skip(h.a);
        } else {
            // FIFO / socket / character device / block device — not representable
            // on a regular filesystem extract anyway. Skip and log.
            QU_LOG("skipping special file (mode=%o) '%s'", mode, p ?: "");
            archive_read_data_skip(h.a);
        }

        done++;
    }

    int finalCode = r;
    const char *finalMsg = (finalCode != QU_ARCHIVE_EOF) ? archive_error_string(h.a) : NULL;
    NSString *finalMsgStr = finalMsg ? [NSString stringWithUTF8String:finalMsg] : nil;
    QUCloseArchive(h);

    if (finalCode != QU_ARCHIVE_EOF) {
        if (error) {
            *error = [NSError errorWithDomain:@"QUArchive" code:6
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                                 [NSString stringWithFormat:@"解压中断: %@",
                                                  finalMsgStr ?: @"unknown"] }];
        }
        return NO;
    }
    if (progress) progress(1.0, @"");
    return YES;
}

- (BOOL)extractEntryAtPath:(NSString *)entryPath
                toDirectory:(NSURL *)destDir
                  password:(NSString *)password
                     error:(NSError **)error {
    // Validate path safety up front (same rules as the bulk extractor).
    if (entryPath.length == 0 ||
        [entryPath hasPrefix:@"/"] ||
        [entryPath isEqualToString:@".."] ||
        [entryPath hasPrefix:@"../"] ||
        [entryPath containsString:@"/../"] ||
        [entryPath hasSuffix:@"/.."]) {
        if (error) {
            *error = [NSError errorWithDomain:@"QUArchive" code:7
                                     userInfo:@{ NSLocalizedDescriptionKey: @"条目路径不安全" }];
        }
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![destDir checkResourceIsReachableAndReturnError:nil]) {
        NSError *mkErr = nil;
        if (![fm createDirectoryAtURL:destDir withIntermediateDirectories:YES attributes:nil error:&mkErr]) {
            if (error) *error = mkErr;
            return NO;
        }
    }

    QUArchiveHandle h = QUOpenArchive(self.fileURL, password, error);
    if (h.a == NULL) return NO;

    NSString *destPath = destDir.path;
    struct archive_entry *entry = NULL;
    int r;
    BOOL found = NO;
    while ((r = archive_read_next_header(h.a, &entry)) == QU_ARCHIVE_OK) {
        const char *p = archive_entry_pathname(entry);
        NSString *relPath = p ? [NSString stringWithUTF8String:p] : @"";
        if (![relPath isEqualToString:entryPath]) {
            archive_read_data_skip(h.a);
            continue;
        }
        found = YES;

        // Encrypted entry without password -> code 5.
        if (archive_entry_is_encrypted(entry) && password.length == 0) {
            if (error) {
                *error = [NSError errorWithDomain:@"QUArchive" code:5
                                         userInfo:@{ NSLocalizedDescriptionKey: @"压缩包已加密，需要密码" }];
            }
            QUCloseArchive(h);
            return NO;
        }

        NSString *fullPath = [destPath stringByAppendingPathComponent:relPath];
        mode_t mode = archive_entry_mode(entry);
        mode_t ft = mode & S_IFMT;

        if (ft == S_IFDIR) {
            [fm createDirectoryAtPath:fullPath withIntermediateDirectories:YES attributes:nil error:nil];
        } else if (ft == S_IFREG || ft == 0) {
            NSString *parent = [fullPath stringByDeletingLastPathComponent];
            if (parent.length > 0 && ![fm fileExistsAtPath:parent]) {
                [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
            }
            int fd = open(fullPath.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd < 0) {
                QU_LOG("single-extract open failed for '%s': %s", fullPath.UTF8String, strerror(errno));
                QUCloseArchive(h);
                if (error) {
                    *error = [NSError errorWithDomain:@"QUArchive" code:8
                                             userInfo:@{ NSLocalizedDescriptionKey:
                                                         [NSString stringWithFormat:@"无法创建文件: %s", strerror(errno)] }];
                }
                return NO;
            }
            const void *buff = NULL;
            size_t sz = 0;
            int64_t off = 0;
            int br;
            while ((br = archive_read_data_block(h.a, &buff, &sz, &off)) == QU_ARCHIVE_OK) {
                if (sz == 0) continue;
                ssize_t w = write(fd, buff, sz);
                if (w < 0 || (size_t)w != sz) {
                    QU_LOG("single-extract write failed for '%s': %s", fullPath.UTF8String, strerror(errno));
                    break;
                }
            }
            if (br != QU_ARCHIVE_EOF) {
                if (archive_entry_is_encrypted(entry)) {
                    close(fd);
                    QUCloseArchive(h);
                    if (error) {
                        *error = [NSError errorWithDomain:@"QUArchive" code:5
                                                 userInfo:@{ NSLocalizedDescriptionKey: @"压缩包已加密，密码错误" }];
                    }
                    return NO;
                }
            }
            time_t mt = archive_entry_mtime(entry);
            if (mt != 0) {
                struct timeval times[2] = {
                    { .tv_sec = mt, .tv_usec = 0 },
                    { .tv_sec = mt, .tv_usec = 0 }
                };
                futimes(fd, times);
            }
            close(fd);
            mode_t perm = mode & 0777;
            if (perm != 0 && perm != 0644) {
                chmod(fullPath.UTF8String, perm);
            }
        } else {
            // Symlinks and special files are not extractable to a previewable
            // regular file; treat as "not found" for preview purposes.
            QUCloseArchive(h);
            if (error) {
                *error = [NSError errorWithDomain:@"QUArchive" code:7
                                         userInfo:@{ NSLocalizedDescriptionKey: @"此类型条目不支持预览" }];
            }
            return NO;
        }
        break;
    }

    QUCloseArchive(h);

    if (!found) {
        if (error) {
            *error = [NSError errorWithDomain:@"QUArchive" code:7
                                     userInfo:@{ NSLocalizedDescriptionKey: @"未找到指定条目" }];
        }
        return NO;
    }
    if (r != QU_ARCHIVE_OK && r != QU_ARCHIVE_EOF) {
        const char *msg = archive_error_string(h.a);
        if (error) {
            *error = [NSError errorWithDomain:@"QUArchive" code:4
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                                 [NSString stringWithFormat:@"读取条目失败: %s", msg ?: "unknown"] }];
        }
        return NO;
    }
    return YES;
}

@end
