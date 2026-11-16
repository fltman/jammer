#import "TestNetGuard.h"
#import <objc/runtime.h>

NSString *const JMNetGuardSelfTestHost = @"netguard-selftest.invalid";
static NSMutableArray<NSString *> *refused;
static NSLock *lock;

NSString *JMNetGuardLogPath(void) {
    NSString *p = NSProcessInfo.processInfo.environment[@"JAMMER_NETGUARD_LOG"];
    return p.length ? p : [NSTemporaryDirectory() stringByAppendingPathComponent:@"jammer-netguard.log"];
}

static BOOL isThisMac(NSString *host) {
    NSString *h = host.lowercaseString;
    return [h isEqualToString:@"localhost"] || [h isEqualToString:@"127.0.0.1"] || [h isEqualToString:@"::1"] || [h isEqualToString:@"[::1]"];
}

static BOOL isAllowed(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return YES;   // file:, data:
    NSString *host = url.host;
    if (host.length == 0) return NO;
    if (isThisMac(host)) return YES;
    for (NSString *a in [NSProcessInfo.processInfo.environment[@"JAMMER_ALLOW_NETWORK"] componentsSeparatedByString:@","]) {
        if (a.length && [host.lowercaseString isEqualToString:a.lowercaseString]) return YES;
    }
    return NO;
}

@interface JMNetGuard : NSURLProtocol
@end

@implementation JMNetGuard

+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return !isAllowed(request.URL); }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    NSString *host = self.request.URL.host ?: @"(no host)";
    [lock lock];
    [refused addObject:host];
    [lock unlock];
    if (![host isEqualToString:JMNetGuardSelfTestHost]) {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", host, self.request.URL.path ?: @""];
        fprintf(stderr, "NETWORK GUARD: a test asked for %s, which is not this Mac and not a stand-in. Refused.\n", self.request.URL.absoluteString.UTF8String);
        NSFileHandle *f = [NSFileHandle fileHandleForWritingAtPath:JMNetGuardLogPath()];
        if (!f) { [NSFileManager.defaultManager createFileAtPath:JMNetGuardLogPath() contents:nil attributes:nil]; f = [NSFileHandle fileHandleForWritingAtPath:JMNetGuardLogPath()]; }
        [f seekToEndOfFile];
        [f writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [f closeFile];
    }
    NSString *why = [NSString stringWithFormat:@"The test network guard refused a request to %@: tests reach only this Mac and their own stand-ins.", host];
    [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet
                                                                   userInfo:@{NSLocalizedDescriptionKey: why}]];
}
- (void)stopLoading {}

static NSURLSessionConfiguration *guarded(NSURLSessionConfiguration *c) {
    NSMutableArray *classes = [NSMutableArray arrayWithObject:JMNetGuard.class];
    for (Class k in c.protocolClasses) if (k != JMNetGuard.class) [classes addObject:k];
    c.protocolClasses = classes;
    return c;
}

+ (void)load {
    refused = [NSMutableArray array];
    lock = [NSLock new];
    [NSURLProtocol registerClass:self];   // URLSession.shared
    // Sessions made from the default and the ephemeral configuration.
    Class meta = object_getClass(NSURLSessionConfiguration.class);
    for (NSString *name in @[@"defaultSessionConfiguration", @"ephemeralSessionConfiguration"]) {
        Method m = class_getClassMethod(NSURLSessionConfiguration.class, NSSelectorFromString(name));
        NSURLSessionConfiguration *(*original)(id, SEL) = (void *)method_getImplementation(m);
        SEL sel = NSSelectorFromString(name);
        IMP replacement = imp_implementationWithBlock(^NSURLSessionConfiguration *(id cls) { return guarded(original(cls, sel)); });
        class_replaceMethod(meta, sel, replacement, method_getTypeEncoding(m));
    }
}
@end

NSArray<NSString *> *JMNetGuardRefused(void) {
    [lock lock];
    NSArray *copy = [refused copy];
    [lock unlock];
    return copy;
}
