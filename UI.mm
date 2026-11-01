#import <AppKit/AppKit.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

static const CGFloat DiskMapPalette[] = {0.15, 0.08, 0.78, 0.51, 0.94, 0.30, 0.60};

static NSColor *DiskMapRootColor(NSDictionary *item, NSInteger index) {
    if ([item[@"hiddenSpace"] boolValue]) {
        return [NSColor colorWithRed:0.72 green:0.20 blue:0.72 alpha:1];
    }
    if ([item[@"restricted"] boolValue]) {
        return [NSColor colorWithRed:0.86 green:0.25 blue:0.20 alpha:1];
    }
    return [NSColor colorWithHue:DiskMapPalette[index % 7]
                      saturation:0.78 brightness:0.96 alpha:1];
}

@interface HoverTableView : NSTableView
@property(assign) BOOL hoverSuppressed;
@property(weak) NSClipView *observedClipView;
@end

@implementation HoverTableView
- (void)viewDidMoveToSuperview {
    if (self.observedClipView) {
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:NSViewBoundsDidChangeNotification
                                                    object:self.observedClipView];
    }
    [super viewDidMoveToSuperview];
    NSClipView *clipView = self.enclosingScrollView.contentView;
    self.observedClipView = clipView;
    clipView.postsBoundsChangedNotifications = YES;
    if (clipView) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clipViewDidScroll:)
                                                   name:NSViewBoundsDidChangeNotification object:clipView];
    }
}
- (void)clipViewDidScroll:(NSNotification *)notification {
    (void)notification;
    self.hoverSuppressed = YES;
    [self setNeedsDisplay:YES];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(restoreHover) object:nil];
    [self performSelector:@selector(restoreHover) withObject:nil afterDelay:0.12];
}
- (void)restoreHover {
    self.hoverSuppressed = NO;
    [self setNeedsDisplay:YES];
}
- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
@end

@interface HoverTableRowView : NSTableRowView
@property(assign) BOOL mouseInside;
@property(strong) NSTrackingArea *hoverTrackingArea;
@end

@implementation HoverTableRowView
- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    [self setNeedsDisplay:YES];
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverTrackingArea) [self removeTrackingArea:self.hoverTrackingArea];
    NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited |
        NSTrackingActiveInActiveApp | NSTrackingInVisibleRect;
    self.hoverTrackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                          options:options owner:self userInfo:nil];
    [self addTrackingArea:self.hoverTrackingArea];
}
- (void)mouseEntered:(NSEvent *)event { (void)event; self.mouseInside = YES; [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)event { (void)event; self.mouseInside = NO; [self setNeedsDisplay:YES]; }
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    self.mouseInside = NO;
    [self setNeedsDisplay:YES];
}
- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    BOOL pointerIsInside = NO;
    HoverTableView *tableView = [self.superview isKindOfClass:HoverTableView.class]
        ? (HoverTableView *)self.superview : nil;
    if (!tableView.hoverSuppressed && self.window && NSApp.isActive && self.window.isKeyWindow) {
        NSPoint localPoint = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
        pointerIsInside = NSPointInRect(localPoint, self.bounds);
    }
    self.mouseInside = pointerIsInside;
    if (!pointerIsInside && !self.isSelected) return;
    NSColor *fill = self.isSelected
        ? [NSColor colorWithRed:0.29 green:0.34 blue:0.39 alpha:1]
        : [NSColor colorWithRed:0.22 green:0.25 blue:0.29 alpha:0.72];
    [fill setFill];
    NSRectFill(self.bounds);
}
@end

@interface DirectoryNameCell : NSTableCellView
@property(strong) NSTextField *nameLabel;
@end


@implementation DirectoryNameCell
- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    self.nameLabel = [NSTextField labelWithString:@""];
    self.nameLabel.font = [NSFont systemFontOfSize:16 weight:NSFontWeightRegular];
    self.nameLabel.textColor = [NSColor colorWithWhite:0.91 alpha:1];
    self.nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.nameLabel.maximumNumberOfLines = 1;
    self.nameLabel.usesSingleLineMode = YES;
    self.nameLabel.cell.wraps = NO;
    self.nameLabel.cell.truncatesLastVisibleLine = YES;
    self.nameLabel.allowsDefaultTighteningForTruncation = YES;
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.nameLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
        [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
        [self.nameLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
    ]];
    return self;
}
@end

@interface DiskMapView : NSView
@property(copy) NSArray<NSDictionary *> *items;
@property(assign) NSInteger selectedIndex;
@property(strong) NSDictionary *selectedItem;
@property(strong) NSMutableArray<NSDictionary *> *hitSegments;
@property(strong) NSDictionary *hoveredItem;
@property(strong) NSTrackingArea *mapTrackingArea;
@property(weak) id actionTarget;
@property(copy) NSString *centerTitle;
@property(copy) NSString *centerSubtitle;
@end

@implementation DiskMapView
- (BOOL)isFlipped { return YES; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.mapTrackingArea) [self removeTrackingArea:self.mapTrackingArea];
    self.mapTrackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                NSTrackingActiveInActiveApp | NSTrackingInVisibleRect
          owner:self userInfo:nil];
    [self addTrackingArea:self.mapTrackingArea];
}

- (NSBezierPath *)wedgeAtCenter:(NSPoint)center inner:(CGFloat)inner outer:(CGFloat)outer
                           start:(CGFloat)start sweep:(CGFloat)sweep {
    NSBezierPath *path = [NSBezierPath bezierPath];
    [path appendBezierPathWithArcWithCenter:center radius:outer startAngle:start
                                   endAngle:start + sweep clockwise:NO];
    [path appendBezierPathWithArcWithCenter:center radius:inner startAngle:start + sweep
                                   endAngle:start clockwise:YES];
    [path closePath];
    return path;
}

- (void)drawItems:(NSArray<NSDictionary *> *)items start:(CGFloat)start sweep:(CGFloat)parentSweep
             depth:(NSInteger)depth center:(NSPoint)center inner:(CGFloat)inner
         ringWidth:(CGFloat)ringWidth rootHue:(CGFloat)rootHue {
    if (depth >= 4 || items.count == 0 || parentSweep < 0.35) return;
    double total = 0;
    for (NSDictionary *item in items) total += [item[@"physicalBytes"] doubleValue];
    if (total <= 0) return;
    CGFloat angle = start;
    for (NSInteger index = 0; index < (NSInteger)items.count; ++index) {
        NSDictionary *item = items[index];
        CGFloat sweep = parentSweep * [item[@"physicalBytes"] doubleValue] / total;
        if (sweep < 0.18) { angle += sweep; continue; }
        CGFloat lower = inner + depth * ringWidth;
        NSBezierPath *wedge = [self wedgeAtCenter:center inner:lower + 1
                                            outer:lower + ringWidth - 1 start:angle sweep:sweep];
        CGFloat hue = depth == 0 ? DiskMapPalette[index % 7] : rootHue;
        CGFloat brightness = MAX(0.50, 0.96 - depth * 0.095);
        NSColor *fill = [item[@"restricted"] boolValue]
            ? [NSColor colorWithRed:0.86 green:0.25 blue:0.20 alpha:1]
            : [NSColor colorWithHue:hue saturation:MAX(0.48, 0.78 - depth * 0.055)
                          brightness:brightness alpha:1];
        [fill setFill];
        [wedge fill];
        if ([item isEqual:self.selectedItem] || [item isEqual:self.hoveredItem]) {
            [NSColor.whiteColor setStroke];
            wedge.lineWidth = [item isEqual:self.selectedItem] ? 3 : 2;
            [wedge stroke];
        }
        [self.hitSegments addObject:@{@"item": item, @"path": wedge}];
        NSArray *children = item[@"children"];
        if ([children isKindOfClass:NSArray.class] && children.count > 0) {
            [self drawItems:children start:angle sweep:sweep depth:depth + 1 center:center
                       inner:inner ringWidth:ringWidth rootHue:hue];
        }
        angle += sweep;
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    [[NSColor colorWithRed:0.105 green:0.115 blue:0.135 alpha:1] setFill];
    NSRectFill(self.bounds);
    if (self.items.count == 0) return;
    NSPoint center = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
    CGFloat outer = MIN(NSWidth(self.bounds), NSHeight(self.bounds)) * 0.475;
    CGFloat inner = outer * 0.255;
    double total = 0;
    for (NSDictionary *item in self.items) total += [item[@"physicalBytes"] doubleValue];
    if (total <= 0) return;
    self.hitSegments = [NSMutableArray array];
    [self drawItems:self.items start:-90 sweep:360 depth:0 center:center inner:inner
           ringWidth:(outer - inner) / 4.0 rootHue:0];
    NSString *title = self.centerTitle.length ? self.centerTitle : @"Disk Map";
    NSString *size = self.centerSubtitle.length ? self.centerSubtitle :
        [NSByteCountFormatter stringFromByteCount:(long long)total countStyle:NSByteCountFormatterCountStyleFile];
    NSMutableParagraphStyle *centeredText = [NSMutableParagraphStyle new];
    centeredText.alignment = NSTextAlignmentCenter;
    centeredText.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *titleAttributes = @{NSForegroundColorAttributeName:[NSColor colorWithWhite:0.95 alpha:1],
        NSFontAttributeName:[NSFont systemFontOfSize:17 weight:NSFontWeightMedium],
        NSParagraphStyleAttributeName:centeredText};
    NSDictionary *sizeAttributes = @{NSForegroundColorAttributeName:[NSColor colorWithWhite:0.66 alpha:1],
        NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular],
        NSParagraphStyleAttributeName:centeredText};
    CGFloat textWidth = MAX(64.0, inner * 1.62);
    NSRect titleRect = NSMakeRect(center.x - textWidth / 2.0, center.y - 19, textWidth, 22);
    NSRect sizeRect = NSMakeRect(center.x - textWidth / 2.0, center.y + 5, textWidth, 18);
    [title drawInRect:titleRect withAttributes:titleAttributes];
    [size drawInRect:sizeRect withAttributes:sizeAttributes];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSDictionary *hit = nil;
    for (NSDictionary *segment in self.hitSegments.reverseObjectEnumerator) {
        if ([segment[@"path"] containsPoint:point]) { hit = segment; break; }
    }
    if (!hit) return;
    self.selectedItem = hit[@"item"];
    self.selectedIndex = [self.items indexOfObjectIdenticalTo:self.selectedItem];
    [self setNeedsDisplay:YES];
    SEL action = event.clickCount > 1 ? @selector(openSelectedMapItem:) : @selector(selectMapItem:);
    [NSApp sendAction:action to:self.actionTarget from:self];
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSDictionary *item = nil;
    for (NSDictionary *segment in self.hitSegments.reverseObjectEnumerator) {
        if ([segment[@"path"] containsPoint:point]) {
            item = segment[@"item"];
            break;
        }
    }
    if (item == self.hoveredItem) return;
    self.hoveredItem = item;
    [self setNeedsDisplay:YES];
    [NSApp sendAction:@selector(hoverMapItem:) to:self.actionTarget from:self];
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    if (!self.hoveredItem) return;
    self.hoveredItem = nil;
    [self setNeedsDisplay:YES];
    [NSApp sendAction:@selector(hoverMapItem:) to:self.actionTarget from:self];
}
@end

