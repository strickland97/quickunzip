//
//  SmokeTest.m
//  Exercises QUArchiveReader (list + extract) against a sample archive.
//  Compiled together with ArchiveBridge.m and linked against system libarchive.
//  NOT part of the QuickUnzip app target; standalone CLI driver for testing.
//

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import "ArchiveBridge.h"

static NSString *SHA1OfFile(NSURL *url) {
    NSData *d = [NSData dataWithContentsOfURL:url];
    if (!d) return @"<missing>";
    unsigned char digest[20];
    CC_SHA1(d.bytes, (CC_LONG)d.length, digest);
    char hex[41];
    for (int i = 0; i < 20; i++) sprintf(hex + i*2, "%02x", digest[i]);
    return [NSString stringWithCString:hex encoding:NSUTF8StringEncoding];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: SmokeTest <archive> [password]\n");
            return 2;
        }
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSString *password = (argc >= 3) ? [NSString stringWithUTF8String:argv[2]] : nil;

        NSURL *outDir = [NSURL fileURLWithPath:@"/tmp/quickunzip_smoke/extracted"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtURL:outDir error:nil];
        [fm createDirectoryAtURL:outDir withIntermediateDirectories:YES attributes:nil error:nil];

        printf("=== Archive: %s ===\n", argv[1]);
        printf("Password: %s\n\n", password ? [password UTF8String] : "(none)");

        // --- 1. List ---
        QUArchiveReader *reader = [[QUArchiveReader alloc] initWithFileURL:url];
        NSError *listErr = nil;
        NSArray<QUArchiveEntry *> *entries = [reader listEntries:&listErr];
        if (!entries) {
            printf("[LIST FAILED] %s\n", listErr.localizedDescription.UTF8String);
            return 1;
        }
        printf("Listed %lu entries:\n", (unsigned long)entries.count);
        for (QUArchiveEntry *e in entries) {
            printf("  %-40s  %10lld bytes  %s%s\n",
                   e.pathname.UTF8String,
                   e.size,
                   e.isDirectory ? "DIR " : "FILE",
                   e.isEncrypted ? " ENCRYPTED" : "");
        }
        printf("\n");

        // --- 2. Extract ---
        NSError *extractErr = nil;
        __block NSUInteger callbackCount = 0;
        BOOL ok = [reader extractAllToDirectory:outDir
                                       password:password
                                       progress:^BOOL(double frac, NSString *path) {
            callbackCount++;
            return YES;
        }
                                          error:&extractErr];
        if (!ok) {
            printf("[EXTRACT FAILED] %s\n", extractErr.localizedDescription.UTF8String);
            return 1;
        }
        printf("Extracted OK (progress callbacks: %lu)\n", (unsigned long)callbackCount);

        // --- 3. Verify tree ---
        NSDirectoryEnumerator<NSURL *> *enu = [fm enumeratorAtURL:outDir
                                          includingPropertiesForKeys:@[NSURLFileSizeKey]
                                                             options:0
                                                        errorHandler:nil];
        NSUInteger fileCount = 0;
        NSMutableString *listing = [NSMutableString string];
        for (NSURL *u in enu) {
            NSNumber *size = nil;
            [u getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            NSString *rel = [u.path substringFromIndex:outDir.path.length];
            [listing appendFormat:@"  %s  %12lld bytes\n", rel.UTF8String, size.longLongValue];
            fileCount++;
        }
        printf("Extracted tree (%lu entries):\n%s", (unsigned long)fileCount, listing.UTF8String);

        // --- 4. Content spot-check ---
        NSURL *helloOut = [outDir URLByAppendingPathComponent:@"hello.txt"];
        NSString *sha = SHA1OfFile(helloOut);
        NSString *content = [NSString stringWithContentsOfURL:helloOut encoding:NSUTF8StringEncoding error:nil];
        printf("\nhello.txt SHA1: %s\n", sha.UTF8String);
        printf("hello.txt content: %s", [content stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]].UTF8String);
        printf("\n\n[PASS]\n");
        return 0;
    }
}
