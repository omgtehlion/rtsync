const std = @import("std");
const utils = @import("./utils.zig");
const watch = @import("./watch.zig");
const fatal = std.zig.fatal;
const log = std.log;
var gpaAlloc = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpaAlloc.allocator();

const version: [4]u8 = .{ 0, 0, 0, 2 }; // ignored.major.minor.fix

const SyncMode = enum(u16) {
    None = 0,
    Inverted,
    Push,
    Pull,
    PushAppend,
    PullAppend,
    _,
};

const Options = packed struct(u16) {
    LazySend: bool = true, // compare checksum, send only if changed
    _: u15 = 0, // something like follow inode/name, filtering, etc, will add later
};

const Msg = struct {
    const Header = extern struct { type: u32, size: u32 };

    const Hello = extern struct {
        const Type: u32 = 0xDCDF;
        header: Header = .{ .type = Type, .size = @sizeOf(@This()) },
        banner: [8]u8,
        version: [4]u8,
    };

    const Heartbeat = extern struct {
        const Type: u32 = 0;
        header: Header = .{ .type = Type, .size = @sizeOf(@This()) },
        index: u32,
    };

    const Reject = extern struct {
        const Type: u32 = 1; // something we do not like
        header: Header = .{ .type = Type, .size = @sizeOf(@This()) },
        reason: u32,
        reserved: u64 = 0,
        // text reason may be stored beyond this member
    };

    const ConfigReq = extern struct {
        const Type: u32 = 2;
        header: Header = .{ .type = Type, .size = @sizeOf(@This()) },
        index: u16, // this is unique
        mode: SyncMode, // this is local to the receiving side
        options: Options,
        // name is stored beyond the last member
    };

    const ConfResult = enum(u16) {
        Success = 0,
        BadIndex,
        BadOptions,
        BadMode,
        BadName,
        WrongSide,
        _,
    };

    const ConfigRes = extern struct {
        const Type: u32 = 3;
        header: Header = .{ .type = Type, .size = @sizeOf(@This()) },
        index: u16,
        result: ConfResult,
    };

    const FileData = extern struct {
        const Type: u32 = 4;
        header: Header = .{ .type = Type, .size = @sizeOf(@This()) },
        index: u16,
        // data is stored beyond the last member
    };

    const FileClear = extern struct {
        const Type: u32 = 5;
        header: Header = .{ .type = Type, .size = @sizeOf(@This()) },
        index: u16,
    };

    pub fn cast(comptime T: type, buf: []const u8) *align(1) const T {
        return @ptrCast(buf[0..@sizeOf(T)]);
    }
};

const ConfiguredFile = struct {
    mode: SyncMode,
    options: Options,
    name: []const u8,
    accepted: bool = false,
    tmpname: [1 + 16 + 4]u8 = undefined,
    file: ?std.fs.File = null,
    lastCheckSum: u128 = 0,
    remoteName: ?[]const u8 = null,
    bytesRead: usize = 0,
};

var keepCopy: bool = false; // for debug purposes
var configured: std.ArrayList(ConfiguredFile) = .init(gpa);
var configuredNames: std.StringHashMap(usize) = .init(gpa); // file name → index
var dirtyFiles: std.AutoHashMap(usize, void) = .init(gpa);

fn addLocalConfig(mode: SyncMode, name: []const u8, options: Options) !*ConfiguredFile {
    const index = configured.items.len;
    const cfg = try configured.addOne();
    cfg.* = .{ .mode = mode, .name = name, .options = options };
    if (mode == .Push or mode == .PushAppend)
        try configuredNames.put(cfg.name, index);
    return cfg;
}

fn nextArg(args: []const [:0]const u8, idx: *usize) ?[:0]const u8 {
    if (idx.* >= args.len) return null;
    defer idx.* += 1;
    return args[idx.*];
}

fn nextArgOrFatal(args: []const [:0]const u8, idx: *usize) [:0]const u8 {
    return nextArg(args, idx) orelse fatal("expected argument after '{s}'\n", .{args[idx.* - 1]});
}

