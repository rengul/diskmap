#import "UpdateController.h"
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#include <unistd.h>

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
@property(strong) NSWindow *progressWindow;
@property(strong) NSProgressIndicator *progressIndicator;
@property(strong) NSTextField *progressLabel;
@property(strong) NSTimer *progressTimer;
@property(strong) NSURLSessionDownloadTask *downloadTask;
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
        alert.informativeText = [NSString stringWithFormat:@"Disk Map %@ is available. You have version %@. Download and install the update?", release[@"version"], current];
        [alert addButtonWithTitle:@"Download and Install"];
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
- (void)showDownloadProgress {
    self.progressWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 380, 110)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    self.progressWindow.title = @"Updating Disk Map";
    self.progressLabel = [NSTextField labelWithString:@"Downloading update…"];
    self.progressLabel.frame = NSMakeRect(20, 65, 340, 20);
    [self.progressWindow.contentView addSubview:self.progressLabel];
    self.progressIndicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 30, 340, 20)];
    self.progressIndicator.indeterminate = YES;
    [self.progressIndicator startAnimation:nil];
    [self.progressWindow.contentView addSubview:self.progressIndicator];
    [self.progressWindow center];
    [self.progressWindow makeKeyAndOrderFront:nil];
    self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        NSProgress *progress = self.downloadTask.progress;
        if (progress.totalUnitCount > 0) {
            self.progressIndicator.indeterminate = NO;
            self.progressIndicator.doubleValue = progress.fractionCompleted * 100;
            self.progressLabel.stringValue = [NSString stringWithFormat:@"Downloading update… %.0f%%", progress.fractionCompleted * 100];
        }
    }];
}
- (void)finishProgress {
    [self.progressTimer invalidate];
    self.progressTimer = nil;
    self.downloadTask = nil;
    [self.progressWindow close];
    self.progressWindow = nil;
}
- (BOOL)runTool:(NSString *)tool arguments:(NSArray<NSString *> *)arguments {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:tool];
    task.arguments = arguments;
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return NO;
    [task waitUntilExit];
    return task.terminationStatus == 0;
}
- (NSString *)prepareUpdate:(NSURL *)archive release:(NSDictionary *)release staged:(NSURL **)stagedOut {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *appURL = NSBundle.mainBundle.bundleURL.URLByStandardizingPath;
    NSURL *parent = appURL.URLByDeletingLastPathComponent;
    if (![appURL.pathExtension.lowercaseString isEqualToString:@"app"] ||
        ![fm isWritableFileAtPath:parent.path])
        return @"The application folder is not writable. Move Disk Map to a writable Applications folder and try again.";
    NSURL *work = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    if (![fm createDirectoryAtURL:work withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions: @0700} error:nil])
        return @"Could not prepare the update.";
    NSString *failure = nil;
    NSURL *staged = nil;
    do {
        if (![self runTool:@"/usr/bin/ditto" arguments:@[@"-x", @"-k", archive.path, work.path]]) {
            failure = @"The update archive could not be extracted."; break;
        }
        NSArray<NSURL *> *contents = [fm contentsOfDirectoryAtURL:work includingPropertiesForKeys:nil options:0 error:nil];
        if (contents.count != 1 || ![contents.firstObject.lastPathComponent isEqualToString:@"DiskMap.app"]) {
            failure = @"The update archive has an unexpected structure."; break;
        }
        NSURL *candidate = contents.firstObject;
        NSBundle *bundle = [NSBundle bundleWithURL:candidate];
        if (![bundle.bundleIdentifier isEqualToString:NSBundle.mainBundle.bundleIdentifier] ||
            ![[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqualToString:release[@"version"]]) {
            failure = @"The downloaded app has an unexpected identity or version."; break;
        }
        SecStaticCodeRef code = NULL;
        SecRequirementRef requirement = NULL;
        OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)candidate, kSecCSDefaultFlags, &code);
        if (status == errSecSuccess) status = SecRequirementCreateWithString(CFSTR("anchor apple generic and certificate leaf[subject.OU] = HU9QF2HFVB"), kSecCSDefaultFlags, &requirement);
        if (status == errSecSuccess) status = SecStaticCodeCheckValidity(code, kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate, requirement);
        if (code) CFRelease(code);
        if (requirement) CFRelease(requirement);
        if (status != errSecSuccess) { failure = @"The downloaded app has an invalid developer signature."; break; }
        staged = [parent URLByAppendingPathComponent:[NSString stringWithFormat:@".DiskMap-update-%@.app", NSUUID.UUID.UUIDString] isDirectory:YES];
        if (![self runTool:@"/usr/bin/ditto" arguments:@[candidate.path, staged.path]]) {
            failure = @"Could not prepare the update in the application folder."; break;
        }
    } while (NO);
    [fm removeItemAtURL:work error:nil];
    if (failure && staged) [fm removeItemAtURL:staged error:nil];
    if (!failure) *stagedOut = staged;
    return failure;
}
- (void)installStagedUpdate:(NSURL *)staged {
    NSURL *app = NSBundle.mainBundle.bundleURL.URLByStandardizingPath;
    NSURL *backup = [app.URLByDeletingLastPathComponent URLByAppendingPathComponent:
        [NSString stringWithFormat:@".DiskMap-backup-%@.app", NSUUID.UUID.UUIDString]];
    // The helper only replaces the bundle after this process has actually exited.
    NSString *script = @"pid=$1; app=$2; staged=$3; backup=$4; i=0\n"
        "while kill -0 \"$pid\" 2>/dev/null; do i=$((i+1)); if [ \"$i\" -ge 120 ]; then /bin/rm -rf -- \"$staged\"; exit 1; fi; /bin/sleep 1; done\n"
        "if /bin/mv -- \"$app\" \"$backup\"; then\n"
        "  if /bin/mv -- \"$staged\" \"$app\"; then\n"
        "    if /usr/bin/open \"$app\"; then /bin/rm -rf -- \"$backup\"; exit 0; fi\n"
        "    /bin/mv -- \"$app\" \"$staged\" || exit 1\n"
        "  fi\n"
        "  /bin/mv -- \"$backup\" \"$app\"\n"
        "fi\n"
        "/bin/rm -rf -- \"$staged\"\n"
        "/usr/bin/open \"$app\"\n"
        "/usr/bin/osascript -e 'display alert \"Disk Map update failed\" message \"The previous version was restored. Please try again.\" as critical'\n";
    NSTask *helper = [NSTask new];
    helper.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    helper.arguments = @[@"-c", script, @"diskmap-updater", [NSString stringWithFormat:@"%d", getpid()], app.path, staged.path, backup.path];
    NSError *error = nil;
    if (![helper launchAndReturnError:&error]) {
        [NSFileManager.defaultManager removeItemAtURL:staged error:nil];
        self.busy = NO;
        [self message:@"Installation Failed" detail:@"Could not start the update installer."];
        return;
    }
    [NSApp terminate:nil];
}
- (void)downloadRelease:(NSDictionary *)release {
    [self showDownloadProgress];
    NSURL *url = [NSURL URLWithString:release[@"url"]];
    self.downloadTask = [self.session downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        NSString *failure = nil;
        NSURL *staged = nil;
        if (error || ![response isKindOfClass:NSHTTPURLResponse.class] || ((NSHTTPURLResponse *)response).statusCode != 200 || !location) {
            failure = @"The update could not be downloaded.";
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.progressTimer invalidate]; self.progressTimer = nil;
                self.progressIndicator.indeterminate = YES;
                [self.progressIndicator startAnimation:nil];
                self.progressLabel.stringValue = @"Verifying and preparing update…";
            });
            NSInputStream *stream = [NSInputStream inputStreamWithURL:location];
            [stream open];
            CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx);
            uint8_t buffer[65536]; NSInteger count;
            while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) CC_SHA256_Update(&ctx, buffer, (CC_LONG)count);
            [stream close];
            unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &ctx);
            NSMutableString *hash = [NSMutableString string];
            for (NSUInteger i = 0; i < sizeof(digest); i++) [hash appendFormat:@"%02x", digest[i]];
            if (count < 0 || [hash caseInsensitiveCompare:release[@"sha256"]] != NSOrderedSame)
                failure = @"The downloaded file failed its integrity check.";
            else failure = [self prepareUpdate:location release:release staged:&staged];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishProgress];
            if (failure) { self.busy = NO; [self message:@"Update Failed" detail:failure]; }
            else [self installStagedUpdate:staged];
        });
    }];
    [self.downloadTask resume];
}
@end