@interface ColorProgressView : NSView
@property(nonatomic, assign) double minValue;
@property(nonatomic, assign) double maxValue;
@property(nonatomic, assign) double doubleValue;
@property(nonatomic, strong) NSColor *fillColor;
- (void)startAnimation:(id)sender;
- (void)stopAnimation:(id)sender;
@end

@implementation ColorProgressView
- (BOOL)isFlipped { return YES; }
- (void)setDoubleValue:(double)value { _doubleValue = value; [self setNeedsDisplay:YES]; }
- (void)setMaxValue:(double)value { _maxValue = value; [self setNeedsDisplay:YES]; }
- (void)setFillColor:(NSColor *)color { _fillColor = color; [self setNeedsDisplay:YES]; }
- (void)startAnimation:(id)sender { (void)sender; }
- (void)stopAnimation:(id)sender { (void)sender; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect track = NSInsetRect(self.bounds, 0, 0.5);
    NSBezierPath *trackPath = [NSBezierPath bezierPathWithRoundedRect:track xRadius:3 yRadius:3];
    [[NSColor colorWithWhite:0.27 alpha:1] setFill];
    [trackPath fill];
    [[NSColor colorWithWhite:0.42 alpha:0.9] setStroke];
    trackPath.lineWidth = 1;
    [trackPath stroke];
    double span = MAX(1.0, self.maxValue - self.minValue);
    double fraction = MIN(1.0, MAX(0.0, (self.doubleValue - self.minValue) / span));
    if (fraction > 0) {
        NSRect fill = track;
        fill.size.width *= fraction;
        [(self.fillColor ?: NSColor.systemBlueColor) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:2 yRadius:2] fill];
    }
}
@end

@interface DockProgressView : NSView
@property(strong) NSImage *applicationIcon;
@property(nonatomic, assign) double progressValue;
@end

@implementation DockProgressView
- (BOOL)isOpaque { return NO; }
- (void)setProgressValue:(double)value {
    _progressValue = MIN(1.0, MAX(0.0, value));
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [self.applicationIcon drawInRect:self.bounds fromRect:NSZeroRect
                           operation:NSCompositingOperationSourceOver fraction:1.0];

    CGFloat side = MIN(NSWidth(self.bounds), NSHeight(self.bounds));
    CGFloat radius = side * 0.245;
    NSPoint center = NSMakePoint(NSMaxX(self.bounds) - radius - side * 0.055,
                                 NSMinY(self.bounds) + radius + side * 0.055);
    NSRect badgeRect = NSMakeRect(center.x - radius, center.y - radius,
                                  radius * 2, radius * 2);
    NSBezierPath *badge = [NSBezierPath bezierPathWithOvalInRect:badgeRect];
    [[NSColor colorWithRed:0.075 green:0.082 blue:0.096 alpha:0.96] setFill];
    [badge fill];
    [[NSColor colorWithWhite:0.72 alpha:0.85] setStroke];
    badge.lineWidth = MAX(1.0, side * 0.012);
    [badge stroke];

    CGFloat ringInset = side * 0.045;
    NSRect ringRect = NSInsetRect(badgeRect, ringInset, ringInset);
    NSBezierPath *track = [NSBezierPath bezierPathWithOvalInRect:ringRect];
    [[NSColor colorWithWhite:0.25 alpha:0.95] setStroke];
    track.lineWidth = MAX(2.0, side * 0.038);
    [track stroke];

    if (self.progressValue > 0) {
        NSBezierPath *arc = [NSBezierPath bezierPath];
        [arc appendBezierPathWithArcWithCenter:center radius:NSWidth(ringRect) / 2.0
                                    startAngle:90 endAngle:90 - self.progressValue * 360
                                     clockwise:YES];
        [[NSColor colorWithRed:0.30 green:0.56 blue:0.98 alpha:1] setStroke];
        arc.lineWidth = track.lineWidth;
        arc.lineCapStyle = NSLineCapStyleRound;
        [arc stroke];
    }

    NSString *percentage = [NSString stringWithFormat:@"%.0f", self.progressValue * 100];
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:side * 0.16
                                                              weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.whiteColor,
        NSParagraphStyleAttributeName: paragraph
    };
    NSSize textSize = [percentage sizeWithAttributes:attributes];
    NSRect textRect = NSMakeRect(NSMinX(badgeRect), center.y - textSize.height / 2.0,
                                 NSWidth(badgeRect), textSize.height + 2);
    [percentage drawInRect:textRect withAttributes:attributes];
}
@end

@interface BreadcrumbView : NSView
@property(copy) NSArray<NSDictionary *> *nodes;
@property(strong) NSMutableArray<NSDictionary *> *hitItems;
@property(weak) id actionTarget;
@end

@implementation BreadcrumbView
- (BOOL)isFlipped { return YES; }

