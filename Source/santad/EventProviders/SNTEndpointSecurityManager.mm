/// Copyright 2019 Google Inc. All rights reserved.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///    http://www.apache.org/licenses/LICENSE-2.0
///
///    Unless required by applicable law or agreed to in writing, software
///    distributed under the License is distributed on an "AS IS" BASIS,
///    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
///    See the License for the specific language governing permissions and
///    limitations under the License.

#import "Source/santad/EventProviders/SNTEndpointSecurityManager.h"

#include "Source/common/SNTPrefixTree.h"

#import "Source/common/SNTConfigurator.h"
#import "Source/common/SNTLogging.h"
#import "Source/common/SantaCache.h"

#include <bsm/libbsm.h>
#include <libproc.h>
#include <atomic>

@interface SNTEndpointSecurityManager () {
  std::atomic<bool> _compilerPIDs[PID_MAX];
}

@property(nonatomic) SNTPrefixTree *prefixTree;
@property(nonatomic, readonly) dispatch_queue_t esAuthQueue;
@property(nonatomic, readonly) dispatch_queue_t esNotifyQueue;
@property(nonatomic, readonly) pid_t selfPID;

@end

@implementation SNTEndpointSecurityManager

- (instancetype)init API_AVAILABLE(macos(10.15)) {
  self = [super init];
  if (self) {
    // To avoid nil deref from es_events arriving before listenForDecisionRequests or
    // listenForLogRequests in the  MockEndpointSecurity testing util.
    _decisionCallback = ^(santa_message_t) {
    };
    _logCallback = ^(santa_message_t) {
    };
    [self establishClient];
    _prefixTree = new SNTPrefixTree();
    _esAuthQueue =
      dispatch_queue_create("com.google.santa.daemon.es_auth", DISPATCH_QUEUE_CONCURRENT);
    dispatch_set_target_queue(_esAuthQueue,
                              dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    _esNotifyQueue =
      dispatch_queue_create("com.google.santa.daemon.es_notify", DISPATCH_QUEUE_CONCURRENT);
    dispatch_set_target_queue(_esNotifyQueue, dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0));
    _selfPID = getpid();
  }

  return self;
}

- (void)dealloc API_AVAILABLE(macos(10.15)) {
  if (_client) {
    es_unsubscribe_all(_client);
    es_delete_client(_client);
  }
  if (_prefixTree) delete _prefixTree;
}

