// old zig code https://github.com/ziglang/zig/blob/8d11ade6a769fe498ed20cdb4f80c6acf4ca91de/lib/std/fs/watch.zig
// new zig code https://github.com/ziglang/zig/blob/03123916e55a9c0c8b66f748a62b7a4a64203535/lib/std/Build/Watch.zig
// see https://www.microsoftpressstore.com/articles/article.aspx?p=2201309&seqNum=3

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Timeout = std.Build.Watch.Timeout;

pub const Os = switch (@import("builtin").os.tag) {
    .linux => struct {
        const Watch = @This();
        const posix = std.posix;
        poll_fds: [2]posix.pollfd,
        pipe_data: [8192]u8 = undefined,

        fn init(gpa: Allocator) !Watch {
            _ = gpa;

            const fan_fd = posix.fanotify_init(.{
                .CLASS = .NOTIF,
                .CLOEXEC = true,
                .NONBLOCK = true,
                .REPORT_NAME = true,
                .REPORT_DIR_FID = true,
                .REPORT_FID = true,
                .REPORT_TARGET_FID = true,
            }, 0) catch |err| switch (err) {
                error.UnsupportedFlags => std.zig.fatal("fanotify_init failed due to old kernel; requires 5.17+", .{}),
                else => |e| return e,
            };
            const path = std.fs.cwd();
            posix.fanotify_mark(fan_fd, .{
                .ADD = true,
                .ONLYDIR = true,
            }, .{
                .CLOSE_WRITE = true,
                .CREATE = true,
                .DELETE = true,
                .DELETE_SELF = true,
                .EVENT_ON_CHILD = true,
                .MOVED_FROM = true,
                .MOVED_TO = true,
                .MOVE_SELF = true,
                .ONDIR = true,
                .MODIFY = true, // monitor appended files
            }, path.fd, ".") catch |err| { //path.subPathOrDot()
                std.zig.fatal("unable to watch {}: {s}", .{ path, @errorName(err) });
            };
            return .{
                .poll_fds = .{
                    .{ .fd = fan_fd, .events = posix.POLL.IN, .revents = undefined },
                    undefined,
                },
            };
        }

        pub fn addFd(w: *Watch, fd: std.fs.File.Handle, key: usize) !void {
            _ = key;
            w.poll_fds[1] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = undefined };
        }

        pub fn wait(w: *Watch, timeout: Timeout, comptime onFileUpdated: fn (str: []const u8) void) !Result {
            const events_len = try posix.poll(&w.poll_fds, timeout.to_i32_ms());
            _ = events_len;
            if (w.poll_fds[0].revents != 0) {
                const fan_fd = w.poll_fds[0].fd;
                const fanotify = std.os.linux.fanotify;
                const M = fanotify.event_metadata;
                var events_buf: [256 + 4096]u8 = undefined;
                var any_dirty = false;
                while (true) {
                    var len = posix.read(fan_fd, &events_buf) catch |err| switch (err) {
                        error.WouldBlock => break, // return any_dirty,
                        else => |e| return e,
                    };
                    var meta: [*]align(1) M = @ptrCast(&events_buf);
                    while (len >= @sizeOf(M) and meta[0].event_len >= @sizeOf(M) and meta[0].event_len <= len) : ({
                        len -= meta[0].event_len;
                        meta = @ptrCast(@as([*]u8, @ptrCast(meta)) + meta[0].event_len);
                    }) {
                        assert(meta[0].vers == M.VERSION);
                        if (meta[0].mask.Q_OVERFLOW) {
                            any_dirty = true;
                            std.log.warn("file system watch queue overflowed; falling back to fstat", .{});
                            //markAllFilesDirty(w, gpa);
                            return .timeout;
                        }
                        const fid: *align(1) fanotify.event_info_fid = @ptrCast(meta + 1);
                        switch (fid.hdr.info_type) {
                            .DFID_NAME => {
                                const file_handle: *align(1) std.os.linux.file_handle = @ptrCast(&fid.handle);
                                const file_name_z: [*:0]u8 = @ptrCast((&file_handle.f_handle).ptr + file_handle.handle_bytes);
                                const file_name = std.mem.span(file_name_z);
                                onFileUpdated(file_name);
                                any_dirty = true;
                            },
                            else => |t| std.log.warn("unexpected fanotify event '{s}'", .{@tagName(t)}),
                        }
                    }
                }
                return if (any_dirty) .fileChanged else .timeout;
            }
            if (w.poll_fds[1].revents != 0) {
                const read = std.os.linux.read(w.poll_fds[1].fd, &w.pipe_data, w.pipe_data.len);
                if (read == 0)
                    return .eof;
                return .{ .pipeRead = .{ .data = w.pipe_data[0..read], .key = std.math.maxInt(usize) } };
            }
            return .timeout;
        }
    },

    .windows => struct {
        const Watch = @This();
        const windows = std.os.windows;
        const watchKey = std.math.maxInt(usize) - 100;
        fds: std.ArrayList(FdBuffer) = undefined,
        dir: *Directory = undefined,
        io_cp: ?windows.HANDLE = null,

        pub fn GetQueuedCompletionStatus(completion_port: windows.HANDLE, bytes_transferred_count: *windows.DWORD, lpCompletionKey: *usize, lpOverlapped: *?*windows.OVERLAPPED, dwMilliseconds: windows.DWORD) windows.GetQueuedCompletionStatusResult {
            if (windows.kernel32.GetQueuedCompletionStatus(completion_port, bytes_transferred_count, lpCompletionKey, lpOverlapped, dwMilliseconds) == windows.FALSE) {
                switch (windows.GetLastError()) {
                    .ABANDONED_WAIT_0 => return .Aborted,
                    .OPERATION_ABORTED => return .Cancelled,
                    .HANDLE_EOF => return .EOF,
                    .BROKEN_PIPE => return .EOF, // added by me
                    .WAIT_TIMEOUT => return .Timeout,
                    else => |err| {
                        if (std.debug.runtime_safety) {
                            @setEvalBranchQuota(2500);
                            std.debug.panic("unexpected error: {}\n", .{err});
                        }
                    },
                }
            }
            return .Normal;
        }

        const Directory = struct {
            handle: windows.HANDLE,
            //id: FileId,
            overlapped: windows.OVERLAPPED,
            // 64 KB is the packet size limit when monitoring over a network.
            // https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-readdirectorychangesw#remarks
            buffer: [64 * 1024]u8 align(@alignOf(windows.FILE_NOTIFY_INFORMATION)) = undefined,

            /// Start listening for events, buffer field will be overwritten eventually.
            fn startListening(self: *@This()) !void {
                const r = windows.kernel32.ReadDirectoryChangesW(
                    self.handle,
                    @ptrCast(&self.buffer),
                    self.buffer.len,
                    0,
                    .{ .creation = true, .dir_name = true, .file_name = true, .last_write = true, .size = true },
                    null,
                    &self.overlapped,
                    null,
                );
                if (r == windows.FALSE) {
                    switch (windows.GetLastError()) {
                        .INVALID_FUNCTION => return error.ReadDirectoryChangesUnsupported,
                        else => |err| return windows.unexpectedError(err),
                    }
                }
            }

            fn init(gpa: Allocator, path: std.fs.Dir) !*@This() {
                // The following code is a drawn out NtCreateFile call. (mostly adapted from std.fs.Dir.makeOpenDirAccessMaskW)
                // It's necessary in order to get the specific flags that are required when calling ReadDirectoryChangesW.
                var dir_handle: windows.HANDLE = undefined;
                const root_fd = path.fd;
                const sub_path = "."; //path.subPathOrDot();
                const sub_path_w = try windows.sliceToPrefixedFileW(root_fd, sub_path);
                const path_len_bytes = std.math.cast(u16, sub_path_w.len * 2) orelse return error.NameTooLong;

                var nt_name = windows.UNICODE_STRING{
                    .Length = @intCast(path_len_bytes),
                    .MaximumLength = @intCast(path_len_bytes),
                    .Buffer = @constCast(sub_path_w.span().ptr),
                };
                var attr = windows.OBJECT_ATTRIBUTES{
                    .Length = @sizeOf(windows.OBJECT_ATTRIBUTES),
                    .RootDirectory = if (std.fs.path.isAbsoluteWindowsW(sub_path_w.span())) null else root_fd,
                    .Attributes = 0, // Note we do not use OBJ_CASE_INSENSITIVE here.
                    .ObjectName = &nt_name,
                    .SecurityDescriptor = null,
                    .SecurityQualityOfService = null,
                };
                var io: windows.IO_STATUS_BLOCK = undefined;

                switch (windows.ntdll.NtCreateFile(
                    &dir_handle,
                    windows.SYNCHRONIZE | windows.GENERIC_READ | windows.FILE_LIST_DIRECTORY,
                    &attr,
                    &io,
                    null,
                    0,
                    windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
                    windows.FILE_OPEN,
                    windows.FILE_DIRECTORY_FILE | windows.FILE_OPEN_FOR_BACKUP_INTENT,
                    null,
                    0,
                )) {
                    .SUCCESS => {},
                    .OBJECT_NAME_INVALID => return error.BadPathName,
                    .OBJECT_NAME_NOT_FOUND => return error.FileNotFound,
                    .OBJECT_NAME_COLLISION => return error.PathAlreadyExists,
                    .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
                    .NOT_A_DIRECTORY => return error.NotDir,
                    // This can happen if the directory has 'List folder contents' permission set to 'Deny'
                    .ACCESS_DENIED => return error.AccessDenied,
                    .INVALID_PARAMETER => unreachable,
                    else => |rc| return windows.unexpectedStatus(rc),
                }
                assert(dir_handle != windows.INVALID_HANDLE_VALUE);
                errdefer windows.CloseHandle(dir_handle);
                const dir_ptr = try gpa.create(@This());
                dir_ptr.* = .{
                    .handle = dir_handle,
                    .overlapped = std.mem.zeroes(windows.OVERLAPPED),
                };
                return dir_ptr;
            }

            fn deinit(self: *@This(), gpa: Allocator) void {
                _ = windows.kernel32.CancelIo(self.handle);
                windows.CloseHandle(self.handle);
                gpa.destroy(self);
            }
        };

        const FdBuffer = struct {
            handle: windows.HANDLE,
            overlapped: windows.OVERLAPPED = undefined,
            currentBuff: usize = 0,
            inBuffs: [2][8192]u8 = undefined,
            key: usize,
            position: usize = 0,
            fn startReading(p: *@This()) !void {
                const b = &p.inBuffs[p.currentBuff];
                p.currentBuff ^= 1;
                if (0 == windows.kernel32.ReadFile(p.handle, b, b.len, null, &p.overlapped))
                    switch (windows.GetLastError()) {
                        .IO_PENDING => return,
                        //.BROKEN_PIPE => return if (read_any_data) .closed_populated else .closed,
                        else => |err| return windows.unexpectedError(err),
                    };
            }
        };

        fn init(gpa: Allocator) !Watch {
            const path = std.fs.cwd(); //initCwd(dirr);
            const dir = try Directory.init(gpa, path);
            errdefer dir.deinit(gpa);
            try dir.startListening();
            return .{
                .fds = .init(gpa),
                .dir = dir,
                .io_cp = try windows.CreateIoCompletionPort(dir.handle, null, watchKey, 0), // ← w.io_cp
            };
        }

        pub fn addFd(w: *Watch, fd: std.fs.File.Handle, key: usize) !void {
            var p = try w.fds.addOne();
            p.* = FdBuffer{ .handle = fd, .key = key };
            w.io_cp = try windows.CreateIoCompletionPort(fd, w.io_cp.?, w.fds.items.len, 0);
            _ = try p.startReading();
        }

        pub fn wait(w: *Watch, timeout: Timeout, comptime onFileUpdated: fn (str: []const u8) void) !Result {
            var bytes_transferred: windows.DWORD = undefined;
            var key: usize = undefined;
            var overlapped_ptr: ?*windows.OVERLAPPED = undefined;
            var dir = w.dir;
            return while (true) switch (GetQueuedCompletionStatus(
                w.io_cp.?,
                &bytes_transferred,
                &key,
                &overlapped_ptr,
                @bitCast(timeout.to_i32_ms()),
            )) {
                .Normal => {
                    if (key == watchKey) {
                        if (bytes_transferred == 0)
                            continue; // break error.Unexpected;
                        const bytes_returned = try windows.GetOverlappedResult(dir.handle, &dir.overlapped, false);
                        if (bytes_returned == 0) {
                            std.log.warn("file system watch queue overflowed; falling back to fstat", .{});
                            unreachable;
                        }
                        var file_name_buf: [std.fs.max_path_bytes]u8 = undefined;
                        var offset: usize = 0;
                        var result: Result = .timeout;
                        while (true) {
                            const notify: *align(1) windows.FILE_NOTIFY_INFORMATION = @ptrCast(&dir.buffer[offset]);
                            const file_name_field: [*]u16 = @ptrFromInt(@intFromPtr(notify) + @sizeOf(windows.FILE_NOTIFY_INFORMATION));
                            const file_name_len = std.unicode.wtf16LeToWtf8(&file_name_buf, file_name_field[0 .. notify.FileNameLength / 2]);
                            const file_name = file_name_buf[0..file_name_len];
                            onFileUpdated(file_name);
                            result = .fileChanged;
                            if (notify.NextEntryOffset == 0)
                                break;
                            offset += notify.NextEntryOffset;
                        }
                        // We call this now since at this point we have finished reading dir.buffer.
                        try dir.startListening();
                        break result;
                    } else {
                        const p = &w.fds.items[key - 1];
                        p.position += bytes_transferred;
                        _ = try p.startReading();
                        break .{ .pipeRead = .{ .data = p.inBuffs[p.currentBuff][0..bytes_transferred], .key = p.key } };
                    }
                },
                .Timeout => break .timeout,
                .EOF => break .eof,
                .Cancelled => continue, // This status is issued because CancelIo was called, skip and try again.
                else => {
                    std.log.err("UNEXPECTED", .{});
                    break error.Unexpected;
                },
            };
        }
    },
    else => void,
};

pub fn init(gpa: Allocator) !Os {
    return Os.init(gpa);
}

pub const Result = union(enum) {
    timeout: void,
    fileChanged: void,
    pipeRead: struct { key: usize, data: []const u8 },
    eof: void,
};
