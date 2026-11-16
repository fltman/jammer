#import <Foundation/Foundation.h>

/// Loaded into the test process before any test runs (+load). From then on a request through
/// URLSession.shared, or through a session made from the default or ephemeral configuration, to anything
/// but this Mac fails, is written to stderr and to the guard's log, and scripts/test.sh fails on that log.
/// A test's own stand-in server (configuration.protocolClasses = [Its.self]) takes the guard's place for
/// that session, so it has to answer every request; a source test checks that.
/// Not covered: the Network framework and raw sockets.
///
/// JAMMER_ALLOW_NETWORK=host1,host2 lets those hosts through, for the suites that are run on purpose
/// against a public address (model downloads for the evaluations); JAMMER_NETGUARD_LOG names the log.
NS_ASSUME_NONNULL_BEGIN
/// The hosts refused so far in this process (the self-test's own host among them).
NSArray<NSString *> *JMNetGuardRefused(void);
NSString *JMNetGuardLogPath(void);
/// The one host the guard's own test may ask for without it counting against the run.
extern NSString *const JMNetGuardSelfTestHost;
NS_ASSUME_NONNULL_END