fn printUsage() void {
    const print = std.debug.print;
    print(
        \\rtsync {}.{}.{} - a realtime file synchroniser
        \\usage: rtsync <remote> [--help] [--exe <path>] [--keep-copy] [<commands>]...
        \\
        \\<remote>:
        \\    /path/to/dir  Synchronise another local directory with current working directory
        \\    host:[/path]  Synchronise with another host,
        \\                  optionally select remote path instead of default (home dir)
        \\
        \\-h, --help        Print this message
        \\--exe <path>      Select executable used on the remote side (mostly for debug)
        \\                  default is 'rtsync'
        \\--keep-copy       Keeps a copy of each updated file on local side (for debug purposes)
        \\
        \\<commands>:
        \\--push <local>[:<remote>] [<local>[:<remote>]]...
        \\                  Synchronise local file named <local> into <remote> file.
        \\                  If <remote> is omitted the same name is used on both sides.
        \\                  Multiple names (or name pairs) are allowed
        \\--pull <local>[:<remote>] [<local>[:<remote>]]...
        \\                  Synchronise <remote> file into <local>.
        \\--push-append <local>[:<remote>] [<local>[:<remote>]]...
        \\                  Synchronise <local> file into <remote> in append mode.
        \\                  On startup the file is copied completely.
        \\                  When more data is added to the source file, it is immediately
        \\                  synchronised to the target file.
        \\--pull-append <local>[:<remote>] [<local>[:<remote>]]...
        \\                  Synchronise <remote> file into <local> in append mode.
        \\
    , .{ version[1], version[2], version[3] });
}

pub fn main() !void {
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len <= 1)
        return printUsage();
    var isMaster = true;
    var exeName: [:0]const u8 = "rtsync";
    var slaveSpec: ?[:0]const u8 = null;
    { // parse args
        var allNames = std.StringHashMap(void).init(gpa); // file name → index
        defer allNames.deinit();
        const mem = std.mem;
        var argIdx: usize = 1;
        var lastMode = SyncMode.None;
        while (nextArg(args, &argIdx)) |arg| {
            if (mem.startsWith(u8, arg, "-")) {
                lastMode = .None;
                if (mem.eql(u8, arg, "--slave")) {
                    utils.label = "SLAVE ";
                    log.info("Running in slave mode, ignoring all other arguments", .{});
                    configured.clearAndFree();
                    configuredNames.clearAndFree();
                    if (nextArg(args, &argIdx)) |cwd| {
                        const dir = std.fs.cwd().openDir(cwd, .{}) catch fatal("cannot find '{s}' directory\n" ++
                            "If you meant remote, please use `rtsync {s}:`", .{ cwd, cwd });
                        try dir.setAsCwd();
                        log.info("set '{s}' as working directory", .{cwd});
                    }
                    isMaster = false;
                    break;
                } else if (mem.eql(u8, arg, "--exe")) {
                    exeName = nextArgOrFatal(args, &argIdx);
                } else if (mem.eql(u8, arg, "--push")) {
                    lastMode = .Push;
                } else if (mem.eql(u8, arg, "--push-append")) {
                    lastMode = .PushAppend;
                } else if (mem.eql(u8, arg, "--pull")) {
                    lastMode = .Pull;
                } else if (mem.eql(u8, arg, "--pull-append")) {
                    lastMode = .PullAppend;
                } else if (mem.eql(u8, arg, "--keep-copy")) {
                    keepCopy = true;
                } else if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
                    return printUsage();
                } else {
                    fatal("unrecognised argument: '{s}'", .{arg});
                }
            } else if (lastMode != .None) {
                switch (lastMode) {
                    .Pull, .Push, .PushAppend, .PullAppend => {
                        var parts = mem.splitScalar(u8, arg, ':');
                        const cfg = addLocalConfig(lastMode, parts.next() orelse fatal("local name required", .{}), .{}) catch fatal("fucked", .{});
                        if (allNames.contains(cfg.name))
                            fatal("possible loop detected, file name '{s}'", .{cfg.name});
                        try allNames.put(cfg.name, {});
                        cfg.remoteName = parts.next() orelse cfg.name;
                        if (parts.next()) |s|
                            fatal("sync description contains unexpected extra data '{s}'", .{s});
                    },
                    else => fatal("Mode {} not yet supported\n", .{lastMode}),
                }
            } else {
                if (slaveSpec) |ss| fatal("slave address must be specified only once, got {s} after {s}", .{ arg, ss });
                slaveSpec = arg;
            }
        }
    }
    const out, const in = if (isMaster) x: {
        utils.label = "MASTER";
        var slaveArgs = std.ArrayList([]const u8).init(gpa);
        defer slaveArgs.deinit();
        var slavePath = slaveSpec orelse fatal("slave address required", .{});
        if (std.mem.indexOfScalar(u8, slavePath, ':')) |s| {
            if (@import("builtin").os.tag != .windows or s != 1) { // hack for disk-rooted paths on win32
                try slaveArgs.append("ssh");
                try slaveArgs.append(slavePath[0..s]);
                slavePath = slavePath[s + 1 ..];
            }
        }
        try slaveArgs.append(exeName);
        try slaveArgs.append("--slave");
        if (slavePath.len > 0) try slaveArgs.append(slavePath);
        var child = std.process.Child.init(slaveArgs.items, gpa);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        try child.spawn();
        break :x .{ child.stdin.?.writer(), child.stdout.?.handle };
    } else x: {
        const out = std.io.getStdOut().writer();
        try out.writeStruct(Msg.Hello{ .banner = .{ 'h', 'e', 'l', 'l', 'o', ' ', ' ', ' ' }, .version = version });
        break :x .{ out, utils.pollableStdIn() };
    };
    log.info("started", .{});
    var watcher = try watch.init(gpa);
    try watcher.addFd(in, @bitCast(@as(isize, -1)));
    var heartbeat: u32 = 1;
    while (true) {
        const x = try watcher.wait(.{ .ms = 30000 }, struct {
            fn onFileChanged(name: []const u8) void {
                //log.debug("event file_name '{s}'", .{ name });
                if (configuredNames.get(name)) |index| {
                    //log.debug("mark index #{}", .{ index });
                    dirtyFiles.put(index, {}) catch unreachable;
                }
            }
        }.onFileChanged);
        switch (x) {
            .timeout => {
                try out.writeStruct(Msg.Heartbeat{ .index = heartbeat });
                heartbeat +%= 1;
            },
            .pipeRead => |pr| {
                if (pr.key > configured.items.len)
                    try processMessages(isMaster, pr.data, out)
                else
                    log.debug("notify file data len {} '{s}'", .{ pr.data.len, pr.data });
            },
            .fileChanged => {
                //log.debug("end of notify batch", .{});
                var iter = dirtyFiles.keyIterator();
                while (iter.next()) |i|
                    try push(i.*, out);
                dirtyFiles.clearRetainingCapacity();
            },
            .eof => {
                log.err("pipe closed, exiting", .{});
                break;
            },
        }
    }
}