- (void)establishClient API_AVAILABLE(macos(10.15)) {
  while (!self.client) {
    SNTConfigurator *config = [SNTConfigurator configurator];

    es_client_t *client = NULL;
    es_new_client_result_t ret = es_new_client(&client, ^(es_client_t *c, const es_message_t *m) {
      pid_t pid = audit_token_to_pid(m->process->audit_token);
      int pidversion = audit_token_to_pidversion(m->process->audit_token);

      // If enabled, skip any action generated from another endpoint security client.
      if (m->process->is_es_client && config.ignoreOtherEndpointSecurityClients) {
        if (m->action_type == ES_ACTION_TYPE_AUTH) {
          es_respond_auth_result(self.client, m, ES_AUTH_RESULT_ALLOW, false);
        }
        if (self.selfPID != pid) {
          LOGD(@"Skipping event type: 0x%x from es_client pid: %d", m->event_type, pid);
        }
        return;
      }

      // Perform the following checks on this serial queue.
      // Some checks are simple filters that avoid copying m.
      // However, the bulk of the work done here is to support transitive whitelisting.
      switch (m->event_type) {
        case ES_EVENT_TYPE_NOTIFY_EXEC: {
          // Deny results are currently logged when ES_EVENT_TYPE_AUTH_EXEC posts a deny.
          // TODO(bur/rah): For ES log denies from NOTIFY messages instead of AUTH.
          if (m->action.notify.result.auth == ES_AUTH_RESULT_DENY) return;

          // Continue log this event
          break;
        }
        case ES_EVENT_TYPE_NOTIFY_CLOSE: {
          // Ignore unmodified files
          if (!m->event.close.modified) return;

          // Remove from decision cache in case this is invalidating a cached binary.
          [self removeCacheEntryForVnodeID:[self vnodeIDForFile:m->event.close.target]];

          // Create a transitive rule if the file was modified by a running compiler
          if ([self isCompilerPID:pid]) {
            santa_message_t sm = {};
            BOOL truncated = [self populateBufferFromESFile:m->event.close.target
                                                     buffer:sm.path
                                                       size:sizeof(sm.path)];
            if (truncated) {
              LOGE(@"CLOSE: error creating transitive rule, the path is truncated: path=%s pid=%d",
                   sm.path, pid);
              break;
            }
            if ([@(sm.path) hasPrefix:@"/dev/"]) {
              break;
            }
            sm.action = ACTION_NOTIFY_WHITELIST;
            sm.pid = pid;
            sm.pidversion = pidversion;
            LOGI(@"CLOSE: creating a transitive rule: path=%s pid=%d", sm.path, sm.pid);
            self.decisionCallback(sm);
          }

          // Continue log this event
          break;
        }
        case ES_EVENT_TYPE_NOTIFY_RENAME: {
          // Create a transitive rule if the file was renamed by a running compiler
          if ([self isCompilerPID:pid]) {
            santa_message_t sm = {};
            BOOL truncated = [self populateRenamedNewPathFromESMessage:m->event.rename
                                                                buffer:sm.path
                                                                  size:sizeof(sm.path)];
            if (truncated) {
              LOGE(@"RENAME: error creating transitive rule, the path is truncated: path=%s pid=%d",
                   sm.path, pid);
              break;
            }
            if ([@(sm.path) hasPrefix:@"/dev/"]) {
              break;
            }
            sm.action = ACTION_NOTIFY_WHITELIST;
            sm.pid = pid;
            sm.pidversion = pidversion;
            LOGI(@"RENAME: creating a transitive rule: path=%s pid=%d", sm.path, sm.pid);
            self.decisionCallback(sm);
          }

          // Continue log this event
          break;
        }
        case ES_EVENT_TYPE_NOTIFY_EXIT: {
          // Update the set of running compiler PIDs
          [self setNotCompilerPID:pid];

          // Skip the standard pipeline and just log.
          if (![config enableForkAndExitLogging]) return;
          santa_message_t sm = {};
          sm.action = ACTION_NOTIFY_EXIT;
          sm.pid = pid;
          sm.pidversion = pidversion;
          sm.ppid = m->process->original_ppid;
          audit_token_t at = m->process->audit_token;
          sm.uid = audit_token_to_ruid(at);
          sm.gid = audit_token_to_rgid(at);
          dispatch_async(self.esNotifyQueue, ^{
            self.logCallback(sm);
          });
          return;
        }
        case ES_EVENT_TYPE_NOTIFY_FORK: {
          // Skip the standard pipeline and just log.
          if (![config enableForkAndExitLogging]) return;
          santa_message_t sm = {};
          sm.action = ACTION_NOTIFY_FORK;
          sm.ppid = m->event.fork.child->original_ppid;
          audit_token_t at = m->event.fork.child->audit_token;
          sm.pid = audit_token_to_pid(at);
          sm.pidversion = audit_token_to_pidversion(at);
          sm.uid = audit_token_to_ruid(at);
          sm.gid = audit_token_to_rgid(at);
          dispatch_async(self.esNotifyQueue, ^{
            self.logCallback(sm);
          });
          return;
        }
        default: {
          break;
        }
      }

      switch (m->action_type) {
        case ES_ACTION_TYPE_AUTH: {
          // Create a timer to deny the execution 5 seconds before the deadline,
          // if a response hasn't already been sent. This block will still be enqueued if
          // the the deadline - 5 secs is < DISPATCH_TIME_NOW.
          // As of 10.15.5, a typical deadline is 60 seconds.
          auto responded = std::make_shared<std::atomic<bool>>(false);
          dispatch_after(dispatch_time(m->deadline, NSEC_PER_SEC * -5), self.esAuthQueue, ^(void) {
            if (responded->load()) return;
            LOGE(@"Deadline reached: deny pid=%d ret=%d", pid,
                 es_respond_auth_result(self.client, m, ES_AUTH_RESULT_DENY, false));
          });

          // Copy the message and return control back to ES
          es_message_t *mc = es_copy_message(m);
          dispatch_async(self.esAuthQueue, ^{
            [self messageHandler:mc];
            responded->store(true);
            es_free_message(mc);
          });
          break;
        }
        case ES_ACTION_TYPE_NOTIFY: {
          // Don't log fileop events from com.google.santa.daemon
          if (self.selfPID == pid && m->event_type != ES_EVENT_TYPE_NOTIFY_EXEC) return;

          // Copy the message and return control back to ES
          es_message_t *mc = es_copy_message(m);
          dispatch_async(self.esNotifyQueue, ^{
            [self messageHandler:mc];
            es_free_message(mc);
          });
          break;
        }
        default: {
          break;
        }
      }
    });

    switch (ret) {
      case ES_NEW_CLIENT_RESULT_SUCCESS:
        LOGI(@"Connected to EndpointSecurity");
        _client = client;
        return;
      case ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED:
        LOGE(@"Unable to create EndpointSecurity client, not full-disk access permitted");
        LOGE(@"Sleeping for 30s before restarting.");
        sleep(30);
        exit(ret);
      default:
        LOGE(@"Unable to create es client: %d. Sleeping for a minute.", ret);
        sleep(60);
        continue;
    }
  }
}

