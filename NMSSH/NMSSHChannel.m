#import "NMSSHChannel.h"
#import "NMSSH+Protected.h"

@interface NMSSHChannel ()
@property (nonatomic, strong) NMSSHSession *session;
@property (nonatomic, assign) LIBSSH2_CHANNEL *channel;

@property (nonatomic, readwrite) NMSSHChannelType type;
@property (nonatomic, assign) const char *ptyTerminalName;
@property (nonatomic, strong) NSString *lastResponse;

#if OS_OBJECT_USE_OBJC
@property (nonatomic, strong) dispatch_source_t source;
#else
@property (nonatomic, assign) dispatch_source_t source;
#endif
@end

@implementation NMSSHChannel

// -----------------------------------------------------------------------------
#pragma mark - INITIALIZER
// -----------------------------------------------------------------------------

- (instancetype)initWithSession:(NMSSHSession *)session {
    if ((self = [super init])) {
        [self setSession:session];
        [self setBufferSize:kNMSSHBufferSize];
        [self setRequestPty:NO];
        [self setPtyTerminalType:NMSSHChannelPtyTerminalVanilla];
        [self setType:NMSSHChannelTypeClosed];

        // Make sure we were provided a valid session
        if (![self.session isKindOfClass:[NMSSHSession class]]) {
            @throw @"You have to provide a valid NMSSHSession!";
        }
    }

    return self;
}