fn push(index: usize, out: anytype) !void {
    var cfg = &configured.items[index];
    var fileDataBuff: [4 * 1024 * 1024]u8 = undefined;
    if (cfg.mode == .Push) {
        const f = std.fs.cwd().openFile(cfg.name, .{ .lock = .exclusive }) catch |err| switch (err) {
            error.FileNotFound => {
                log.info("file {s} not found", .{cfg.name});
                cfg.lastCheckSum = 0;
                try out.writeStruct(Msg.FileData{ .index = @intCast(index) }); // sends empty file
                return {};
            },
            else => return err,
        };
        const data = fileDataBuff[0..try f.readAll(&fileDataBuff)];
        f.close(); // close right away
        if (cfg.options.LazySend) {
            const cksum = utils.checksum(data);
            if (cksum == cfg.lastCheckSum)
                return log.debug("read {} bytes, content not changed", .{data.len});
            log.debug("read {} bytes, new checksum {x}", .{ data.len, cksum });
            cfg.lastCheckSum = cksum;
        } else {
            log.debug("read {} bytes", .{data.len});
        }
        var msg = Msg.FileData{ .index = @intCast(index) };
        msg.header.size += @intCast(data.len);
        try out.writeStruct(msg);
        try out.writeAll(data);
    } else if (cfg.mode == .PushAppend) {
        if (cfg.file == null) {
            cfg.file = std.fs.cwd().openFile(cfg.name, .{}) catch |err| {
                log.warn("file #{} is inaccessible {}", .{ index, err });
                try out.writeStruct(Msg.FileClear{ .index = @intCast(index) });
                return;
            };
            log.debug("started watching #{} '{s}'", .{ index, cfg.name });
        }
        var f = cfg.file.?;
        var stat = try f.stat();
        log.debug("new size {}", .{stat.size});
        if (stat.size == cfg.bytesRead) { // might be a new file
            const newStat = std.fs.cwd().statFile(cfg.name) catch |err| {
                log.warn("file #{} is inaccessible {}", .{ index, err });
                try out.writeStruct(Msg.FileClear{ .index = @intCast(index) });
                return;
            };
            if (newStat.inode != stat.inode) {
                log.info("file #{} was replaced", .{index});
                stat = newStat;
                f.close();
                f = try std.fs.cwd().openFile(cfg.name, .{});
                try out.writeStruct(Msg.FileClear{ .index = @intCast(index) });
                cfg.bytesRead = 0;
                cfg.file = f;
            }
        }
        if (stat.size < cfg.bytesRead) {
            log.info("file #{} truncated", .{index});
            try out.writeStruct(Msg.FileClear{ .index = @intCast(index) });
            try f.seekTo(0);
            cfg.bytesRead = 0;
        }
        while (cfg.bytesRead < stat.size) {
            const data = fileDataBuff[0..try f.read(&fileDataBuff)];
            log.debug("push {} more bytes", .{data.len});
            cfg.bytesRead += data.len;
            var msg = Msg.FileData{ .index = @intCast(index) };
            msg.header.size += @intCast(data.len);
            try out.writeStruct(msg);
            try out.writeAll(data);
        }
    }
}