- (NSString *)titleForNode:(NSDictionary *)node {
    NSString *path = node[@"path"];
    NSString *name = node[@"name"];
    if ([path isEqualToString:@"/"]) {
        NSString *volume = [[NSFileManager defaultManager] displayNameAtPath:path];
        return volume.length ? volume : @"Startup Disk";
    }
    if (!name.length || [name isEqualToString:path]) name = path.lastPathComponent;
    return name.length ? name : @"Folder";
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor colorWithRed:0.125 green:0.14 blue:0.165 alpha:1] setFill];
    NSRectFill(self.bounds);
    self.hitItems = [NSMutableArray array];
    if (!self.nodes.count) return;

    NSDictionary *attrs = @{NSFontAttributeName:[NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium]};
    NSMutableArray<NSDictionary *> *parts = [NSMutableArray array];
    CGFloat required = 8;
    for (NSInteger index = 0; index < (NSInteger)self.nodes.count; ++index) {
        NSString *title = [self titleForNode:self.nodes[index]];
        CGFloat width = MIN(150, [title sizeWithAttributes:attrs].width + 24);
        [parts addObject:@{@"nodeIndex": @(index), @"title": title, @"width": @(width)}];
        required += width + 2;
    }
    while (required > NSWidth(self.bounds) && parts.count > 3) {
        required -= [parts[1][@"width"] doubleValue] + 2;
        [parts removeObjectAtIndex:1];
    }
    if (parts.count < self.nodes.count) {
        [parts insertObject:@{@"nodeIndex": @(-1), @"title": @"…", @"width": @34} atIndex:1];
    }

    CGFloat x = 6;
    for (NSInteger partIndex = 0; partIndex < (NSInteger)parts.count; ++partIndex) {
        NSDictionary *part = parts[partIndex];
        CGFloat width = [part[@"width"] doubleValue];
        NSRect rect = NSMakeRect(x, 3, width, NSHeight(self.bounds) - 6);
        BOOL current = partIndex == (NSInteger)parts.count - 1;
        NSColor *fill = current
            ? [NSColor colorWithRed:0.20 green:0.42 blue:0.78 alpha:1]
            : [NSColor colorWithRed:0.17 green:0.19 blue:0.22 alpha:1];
        [fill setFill];
        [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:4 yRadius:4] fill];
        NSString *title = part[@"title"];
        NSMutableDictionary *textAttrs = [attrs mutableCopy];
        textAttrs[NSForegroundColorAttributeName] = current
            ? NSColor.whiteColor : [NSColor colorWithWhite:0.82 alpha:1];
        NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
        paragraph.alignment = NSTextAlignmentCenter;
        paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
        textAttrs[NSParagraphStyleAttributeName] = paragraph;
        CGFloat lineHeight = [title sizeWithAttributes:textAttrs].height;
        NSRect textRect = NSMakeRect(NSMinX(rect) + 9,
                                     NSMidY(rect) - lineHeight / 2,
                                     MAX(0, NSWidth(rect) - 18), lineHeight + 2);
        [title drawInRect:textRect withAttributes:textAttrs];
        if (partIndex < (NSInteger)parts.count - 1) {
            [[NSColor colorWithWhite:0.38 alpha:1] setStroke];
            NSBezierPath *chevron = [NSBezierPath bezierPath];
            [chevron moveToPoint:NSMakePoint(NSMaxX(rect) - 5, NSMinY(rect) + 4)];
            [chevron lineToPoint:NSMakePoint(NSMaxX(rect) + 1, NSMidY(rect))];
            [chevron lineToPoint:NSMakePoint(NSMaxX(rect) - 5, NSMaxY(rect) - 4)];
            chevron.lineWidth = 1;
            [chevron stroke];
        }
        NSInteger nodeIndex = [part[@"nodeIndex"] integerValue];
        if (nodeIndex >= 0) [self.hitItems addObject:@{@"rect": [NSValue valueWithRect:rect], @"index": @(nodeIndex)}];
        x += width + 2;
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    for (NSDictionary *hit in self.hitItems) {
        if (NSPointInRect(point, [hit[@"rect"] rectValue])) {
            [NSApp sendAction:@selector(breadcrumbSelected:) to:self.actionTarget from:hit[@"index"]];
            return;
        }
    }
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property(strong) NSWindow *window;
@property(strong) NSWindow *splashWindow;
@property(strong) NSTextField *pathLabel;
@property(strong) NSTextField *sourceSubtitle;
@property(strong) NSTextField *statusLabel;
@property(strong) NSTextField *detailLabel;
@property(strong) NSTextField *volumeLabel;
@property(strong) NSButton *scanButton;
@property(strong) NSButton *backButton;
@property(strong) NSButton *forwardButton;
@property(strong) NSButton *cancelButton;
@property(strong) NSButton *revealButton;
@property(strong) ColorProgressView *progress;
@property(strong) NSTextField *progressCaption;
@property(strong) NSTask *scanTask;
@property(strong) DiskMapView *mapView;
@property(strong) DockProgressView *dockProgressView;
@property(strong) NSTableView *table;
@property(strong) NSScrollView *resultsScroll;
@property(strong) NSTextField *sidebarTitle;
@property(strong) NSTextField *sidebarSize;
@property(strong) BreadcrumbView *breadcrumb;
@property(strong) NSView *statusBar;
@property(strong) NSTextField *scanStatsLabel;
@property(copy) NSString *selectedPath;
@property(copy) NSArray<NSDictionary *> *items;
@property(copy) NSArray<NSDictionary *> *listedItems;
@property(copy) NSArray<NSDictionary *> *visibleItems;
@property(copy) NSArray<NSDictionary *> *collapsedSmallItems;
@property(assign) BOOL smallItemsExpanded;
@property(assign) unsigned long long listedItemsTotalBytes;
@property(strong) NSDictionary *rootNode;
@property(strong) NSDictionary *currentNode;
@property(strong) NSMutableArray<NSDictionary *> *history;
@property(strong) NSMutableArray<NSDictionary *> *forwardHistory;
@property(strong) NSMutableSet<NSString *> *missingPaths;
@property(strong) dispatch_source_t directoryMonitor;
@property(strong) NSTimer *volumeRefreshTimer;
@property(assign) unsigned long long volumeCapacityBytes;
@property(assign) unsigned long long volumeFreeBytes;
@property(copy) NSArray<NSLayoutConstraint *> *expandedResultConstraints;
@property(copy) NSArray<NSView *> *resultViews;
@property(assign) CGFloat expandedContentHeight;
@property(assign) BOOL resultAreaExpanded;
@end

@implementation AppDelegate
- (void)stopDirectoryMonitor {
    if (self.directoryMonitor) {
        dispatch_source_cancel(self.directoryMonitor);
        self.directoryMonitor = nil;
    }
}

- (void)refreshMissingItems {
    NSMutableSet<NSString *> *missing = [NSMutableSet set];
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSDictionary *item in self.items) {
        NSString *path = item[@"path"];
        if (path.length && ![manager fileExistsAtPath:path]) [missing addObject:path];
    }
    if (![missing isEqualToSet:self.missingPaths ?: [NSSet set]]) {
        self.missingPaths = missing;
        [self.table reloadData];
    }
}

- (void)startDirectoryMonitorForPath:(NSString *)path {
    [self stopDirectoryMonitor];
    [self refreshMissingItems];
    if (!path.length) return;
    int descriptor = open(path.fileSystemRepresentation, O_EVTONLY);
    if (descriptor < 0) return;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,
        (uintptr_t)descriptor,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME |
        DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_ATTRIB,
        dispatch_get_main_queue());
    if (!source) { close(descriptor); return; }
    __weak AppDelegate *weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        [weakSelf refreshMissingItems];
    });
    dispatch_source_set_cancel_handler(source, ^{
        close(descriptor);
    });
    self.directoryMonitor = source;
    dispatch_resume(source);
}

- (NSString *)applicationVersion {
    NSURL *url = [NSBundle.mainBundle URLForResource:@"Version" withExtension:@"plist"];
    NSDictionary *versionInfo = url ? [NSDictionary dictionaryWithContentsOfURL:url] : nil;
    NSString *version = versionInfo[@"ShortVersion"];
    if (!version.length) version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return version.length ? version : @"0.0";
}

- (void)showAboutPanel:(id)sender {
    (void)sender;
    NSString *website = @"https://launcher.renguldev.net";
    NSMutableAttributedString *credits = [[NSMutableAttributedString alloc]
        initWithString:website
            attributes:@{
                NSLinkAttributeName: [NSURL URLWithString:website],
                NSForegroundColorAttributeName: NSColor.linkColor
            }];
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        NSAboutPanelOptionCredits: credits
    }];
}