- (BOOL)openChannel:(NSError *__autoreleasing *)error {
    pthread_mutex_lock(&self.session->wrapperLock);
    if (self.channel != NULL) {
        NMSSHLogWarn(@"The channel will be closed before continue");
        if (self.type == NMSSHChannelTypeShell) {
            [self closeShell];
        }
        else {
            [self closeChannel];
        }
    }

    
    // Set blocking mode
    libssh2_session_set_blocking(self.session.rawSession, 1);

    // Open up the channel
    LIBSSH2_CHANNEL *channel = libssh2_channel_open_session(self.session.rawSession);

    if (channel == NULL){
        NMSSHLogError(@"Unable to open a session");
        if (error) {
            *error = [NSError errorWithDomain:@"NMSSH"
                                         code:NMSSHChannelAllocationError
                                     userInfo:@{ NSLocalizedDescriptionKey : @"Channel allocation error" }];
        }

        pthread_mutex_unlock(&self.session->wrapperLock);
        return NO;
    }

    [self setChannel:channel];

    // Try to set environment variables
    if (self.environmentVariables) {
        for (NSString *key in self.environmentVariables) {
            if ([key isKindOfClass:[NSString class]] && [[self.environmentVariables objectForKey:key] isKindOfClass:[NSString class]]) {
                libssh2_channel_setenv(self.channel, [key UTF8String], [[self.environmentVariables objectForKey:key] UTF8String]);
            }
        }
    }

    int rc = 0;

    // If requested, try to allocate a pty
    if (self.requestPty) {
        rc = libssh2_channel_request_pty(self.channel, self.ptyTerminalName);

        if (rc != 0) {
            if (error) {
                NSDictionary *userInfo = @{ NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Error requesting %s pty: %@", self.ptyTerminalName, [[self.session lastError] localizedDescription]] };

                *error = [NSError errorWithDomain:@"NMSSH"
                                             code:NMSSHChannelRequestPtyError
                                         userInfo:userInfo];
            }

            NMSSHLogError(@"Error requesting pseudo terminal");
            [self closeChannel];

            pthread_mutex_unlock(&self.session->wrapperLock);
            return NO;
        }
    }

    pthread_mutex_unlock(&self.session->wrapperLock);
    
    return YES;
}

- (void)closeChannel {
    // Set blocking mode
    pthread_mutex_lock(&self.session->wrapperLock);
    if (self.session.rawSession) {
        libssh2_session_set_blocking(self.session.rawSession, 1);
    }

    if (self.channel) {
        int rc;

        rc = libssh2_channel_close(self.channel);

        if (rc == 0) {
            libssh2_channel_wait_closed(self.channel);
        }

        libssh2_channel_free(self.channel);
        [self setType:NMSSHChannelTypeClosed];
        [self setChannel:NULL];
    }
    pthread_mutex_unlock(&self.session->wrapperLock);
}

- (BOOL)sendEOF {
    int rc;

    pthread_mutex_lock(&self.session->wrapperLock);
    // Send EOF to host
    rc = libssh2_channel_send_eof(self.channel);
    pthread_mutex_unlock(&self.session->wrapperLock);
    NMSSHLogVerbose(@"Sent EOF to host (return code = %i)", rc);

    return rc == 0;
}

- (void)waitEOF {
    pthread_mutex_lock(&self.session->wrapperLock);
    if (libssh2_channel_eof(self.channel) == 0) {
        // Wait for host acknowledge
        int rc = libssh2_channel_wait_eof(self.channel);
        NMSSHLogVerbose(@"Received host acknowledge for EOF (return code = %i)", rc);
    }
    pthread_mutex_unlock(&self.session->wrapperLock);
}

// -----------------------------------------------------------------------------
#pragma mark - SHELL COMMAND EXECUTION
// -----------------------------------------------------------------------------

- (const char *)ptyTerminalName {
    switch (self.ptyTerminalType) {
        case NMSSHChannelPtyTerminalVanilla:
            return "vanilla";

        case NMSSHChannelPtyTerminalVT100:
            return "vt100";

        case NMSSHChannelPtyTerminalVT102:
            return "vt102";

        case NMSSHChannelPtyTerminalVT220:
            return "vt220";

        case NMSSHChannelPtyTerminalAnsi:
            return "ansi";

        case NMSSHChannelPtyTerminalXterm:
            return "xterm";
    }

    // catch invalid values
    return "vanilla";
}

- (void)executeStream:(NSString *)command channelStream: (NMSSHChannelStream*)channelStream {
    NMSSHLogInfo(@"Exec command stream %@", command);
    
    // In case of error...
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:command forKey:@"command"];
    
    NSError *__autoreleasing error;
    
    if (![self openChannel:&error]) {
        [[channelStream delegate] onError:error];
        [[channelStream delegate] onExit:@1 exitSignal: NULL];
        return;
    }

    [self setLastResponse:nil];

    int rc = 0;
    [self setType:NMSSHChannelTypeExec];
    
    pthread_mutex_lock(&self.session->wrapperLock);
    // Try executing command
    rc = libssh2_channel_exec(self.channel, [command UTF8String]);
    pthread_mutex_unlock(&self.session->wrapperLock);
    
    if (rc != 0) {
        if (error) {
            [userInfo setObject:[[self.session lastError] localizedDescription] forKey:NSLocalizedDescriptionKey];
            [userInfo setObject:[NSString stringWithFormat:@"%i", rc] forKey:NSLocalizedFailureReasonErrorKey];

            error = [NSError errorWithDomain:@"NMSSH"
                                         code:NMSSHChannelExecutionError
                                     userInfo:userInfo];
        }
        
        char* exitSignal;
        size_t exitSignalLength;
        NSString *exitSignalString;
        
        pthread_mutex_lock(&self.session->wrapperLock);
        
        int esc = libssh2_channel_get_exit_signal(self.channel, &exitSignal, &exitSignalLength, NULL, NULL, NULL, NULL);
        
        pthread_mutex_unlock(&self.session->wrapperLock);
        
        if (exitSignal != NULL) exitSignal[exitSignalLength] = 0;
        
        if (esc == 0 && exitSignalLength > 0) {
            exitSignalString = [NSString stringWithFormat:@"%s", exitSignal];
        }

        NMSSHLogError(@"Error executing command");
        [self closeChannel];
        [[channelStream delegate] onError:error];
        [[channelStream delegate] onExit:@1 exitSignal:exitSignalString];
        return;
    }
    
    pthread_mutex_lock(&self.session->wrapperLock);
    // Set non-blocking mode
    libssh2_session_set_blocking(self.session.rawSession, 0);
    pthread_mutex_unlock(&self.session->wrapperLock);

    for (;;) {
        ssize_t rc;
        ssize_t erc;
        char buffer[self.bufferSize];
        char errorBuffer[self.bufferSize];

        do {
            pthread_mutex_lock(&self.session->wrapperLock);
            rc = libssh2_channel_read(self.channel, buffer, (ssize_t)sizeof(buffer));
            
            erc = libssh2_channel_read_stderr(self.channel, errorBuffer, (ssize_t)sizeof(errorBuffer));
            pthread_mutex_unlock(&self.session->wrapperLock);

            if (rc > 0) {
                [[channelStream delegate] onStdout:[[NSString alloc] initWithBytes:buffer length:rc encoding:NSUTF8StringEncoding]];
            }
            
            if (erc > 0) {
                [[channelStream delegate] onStderr:[[NSString alloc] initWithBytes:errorBuffer length:erc encoding:NSUTF8StringEncoding]];
            }

            pthread_mutex_lock(&self.session->wrapperLock);
            int exitCode = libssh2_channel_get_exit_status(self.channel);
            pthread_mutex_unlock(&self.session->wrapperLock);
            
            // Store all errors that might occur
            if (exitCode) {
                if (error) {
                
                    [userInfo setObject:[NSString stringWithFormat:@"%zi", erc] forKey:NSLocalizedFailureReasonErrorKey];
                    [userInfo setObject:[NSString stringWithFormat:@"%d", exitCode] forKey:@"exit_code"];

                    error = [NSError errorWithDomain:@"NMSSH"
                                                 code:NMSSHChannelExecutionError
                                             userInfo:userInfo];
                }
            }
            
            pthread_mutex_lock(&self.session->wrapperLock);
            int eof = libssh2_channel_eof(self.channel);
            pthread_mutex_unlock(&self.session->wrapperLock);

            if (eof == 1 || rc == 0) {
                while (true) {
                    pthread_mutex_lock(&self.session->wrapperLock);
                    rc  = libssh2_channel_read(self.channel, buffer, (ssize_t)sizeof(buffer));
                    pthread_mutex_unlock(&self.session->wrapperLock);
                    if (rc <= 0) { break; }
                    [[channelStream delegate] onStdout:[[NSString alloc] initWithBytes:buffer length:rc encoding:NSUTF8StringEncoding]];
                }
                while (true) {
                    pthread_mutex_lock(&self.session->wrapperLock);
                    erc  = libssh2_channel_read(self.channel, errorBuffer, (ssize_t)sizeof(errorBuffer));
                    pthread_mutex_unlock(&self.session->wrapperLock);
                    if (erc <= 0) { break; }
                    [[channelStream delegate] onStderr:[[NSString alloc] initWithBytes:errorBuffer length:erc encoding:NSUTF8StringEncoding]];
                }
                
                char* exitSignal;
                size_t exitSignalLength;
                NSString *exitSignalString;
                
                pthread_mutex_lock(&self.session->wrapperLock);
                
                int esc = libssh2_channel_get_exit_signal(self.channel, &exitSignal, &exitSignalLength, NULL, NULL, NULL, NULL);
                
                pthread_mutex_unlock(&self.session->wrapperLock);
                
                if (exitSignal != NULL) exitSignal[exitSignalLength] = 0;
                
                if (esc == 0 && exitSignalLength > 0) {
                    exitSignalString = [NSString stringWithFormat:@"%s", exitSignal];
                }
                
                [self closeChannel];
                
                if (error) {
                    [[channelStream delegate] onError:error];
                }

                [[channelStream delegate] onExit:[NSNumber numberWithInt:exitCode] exitSignal:exitSignalString];
                return;
            }

        } while (rc > 0);

        if (rc != LIBSSH2_ERROR_EAGAIN) {
            break;
        }

        waitsocket(CFSocketGetNative([self.session socket]), self.session.rawSession);
    }

    // If we've got this far, it means fetching execution response failed
    if (error) {
        [userInfo setObject:[[self.session lastError] localizedDescription] forKey:NSLocalizedDescriptionKey];
        error = [NSError errorWithDomain:@"NMSSH"
                                     code:NMSSHChannelExecutionResponseError
                                 userInfo:userInfo];
        
        [[channelStream delegate] onError:error];
    }
    
    char* exitSignal;
    size_t exitSignalLength;
    NSString *exitSignalString;
    
    pthread_mutex_lock(&self.session->wrapperLock);
    
    int esc = libssh2_channel_get_exit_signal(self.channel, &exitSignal, &exitSignalLength, NULL, NULL, NULL, NULL);
    
    pthread_mutex_unlock(&self.session->wrapperLock);
    
    exitSignal[exitSignalLength] = 0;
    
    if (esc == 0 && exitSignalLength > 0) {
        exitSignalString = [NSString stringWithFormat:@"%s", exitSignal];
    }

    NMSSHLogError(@"Error fetching response from command");
    [self closeChannel];
    
    [[channelStream delegate] onExit:@1 exitSignal:exitSignalString];
}