var receivingIndex: ?usize = null;
var receivingBytesLeft: usize = 0;

fn receiveFileData(buf: []const u8) !usize {
    const read = @min(receivingBytesLeft, buf.len);
    const cfg = &configured.items[receivingIndex.?];
    try cfg.file.?.writeAll(buf[0..read]);
    receivingBytesLeft -= read;
    if (receivingBytesLeft == 0) {
        if (cfg.mode == .Pull) { // do not finish appended files ever
            log.info("finish #{} into {s} -> {s}", .{ receivingIndex.?, cfg.tmpname, cfg.name });
            cfg.file.?.close();
            cfg.file = null;
            if (keepCopy)
                try std.fs.cwd().copyFile(&cfg.tmpname, std.fs.cwd(), cfg.name, .{})
            else
                try std.fs.cwd().rename(&cfg.tmpname, cfg.name);
        }
        receivingIndex = null;
    }
    return read;
}

fn receiveStart(index: usize, dataSize: usize) !void {
    var cfg = &configured.items[index];
    receivingIndex = index;
    receivingBytesLeft = dataSize;
    if (cfg.mode == .Pull) {
        _ = try std.fmt.bufPrint(&cfg.tmpname, "~{X:0>16}.tmp", .{std.crypto.random.int(u64)});
        cfg.file = try std.fs.cwd().createFile(&cfg.tmpname, .{ .lock = .exclusive, .exclusive = true });
        log.debug("start receiving {} bytes into #{} tmp {s} -> {s}", .{
            receivingBytesLeft, receivingIndex.?, cfg.tmpname, cfg.name,
        });
    } else if (cfg.mode == .PullAppend) {
        if (cfg.file == null) {
            cfg.file = try std.fs.cwd().createFile(cfg.name, .{});
            log.debug("start receiving #{} -> {s}", .{ receivingIndex.?, cfg.name });
        }
    } else {
        fatal("bad mode {} for file #{}", .{ cfg.mode, index });
    }
}

var dataBuffer: [8192]u8 = undefined;
var bytesLeft: usize = 0;

