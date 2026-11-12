#import <AppKit/AppKit.h>

@interface UpdateController : NSObject <NSURLSessionTaskDelegate>
- (void)checkForUpdates:(BOOL)interactive;
@end
