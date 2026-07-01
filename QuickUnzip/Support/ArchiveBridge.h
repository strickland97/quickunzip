//
//  ArchiveBridge.h
//  QuickUnzip
//
//  Obj-C facade over the system libarchive (linked via libarchive.tbd).
//  libarchive's public header (archive.h) is not exposed in the macOS SDK,
//  so this bridge declares the subset of libarchive symbols we use and
//  exposes a small, Swift-friendly API.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One entry inside an archive.
@interface QUArchiveEntry : NSObject
@property (nonatomic, copy) NSString *pathname;
@property (nonatomic, assign) int64_t size;
@property (nonatomic, assign) int64_t mtime;       // unix seconds
@property (nonatomic, assign) BOOL isDirectory;
@property (nonatomic, assign) BOOL isEncrypted;
@end

/// Reads an archive using libarchive. Each scanning/extracting call opens
/// the archive fresh, so instances are effectively stateless beyond the URL.
@interface QUArchiveReader : NSObject

/// Stores the URL; never fails. Actual open/validation happens lazily inside
/// `listEntries:` / `extractAllToDirectory:password:progress:error:`.
- (instancetype)initWithFileURL:(NSURL *)fileURL;

/// Lists every entry. Returns nil on failure (error set).
- (nullable NSArray<QUArchiveEntry *> *)listEntries:(NSError * _Nullable * _Nullable)error;

/// Extracts every entry into `destDir` (created if missing).
/// `progress` is called on the calling thread with a 0..1 fraction and the
/// current entry pathname. Returning NO from `progress` cancels the extraction
/// (the bridge stops iterating and returns NO with error code 6). Returns YES
/// on full success.
- (BOOL)extractAllToDirectory:(NSURL *)destDir
                     password:(nullable NSString *)password
                     progress:(BOOL (^_Nullable)(double fraction, NSString *currentPath))progress
                        error:(NSError * _Nullable * _Nullable)error;

/// Extracts a single entry identified by `entryPath` into `destDir`.
/// `destDir` is created if missing. On success the extracted file lives at
/// `<destDir>/<entryPath>` (parent folders created as needed). Returns YES on
/// success. Error codes match `extractAllToDirectory:` (5 = needs password,
/// 7 = entry not found).
- (BOOL)extractEntryAtPath:(NSString *)entryPath
                toDirectory:(NSURL *)destDir
                  password:(nullable NSString *)password
                     error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