fn processMessages(isMaster: bool, data: []const u8, out: anytype) !void {
    var buf = data;
    if (bytesLeft > 0) {
        const totalData = bytesLeft + data.len;
        if (totalData > dataBuffer.len)
            fatal("got too much data", .{});
        @memcpy(dataBuffer[bytesLeft..totalData], data);
        bytesLeft = totalData;
        buf = dataBuffer[0..bytesLeft];
    }
    if (receivingIndex != null)
        buf = buf[try receiveFileData(buf)..];
    while (buf.len >= @sizeOf(Msg.Header)) {
        const header = Msg.cast(Msg.Header, buf);
        if (header.size > dataBuffer.len and header.type != Msg.FileData.Type) // FileData messages can be big
            fatal("got overlong message of size={}", .{header.size});
        if (header.size > buf.len and header.type != Msg.FileData.Type)
            break; // wait more data
        switch (header.type) {
            Msg.Hello.Type => {
                const hello = Msg.cast(Msg.Hello, buf);
                if (!std.mem.eql(u8, &hello.banner, "hello   "))
                    fatal("bad Hello message", .{});
                const v0, const v1, const v2, const v3 = hello.version;
                if (v0 != version[0] or v1 != version[1] or v2 != version[2])
                    fatal("remote version {}.{}.{}.{} is incompatible with local version", .{ v0, v1, v2, v3 });
                if (isMaster) for (configured.items, 0..) |*cfg, i| {
                    const remoteMode: SyncMode = @enumFromInt(@intFromEnum(cfg.mode) ^ @intFromEnum(SyncMode.Inverted));
                    const remoteName = cfg.remoteName orelse fatal("unexpected", .{});
                    var msg = Msg.ConfigReq{ .index = @intCast(i), .mode = remoteMode, .options = cfg.options };
                    msg.header.size += @intCast(remoteName.len);
                    try out.writeStruct(msg);
                    try out.writeAll(remoteName);
                };
            },
            Msg.Heartbeat.Type => {
                const message = Msg.cast(Msg.Heartbeat, buf);
                log.info("received Heartbeat #{}", .{message.index});
            },
            Msg.ConfigReq.Type => {
                const req = Msg.cast(Msg.ConfigReq, buf);
                var fname: []const u8 = undefined;
                const res = Msg.ConfigRes{
                    .index = req.index,
                    .result = r: {
                        if (isMaster)
                            break :r .WrongSide;
                        fname = buf[@sizeOf(Msg.ConfigReq)..header.size];
                        log.info("received file request #{} {s}", .{ req.index, fname });
                        if (req.index != configured.items.len)
                            break :r .BadIndex;
                        if (req.mode != .Push and req.mode != .Pull and req.mode != .PullAppend and req.mode != .PushAppend)
                            break :r .BadMode;
                        if (req.options._ != 0)
                            break :r .BadOptions;
                        if (std.mem.indexOfAny(u8, fname, "<>:\"/\\|?*\x00") != null or std.mem.indexOf(u8, fname, "..") != null or
                            (fname.len == 1 and fname[0] == '.'))
                            break :r .BadName;
                        break :r .Success;
                    },
                };
                if (res.result == .Success) {
                    try out.writeStruct(res);
                    _ = try addLocalConfig(req.mode, try gpa.dupe(u8, fname), req.options);
                    try push(req.index, out);
                } else {
                    try out.writeStruct(res);
                }
            },
            Msg.ConfigRes.Type => r: {
                if (!isMaster)
                    break :r try out.writeStruct(Msg.Reject{ .reason = 665 });
                const res = Msg.cast(Msg.ConfigRes, buf);
                if (res.index < 0 or res.index >= configured.items.len)
                    fatal("bad index ({}) in file response", .{res.index});
                if (res.result != .Success)
                    fatal("file #{} request failed with reason {}", .{ res.index, res.result });
                var cfg = &configured.items[res.index];
                if (cfg.accepted)
                    fatal("already accepted file #{} request", .{res.index});
                cfg.accepted = true;
                log.info("file request accepted #{}, local name {s}", .{ res.index, cfg.name });
                try push(res.index, out);
            },
            Msg.FileData.Type => {
                if (buf.len < @sizeOf(Msg.FileData))
                    break; // wait more data, do not panic on overlong messages
                const msg = Msg.cast(Msg.FileData, buf);
                if (msg.index < 0 or msg.index >= configured.items.len)
                    fatal("bad index ({}) in file data message", .{msg.index});
                try receiveStart(msg.index, header.size - @sizeOf(Msg.FileData));
                buf = buf[@sizeOf(Msg.FileData)..]; // advance only header
                buf = buf[try receiveFileData(buf)..];
                continue; // buffer already advanced
            },
            Msg.FileClear.Type => {
                const msg = Msg.cast(Msg.FileClear, buf);
                if (msg.index < 0 or msg.index >= configured.items.len)
                    fatal("bad index ({}) in file clear message", .{msg.index});
                const cfg = configured.items[msg.index];
                if (cfg.mode != .PullAppend)
                    fatal("bad mode ({}) in file clear message for file #{}", .{ cfg.mode, msg.index });
                if (cfg.file) |f| {
                    try f.seekTo(0);
                    try f.setEndPos(0);
                }
            },
            else => {
                fatal("received unknown message {}", .{header});
            },
        }
        buf = buf[header.size..];
    }
    std.mem.copyForwards(u8, dataBuffer[0..buf.len], buf);
    bytesLeft = buf.len;
}

pub const std_options = utils.std_options;