- (BOOL)respondFromCache:(es_message_t *)m API_AVAILABLE(macos(10.15)) {
  return NO;
}

- (void)messageHandler:(es_message_t *)m API_AVAILABLE(macos(10.15)) {
  santa_message_t sm = {};
  sm.es_message = (void *)m;

  es_process_t *targetProcess = NULL;
  es_file_t *targetFile = NULL;
  void (^callback)(santa_message_t);

  switch (m->event_type) {
    case ES_EVENT_TYPE_AUTH_EXEC: {
      if ([self respondFromCache:m]) {
        return;
      }

      sm.action = ACTION_REQUEST_BINARY;
      targetFile = m->event.exec.target->executable;
      targetProcess = m->event.exec.target;
      callback = self.decisionCallback;
      break;
    }
    case ES_EVENT_TYPE_NOTIFY_EXEC: {
      sm.action = ACTION_NOTIFY_EXEC;
      targetFile = m->event.exec.target->executable;
      targetProcess = m->event.exec.target;

      // TODO(rah): Profile this, it might need to be improved.
      uint32_t argCount = es_exec_arg_count(&(m->event.exec));
      NSMutableArray *args = [NSMutableArray arrayWithCapacity:argCount];
      for (int i = 0; i < argCount; ++i) {
        es_string_token_t arg = es_exec_arg(&(m->event.exec), i);
        NSString *argStr = [[NSString alloc] initWithBytes:arg.data
                                                    length:arg.length
                                                  encoding:NSUTF8StringEncoding];
        if (argStr.length) [args addObject:argStr];
      }
      sm.args_array = (void *)CFBridgingRetain(args);
      callback = self.logCallback;
      break;
    }
    case ES_EVENT_TYPE_AUTH_UNLINK: {
      es_string_token_t pathToken = m->event.unlink.target->path;
      NSString *path = [[NSString alloc] initWithBytes:pathToken.data
                                                length:pathToken.length
                                              encoding:NSUTF8StringEncoding];
      if ([self isDatabasePath:path] &&
          audit_token_to_pid(m->process->audit_token) != self.selfPID) {
        LOGW(@"Preventing attempt to delete Santa databases!");
        es_respond_auth_result(self.client, m, ES_AUTH_RESULT_DENY, true);
        return;
      }
      es_respond_auth_result(self.client, m, ES_AUTH_RESULT_ALLOW, true);
      return;
    }
    case ES_EVENT_TYPE_AUTH_RENAME: {
      es_string_token_t pathToken = m->event.rename.source->path;
      NSString *path = [[NSString alloc] initWithBytes:pathToken.data
                                                length:pathToken.length
                                              encoding:NSUTF8StringEncoding];

      if ([self isDatabasePath:path] &&
          audit_token_to_pid(m->process->audit_token) != self.selfPID) {
        LOGW(@"Preventing attempt to rename Santa databases!");
        es_respond_auth_result(self.client, m, ES_AUTH_RESULT_DENY, true);
        return;
      }
      if (m->event.rename.destination_type == ES_DESTINATION_TYPE_EXISTING_FILE) {
        es_string_token_t destToken = m->event.rename.destination.existing_file->path;
        NSString *destPath = [[NSString alloc] initWithBytes:destToken.data
                                                      length:destToken.length
                                                    encoding:NSUTF8StringEncoding];
        if ([self isDatabasePath:destPath] &&
            audit_token_to_pid(m->process->audit_token) != self.selfPID) {
          LOGW(@"Preventing attempt to overwrite Santa databases!");
          es_respond_auth_result(self.client, m, ES_AUTH_RESULT_DENY, true);
          return;
        }
      }
      es_respond_auth_result(self.client, m, ES_AUTH_RESULT_ALLOW, true);
      return;
    }
    case ES_EVENT_TYPE_AUTH_KEXTLOAD: {
      es_string_token_t identifier = m->event.kextload.identifier;
      NSString *ident = [[NSString alloc] initWithBytes:identifier.data
                                                 length:identifier.length
                                               encoding:NSUTF8StringEncoding];
      if ([ident isEqualToString:@"com.google.santa-driver"]) {
        LOGW(@"Preventing attempt to load Santa kext!");
        es_respond_auth_result(self.client, m, ES_AUTH_RESULT_DENY, true);
        return;
      }
      es_respond_auth_result(self.client, m, ES_AUTH_RESULT_ALLOW, true);
      return;
    }
    case ES_EVENT_TYPE_NOTIFY_CLOSE: {
      sm.action = ACTION_NOTIFY_WRITE;
      targetFile = m->event.close.target;
      targetProcess = m->process;
      callback = self.logCallback;
      break;
    }
    case ES_EVENT_TYPE_NOTIFY_UNLINK: {
      sm.action = ACTION_NOTIFY_DELETE;
      targetFile = m->event.unlink.target;
      targetProcess = m->process;
      callback = self.logCallback;
      break;
    }
    case ES_EVENT_TYPE_NOTIFY_LINK: {
      sm.action = ACTION_NOTIFY_LINK;
      targetFile = m->event.link.source;
      targetProcess = m->process;
      NSString *p = @(m->event.link.target_dir->path.data);
      p = [p stringByAppendingPathComponent:@(m->event.link.target_filename.data)];
      [self populateBufferFromString:p.UTF8String
                              length:p.length
                              buffer:sm.newpath
                                size:sizeof(sm.newpath)];
      callback = self.logCallback;
      break;
    }
    case ES_EVENT_TYPE_NOTIFY_RENAME: {
      sm.action = ACTION_NOTIFY_RENAME;
      targetFile = m->event.rename.source;
      targetProcess = m->process;
      [self populateRenamedNewPathFromESMessage:m->event.rename
                                         buffer:sm.newpath
                                           size:sizeof(sm.newpath)];
      callback = self.logCallback;
      break;
    }
    default: LOGE(@"Unknown es message: %d", m->event_type); return;
  }

  // Deny auth exec events if the path doesn't fit in the santa message.
  // TODO(bur/rah): Add support for larger paths.
  if ([self populateBufferFromESFile:targetFile buffer:sm.path size:sizeof(sm.path)] &&
      m->event_type == ES_EVENT_TYPE_AUTH_EXEC) {
    LOGE(@"path is truncated, deny: %s", sm.path);
    es_respond_auth_result(self.client, m, ES_AUTH_RESULT_DENY, false);
    return;
  }

  // Filter file op events matching the prefix tree.
  if (!(m->event_type == ES_EVENT_TYPE_AUTH_EXEC || m->event_type == ES_EVENT_TYPE_NOTIFY_EXEC) &&
      self.prefixTree->HasPrefix(sm.path)) {
    return;
  }

  sm.vnode_id.fsid = targetFile->stat.st_dev;
  sm.vnode_id.fileid = targetFile->stat.st_ino;
  sm.uid = audit_token_to_ruid(targetProcess->audit_token);
  sm.gid = audit_token_to_rgid(targetProcess->audit_token);
  sm.pid = audit_token_to_pid(targetProcess->audit_token);
  sm.pidversion = audit_token_to_pidversion(targetProcess->audit_token);
  sm.ppid = targetProcess->original_ppid;
  proc_name((m->event_type == ES_EVENT_TYPE_AUTH_EXEC) ? sm.ppid : sm.pid, sm.pname, 1024);
  callback(sm);
}