- (void)setupMainMenu {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];

    NSMenuItem *applicationItem = [[NSMenuItem alloc] initWithTitle:@"Disk Map"
                                                             action:nil keyEquivalent:@""];
    NSMenu *applicationMenu = [[NSMenu alloc] initWithTitle:@"Disk Map"];
    NSMenuItem *about = [[NSMenuItem alloc] initWithTitle:@"About Disk Map"
                                                   action:@selector(showAboutPanel:)
                                            keyEquivalent:@""];
    about.target = self;
    [applicationMenu addItem:about];
    [applicationMenu addItem:NSMenuItem.separatorItem];
    [applicationMenu addItemWithTitle:@"Hide Disk Map" action:@selector(hide:) keyEquivalent:@"h"];
    NSMenuItem *hideOthers = [applicationMenu addItemWithTitle:@"Hide Others"
                                                        action:@selector(hideOtherApplications:)
                                                 keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [applicationMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:)
                         keyEquivalent:@""];
    [applicationMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [applicationMenu addItemWithTitle:@"Quit Disk Map"
                                                   action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    applicationItem.submenu = applicationMenu;
    [mainMenu addItem:applicationItem];

    NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    NSMenuItem *open = [fileMenu addItemWithTitle:@"Open Folder…"
                                           action:@selector(chooseFolder:) keyEquivalent:@"o"];
    open.target = self;
    NSMenuItem *scan = [fileMenu addItemWithTitle:@"Scan"
                                           action:@selector(scan:) keyEquivalent:@"r"];
    scan.target = self;
    [fileMenu addItem:NSMenuItem.separatorItem];
    [fileMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
    fileItem.submenu = fileMenu;
    [mainMenu addItem:fileItem];

    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    NSMenuItem *redo = [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [editMenu addItem:NSMenuItem.separatorItem];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = editMenu;
    [mainMenu addItem:editItem];

    NSMenuItem *windowItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    windowItem.submenu = windowMenu;
    [mainMenu addItem:windowItem];
    NSApp.windowsMenu = windowMenu;

    NSMenuItem *helpItem = [[NSMenuItem alloc] initWithTitle:@"Help" action:nil keyEquivalent:@""];
    helpItem.submenu = [[NSMenu alloc] initWithTitle:@"Help"];
    [mainMenu addItem:helpItem];
    NSApp.helpMenu = helpItem.submenu;
    NSApp.mainMenu = mainMenu;
}

- (void)showSplashThenMainWindow {
    NSURL *splashURL = [NSBundle.mainBundle URLForResource:@"DiskMapSplash" withExtension:@"png"];
    NSImage *image = splashURL ? [[NSImage alloc] initWithContentsOfURL:splashURL] : nil;
    if (!image) {
        [self.window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        return;
    }

    NSRect visible = NSScreen.mainScreen.visibleFrame;
    CGFloat width = MIN(720.0, NSWidth(visible) * 0.76);
    CGFloat height = width * 2.0 / 3.0;
    if (height > NSHeight(visible) * 0.76) {
        height = NSHeight(visible) * 0.76;
        width = height * 1.5;
    }
    self.splashWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
                                                    styleMask:NSWindowStyleMaskBorderless
                                                      backing:NSBackingStoreBuffered defer:NO];
    self.splashWindow.opaque = YES;
    self.splashWindow.backgroundColor = NSColor.blackColor;
    self.splashWindow.hasShadow = YES;
    self.splashWindow.level = NSFloatingWindowLevel;
    self.splashWindow.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    NSImageView *imageView = [[NSImageView alloc] initWithFrame:self.splashWindow.contentView.bounds];
    imageView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    imageView.image = image;
    imageView.imageScaling = NSImageScaleAxesIndependently;
    [self.splashWindow.contentView addSubview:imageView];

    NSTextField *version = [NSTextField labelWithString:
        [NSString stringWithFormat:@"Version %@", [self applicationVersion]]];
    version.translatesAutoresizingMaskIntoConstraints = NO;
    version.font = [NSFont systemFontOfSize:15 weight:NSFontWeightMedium];
    version.textColor = [NSColor colorWithWhite:0.94 alpha:1];
    version.alignment = NSTextAlignmentCenter;
    version.wantsLayer = YES;
    version.layer.shadowColor = NSColor.blackColor.CGColor;
    version.layer.shadowOpacity = 0.75;
    version.layer.shadowRadius = 3;
    [self.splashWindow.contentView addSubview:version];
    [NSLayoutConstraint activateConstraints:@[
        [version.centerXAnchor constraintEqualToAnchor:self.splashWindow.contentView.centerXAnchor
                                               constant:width * 0.245],
        [version.centerYAnchor constraintEqualToAnchor:self.splashWindow.contentView.centerYAnchor
                                               constant:-height * 0.18]
    ]];

    [self.splashWindow center];
    [self.splashWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self.splashWindow orderOut:nil];
        self.splashWindow = nil;
        [self.window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    });
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.volumeRefreshTimer invalidate];
    [self stopDirectoryMonitor];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)hasVisibleWindows {
    (void)sender;
    if (!hasVisibleWindows) [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    return YES;
}

- (void)expandResultAreaAnimated:(BOOL)animated {
    if (self.resultAreaExpanded) return;
    self.resultAreaExpanded = YES;
    NSRect currentFrame = self.window.frame;
    NSRect requestedContent = NSMakeRect(0, 0, NSWidth(self.window.contentView.bounds),
                                         self.expandedContentHeight);
    NSRect targetFrame = [self.window frameRectForContentRect:requestedContent];
    targetFrame.origin.x = currentFrame.origin.x;
    targetFrame.origin.y = NSMaxY(currentFrame) - NSHeight(targetFrame);
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    if (NSMinY(targetFrame) < NSMinY(visible)) targetFrame.origin.y = NSMinY(visible);
    if (NSMaxY(targetFrame) > NSMaxY(visible)) targetFrame.origin.y = NSMaxY(visible) - NSHeight(targetFrame);

    void (^revealResults)(void) = ^{
        [NSLayoutConstraint activateConstraints:self.expandedResultConstraints];
        for (NSView *view in self.resultViews) {
            view.hidden = NO;
            view.alphaValue = 0;
        }
        [self.window.contentView layoutSubtreeIfNeeded];
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = animated ? 0.18 : 0;
            for (NSView *view in self.resultViews) view.animator.alphaValue = 1;
        } completionHandler:nil];
        self.window.minSize = NSMakeSize(680, 440);
    };

    if (!animated) {
        [self.window setFrame:targetFrame display:YES];
        revealResults();
        return;
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.42;
        [self.window.animator setFrame:targetFrame display:YES];
    } completionHandler:revealResults];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [self setupMainMenu];
    self.items = @[];
    self.history = [NSMutableArray array];
    self.forwardHistory = [NSMutableArray array];
    self.missingPaths = [NSMutableSet set];
    NSRect visibleFrame = NSScreen.mainScreen.visibleFrame;
    CGFloat initialWidth = MIN(820.0, floor(NSWidth(visibleFrame) * 0.68));
    CGFloat initialHeight = MIN(560.0, floor(NSHeight(visibleFrame) * 0.70));
    CGFloat compactHeight = 160.0;
    initialWidth = MAX(680.0, initialWidth);
    initialHeight = MAX(440.0, initialHeight);
    self.expandedContentHeight = initialHeight;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, initialWidth, compactHeight)
                                              styleMask:NSWindowStyleMaskTitled |
                                                        NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskResizable |
                                                        NSWindowStyleMaskMiniaturizable |
                                                        NSWindowStyleMaskFullSizeContentView
                                                backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Disk Map";
    self.window.titleVisibility = NSWindowTitleHidden;
    self.window.titlebarAppearsTransparent = YES;
    self.window.movableByWindowBackground = YES;
    self.window.restorable = NO;
    self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.window.minSize = NSMakeSize(680, compactHeight);
    self.window.maxSize = visibleFrame.size;
    [self.window center];

    NSView *content = self.window.contentView;
    content.wantsLayer = YES;
    content.layer.backgroundColor = [NSColor colorWithRed:0.105 green:0.115 blue:0.135 alpha:1].CGColor;

    NSButton *choose = [NSButton buttonWithTitle:@"Open Folder…" target:self action:@selector(chooseFolder:)];
    choose.translatesAutoresizingMaskIntoConstraints = NO;
    [choose setContentHuggingPriority:NSLayoutPriorityRequired
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSImage *backImage = [NSImage imageWithSystemSymbolName:@"chevron.left"
                                  accessibilityDescription:@"Back"];
    self.backButton = [NSButton buttonWithImage:backImage target:self action:@selector(goBack:)];
    self.backButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.backButton.enabled = NO;
    self.backButton.bordered = NO;
    self.backButton.imagePosition = NSImageOnly;
    self.backButton.toolTip = @"Back";
    [self.backButton setContentHuggingPriority:NSLayoutPriorityRequired
                                forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSImage *forwardImage = [NSImage imageWithSystemSymbolName:@"chevron.right"
                                     accessibilityDescription:@"Forward"];
    self.forwardButton = [NSButton buttonWithImage:forwardImage target:self action:@selector(goForward:)];
    self.forwardButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.forwardButton.enabled = NO;
    self.forwardButton.bordered = NO;
    self.forwardButton.imagePosition = NSImageOnly;
    self.forwardButton.toolTip = @"Forward";
    [self.forwardButton setContentHuggingPriority:NSLayoutPriorityRequired
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.scanButton = [NSButton buttonWithTitle:@"Scan" target:self action:@selector(scan:)];
    self.scanButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.scanButton.enabled = YES;
    [self.scanButton setContentHuggingPriority:NSLayoutPriorityRequired
                                forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelScan:)];
    self.cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.cancelButton.hidden = YES;
    [self.cancelButton setContentHuggingPriority:NSLayoutPriorityRequired
                                  forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.selectedPath = @"/";
    NSString *startupDisk = [[NSFileManager defaultManager] displayNameAtPath:self.selectedPath];
    self.pathLabel = [NSTextField labelWithString:
        startupDisk.length ? startupDisk : @"Startup Disk"];
    self.pathLabel.textColor = NSColor.secondaryLabelColor;
    self.pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.pathLabel.font = [NSFont systemFontOfSize:17 weight:NSFontWeightMedium];
    [self.pathLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.pathLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.sourceSubtitle = [NSTextField labelWithString:@"Startup disk • ready to scan"];
    self.sourceSubtitle.textColor = [NSColor colorWithWhite:0.46 alpha:1];
    self.sourceSubtitle.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    self.sourceSubtitle.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.sourceSubtitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel = [NSTextField labelWithString:@"Ready"];
    self.statusLabel.textColor = [NSColor colorWithWhite:0.56 alpha:1];
    self.statusLabel.font = [NSFont systemFontOfSize:12];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailLabel = [NSTextField labelWithString:@""];
    self.detailLabel.textColor = [NSColor colorWithWhite:0.84 alpha:1];
    self.detailLabel.font = [NSFont systemFontOfSize:12];
    self.detailLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.detailLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.volumeLabel = [NSTextField labelWithString:@""];
    self.volumeLabel.textColor = NSColor.secondaryLabelColor;
    self.volumeLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.volumeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.volumeLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.volumeLabel.font = [NSFont systemFontOfSize:12];
    self.sidebarTitle = [NSTextField labelWithString:@"Contents"];
    self.sidebarTitle.font = [NSFont systemFontOfSize:22 weight:NSFontWeightMedium];
    self.sidebarTitle.textColor = [NSColor colorWithWhite:0.96 alpha:1];
    self.sidebarTitle.lineBreakMode = NSLineBreakByTruncatingTail;
    self.sidebarTitle.maximumNumberOfLines = 1;
    self.sidebarTitle.usesSingleLineMode = YES;
    self.sidebarTitle.cell.wraps = NO;
    self.sidebarTitle.cell.scrollable = NO;
    self.sidebarTitle.cell.truncatesLastVisibleLine = YES;
    self.sidebarTitle.allowsDefaultTighteningForTruncation = YES;
    [self.sidebarTitle setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.sidebarTitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarSize = [NSTextField labelWithString:@""];
    self.sidebarSize.font = [NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightRegular];
    self.sidebarSize.textColor = [NSColor colorWithWhite:0.58 alpha:1];
    self.sidebarSize.alignment = NSTextAlignmentRight;
    [self.sidebarSize setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.sidebarSize setContentHuggingPriority:NSLayoutPriorityRequired
                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.sidebarSize.translatesAutoresizingMaskIntoConstraints = NO;
    self.revealButton = [NSButton buttonWithTitle:@"Show in Finder" target:self
                                           action:@selector(showInFinder:)];
    self.revealButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.revealButton.enabled = NO;
    self.progress = [[ColorProgressView alloc] init];
    self.progress.minValue = 0;
    self.progress.fillColor = NSColor.systemBlueColor;
    self.progress.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressCaption = [NSTextField labelWithString:@""];
    self.progressCaption.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    self.progressCaption.textColor = NSColor.secondaryLabelColor;
    self.progressCaption.alignment = NSTextAlignmentRight;
    self.progressCaption.lineBreakMode = NSLineBreakByTruncatingHead;
    self.progressCaption.translatesAutoresizingMaskIntoConstraints = NO;
    self.breadcrumb = [[BreadcrumbView alloc] init];
    self.breadcrumb.nodes = @[@{@"name": startupDisk.length ? startupDisk : @"Startup Disk",
                               @"path": self.selectedPath}];
    self.breadcrumb.actionTarget = self;
    self.breadcrumb.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusBar = [[NSView alloc] init];
    self.statusBar.wantsLayer = YES;
    self.statusBar.layer.backgroundColor = [NSColor colorWithRed:0.075 green:0.082 blue:0.096 alpha:1].CGColor;
    self.statusBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.scanStatsLabel = [NSTextField labelWithString:@"0 files   •   0 folders"];
    self.scanStatsLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.scanStatsLabel.textColor = [NSColor colorWithWhite:0.55 alpha:1];
    self.scanStatsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusBar addSubview:self.scanStatsLabel];

    self.mapView = [[DiskMapView alloc] init];
    self.mapView.selectedIndex = NSNotFound;
    self.mapView.actionTarget = self;
    self.mapView.translatesAutoresizingMaskIntoConstraints = NO;
    self.table = [[HoverTableView alloc] init];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.target = self;
    self.table.action = @selector(tableClicked:);
    self.table.doubleAction = @selector(openSelectedTableItem:);
    self.table.headerView = nil;
    self.table.backgroundColor = NSColor.clearColor;
    self.table.rowHeight = 26;
    self.table.intercellSpacing = NSMakeSize(0, 0);
    self.table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    self.table.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@"Item"];
    NSMenuItem *revealItem = [[NSMenuItem alloc] initWithTitle:@"Show in Finder"
                                                        action:@selector(showInFinder:) keyEquivalent:@""];
    revealItem.target = self;
    [contextMenu addItem:revealItem];
    NSMenuItem *copyPathItem = [[NSMenuItem alloc] initWithTitle:@"Copy Path"
                                                          action:@selector(copyPath:) keyEquivalent:@""];
    copyPathItem.target = self;
    [contextMenu addItem:copyPathItem];
    self.table.menu = contextMenu;
    self.mapView.menu = contextMenu;
    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameColumn.width = 175;
    nameColumn.minWidth = 110;
    nameColumn.resizingMask = NSTableColumnAutoresizingMask;
    [self.table addTableColumn:nameColumn];
    NSTableColumn *sizeColumn = [[NSTableColumn alloc] initWithIdentifier:@"size"];
    sizeColumn.width = 92;
    sizeColumn.minWidth = 92;
    sizeColumn.maxWidth = 92;
    sizeColumn.resizingMask = NSTableColumnNoResizing;
    [self.table addTableColumn:sizeColumn];
    NSScrollView *scroll = [[NSScrollView alloc] init];
    self.resultsScroll = scroll;
    scroll.documentView = self.table;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *view in @[self.backButton, self.forwardButton, choose, self.scanButton, self.cancelButton,
                           self.pathLabel, self.sourceSubtitle,
                           self.sidebarTitle, self.sidebarSize,
                           self.progress, self.progressCaption, self.breadcrumb,
                           self.mapView, scroll, self.statusBar]) [content addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [self.backButton.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:104],
        [self.backButton.topAnchor constraintEqualToAnchor:content.topAnchor constant:9],
        [self.backButton.widthAnchor constraintEqualToConstant:24],
        [self.backButton.heightAnchor constraintEqualToConstant:24],
        [self.forwardButton.leadingAnchor constraintEqualToAnchor:self.backButton.trailingAnchor constant:2],
        [self.forwardButton.centerYAnchor constraintEqualToAnchor:self.backButton.centerYAnchor],
        [self.forwardButton.widthAnchor constraintEqualToConstant:24],
        [self.forwardButton.heightAnchor constraintEqualToConstant:24],
        [choose.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [choose.topAnchor constraintEqualToAnchor:self.sourceSubtitle.bottomAnchor constant:10],
        [self.scanButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [self.scanButton.widthAnchor constraintEqualToConstant:62],
        [self.scanButton.centerYAnchor constraintEqualToAnchor:self.pathLabel.centerYAnchor],
        [self.cancelButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [self.cancelButton.centerYAnchor constraintEqualToAnchor:self.pathLabel.centerYAnchor],
        [self.pathLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [self.pathLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.progress.leadingAnchor constant:-18],
        [self.pathLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:42],
        [self.sourceSubtitle.leadingAnchor constraintEqualToAnchor:self.pathLabel.leadingAnchor],
        [self.sourceSubtitle.trailingAnchor constraintLessThanOrEqualToAnchor:self.progress.leadingAnchor constant:-18],
        [self.sourceSubtitle.topAnchor constraintEqualToAnchor:self.pathLabel.bottomAnchor constant:2],
        [self.progress.trailingAnchor constraintEqualToAnchor:self.scanButton.leadingAnchor constant:-12],
        [self.progress.widthAnchor constraintEqualToConstant:270],
        [self.progress.heightAnchor constraintEqualToConstant:7],
        [self.progress.centerYAnchor constraintEqualToAnchor:self.pathLabel.centerYAnchor],
        [self.progressCaption.leadingAnchor constraintEqualToAnchor:self.progress.leadingAnchor],
        [self.progressCaption.trailingAnchor constraintEqualToAnchor:self.progress.trailingAnchor],
        [self.progressCaption.topAnchor constraintEqualToAnchor:self.progress.bottomAnchor constant:4],
        [self.breadcrumb.leadingAnchor constraintEqualToAnchor:self.forwardButton.trailingAnchor constant:6],
        [self.breadcrumb.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [self.breadcrumb.centerYAnchor constraintEqualToAnchor:self.backButton.centerYAnchor],
        [self.breadcrumb.heightAnchor constraintEqualToConstant:28]
    ]];
    self.expandedResultConstraints = @[
        [self.statusBar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.statusBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [self.statusBar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [self.statusBar.heightAnchor constraintEqualToConstant:28],
        [self.scanStatsLabel.leadingAnchor constraintEqualToAnchor:self.statusBar.leadingAnchor constant:14],
        [self.scanStatsLabel.centerYAnchor constraintEqualToAnchor:self.statusBar.centerYAnchor],
        [self.mapView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.mapView.topAnchor constraintEqualToAnchor:choose.bottomAnchor constant:8],
        [self.mapView.bottomAnchor constraintEqualToAnchor:self.statusBar.topAnchor],
        [self.mapView.widthAnchor constraintEqualToAnchor:content.widthAnchor multiplier:0.60],
        [self.sidebarTitle.leadingAnchor constraintEqualToAnchor:self.mapView.trailingAnchor constant:26],
        [self.sidebarTitle.topAnchor constraintEqualToAnchor:self.mapView.topAnchor constant:16],
        [self.sidebarTitle.trailingAnchor constraintEqualToAnchor:self.sidebarSize.leadingAnchor constant:-12],
        [self.sidebarSize.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-22],
        [self.sidebarSize.centerYAnchor constraintEqualToAnchor:self.sidebarTitle.centerYAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.sidebarTitle.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-18],
        [scroll.topAnchor constraintEqualToAnchor:self.sidebarTitle.bottomAnchor constant:10],
        [scroll.bottomAnchor constraintEqualToAnchor:self.statusBar.topAnchor constant:-12]
    ];
    self.resultViews = @[self.mapView, self.sidebarTitle, self.sidebarSize, scroll, self.statusBar];
    for (NSView *view in self.resultViews) {
        view.hidden = YES;
        view.alphaValue = 0;
    }
    [content layoutSubtreeIfNeeded];
    [self.window setContentSize:NSMakeSize(initialWidth, compactHeight)];
    NSRect expandedFrame = [self.window frameRectForContentRect:
        NSMakeRect(0, 0, initialWidth, initialHeight)];
    expandedFrame.origin.x = NSMidX(visibleFrame) - NSWidth(expandedFrame) / 2.0;
    expandedFrame.origin.y = NSMidY(visibleFrame) - NSHeight(expandedFrame) / 2.0;
    NSRect compactFrame = self.window.frame;
    compactFrame.origin.x = expandedFrame.origin.x;
    compactFrame.origin.y = NSMaxY(expandedFrame) - NSHeight(compactFrame);
    [self.window setFrame:compactFrame display:NO];
    [self refreshVolumeIndicatorForPath:self.selectedPath];
    [self showSplashThenMainWindow];
}

- (void)chooseFolder:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.allowsMultipleSelection = NO;
    if ([panel runModal] == NSModalResponseOK) {
        [self.volumeRefreshTimer invalidate];
        self.volumeRefreshTimer = nil;
        self.selectedPath = panel.URL.path;
        self.pathLabel.stringValue = panel.URL.lastPathComponent.length
            ? panel.URL.lastPathComponent : self.selectedPath;
        self.sourceSubtitle.stringValue = self.selectedPath;
        self.breadcrumb.nodes = @[@{@"name": self.pathLabel.stringValue,
                                   @"path": self.selectedPath}];
        [self.breadcrumb setNeedsDisplay:YES];
        [self.history removeAllObjects];
        [self.forwardHistory removeAllObjects];
        self.backButton.enabled = NO;
        self.forwardButton.enabled = NO;
        [self refreshVolumeIndicatorForPath:self.selectedPath];
        self.scanButton.enabled = YES;
    }
}

- (void)refreshVolumeIndicatorForPath:(NSString *)path {
    [self refreshVolumeIndicatorForPath:path updateSubtitle:YES];
}

- (void)refreshVolumeIndicatorForPath:(NSString *)path updateSubtitle:(BOOL)updateSubtitle {
    NSError *error = nil;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfFileSystemForPath:path error:&error];
    if (!attributes || error) {
        self.progress.maxValue = 1;
        self.progress.doubleValue = 0;
        self.progressCaption.stringValue = @"Space unavailable";
        self.progressCaption.textColor = NSColor.secondaryLabelColor;
        if (updateSubtitle) self.sourceSubtitle.stringValue = @"Disk space unavailable";
        return;
    }
    self.volumeCapacityBytes = [attributes[NSFileSystemSize] unsignedLongLongValue];
    self.volumeFreeBytes = [attributes[NSFileSystemFreeSize] unsignedLongLongValue];
    unsigned long long used = self.volumeCapacityBytes - MIN(self.volumeCapacityBytes, self.volumeFreeBytes);
    self.progress.maxValue = MAX(1.0, (double)self.volumeCapacityBytes);
    self.progress.doubleValue = (double)used;
    double occupancy = self.volumeCapacityBytes > 0 ? (double)used / (double)self.volumeCapacityBytes : 0;
    NSColor *occupancyColor = occupancy < 0.70 ? NSColor.systemGreenColor
        : (occupancy < 0.90 ? NSColor.systemOrangeColor : NSColor.systemRedColor);
    self.progress.fillColor = occupancyColor;
    NSString *freeText = [NSByteCountFormatter stringFromByteCount:(long long)self.volumeFreeBytes
                                                        countStyle:NSByteCountFormatterCountStyleFile];
    NSString *capacityText = [NSByteCountFormatter stringFromByteCount:(long long)self.volumeCapacityBytes
                                                            countStyle:NSByteCountFormatterCountStyleFile];
    self.progressCaption.stringValue = [NSString stringWithFormat:@"%@ available", freeText];
    self.progressCaption.textColor = occupancyColor;
    if (updateSubtitle) self.sourceSubtitle.stringValue = [NSString stringWithFormat:@"Capacity %@ • ready to scan", capacityText];
}

- (NSString *)displayNameForNode:(NSDictionary *)node {
    NSString *name = node[@"name"];
    NSString *path = node[@"path"];
    if ([path isEqualToString:@"/"]) {
        NSString *volume = [[NSFileManager defaultManager] displayNameAtPath:path];
        if (volume.length) return volume;
    }
    if (!name.length || [name isEqualToString:path]) {
        NSString *component = path.lastPathComponent;
        if (component.length) name = component;
    }
    return name.length ? name : @"Disk Map";
}

- (void)rebuildVisibleItems {
    if (self.smallItemsExpanded || self.listedItems.count < 3) {
        self.visibleItems = self.listedItems;
        self.collapsedSmallItems = @[];
        return;
    }

    unsigned long long total = self.listedItemsTotalBytes;
    unsigned long long cutoff = MAX(1ULL, total / 100ULL);
    NSInteger firstSmallIndex = self.listedItems.count;
    unsigned long long collapsedBytes = 0;
    for (NSInteger index = (NSInteger)self.listedItems.count - 1; index >= 1; --index) {
        unsigned long long itemBytes = [self.listedItems[index][@"physicalBytes"] unsignedLongLongValue];
        if (itemBytes > cutoff - collapsedBytes) break;
        collapsedBytes += itemBytes;
        firstSmallIndex = index;
    }
    NSInteger smallCount = (NSInteger)self.listedItems.count - firstSmallIndex;
    if (smallCount < 2) {
        self.visibleItems = self.listedItems;
        self.collapsedSmallItems = @[];
        return;
    }

    self.collapsedSmallItems = [self.listedItems subarrayWithRange:NSMakeRange(firstSmallIndex, smallCount)];
    NSDictionary *summary = @{@"name": @"smaller objects…",
                              @"physicalBytes": @(collapsedBytes),
                              @"smallItemsSummary": @YES};
    NSMutableArray<NSDictionary *> *visible = [[self.listedItems subarrayWithRange:
        NSMakeRange(0, firstSmallIndex)] mutableCopy];
    [visible addObject:summary];
    self.visibleItems = visible;
}

- (void)displayNode:(NSDictionary *)node pushingHistory:(BOOL)push {
    if (!node) return;
    if (push && self.currentNode) {
        [self.history addObject:self.currentNode];
        [self.forwardHistory removeAllObjects];
    }
    self.currentNode = node;
    self.items = node[@"children"] ?: @[];
    self.listedItems = self.items;
    self.listedItemsTotalBytes = [node[@"physicalBytes"] unsignedLongLongValue];
    self.smallItemsExpanded = NO;
    [self rebuildVisibleItems];
    self.mapView.items = self.items;
    self.mapView.selectedIndex = NSNotFound;
    self.mapView.selectedItem = nil;
    NSString *displayName = [self displayNameForNode:node];
    self.mapView.centerTitle = displayName;
    self.backButton.enabled = self.history.count > 0;
    self.forwardButton.enabled = self.forwardHistory.count > 0;
    self.revealButton.enabled = node[@"path"] != nil;
    [self showDetailsForItem:node];
    [self.mapView setNeedsDisplay:YES];
    [self.table reloadData];
    [self.table deselectAll:nil];
    [self startDirectoryMonitorForPath:node[@"path"]];
    NSString *bytes = [NSByteCountFormatter stringFromByteCount:[node[@"physicalBytes"] longLongValue]
                                                     countStyle:NSByteCountFormatterCountStyleFile];
    self.mapView.centerSubtitle = bytes;
    self.sidebarTitle.stringValue = displayName;
    self.sidebarSize.stringValue = [NSString stringWithFormat:@"%@  ·  %lu items", bytes,
                                    (unsigned long)self.items.count];
    NSMutableArray<NSDictionary *> *crumbs = [self.history mutableCopy];
    [crumbs addObject:node];
    self.breadcrumb.nodes = crumbs;
    [self.breadcrumb setNeedsDisplay:YES];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"%@ — %lu items", bytes,
                                    (unsigned long)self.items.count];
}

- (void)showListForNode:(NSDictionary *)node preview:(BOOL)preview {
    if (!node) node = self.currentNode;
    NSArray<NSDictionary *> *children = node[@"children"];
    BOOL hasChildren = [children isKindOfClass:NSArray.class] && children.count > 0;
    self.listedItems = hasChildren ? children : (preview ? @[node] : self.items);
    self.listedItemsTotalBytes = [node[@"physicalBytes"] unsignedLongLongValue];
    self.smallItemsExpanded = NO;
    [self rebuildVisibleItems];
    [self.table reloadData];
    [self.table deselectAll:nil];

    NSString *displayName = [self displayNameForNode:node];
    NSString *bytes = [NSByteCountFormatter stringFromByteCount:
        [node[@"physicalBytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile];
    self.sidebarTitle.stringValue = displayName;
    self.sidebarSize.stringValue = [NSString stringWithFormat:@"%@  ·  %lu items", bytes,
                                    (unsigned long)self.listedItems.count];
}

- (void)hoverMapItem:(DiskMapView *)sender {
    [self showListForNode:(sender.hoveredItem ?: self.currentNode)
                  preview:sender.hoveredItem != nil];
}

- (void)breadcrumbSelected:(NSNumber *)sender {
    NSInteger index = sender.integerValue;
    NSMutableArray<NSDictionary *> *chain = [self.history mutableCopy];
    if (self.currentNode) [chain addObject:self.currentNode];
    if (index < 0 || index >= (NSInteger)chain.count - 1) return;
    NSDictionary *target = chain[index];
    self.forwardHistory = [NSMutableArray array];
    for (NSInteger next = (NSInteger)chain.count - 1; next > index; --next) {
        [self.forwardHistory addObject:chain[next]];
    }
    self.history = [[chain subarrayWithRange:NSMakeRange(0, index)] mutableCopy];
    [self displayNode:target pushingHistory:NO];
}

- (void)showDetailsForItem:(NSDictionary *)item {
    if (!item) return;
    NSString *allocated = [NSByteCountFormatter stringFromByteCount:[item[@"physicalBytes"] longLongValue]
                                                          countStyle:NSByteCountFormatterCountStyleFile];
    NSString *logical = [NSByteCountFormatter stringFromByteCount:[item[@"logicalBytes"] longLongValue]
                                                        countStyle:NSByteCountFormatterCountStyleFile];
    NSString *access = [item[@"restricted"] boolValue] ? @" • access restricted" : @"";
    self.detailLabel.stringValue = [NSString stringWithFormat:@"%@%@ • allocated %@ • logical %@ • %@",
                                    item[@"kind"] ?: @"item", access, allocated, logical,
                                    item[@"path"] ?: @""];
    self.detailLabel.textColor = [item[@"restricted"] boolValue]
        ? NSColor.systemOrangeColor : NSColor.labelColor;
    self.revealButton.enabled = item[@"path"] != nil;
}

- (void)showVolumeSummary:(NSDictionary *)summary {
    if (![summary isKindOfClass:NSDictionary.class] || summary[@"error"]) {
        self.volumeLabel.stringValue = @"Volume information unavailable";
        return;
    }
    NSString *(^format)(NSNumber *) = ^NSString *(NSNumber *number) {
        return [NSByteCountFormatter stringFromByteCount:number.longLongValue
                                              countStyle:NSByteCountFormatterCountStyleFile];
    };
    NSString *purgeable = [summary[@"purgeableEstimateAvailable"] boolValue]
        ? format(summary[@"purgeableEstimateBytes"]) : @"unavailable";
    self.volumeLabel.stringValue = [NSString stringWithFormat:
        @"Free %@   •   Purgeable ~%@   •   Capacity %@   •   %@",
        format(summary[@"freeBytes"]), purgeable, format(summary[@"capacityBytes"]),
        summary[@"fileSystem"] ?: @""];
}

- (NSDictionary *)selectedItemOrCurrentNode {
    NSInteger row = self.table.selectedRow;
    if (row >= 0 && row < (NSInteger)self.visibleItems.count) {
        NSDictionary *item = self.visibleItems[row];
        if (![item[@"smallItemsSummary"] boolValue]) return item;
    }
    return self.mapView.selectedItem ?: self.currentNode;
}

- (void)showInFinder:(id)sender {
    (void)sender;
    NSString *path = [self selectedItemOrCurrentNode][@"path"];
    if (!path.length) { NSBeep(); return; }
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:
        @[[NSURL fileURLWithPath:path]]];
}

- (void)copyPath:(id)sender {
    (void)sender;
    NSString *path = [self selectedItemOrCurrentNode][@"path"];
    if (!path.length) { NSBeep(); return; }
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setString:path forType:NSPasteboardTypeString];
}

- (void)openItem:(NSDictionary *)item {
    if ([item[@"kind"] isEqualToString:@"directory"] && [item[@"children"] isKindOfClass:NSArray.class]) {
        [self displayNode:item pushingHistory:YES];
    } else {
        NSBeep();
    }
}

- (void)goBack:(id)sender {
    (void)sender;
    NSDictionary *node = self.history.lastObject;
    if (!node) return;
    if (self.currentNode) [self.forwardHistory addObject:self.currentNode];
    [self.history removeLastObject];
    [self displayNode:node pushingHistory:NO];
}

- (void)goForward:(id)sender {
    (void)sender;
    NSDictionary *node = self.forwardHistory.lastObject;
    if (!node) return;
    if (self.currentNode) [self.history addObject:self.currentNode];
    [self.forwardHistory removeLastObject];
    [self displayNode:node pushingHistory:NO];
}

- (void)selectMapItem:(id)sender {
    (void)sender;
    NSDictionary *item = self.mapView.selectedItem;
    if (!item) return;
    NSInteger index = [self.visibleItems indexOfObjectIdenticalTo:item];
    if (index == NSNotFound && [self.collapsedSmallItems containsObject:item]) {
        self.smallItemsExpanded = YES;
        [self rebuildVisibleItems];
        [self.table reloadData];
        index = [self.visibleItems indexOfObjectIdenticalTo:item];
    }
    if (index != NSNotFound) {
        [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
        [self.table scrollRowToVisible:index];
    } else {
        [self.table deselectAll:nil];
    }
    NSString *bytes = [NSByteCountFormatter stringFromByteCount:[item[@"physicalBytes"] longLongValue]
                                                     countStyle:NSByteCountFormatterCountStyleFile];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"%@ — %@", item[@"name"], bytes];
    [self showDetailsForItem:item];
}

- (void)openSelectedMapItem:(id)sender {
    [self selectMapItem:sender];
    if (self.mapView.selectedItem) [self openItem:self.mapView.selectedItem];
}

- (void)openSelectedTableItem:(id)sender {
    (void)sender;
    NSInteger row = self.table.clickedRow;
    if (row < 0) row = self.table.selectedRow;
    if (row >= 0 && row < (NSInteger)self.visibleItems.count) {
        NSDictionary *item = self.visibleItems[row];
        if (![item[@"smallItemsSummary"] boolValue]) [self openItem:item];
    }
}

- (void)tableClicked:(id)sender {
    (void)sender;
    NSInteger row = self.table.clickedRow;
    if (row < 0 || row >= (NSInteger)self.visibleItems.count) return;
    if (![self.visibleItems[row][@"smallItemsSummary"] boolValue]) return;
    self.smallItemsExpanded = YES;
    [self rebuildVisibleItems];
    [self.table reloadData];
    [self.table deselectAll:nil];
}

- (void)showDockProgress:(double)progressValue {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(hideDockProgress) object:nil];
    if (!self.dockProgressView) {
        self.dockProgressView = [[DockProgressView alloc] initWithFrame:NSMakeRect(0, 0, 128, 128)];
        self.dockProgressView.applicationIcon = [NSApp.applicationIconImage copy];
    }
    self.dockProgressView.progressValue = progressValue;
    NSApp.dockTile.contentView = self.dockProgressView;
    [NSApp.dockTile display];
}

- (void)hideDockProgress {
    NSApp.dockTile.contentView = nil;
    [NSApp.dockTile display];
}

- (void)scan:(id)sender {
    (void)sender;
    if (!self.selectedPath) return;
    [self.volumeRefreshTimer invalidate];
    self.volumeRefreshTimer = nil;
    self.scanButton.enabled = NO;
    self.scanButton.hidden = YES;
    self.cancelButton.hidden = NO;
    self.cancelButton.enabled = YES;
    unsigned long long estimatedUsed = self.volumeCapacityBytes -
        MIN(self.volumeCapacityBytes, self.volumeFreeBytes);
    self.progress.maxValue = MAX(1.0, (double)estimatedUsed);
    self.progress.doubleValue = 0;
    self.progress.fillColor = NSColor.systemBlueColor;
    self.progressCaption.stringValue = @"Scan in progress";
    self.progressCaption.textColor = NSColor.systemBlueColor;
    self.scanStatsLabel.stringValue = @"0 files   •   0 folders   •   preparing…";
    self.sourceSubtitle.stringValue = @"Scanning startup volume…";
    self.statusLabel.stringValue = @"Preparing scan…";
    [self showDockProgress:0];
    [self.progress startAnimation:nil];
    NSString *tool = [[NSBundle mainBundle] pathForResource:@"ddscan" ofType:nil];
    NSTask *task = [[NSTask alloc] init];
    self.scanTask = task;
    task.executableURL = [NSURL fileURLWithPath:tool];
    task.arguments = @[@"--threads", @"8", @"--tree", @"--progress",
                       @"--volume-summary", self.selectedPath];
    NSString *temporaryName = [NSString stringWithFormat:@"diskmap-%@.json", NSUUID.UUID.UUIDString];
    NSString *temporaryPath = [NSTemporaryDirectory() stringByAppendingPathComponent:temporaryName];
    [[NSFileManager defaultManager] createFileAtPath:temporaryPath contents:nil attributes:nil];
    NSFileHandle *outputFile = [NSFileHandle fileHandleForWritingAtPath:temporaryPath];
    task.standardOutput = outputFile;
    NSPipe *progressPipe = [NSPipe pipe];
    task.standardError = progressPipe;
    NSFileHandle *progressReader = progressPipe.fileHandleForReading;
    NSMutableData *diagnostics = [NSMutableData data];
    progressReader.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *chunk = handle.availableData;
        if (chunk.length == 0) { handle.readabilityHandler = nil; return; }
        @synchronized (diagnostics) { [diagnostics appendData:chunk]; }
        NSString *text = [[NSString alloc] initWithData:chunk encoding:NSUTF8StringEncoding];
        NSArray<NSString *> *updates = [text componentsSeparatedByCharactersInSet:
                                         [NSCharacterSet characterSetWithCharactersInString:@"\r\n"]];
        NSString *latest = nil;
        for (NSString *candidate in updates) if (candidate.length > 0) latest = candidate;
        if (latest && [latest containsString:@"files="]) dispatch_async(dispatch_get_main_queue(), ^{
            if (self.scanTask == task) {
                self.sourceSubtitle.stringValue = @"Scanning…";
                NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
                for (NSString *token in [latest componentsSeparatedByString:@" "]) {
                    NSArray<NSString *> *pair = [token componentsSeparatedByString:@"="];
                    if (pair.count == 2) values[pair[0]] = pair[1];
                }
                self.scanStatsLabel.stringValue = [NSString stringWithFormat:
                    @"%@ files   •   %@ folders   •   %@ pending",
                    values[@"files"] ?: @"0", values[@"dirs"] ?: @"0", values[@"pending"] ?: @"0"];
                NSRange marker = [latest rangeOfString:@"allocated="];
                if (marker.location != NSNotFound) {
                    NSString *tail = [latest substringFromIndex:NSMaxRange(marker)];
                    NSScanner *scanner = [NSScanner scannerWithString:tail];
                    unsigned long long mebibytes = 0;
                    if ([scanner scanUnsignedLongLong:&mebibytes]) {
                        double scannedBytes = (double)mebibytes * 1024.0 * 1024.0;
                        // Keep a clearly visible completion reserve: enumerating bytes is not the
                        // end of the scan because workers can still be draining pending folders and
                        // the final tree/JSON still has to be assembled.
                        self.progress.doubleValue = MIN(self.progress.maxValue * 0.90, scannedBytes);
                        [self showDockProgress:self.progress.doubleValue / self.progress.maxValue];
                    }
                }
            }
        });
    };
    task.terminationHandler = ^(NSTask *finished) {
        progressReader.readabilityHandler = nil;
        NSData *remaining = [progressReader readDataToEndOfFile];
        @synchronized (diagnostics) { [diagnostics appendData:remaining]; }
        [outputFile closeFile];
        NSData *data = [NSData dataWithContentsOfFile:temporaryPath];
        [[NSFileManager defaultManager] removeItemAtPath:temporaryPath error:nil];
        NSError *error = nil;
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.progress stopAnimation:nil];
            self.scanButton.enabled = YES;
            self.scanButton.hidden = NO;
            self.cancelButton.hidden = YES;
            self.scanTask = nil;
            if (![json isKindOfClass:NSDictionary.class] || ![json[@"tree"] isKindOfClass:NSDictionary.class]) {
                [self hideDockProgress];
                NSString *stderrText;
                @synchronized (diagnostics) {
                    stderrText = [[NSString alloc] initWithData:diagnostics encoding:NSUTF8StringEncoding];
                }
                NSMutableArray<NSString *> *messages = [NSMutableArray array];
                for (NSString *line in [stderrText componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
                    NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    if (trimmed.length && ![trimmed hasPrefix:@"files="]) [messages addObject:trimmed];
                }
                NSArray *scanErrors = [json isKindOfClass:NSDictionary.class] ? json[@"errors"] : nil;
                NSDictionary *firstError = [scanErrors isKindOfClass:NSArray.class] ? scanErrors.firstObject : nil;
                NSString *detail = messages.count ? [messages componentsJoinedByString:@"\n"] :
                    (firstError[@"message"] ?: error.localizedDescription);
                if (!messages.count && !firstError && error && finished.terminationStatus != 0) {
                    detail = [NSString stringWithFormat:@"%@\nScanner exited with %@ %d.", detail,
                        finished.terminationReason == NSTaskTerminationReasonUncaughtSignal ? @"signal" : @"status",
                        finished.terminationStatus];
                }
                if (!detail.length) detail = [NSString stringWithFormat:@"Scanner exited with status %d%@.",
                    finished.terminationStatus, finished.terminationReason == NSTaskTerminationReasonUncaughtSignal ? @" (signal)" : @""];
                self.sourceSubtitle.stringValue = @"Scan failed";
                self.statusLabel.stringValue = detail;
                self.scanStatsLabel.stringValue = @"Scan failed";
                self.progressCaption.stringValue = @"Scan failed";
                self.progressCaption.textColor = NSColor.systemRedColor;
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Scan failed";
                alert.informativeText = detail;
                [alert beginSheetModalForWindow:self.window completionHandler:nil];
                return;
            }
            self.rootNode = json[@"tree"];
            [self showVolumeSummary:json[@"volumeSummary"]];
            [self.history removeAllObjects];
            [self.forwardHistory removeAllObjects];
            [self displayNode:self.rootNode pushingHistory:NO];
            [self expandResultAreaAnimated:YES];
            NSString *bytes = [NSByteCountFormatter stringFromByteCount:[json[@"physicalBytes"] longLongValue]
                                                              countStyle:NSByteCountFormatterCountStyleFile];
            NSInteger restricted = [json[@"restrictedDirectoryCount"] integerValue];
            NSString *completion = finished.terminationStatus == 0 ? @"Complete" : @"Partial";
            if (restricted > 0) completion = @"Complete with limited access";
            self.statusLabel.stringValue = restricted > 0
                ? [NSString stringWithFormat:@"%@ — %@ items — %@ — %ld restricted folders",
                    completion, json[@"files"], bytes, (long)restricted]
                : [NSString stringWithFormat:@"%@ — %@ items — %@",
                    completion, json[@"files"], bytes];
            self.sourceSubtitle.stringValue = [NSString stringWithFormat:@"Scan complete • %@ items", json[@"files"]];
            [self showDockProgress:1.0];
            [self performSelector:@selector(hideDockProgress) withObject:nil afterDelay:0.45];
            [self refreshVolumeIndicatorForPath:self.selectedPath updateSubtitle:NO];
            __weak AppDelegate *weakSelf = self;
            self.volumeRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
                (void)timer;
                AppDelegate *strongSelf = weakSelf;
                if (strongSelf) [strongSelf refreshVolumeIndicatorForPath:strongSelf.selectedPath updateSubtitle:NO];
            }];
            self.scanStatsLabel.stringValue = [NSString stringWithFormat:
                @"%@ files   •   %@ folders   •   scan complete",
                json[@"files"] ?: @"0", json[@"directories"] ?: @"0"];
        });
    };
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        [self.progress stopAnimation:nil];
        self.scanButton.enabled = YES;
        self.scanButton.hidden = NO;
        self.cancelButton.hidden = YES;
        self.scanTask = nil;
        [self hideDockProgress];
        [self refreshVolumeIndicatorForPath:self.selectedPath];
        self.scanStatsLabel.stringValue = @"0 files   •   0 folders   •   scan failed";
        self.statusLabel.stringValue = launchError.localizedDescription;
        self.progressCaption.stringValue = @"Scan failed";
        self.progressCaption.textColor = NSColor.systemRedColor;
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Could not start scan";
        alert.informativeText = launchError.localizedDescription ?: @"The scanner could not be started.";
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
    }
}