- (NSString *)execute:(NSString *)command error:(NSError *__autoreleasing *)error {
    return [self execute:command error:error timeout:@0];
}

- (NSString *)execute:(NSString *)command error:(NSError *__autoreleasing *)error stdout_out: (NSString **)stdout_out stderr_out: (NSString **)stderr_out {
    return [self execute:command error:error stdout_out:stdout_out stderr_out:stderr_out timeout:@0];
}

- (NSString *)execute:(NSString *)command error:(NSError *__autoreleasing *)error stdout_out: (NSString **)stdout_out stderr_out: (NSString **)stderr_out timeout:(NSNumber *)timeout {
    NSNumber *exitCode;
    NSString *exitSignal;
    return [self execute:command error:error stdout_out:stdout_out stderr_out:stderr_out exitCode:&exitCode exitSignal:&exitSignal timeout:timeout];
}

- (NSString *)execute:(NSString *)command error:(NSError *__autoreleasing *)error stdout_out: (NSString **)stdout_out stderr_out: (NSString **)stderr_out exitSignal: (NSString * *)exitSignal timeout:(NSNumber *)timeout {
    NSNumber *exitCode;
    return [self execute:command error:error stdout_out:stdout_out stderr_out:stderr_out exitCode:&exitCode exitSignal:exitSignal timeout:timeout];
}