- (void)listenForDecisionRequests:(void (^)(santa_message_t))callback API_AVAILABLE(macos(10.15)) {
  while (!self.connectionEstablished)
    usleep(100000);  // 100ms

  self.decisionCallback = callback;
  es_event_type_t events[] = {
    ES_EVENT_TYPE_AUTH_EXEC,
    ES_EVENT_TYPE_AUTH_UNLINK,
    ES_EVENT_TYPE_AUTH_RENAME,
    ES_EVENT_TYPE_AUTH_KEXTLOAD,

    // This is in the decision callback because it's used for detecting
    // the exit of a 'compiler' used by transitive whitelisting.
    ES_EVENT_TYPE_NOTIFY_EXIT,
  };
  es_return_t sret = es_subscribe(self.client, events, sizeof(events) / sizeof(es_event_type_t));
  if (sret != ES_RETURN_SUCCESS) LOGE(@"Unable to subscribe to auth events: %d", sret);

  // There's a gap between creating a client and subscribing to events. Creating the client
  // triggers a cache flush automatically but any events that happen in this gap could be allowed
  // and cached, so we force the cache to flush again.
  [self flushCacheNonRootOnly:YES];
}

- (void)listenForLogRequests:(void (^)(santa_message_t))callback API_AVAILABLE(macos(10.15)) {
  while (!self.connectionEstablished)
    usleep(100000);  // 100ms

  self.logCallback = callback;
  es_event_type_t events[] = {
    ES_EVENT_TYPE_NOTIFY_EXEC,   ES_EVENT_TYPE_NOTIFY_CLOSE,  ES_EVENT_TYPE_NOTIFY_LINK,
    ES_EVENT_TYPE_NOTIFY_RENAME, ES_EVENT_TYPE_NOTIFY_UNLINK, ES_EVENT_TYPE_NOTIFY_FORK,
  };
  es_return_t sret = es_subscribe(self.client, events, sizeof(events) / sizeof(es_event_type_t));
  if (sret != ES_RETURN_SUCCESS) LOGE(@"Unable to subscribe to notify events: %d", sret);
}

