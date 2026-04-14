const std = @import("std");
const builtin = @import("builtin");

pub var label: []const u8 = "";

pub const pollableStdIn = switch (builtin.os.tag) {
    .linux => struct {
        fn getStdIn() std.fs.File.Handle {
            return std.io.getStdIn().handle;
        }
    },
    .windows => struct {
        const w32 = std.os.windows;
        extern "kernel32" fn ConnectNamedPipe(hNamedPipe: w32.HANDLE, lpOverlapped: ?*anyopaque) callconv(.winapi) w32.BOOL;
        var pipeNameBuff: [256]u8 = undefined;
        fn win32hack() !w32.HANDLE {
            const pipeName = try std.fmt.bufPrint(&pipeNameBuff, "\\\\.\\pipe\\rt~{x}", .{std.crypto.random.int(u128)});
            //std.debug.print("pipe name {s}\n", .{pipeName});
            var u16buff: [256 * 2]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&u16buff);
            const wtf16 = try std.unicode.wtf8ToWtf16LeAllocZ(fba.allocator(), pipeName);
            defer fba.allocator().free(wtf16);
            const pipe = w32.kernel32.CreateNamedPipeW(wtf16, w32.PIPE_ACCESS_DUPLEX | w32.FILE_FLAG_OVERLAPPED, //| w32.FILE_FLAG_FIRST_PIPE_INSTANCE
                w32.PIPE_TYPE_BYTE | w32.PIPE_READMODE_BYTE, // | w32.PIPE_REJECT_REMOTE_CLIENTS,
                1, 4096, 4096, 0, null);
            _ = try std.Thread.spawn(.{}, pumpStdin, .{pipeName});
            _ = ConnectNamedPipe(pipe, null);
            return pipe;
        }
        fn pumpStdin(pipeName: []const u8) void {
            //std.debug.print("pump thread started\n", .{});
            const in = std.io.getStdIn().reader();
            const out = std.fs.cwd().openFile(pipeName, .{ .mode = .write_only }) catch unreachable;
            var buff: [4096]u8 = undefined;
            while (true) {
                const read = in.read(&buff) catch break;
                if (read == 0)
                    break;
                out.writeAll(buff[0..read]) catch break;
            }
            //std.debug.print("pump thread exit\n", .{});
        }
        fn getStdIn() std.fs.File.Handle {
            return win32hack() catch unreachable;
        }
    },
    else => void,
}.getStdIn;

pub fn checksum(source: []const u8) u128 {
    // from https://github.com/tigerbeetle/tigerbeetle/commit/fa1f6068f844fc89103dcb1b7025081862c6ce4a
    const AesBlock = std.crypto.core.aes.Block;
    const Aegis128 = struct {
        const State = [8]AesBlock;
        const key = std.mem.zeroes([16]u8);
        const nonce = std.mem.zeroes([16]u8);
        var seed_once = std.once(seed_init);
        var seed_state: State = undefined;
        fn seed_init() void {
            const c1 = AesBlock.fromBytes(&[16]u8{ 0xdb, 0x3d, 0x18, 0x55, 0x6d, 0xc2, 0x2f, 0xf1, 0x20, 0x11, 0x31, 0x42, 0x73, 0xb5, 0x28, 0xdd });
            const c2 = AesBlock.fromBytes(&[16]u8{ 0x0, 0x1, 0x01, 0x02, 0x03, 0x05, 0x08, 0x0d, 0x15, 0x22, 0x37, 0x59, 0x90, 0xe9, 0x79, 0x62 });
            const key_block = AesBlock.fromBytes(&key);
            const nonce_block = AesBlock.fromBytes(&nonce);
            seed_state = [8]AesBlock{ key_block.xorBlocks(nonce_block), c1, c2, c1, key_block.xorBlocks(nonce_block), key_block.xorBlocks(c2), key_block.xorBlocks(c1), key_block.xorBlocks(c2) };
            var i: usize = 0;
            while (i < 10) : (i += 1) update(&seed_state, nonce_block, key_block);
        }
        inline fn update(blocks: *State, d1: AesBlock, d2: AesBlock) void {
            const tmp = blocks[7];
            comptime var i: usize = 7;
            inline while (i > 0) : (i -= 1) blocks[i] = blocks[i - 1].encrypt(blocks[i]);
            blocks[0] = tmp.encrypt(blocks[0]);
            blocks[0] = blocks[0].xorBlocks(d1);
            blocks[4] = blocks[4].xorBlocks(d2);
        }
        fn enc(state: *State, src: *const [32]u8) void {
            const msg0 = AesBlock.fromBytes(src[0..16]);
            const msg1 = AesBlock.fromBytes(src[16..32]);
            update(state, msg0, msg1);
        }
        fn mac(blocks: *State, adlen: usize, mlen: usize) [16]u8 {
            var sizes: [16]u8 = undefined;
            std.mem.writeInt(u64, sizes[0..8], adlen * 8, .little);
            std.mem.writeInt(u64, sizes[8..16], mlen * 8, .little);
            const tmp = AesBlock.fromBytes(&sizes).xorBlocks(blocks[2]);
            var i: usize = 0;
            while (i < 7) : (i += 1) update(blocks, tmp, tmp);
            return blocks[0].xorBlocks(blocks[1]).xorBlocks(blocks[2]).xorBlocks(blocks[3]).xorBlocks(blocks[4])
                .xorBlocks(blocks[5]).xorBlocks(blocks[6]).toBytes();
        }
    };
    // Initialize the seed state and make a copy.
    Aegis128.seed_once.call();
    var state = Aegis128.seed_state;
    // Encrypt the source with the state (without an output cipher).
    var src: [32]u8 align(16) = undefined;
    var i: usize = 0;
    while (i + 32 <= source.len) : (i += 32) Aegis128.enc(&state, source[i..][0..32]);
    if (source.len % 32 != 0) {
        @memset(src[0..], 0);
        @memcpy(src[0 .. source.len % 32], source[i .. i + source.len % 32]);
        Aegis128.enc(&state, &src);
    }
    return @bitCast(Aegis128.mac(&state, 0, source.len));
}

pub const std_options = std.Options{
    // Set the log level to info
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe, .ReleaseSmall => .info,
        .ReleaseFast => .err,
    },
    .logFn = struct {
        fn myLogFn(comptime level: std.log.Level, comptime scope: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
            _ = scope;
            std.debug.lockStdErr();
            defer std.debug.unlockStdErr();
            const stderr = std.io.getStdErr().writer();
            var bw = std.io.bufferedWriter(stderr);
            const writer = bw.writer();
            nosuspend {
                const prefix = comptime "EWID"[@intFromEnum(level)]; // "[" ++ comptime level.asText() ++ "] " ++ scope_prefix;
                writer.print("{s} {c} [{s}] ", .{ now(), prefix, label }) catch return;
                writer.print(format ++ "\n", args) catch return;
                bw.flush() catch return;
            }
        }
        var timeBuffer: [8 + 4]u8 = undefined;
        fn now() []u8 {
            const ms: u64 = @intCast(@mod(std.time.milliTimestamp(), std.time.ms_per_day));
            const sec = ms / 1000;
            return std.fmt.bufPrint(&timeBuffer, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ sec / 3600, (sec / 60) % 60, sec % 60, ms % 1000 }) catch unreachable;
        }
    }.myLogFn,
};