- (NSString *)execute:(NSString *)command error:(NSError *__autoreleasing *)error stdout_out: (NSString **)stdout_out stderr_out: (NSString **)stderr_out exitCode: (NSNumber **)exitCode timeout:(NSNumber *)timeout {
    NSString *exitSignal;
    return [self execute:command error:error stdout_out:stdout_out stderr_out:stderr_out exitCode:exitCode exitSignal:&exitSignal timeout:timeout];
}

- (NSString *)execute:(NSString *)command error:(NSError *__autoreleasing *)error stdout_out: (NSString **)stdout_out stderr_out: (NSString **)stderr_out exitSignal: (NSString * *)exitSignal {
    NSNumber *exitCode;
    return [self execute:command error:error stdout_out:stdout_out stderr_out:stderr_out exitCode:&exitCode exitSignal:exitSignal timeout:@0];
}

- (NSString *)execute:(NSString *)command error:(NSError *__autoreleasing *)error stdout_out: (NSString **)stdout_out stderr_out: (NSString **)stderr_out exitCode: (NSNumber **)exitCode {
    NSString *exitSignal;
    return [self execute:command error:error stdout_out:stdout_out stderr_out:stderr_out exitCode:exitCode exitSignal:&exitSignal timeout:@0];
}

- (NSString *)execute:(NSString *)command error:(NSError *__autoreleasing *)error stdout_out: (NSString **)stdout_out stderr_out: (NSString **)stderr_out exitCode: (NSNumber **)exitCode exitSignal: (NSString * *)exitSignal {
    return [self execute:command error:error stdout_out:stdout_out stderr_out:stderr_out exitCode:exitCode exitSignal:exitSignal timeout:@0];
}