- (int)postAction:(santa_action_t)action
       forMessage:(santa_message_t)sm API_AVAILABLE(macos(10.15)) {
  es_respond_result_t ret;
  switch (action) {
    case ACTION_RESPOND_ALLOW_COMPILER:
      [self setIsCompilerPID:sm.pid];

      // Allow the exec, but don't cache the decision so subsequent execs of the compiler get
      // marked appropriately.
      ret = es_respond_auth_result(self.client, (es_message_t *)sm.es_message, ES_AUTH_RESULT_ALLOW,
                                   false);
      break;
    case ACTION_RESPOND_ALLOW:
    case ACTION_RESPOND_ALLOW_PENDING_TRANSITIVE:
      ret = es_respond_auth_result(self.client, (es_message_t *)sm.es_message, ES_AUTH_RESULT_ALLOW,
                                   true);
      break;
    case ACTION_RESPOND_DENY:
    case ACTION_RESPOND_TOOLONG:
      ret = es_respond_auth_result(self.client, (es_message_t *)sm.es_message, ES_AUTH_RESULT_DENY,
                                   false);
      break;
    case ACTION_RESPOND_ACK: return ES_RESPOND_RESULT_SUCCESS;
    default: ret = ES_RESPOND_RESULT_ERR_INVALID_ARGUMENT;
  }

  return ret;
}

