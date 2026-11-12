#import "UpdateController.h"
#import <CommonCrypto/CommonDigest.h>

static NSString * const UpdateEndpoint = @"https://yqg6jl3fmi.execute-api.eu-south-1.amazonaws.com/Prod/rengul/v1/public/apps/7bb48168-ad2d-4d09-90a2-94400928e697/latest";
static NSString * const UpdateBundleID = @"net.rengul.diskmap";
static NSString * const UpdateTeamID = @"HU9QF2HFVB";

static BOOL ValidVersion(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length]) return NO;
    NSArray *parts = [value componentsSeparatedByString:@"."];
    if (parts.count > 3) return NO;
    NSCharacterSet *invalid = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    for (NSString *part in parts) {
        if (!part.length || part.length > 9 || [part rangeOfCharacterFromSet:invalid].location != NSNotFound) return NO;
    }
    return YES;
}

static NSComparisonResult CompareVersions(NSString *a, NSString *b) {
    NSArray *left = [a componentsSeparatedByString:@"."];
    NSArray *right = [b componentsSeparatedByString:@"."];
    for (NSUInteger i = 0; i < MAX(left.count, right.count); i++) {
        NSInteger x = i < left.count ? [left[i] integerValue] : 0;
        NSInteger y = i < right.count ? [right[i] integerValue] : 0;
        if (x != y) return x < y ? NSOrderedAscending : NSOrderedDescending;
    }
    return NSOrderedSame;
}

@interface UpdateController ()
@property(strong) NSURLSession *session;
@property(assign) BOOL busy;
@end

@implementation UpdateController
- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        config.timeoutIntervalForRequest = 30;
        _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    }
    return self;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    (void)session; (void)task; (void)response;
    completionHandler([request.URL.scheme.lowercaseString isEqualToString:@"https"] ? request : nil);
}
- (void)message:(NSString *)title detail:(NSString *)detail {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = detail;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}
- (void)fetchRelease:(void (^)(NSDictionary *, NSString *))completion {
    NSURL *url = [NSURL URLWithString:UpdateEndpoint];
    [[self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *failure = nil;
        NSDictionary *release = nil;
        if (error || ![response isKindOfClass:NSHTTPURLResponse.class] || ((NSHTTPURLResponse *)response).statusCode != 200) {
            failure = @"Could not contact the update server. Please try again later.";
        } else {
            id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if ([json isKindOfClass:NSDictionary.class]) release = json;
            id checksum = release[@"sha256"];
            id link = release[@"url"];
            NSURL *downloadURL = [link isKindOfClass:NSString.class] ? [NSURL URLWithString:link] : nil;
            NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
            if (![release[@"bundleId"] isEqual:UpdateBundleID] || ![release[@"teamIdentifier"] isEqual:UpdateTeamID] ||
                !ValidVersion(release[@"version"]) || !ValidVersion(release[@"minimumMacOS"]) ||
                ![checksum isKindOfClass:NSString.class] || [checksum length] != 64 ||
                [checksum rangeOfCharacterFromSet:nonHex].location != NSNotFound ||
                ![downloadURL.scheme.lowercaseString isEqualToString:@"https"] || !downloadURL.host.length) {
                failure = @"The update server returned invalid release information.";
                release = nil;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(release, failure); });
    }] resume];
}
- (void)checkForUpdates:(BOOL)interactive {
    if (self.busy) return;
    self.busy = YES;
    [self fetchRelease:^(NSDictionary *release, NSString *error) {
        if (error) {
            self.busy = NO;
            if (interactive) [self message:@"Update Check Failed" detail:error];
            return;
        }
        NSString *current = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0.0";
        if (!ValidVersion(current) || CompareVersions(release[@"version"], current) != NSOrderedDescending) {
            self.busy = NO;
            if (interactive) [self message:@"Disk Map Is Up to Date" detail:[NSString stringWithFormat:@"You have version %@.", current]];
            return;
        }
        NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
        NSString *system = [NSString stringWithFormat:@"%ld.%ld.%ld", (long)os.majorVersion, (long)os.minorVersion, (long)os.patchVersion];
        if (CompareVersions(system, release[@"minimumMacOS"]) == NSOrderedAscending) {
            self.busy = NO;
            [self message:@"Update Requires a Newer macOS" detail:[NSString stringWithFormat:@"Disk Map %@ requires macOS %@ or later.", release[@"version"], release[@"minimumMacOS"]]];
            return;
        }
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"A New Version Is Available";
        alert.informativeText = [NSString stringWithFormat:@"Disk Map %@ is available. You have version %@. Download the update?", release[@"version"], current];
        [alert addButtonWithTitle:@"Download"];
        [alert addButtonWithTitle:@"Later"];
        if ([alert runModal] != NSAlertFirstButtonReturn) { self.busy = NO; return; }
        // Fetch a fresh signed URL after the user decides, since URLs expire.
        [self fetchRelease:^(NSDictionary *fresh, NSString *fetchError) {
            if (fetchError || ![fresh[@"version"] isEqual:release[@"version"]] ||
                [fresh[@"sha256"] caseInsensitiveCompare:release[@"sha256"]] != NSOrderedSame ||
                CompareVersions(system, fresh[@"minimumMacOS"]) == NSOrderedAscending) {
                self.busy = NO;
                [self message:@"Download Failed" detail:fetchError ?: @"The release changed. Please check for updates again."];
                return;
            }
            [self downloadRelease:fresh];
        }];
    }];
}
- (void)downloadRelease:(NSDictionary *)release {
    NSURL *url = [NSURL URLWithString:release[@"url"]];
    [[self.session downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        NSString *failure = nil;
        NSURL *saved = nil;
        if (error || ![response isKindOfClass:NSHTTPURLResponse.class] || ((NSHTTPURLResponse *)response).statusCode != 200 || !location) {
            failure = @"The update could not be downloaded.";
        } else {
            NSInputStream *stream = [NSInputStream inputStreamWithURL:location];
            [stream open];
            CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx);
            uint8_t buffer[65536]; NSInteger count;
            while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) CC_SHA256_Update(&ctx, buffer, (CC_LONG)count);
            [stream close];
            unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &ctx);
            NSMutableString *hash = [NSMutableString string];
            for (NSUInteger i = 0; i < sizeof(digest); i++) [hash appendFormat:@"%02x", digest[i]];
            if (count < 0 || [hash caseInsensitiveCompare:release[@"sha256"]] != NSOrderedSame) {
                failure = @"The downloaded file failed its integrity check.";
            } else {
                NSURL *downloads = [NSFileManager.defaultManager URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject;
                NSString *name = [NSString stringWithFormat:@"DiskMap-%@-%@.zip", release[@"version"], NSUUID.UUID.UUIDString];
                saved = [downloads URLByAppendingPathComponent:name];
                NSError *saveError = nil;
                if (!saved || ![NSFileManager.defaultManager copyItemAtURL:location toURL:saved error:&saveError]) {
                    saved = nil; failure = @"The verified update could not be saved to Downloads.";
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            if (failure) [self message:@"Download Failed" detail:failure];
            else {
                [self message:@"Download Complete" detail:@"The verified update was saved to Downloads. Open the archive to install it."];
                [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[saved]];
            }
        });
    }] resume];
}
@end