- (NSString *)execute:(NSString *)command error:(NSError *__autoreleasing *)error stdout_out: (NSString **)stdout_out stderr_out: (NSString **)stderr_out exitCode: (NSNumber **)exitCode exitSignal: (NSString * *)exitSignal timeout:(NSNumber *)timeout {
    NMSSHLogInfo(@"Exec command %@", command);

    // In case of error...
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:command forKey:@"command"];

    if (![self openChannel:error]) {
        *exitCode = [NSNumber numberWithInt:1];
        return nil;
    }

    [self setLastResponse:nil];

    int rc = 0;
    [self setType:NMSSHChannelTypeExec];

    pthread_mutex_lock(&self.session->wrapperLock);
    // Try executing command
    rc = libssh2_channel_exec(self.channel, [command UTF8String]);
    pthread_mutex_unlock(&self.session->wrapperLock);

    if (rc != 0) {
        if (error) {
            [userInfo setObject:[[self.session lastError] localizedDescription] forKey:NSLocalizedDescriptionKey];
            [userInfo setObject:[NSString stringWithFormat:@"%i", rc] forKey:NSLocalizedFailureReasonErrorKey];

            *error = [NSError errorWithDomain:@"NMSSH"
                                         code:NMSSHChannelExecutionError
                                     userInfo:userInfo];
        }

        *exitCode = [NSNumber numberWithInt:1];
        
        NMSSHLogError(@"Error executing command");
        [self closeChannel];
        return nil;
    }

    pthread_mutex_lock(&self.session->wrapperLock);
    // Set non-blocking mode
    libssh2_session_set_blocking(self.session.rawSession, 0);
    pthread_mutex_unlock(&self.session->wrapperLock);

    // Set the timeout for blocking session
    CFAbsoluteTime time = CFAbsoluteTimeGetCurrent() + [timeout doubleValue];
    
    NSMutableString *response = [[NSMutableString alloc] init];
    NSMutableString *response_stderr = [[NSMutableString alloc] init];

    for (;;) {
        ssize_t rc;
        ssize_t erc;
        char buffer[self.bufferSize];
        char errorBuffer[self.bufferSize];

        do {
            pthread_mutex_lock(&self.session->wrapperLock);
            rc = libssh2_channel_read(self.channel, buffer, (ssize_t)sizeof(buffer));
            
            erc = libssh2_channel_read_stderr(self.channel, errorBuffer, (ssize_t)sizeof(errorBuffer));
            pthread_mutex_unlock(&self.session->wrapperLock);

            if (rc > 0) {
                [response appendFormat:@"%@", [[NSString alloc] initWithBytes:buffer length:rc encoding:NSUTF8StringEncoding]];
            }
            
            if (erc > 0) {
                [response_stderr appendFormat:@"%@", [[NSString alloc] initWithBytes:errorBuffer length:erc encoding:NSUTF8StringEncoding]];
            }
            
            char* exitSignalChar;
            size_t exitSignalLength;
            
            pthread_mutex_lock(&self.session->wrapperLock);
            int exitCodeResponse = libssh2_channel_get_exit_status(self.channel);
            int esc = libssh2_channel_get_exit_signal(self.channel, &exitSignalChar, &exitSignalLength, NULL, NULL, NULL, NULL);
            pthread_mutex_unlock(&self.session->wrapperLock);
            
            if (exitSignalChar != NULL) exitSignalChar[exitSignalLength] = 0;
            
            // Store all errors that might occur
            if (exitCodeResponse) {
                if (error) {
                
                    [userInfo setObject:[response_stderr copy] forKey:NSLocalizedDescriptionKey];
                    [userInfo setObject:[NSString stringWithFormat:@"%zi", erc] forKey:NSLocalizedFailureReasonErrorKey];
                    [userInfo setObject:[NSString stringWithFormat:@"%d", exitCodeResponse] forKey:@"exit_code"];

                    *error = [NSError errorWithDomain:@"NMSSH"
                                                 code:NMSSHChannelExecutionError
                                             userInfo:userInfo];
                }
            }

            pthread_mutex_lock(&self.session->wrapperLock);
            int eof = libssh2_channel_eof(self.channel);
            pthread_mutex_unlock(&self.session->wrapperLock);
            
            if (eof == 1 || rc == 0) {
                while (true) {
                    pthread_mutex_lock(&self.session->wrapperLock);
                    rc  = libssh2_channel_read(self.channel, buffer, (ssize_t)sizeof(buffer));
                    pthread_mutex_unlock(&self.session->wrapperLock);
                    if (rc <= 0) { break; }
                    [response appendFormat:@"%@", [[NSString alloc] initWithBytes:buffer length:rc encoding:NSUTF8StringEncoding] ];
                }
                while (true) {
                    pthread_mutex_lock(&self.session->wrapperLock);
                    erc  = libssh2_channel_read(self.channel, errorBuffer, (ssize_t)sizeof(errorBuffer));
                    pthread_mutex_unlock(&self.session->wrapperLock);
                    if (erc <= 0) { break; }
                    [response_stderr appendFormat:@"%@", [[NSString alloc] initWithBytes:errorBuffer length:erc encoding:NSUTF8StringEncoding] ];
                }

                *stdout_out = [response copy];
                *stderr_out = [response_stderr copy];
                
                if (esc == 0 && exitSignalLength > 0) {
                    *exitSignal = [NSString stringWithFormat:@"%s", exitSignalChar];
                }
                
                *exitCode = [NSNumber numberWithInt:exitCodeResponse];
                
                [self setLastResponse:[response copy]];
                [self closeChannel];

                return self.lastResponse;
            }

            // Check if the connection timed out
            if ([timeout longValue] > 0 && time < CFAbsoluteTimeGetCurrent()) {
                if (error) {
                    NSString *desc = @"Connection timed out";

                    [userInfo setObject:desc forKey:NSLocalizedDescriptionKey];

                    *error = [NSError errorWithDomain:@"NMSSH"
                                                 code:NMSSHChannelExecutionTimeout
                                             userInfo:userInfo];
                }

                while (true) {
                    pthread_mutex_lock(&self.session->wrapperLock);
                    rc  = libssh2_channel_read(self.channel, buffer, (ssize_t)sizeof(buffer));
                    pthread_mutex_unlock(&self.session->wrapperLock);
                    if (rc <= 0) { break; }
                    [response appendFormat:@"%@", [[NSString alloc] initWithBytes:buffer length:rc encoding:NSUTF8StringEncoding] ];
                }
                while (true) {
                    pthread_mutex_lock(&self.session->wrapperLock);
                    erc  = libssh2_channel_read(self.channel, errorBuffer, (ssize_t)sizeof(errorBuffer));
                    pthread_mutex_unlock(&self.session->wrapperLock);
                    if (erc <= 0) { break; }
                    [response_stderr appendFormat:@"%@", [[NSString alloc] initWithBytes:errorBuffer length:erc encoding:NSUTF8StringEncoding] ];
                }

                *stdout_out = [response copy];
                *stderr_out = [response_stderr copy];
                
                *exitCode = [NSNumber numberWithInt:exitCodeResponse];
                
                [self setLastResponse:[response copy]];
                [self closeChannel];

                return self.lastResponse;
            }
        } while (rc > 0);

        if (rc != LIBSSH2_ERROR_EAGAIN) {
            break;
        }

        waitsocket(CFSocketGetNative([self.session socket]), self.session.rawSession);
    }

    // If we've got this far, it means fetching execution response failed
    if (error) {
        [userInfo setObject:[[self.session lastError] localizedDescription] forKey:NSLocalizedDescriptionKey];
        *error = [NSError errorWithDomain:@"NMSSH"
                                     code:NMSSHChannelExecutionResponseError
                                 userInfo:userInfo];
    }
    
    *exitCode = [NSNumber numberWithInt:1];

    NMSSHLogError(@"Error fetching response from command");
    [self closeChannel];

    return nil;
}