- (BOOL)flushCacheNonRootOnly:(BOOL)nonRootOnly API_AVAILABLE(macos(10.15)) {
  if (!self.connectionEstablished) return YES;  // if not connected, there's nothing to flush.
  return es_clear_cache(self.client) == ES_CLEAR_CACHE_RESULT_SUCCESS;
}

- (void)fileModificationPrefixFilterAdd:(NSArray *)filters {
  for (NSString *filter in filters) {
    self.prefixTree->AddPrefix(filter.fileSystemRepresentation);
  }
}

- (void)fileModificationPrefixFilterReset {
  self.prefixTree->Reset();
}

- (NSArray<NSNumber *> *)cacheCounts {
  return nil;
}

- (NSArray<NSNumber *> *)cacheBucketCount {
  return nil;
}

- (santa_action_t)checkCache:(santa_vnode_id_t)vnodeID {
  return ACTION_UNSET;
}

- (kern_return_t)removeCacheEntryForVnodeID:(santa_vnode_id_t)vnodeId {
  return KERN_FAILURE;
}

- (BOOL)connectionEstablished {
  return self.client != nil;
}

#pragma mark helpers

// Returns YES if the path was truncated.
// The populated path will be NUL terminated.
- (BOOL)populateBufferFromESFile:(es_file_t *)file buffer:(char *)buffer size:(size_t)size {
  return [self populateBufferFromString:file->path.data
                                 length:file->path.length
                                 buffer:buffer
                                   size:size];
}

// Returns YES if the path was truncated.
// The populated path will be NUL terminated.
- (BOOL)populateBufferFromString:(const char *)string
                          length:(size_t)length
                          buffer:(char *)buffer
                            size:(size_t)size {
  if (length++ > size) length = size;
  return strlcpy(buffer, string, length) >= length;
}

- (BOOL)populateRenamedNewPathFromESMessage:(es_event_rename_t)mv
                                     buffer:(char *)buffer
                                       size:(size_t)size {
  BOOL truncated = NO;
  switch (mv.destination_type) {
    case ES_DESTINATION_TYPE_NEW_PATH: {
      NSString *p = @(mv.destination.new_path.dir->path.data);
      p = [p stringByAppendingPathComponent:@(mv.destination.new_path.filename.data)];
      truncated = [self populateBufferFromString:p.UTF8String
                                          length:p.length
                                          buffer:buffer
                                            size:size];
      break;
    }
    case ES_DESTINATION_TYPE_EXISTING_FILE: {
      truncated = [self populateBufferFromESFile:mv.destination.existing_file
                                          buffer:buffer
                                            size:size];
      break;
    }
  }
  return truncated;
}

- (santa_vnode_id_t)vnodeIDForFile:(es_file_t *)file {
  return {
    .fsid = (uint64_t)file->stat.st_dev,
    .fileid = file->stat.st_ino,
  };
}

- (BOOL)isDatabasePath:(NSString *)path {
  return [path isEqualToString:@"/private/var/db/santa/rules.db"] ||
         [path isEqualToString:@"/private/var/db/santa/events.db"];
}

- (BOOL)isCompilerPID:(pid_t)pid {
  return (pid && pid < PID_MAX && self->_compilerPIDs[pid].load());
}

- (void)setIsCompilerPID:(pid_t)pid {
  if (pid < 1) {
    LOGE(@"Unable to watch compiler pid=%d", pid);
  } else if (pid >= PID_MAX) {
    LOGE(@"Unable to watch compiler pid=%d >= PID_MAX(%d)", pid, PID_MAX);
  } else {
    self->_compilerPIDs[pid].store(true);
    LOGD(@"Watching compiler pid=%d", pid);
  }
}

- (void)setNotCompilerPID:(pid_t)pid {
  if (pid && pid < PID_MAX) self->_compilerPIDs[pid].store(false);
}

@end