- (void)cancelScan:(id)sender {
    (void)sender;
    NSTask *task = self.scanTask;
    if (!task.running) return;
    self.cancelButton.enabled = NO;
    self.statusLabel.stringValue = @"Cancelling…";
    self.scanStatsLabel.stringValue = [self.scanStatsLabel.stringValue stringByAppendingString:@"   •   cancelling"];
    kill(task.processIdentifier, SIGINT);
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    self.mapView.selectedIndex = self.table.selectedRow;
    NSDictionary *selected = self.table.selectedRow >= 0 &&
        self.table.selectedRow < (NSInteger)self.visibleItems.count
        ? self.visibleItems[self.table.selectedRow] : nil;
    self.mapView.selectedItem = [selected[@"smallItemsSummary"] boolValue] ? nil : selected;
    if (self.mapView.selectedItem) [self showDetailsForItem:self.mapView.selectedItem];
    [self.mapView setNeedsDisplay:YES];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView; return self.visibleItems.count;
}
- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    (void)tableView; (void)row;
    return [[HoverTableRowView alloc] initWithFrame:NSZeroRect];
}
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSString *identifier = column.identifier;
    NSDictionary *item = self.visibleItems[row];
    BOOL summary = [item[@"smallItemsSummary"] boolValue];
    BOOL missing = [self.missingPaths containsObject:item[@"path"] ?: @""];
    NSString *size = [NSByteCountFormatter stringFromByteCount:[item[@"physicalBytes"] longLongValue]
                                                     countStyle:NSByteCountFormatterCountStyleFile];
    BOOL restricted = [item[@"restricted"] boolValue];
    if ([identifier isEqualToString:@"size"]) {
        NSTextField *cell = [tableView makeViewWithIdentifier:identifier owner:self];
        if (!cell) {
            cell = [NSTextField labelWithString:@""];
            cell.identifier = identifier;
            cell.lineBreakMode = NSLineBreakByTruncatingTail;
            cell.maximumNumberOfLines = 1;
            cell.usesSingleLineMode = YES;
            cell.cell.wraps = NO;
        }
        cell.alignment = NSTextAlignmentRight;
        cell.font = [NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightRegular];
        NSColor *sizeColor = summary ? [NSColor colorWithWhite:0.48 alpha:1]
            : (missing ? [NSColor colorWithWhite:0.48 alpha:1]
                       : [NSColor colorWithWhite:0.86 alpha:1]);
        NSDictionary *attributes = missing
            ? @{NSForegroundColorAttributeName: sizeColor,
                NSStrikethroughStyleAttributeName: @(NSUnderlineStyleSingle)}
            : @{NSForegroundColorAttributeName: sizeColor};
        cell.attributedStringValue = [[NSAttributedString alloc] initWithString:size
                                                                    attributes:attributes];
        return cell;
    }

    DirectoryNameCell *cell = [tableView makeViewWithIdentifier:identifier owner:self];
    if (!cell) {
        cell = [[DirectoryNameCell alloc] initWithFrame:NSZeroRect];
        cell.identifier = identifier;
    }
    NSColor *nameColor = summary ? [NSColor colorWithWhite:0.40 alpha:1]
        : (missing ? [NSColor colorWithWhite:0.52 alpha:1]
        : (restricted ? NSColor.systemOrangeColor : [NSColor colorWithWhite:0.91 alpha:1]));
    NSMutableAttributedString *label = [[NSMutableAttributedString alloc]
        initWithString:@"●  " attributes:@{
            NSForegroundColorAttributeName: summary
                ? [NSColor colorWithWhite:0.24 alpha:1] : DiskMapRootColor(item, row),
            NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
        }];
    NSUInteger nameStart = label.length;
    [label appendAttributedString:[[NSAttributedString alloc]
        initWithString:(item[@"name"] ?: @"") attributes:@{
            NSForegroundColorAttributeName: nameColor,
            NSFontAttributeName: [NSFont systemFontOfSize:16 weight:NSFontWeightRegular]
        }]];
    if (missing && label.length > nameStart) {
        [label addAttribute:NSStrikethroughStyleAttributeName value:@(NSUnderlineStyleSingle)
                      range:NSMakeRange(nameStart, label.length - nameStart)];
    }
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    [label addAttribute:NSParagraphStyleAttributeName value:paragraph
                  range:NSMakeRange(0, label.length)];
    cell.nameLabel.attributedStringValue = label;
    return cell;
}
@end

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        application.activationPolicy = NSApplicationActivationPolicyRegular;
        AppDelegate *delegate = [[AppDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