- (NSString *)execute:(NSString *)command error:(NSError *__autoreleasing *)error timeout:(NSNumber *)timeout {
    NSString *response_stdout = [NSString alloc];
    NSString *response_stderr = [NSString alloc];
    return [self execute:command error:error stdout_out:&response_stdout stderr_out:&response_stderr timeout:@0];
}

// -----------------------------------------------------------------------------
#pragma mark - REMOTE SHELL SESSION
// -----------------------------------------------------------------------------

- (BOOL)startShell:(NSError *__autoreleasing *)error  {
    NMSSHLogInfo(@"Starting shell");

    if (![self openChannel:error]) {
        return NO;
    }

    pthread_mutex_lock(&self.session->wrapperLock);
    // Set non-blocking mode
    libssh2_session_set_blocking(self.session.rawSession, 0);
    pthread_mutex_unlock(&self.session->wrapperLock);

    // Fetch response from output buffer
#if !(OS_OBJECT_USE_OBJC)
    if (self.source) {
        dispatch_release(self.source);
    }
#endif

    [self setLastResponse:nil];
    [self setSource:dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, CFSocketGetNative([self.session socket]),
                                           0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0))];
    dispatch_source_set_event_handler(self.source, ^{
        NMSSHLogVerbose(@"Data available on the socket!");
        ssize_t rc, erc=0;
        char buffer[self.bufferSize];

        while (self.channel != NULL) {

            pthread_mutex_lock(&self.session->wrapperLock);
            rc = libssh2_channel_read(self.channel, buffer, (ssize_t)sizeof(buffer));
            erc = libssh2_channel_read_stderr(self.channel, buffer, (ssize_t)sizeof(buffer));
            pthread_mutex_unlock(&self.session->wrapperLock);

            if (!(rc >=0 || erc >= 0)) {
                NMSSHLogVerbose(@"Return code of response %ld, error %ld", (long)rc, (long)erc);

                if (rc == LIBSSH2_ERROR_SOCKET_RECV || erc == LIBSSH2_ERROR_SOCKET_RECV) {
                    NMSSHLogVerbose(@"Error received, closing channel...");
                    [self closeShell];
                }
                return;
            }
            else if (rc > 0) {
                NSData *data = [[NSData alloc] initWithBytes:buffer length:rc];
                NSString *response = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                [self setLastResponse:[response copy]];

                if (response && self.delegate && [self.delegate respondsToSelector:@selector(channel:didReadData:)]) {
                    [self.delegate channel:self didReadData:self.lastResponse];
                }

                if (self.delegate && [self.delegate respondsToSelector:@selector(channel:didReadRawData:)]) {
                    [self.delegate channel:self didReadRawData:data];
                }
            }
            else if (erc > 0) {
                NSData *data = [[NSData alloc] initWithBytes:buffer length:erc];
                NSString *response = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

                if (response && self.delegate && [self.delegate respondsToSelector:@selector(channel:didReadError:)]) {
                    [self.delegate channel:self didReadError:response];
                }

                if (self.delegate && [self.delegate respondsToSelector:@selector(channel:didReadRawError:)]) {
                    [self.delegate channel:self didReadRawError:data];
                }
            }
            else {
                pthread_mutex_lock(&self.session->wrapperLock);
                int get = libssh2_channel_eof(self.channel);
                pthread_mutex_unlock(&self.session->wrapperLock);
                if (get == 1) {
                    NMSSHLogVerbose(@"Host EOF received, closing channel...");
                    [self closeShell];
                }
            }
        }
    });

    dispatch_source_set_cancel_handler(self.source, ^{
        NMSSHLogVerbose(@"Shell source cancelled");

        if (self.delegate && [self.delegate respondsToSelector:@selector(channelShellDidClose:)]) {
            [self.delegate channelShellDidClose:self];
        }
    });

    dispatch_resume(self.source);

    int rc = 0;

    // Try opening the shell
    while (true) {
        pthread_mutex_lock(&self.session->wrapperLock);
        rc = libssh2_channel_shell(self.channel);
        pthread_mutex_unlock(&self.session->wrapperLock);
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            waitsocket(CFSocketGetNative([self.session socket]), [self.session rawSession]);
        } else {
            break;
        }
    }

    if (rc != 0) {
        NMSSHLogError(@"Shell request error");
        if (error) {
            *error = [NSError errorWithDomain:@"NMSSH"
                                         code:NMSSHChannelRequestShellError
                                     userInfo:@{ NSLocalizedDescriptionKey : [[self.session lastError] localizedDescription] }];
        }

        [self closeShell];
        return NO;
    }

    NMSSHLogVerbose(@"Shell allocated");
    [self setType:NMSSHChannelTypeShell];

    return YES;
}

