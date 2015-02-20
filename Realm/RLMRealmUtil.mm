////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMRealmUtil.h"

#import "RLMRealm_Private.hpp"

#import <sys/event.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <unistd.h>

// Global realm state
static NSMutableDictionary *s_realmsPerPath = [NSMutableDictionary new];

void RLMCacheRealm(RLMRealm *realm) {
    @synchronized(s_realmsPerPath) {
        if (!s_realmsPerPath[realm.path]) {
            s_realmsPerPath[realm.path] = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPersonality
                                                                valueOptions:NSPointerFunctionsWeakMemory];
        }
        [s_realmsPerPath[realm.path] setObject:realm forKey:@(realm->_threadID)];
    }
}

RLMRealm *RLMGetAnyCachedRealmForPath(NSString *path) {
    @synchronized(s_realmsPerPath) {
        return [s_realmsPerPath[path] objectEnumerator].nextObject;
    }
}

RLMRealm *RLMGetCurrentThreadCachedRealmForPath(NSString *path) {
    mach_port_t threadID = pthread_mach_thread_np(pthread_self());
    @synchronized(s_realmsPerPath) {
        return [s_realmsPerPath[path] objectForKey:@(threadID)];
    }
}

void RLMClearRealmCache() {
    @synchronized(s_realmsPerPath) {
        [s_realmsPerPath removeAllObjects];
    }
}

// Convert 'return -1 and set errno' error reporting to exception throws
static int checkError(int ret) {
    if (ret < 0 && errno != EEXIST) {
        @throw RLMException(@(strerror(errno)));
    }
    return ret;
}

// Write a byte to a pipe to notify anyone waiting for data on the pipe
static void notifyFd(int fd) {
    while (true) {
        char c = 0;
        ssize_t ret = write(fd, &c, 1);
        if (ret == 1) {
            break;
        }

        // If the pipe's buffer is full, we need to read some of the old data in
        // it to make space. We don't just read in the code waiting for
        // notifications so that we can notify multiple waiters with a single
        // write.
        assert(ret == -1 && errno == EAGAIN);
        char buff[1024];
        read(fd, buff, sizeof buff);
    }
}

namespace {
// A RAII holder for a file descriptor which automatically closes the wrapped fd
// when it's deallocated
class FdHolder {
    int fd = -1;
    void close() {
        if (fd != -1) {
            ::close(fd);
        }
        fd = -1;
    }

public:
    ~FdHolder() { close(); }
    operator int() const { return fd; }
    FdHolder& operator=(int newFd) {
        close();
        fd = newFd;
        return *this;
    }
};
}

// Inter-thread and inter-process notifications of changes are done using a
// named pipe in the filesystem next to the Realm file. Everyone who wants to be
// notified of commits waits for data to become available on the pipe, and anyone
// who commits a write transaction writes data to the pipe after releasing the
// write lock. Note that no one ever actually *reads* from the pipe: the data
// actually written is meaningless, and trying to read from a pipe from multiple
// processes at once is fraught with race conditions.

// When a RLMRealm instance is created, we add a CFRunLoopSource to the current
// thread's runloop. On each cycle of the run loop, the run loop checks each of
// its sources for work to do, which in the case of CFRunLoopSource is just
// checking if CFRunLoopSourceSignal has been called since the last time it ran,
// and if so invokes the function pointer supplied when the source is created,
// which in our case just invokes `[realm handleExternalChange]`.

// Listening for external changes is done using kqueue() on a background thread.
// kqueue() lets us efficiently wait until the amount of data which can be read
// from one or more file descriptors has changed, and tells us which of the file
// descriptors it was that changed. We use this to wait on both the shared named
// pipe, and a local anonymous pipe. When data is written to the named pipe, we
// signal the runloop source and wake up the target runloop, and when data is
// written to the anonymous pipe the background thread removes the runloop
// source from the runloop and and shuts down.

@implementation RLMNotifier {
    // Realm to notify of changes
    __weak RLMRealm *_realm;
    // Runloop which notifications are delivered on
    CFRunLoopRef _runLoop;
    CFRunLoopSourceRef _signal;

    // Read-write file descriptor for the named pipe which is waited on for
    // changes and written to when a commit is made
    FdHolder _notifyFd;
    // File descriptor for the kqueue
    FdHolder _kq;
    // The two ends of an anonymous pipe used to notify the kqueue() thread that
    // it should be shut down.
    FdHolder _shutdownReadFd;
    FdHolder _shutdownWriteFd;
}

- (instancetype)initWithRealm:(RLMRealm *)realm {
    self = [super init];
    if (self) {
        _realm = realm;
        _runLoop = CFRunLoopGetCurrent();
        _kq = checkError(kqueue());

        const char *path = [realm.path stringByAppendingString:@".note"].UTF8String;

        // Create and open the named pipe
        checkError(mkfifo(path, 0600));
        _notifyFd = checkError(open(path, O_RDWR));
        // Make writing to the pipe return -1 when the pipe's buffer is full
        // rather than blocking until there's space available
        fcntl(_notifyFd, F_SETFL, O_NONBLOCK);

        // Create the anonymous pipe
        int pipeFd[2];
        checkError(pipe(pipeFd));
        _shutdownReadFd = pipeFd[0];
        _shutdownWriteFd = pipeFd[1];

        // Create the runloop source
        CFRunLoopSourceContext ctx{};
        ctx.info = (__bridge void *)self;
        ctx.perform = [](void *info) {
            RLMNotifier *notifier = (__bridge RLMNotifier *)info;
            if (RLMRealm *realm = notifier->_realm) {
                [realm handleExternalCommit];
            }
        };

        _signal = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &ctx);
        CFRunLoopAddSource(_runLoop, _signal, kCFRunLoopDefaultMode);
        CFRelease(_signal); // the runloop retains the signal

        [self listen];
    }
    return self;
}

- (void)listen {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Set up the kqueue
        // EVFILT_READ indicates that we care about data being available to read
        // on the given file descriptor.
        // EV_CLEAR makes it wait for the amount of data available to be read to
        // change rather than just returning when there is any data to read.
        struct kevent ke[2];
        EV_SET(&ke[0], _notifyFd, EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, 0);
        EV_SET(&ke[1], _shutdownReadFd, EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, 0);
        kevent(_kq, ke, 2, nullptr, 0, nullptr);

        while (true) {
            struct kevent event;
            // Wait for data to become on either fd
            // Return code is number of bytes available or -1 on error
            int ret = kevent(_kq, nullptr, 0, &event, 1, nullptr);
            assert(ret >= 0);
            if (ret == 0) {
                // Spurious wakeup; just wait again
                continue;
            }

            // Check which file descriptor had activity: if it's the shutdown
            // pipe, then someone called -stop; otherwise it's the named pipe
            // and someone committed a write transaction
            if (event.ident == (uint32_t)_shutdownReadFd) {
                CFRunLoopSourceInvalidate(_signal);
                return;
            }

            CFRunLoopSourceSignal(_signal);
            // Signalling the source makes it run the next time the runloop gets
            // to it, but doesn't make the runloop start if it's currently idle
            // waiting for events
            CFRunLoopWakeUp(_runLoop);
        }
    });
}

- (void)stop {
    notifyFd(_shutdownWriteFd);
}

- (void)notifyOtherRealms {
    notifyFd(_notifyFd);
}
@end
