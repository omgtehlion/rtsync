# rtsync

**rtsync** — a real-time file synchroniser written in Zig 0.14. It watches local files for changes and instantly pushes or pulls them to/from a remote host (or another local directory) over a binary protocol, with minimal overhead and no external dependencies.

---

## Features

- **Real-time sync** — detects file changes the moment they happen using native OS APIs (fanotify on Linux, ReadDirectoryChangesW on Windows)
- **Push & pull** — sync files in either direction; the same binary runs on both sides
- **Append mode** — stream log files and append-only data without resending the full file
- **Lazy send** — compares checksums before sending; skips the transfer if the file content hasn't changed
- **SSH transport** — connects to remote hosts via SSH; the remote side runs automatically
- **Local mode** — sync between two local directories without any network involved
- **Heartbeat** — keeps the connection alive over idle periods

---

## Platform Support

| Platform | File Watch Backend        | Minimum Version      |
|----------|---------------------------|----------------------|
| Linux    | `fanotify`                | Kernel 5.17+         |
| Windows  | `ReadDirectoryChangesW`   | Windows Vista+       |
| Others   | Not supported             | —                    |

---

## Installation

### Prerequisites

- [Zig 0.14](https://ziglang.org/download/#release-0.14.1)

### Build

```sh
zig build -Doptimize=ReleaseSafe
```

The binary will be placed at `zig-out/bin/rtsync`. Copy it to any directory in your `PATH`, and on the remote host as well.

---

## Usage

```
rtsync <remote> [--help] [--exe <path>] [--keep-copy] [<commands>]...
```

### `<remote>`

| Value            | Description                                                   |
|------------------|---------------------------------------------------------------|
| `/path/to/dir`   | Sync with another local directory                             |
| `host:[/path]`   | Sync with a remote host via SSH; `/path` defaults to home dir |

### Options

| Flag              | Description                                                           |
|-------------------|-----------------------------------------------------------------------|
| `-h`, `--help`    | Print usage                                                           |
| `--exe <path>`    | Path to `rtsync` on the remote side (default: `rtsync`)              |
| `--keep-copy`     | Keep a local copy of each received file (debug)                      |

### Commands

| Command                              | Description                                                          |
|--------------------------------------|----------------------------------------------------------------------|
| `--push <local>[:<remote>]`         | Send local file to remote on every change                            |
| `--pull <local>[:<remote>]`         | Receive remote file locally on every change                          |
| `--push-append <local>[:<remote>]`  | Stream appended data from local to remote (log/append-only files)   |
| `--pull-append <local>[:<remote>]`  | Stream appended data from remote to local                            |

Multiple file arguments can follow a single `--push` / `--pull` flag. The optional `:<remote>` suffix lets you use a different filename on the remote side.

---

## Examples

**Push a config file to a server on every save:**
```sh
rtsync user@server --push config.toml
```

**Push a local file with a different name on the remote:**
```sh
rtsync user@server --push local.conf:app/production.conf
```

**Pull a remote file into the current directory:**
```sh
rtsync user@server --pull data.db
```

**Stream a growing log file from a server in real time:**
```sh
rtsync user@server --pull-append /var/log/app.log:app.log
```

**Sync multiple files in both directions:**
```sh
rtsync user@server --push src/main.zig --pull output/result.bin
```

**Sync with another local directory:**
```sh
rtsync /tmp/mirror --push notes.md
```

---

## How It Works

rtsync spawns itself on the remote side via SSH, then communicates over stdin/stdout using a simple binary protocol.
The master sends configuration requests describing which files to sync and in which direction.
From that point on, both sides independently watch their files and stream updates to each other as changes are detected.


## Sync Modes

| Mode         | Direction       | Behaviour on change                                                        |
|--------------|-----------------|----------------------------------------------------------------------------|
| `Push`       | local → remote  | Full file re-sent (skipped if checksum unchanged)                          |
| `Pull`       | remote → local  | Full file received into a temp file, then atomically renamed               |
| `PushAppend` | local → remote  | Only newly appended bytes are sent; handles truncation and inode rotation  |
| `PullAppend` | remote → local  | Appended bytes written directly; `FileClear` resets the file on truncation |

## Limitations

- Only the **current working directory** is watched; subdirectory monitoring is not yet supported
- The `--push` file buffer is capped at **4 MB**
- `fanotify` requires **Linux kernel 5.17** or newer
- File filtering and inode-following options are planned but not yet implemented

## Version

Current version: **0.0.2**

The version is verified during the protocol handshake — both sides must run the same major and minor version.


## License

MIT