- (void)closeShell {
    if (self.source) {
        dispatch_source_cancel(self.source);
#if !(OS_OBJECT_USE_OBJC)
        dispatch_release(self.source);
#endif
        [self setSource: nil];
    }

    if (self.type == NMSSHChannelTypeShell) {
        // Set blocking mode
        pthread_mutex_lock(&self.session->wrapperLock);
        libssh2_session_set_blocking(self.session.rawSession, 1);
        pthread_mutex_unlock(&self.session->wrapperLock);

        [self sendEOF];
    }

    [self closeChannel];
}

- (BOOL)write:(NSString *)command error:(NSError *__autoreleasing *)error {
    return [self write:command error:error timeout:@0];
}

- (BOOL)write:(NSString *)command error:(NSError *__autoreleasing *)error timeout:(NSNumber *)timeout {
    return [self writeData:[command dataUsingEncoding:NSUTF8StringEncoding] error:error timeout:timeout];
}

- (BOOL)writeData:(NSData *)data error:(NSError *__autoreleasing *)error {
    return [self writeData:data error:error timeout:@0];
}

- (BOOL)writeData:(NSData *)data error:(NSError *__autoreleasing *)error timeout:(NSNumber *)timeout {
    if (self.type != NMSSHChannelTypeShell) {
        NMSSHLogError(@"Shell required");
        return NO;
    }

    ssize_t rc;

    // Set the timeout
    CFAbsoluteTime time = CFAbsoluteTimeGetCurrent() + [timeout doubleValue];

    // Try writing on shell
    while (true) {
        pthread_mutex_lock(&self.session->wrapperLock);
        rc = libssh2_channel_write(self.channel, [data bytes], [data length]);
        pthread_mutex_unlock(&self.session->wrapperLock);
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            // Check if the connection timed out
            if ([timeout longValue] > 0 && time < CFAbsoluteTimeGetCurrent()) {
                if (error) {
                    NSString *description = @"Connection timed out";

                    *error = [NSError errorWithDomain:@"NMSSH"
                                                 code:NMSSHChannelExecutionTimeout
                                             userInfo:@{ NSLocalizedDescriptionKey : description }];
                }

                return NO;
            }

            waitsocket(CFSocketGetNative([self.session socket]), self.session.rawSession);
        } else {
            break;
        }
    }

    if (rc < 0) {
        NMSSHLogError(@"Error writing on the shell");
        if (error) {
            NSString *command = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            *error = [NSError errorWithDomain:@"NMSSH"
                                         code:NMSSHChannelWriteError
                                     userInfo:@{ NSLocalizedDescriptionKey : [[self.session lastError] localizedDescription],
                                                 @"command"                : command }];
        }
    }

    return YES;
}

- (BOOL)requestSizeWidth:(NSUInteger)width height:(NSUInteger)height {
    pthread_mutex_lock(&self.session->wrapperLock);
    int rc = libssh2_channel_request_pty_size(self.channel, (int)width, (int)height);
    pthread_mutex_unlock(&self.session->wrapperLock);
    if (rc) {
        NMSSHLogError(@"Request size failed with error %i", rc);
    }

    return rc == 0;
}

// -----------------------------------------------------------------------------
#pragma mark - SCP FILE TRANSFER
// -----------------------------------------------------------------------------

- (BOOL)uploadFile:(NSString *)localPath to:(NSString *)remotePath {
    return [self uploadFile:localPath to:remotePath progress:NULL];
}

- (BOOL)uploadFile:(NSString *)localPath to:(NSString *)remotePath progress:(BOOL (^)(NSUInteger))progress {
    if (self.channel != NULL) {
        NMSSHLogWarn(@"The channel will be closed before continue");

        if (self.type == NMSSHChannelTypeShell) {
            [self closeShell];
        }
        else {
            [self closeChannel];
        }
    }

    localPath = [localPath stringByExpandingTildeInPath];

    // Inherit file name if to: contains a directory
    if ([remotePath hasSuffix:@"/"]) {
        remotePath = [remotePath stringByAppendingString:
                      [[localPath componentsSeparatedByString:@"/"] lastObject]];
    }

    // Read local file
    FILE *local = fopen([localPath UTF8String], "rb");
    if (!local) {
        NMSSHLogError(@"Can't read local file");
        return NO;
    }

    // Set blocking mode
    pthread_mutex_lock(&self.session->wrapperLock);
    libssh2_session_set_blocking(self.session.rawSession, 1);
    pthread_mutex_unlock(&self.session->wrapperLock);

    // Try to send a file via SCP.
    struct stat fileinfo;
    stat([localPath UTF8String], &fileinfo);
    pthread_mutex_lock(&self.session->wrapperLock);
    LIBSSH2_CHANNEL *channel = libssh2_scp_send64(self.session.rawSession, [remotePath UTF8String], fileinfo.st_mode & 0644,
                                                  (unsigned long)fileinfo.st_size, 0, 0);;
    pthread_mutex_unlock(&self.session->wrapperLock);

    if (channel == NULL) {
        NMSSHLogError(@"Unable to open SCP session");
        fclose(local);

        return NO;
    }

    [self setChannel:channel];
    [self setType:NMSSHChannelTypeSCP];

    // Wait for file transfer to finish
    char mem[self.bufferSize];
    size_t nread;
    char *ptr;
    long rc;
    NSUInteger total = 0;
    BOOL abort = NO;
    while (!abort && (nread = fread(mem, 1, sizeof(mem), local)) > 0) {
        ptr = mem;

        do {
            // Write the same data over and over, until error or completion
            pthread_mutex_lock(&self.session->wrapperLock);
            rc = libssh2_channel_write(self.channel, ptr, nread);
            pthread_mutex_unlock(&self.session->wrapperLock);

            if (rc < 0) {
                NMSSHLogError(@"Failed writing file");
                [self closeChannel];
                return NO;
            }
            else {
                // rc indicates how many bytes were written this time
                total += rc;
                if (progress && !progress(total)) {
                    abort = YES;
                    break;
                }
                ptr += rc;
                nread -= rc;
            }
        } while (nread);
    };

    fclose(local);

    if ([self sendEOF]) {
        [self waitEOF];
    }
    [self closeChannel];

    return !abort;
}

- (BOOL)downloadFile:(NSString *)remotePath to:(NSString *)localPath {
    return [self downloadFile:remotePath to:localPath progress:NULL];
}

- (BOOL)downloadFile:(NSString *)remotePath to:(NSString *)localPath progress:(BOOL (^)(NSUInteger, NSUInteger))progress {
    if (self.channel != NULL) {
        NMSSHLogWarn(@"The channel will be closed before continue");

        if (self.type == NMSSHChannelTypeShell) {
            [self closeShell];
        }
        else {
            [self closeChannel];
        }
    }

    localPath = [localPath stringByExpandingTildeInPath];

    // Inherit file name if to: contains a directory
    if ([localPath hasSuffix:@"/"]) {
        localPath = [localPath stringByAppendingString:[[remotePath componentsSeparatedByString:@"/"] lastObject]];
    }

    // Set blocking mode
    pthread_mutex_lock(&self.session->wrapperLock);
    libssh2_session_set_blocking(self.session.rawSession, 1);
    pthread_mutex_unlock(&self.session->wrapperLock);

    // Request a file via SCP
    struct stat fileinfo;
    pthread_mutex_lock(&self.session->wrapperLock);
    LIBSSH2_CHANNEL *channel = libssh2_scp_recv(self.session.rawSession, [remotePath UTF8String], &fileinfo);
    pthread_mutex_unlock(&self.session->wrapperLock);

    if (channel == NULL) {
        NMSSHLogError(@"Unable to open SCP session");
        return NO;
    }

    [self setChannel:channel];
    [self setType:NMSSHChannelTypeSCP];

    if ([[NSFileManager defaultManager] fileExistsAtPath:localPath]) {
        NMSSHLogInfo(@"A file already exists at %@, it will be overwritten", localPath);
        [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
    }

    // Open local file in order to write to it
    int localFile = open([localPath UTF8String], O_WRONLY|O_CREAT, 0644);

    // Save data to local file
    off_t got = 0;
    while (got < fileinfo.st_size) {
        char mem[self.bufferSize];
        size_t amount = sizeof(mem);

        if ((fileinfo.st_size - got) < amount) {
            amount = (size_t)(fileinfo.st_size - got);
        }

        pthread_mutex_lock(&self.session->wrapperLock);
        ssize_t rc = libssh2_channel_read(self.channel, mem, amount);
        pthread_mutex_unlock(&self.session->wrapperLock);

        if (rc > 0) {
            size_t n = write(localFile, mem, rc);
            if (n < rc) {
                NMSSHLogError(@"Failed to write to local file");
                close(localFile);
                [self closeChannel];
                return NO;
            }
            got += rc;
            if (progress && !progress((NSUInteger)got, (NSUInteger)fileinfo.st_size)) {
                close(localFile);
                [self closeChannel];
                return NO;
            }
        }
        else if (rc < 0) {
            NMSSHLogError(@"Failed to read SCP data");
            close(localFile);
            [self closeChannel];

            return NO;
        }

        memset(mem, 0x0, sizeof(mem));
    }

    close(localFile);
    [self closeChannel];

    return YES;
}

@end
