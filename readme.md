Structured Logging for Zig

logz is an opinionated structured logger that outputs to stdout, stderr, a file or a custom writer using logfmt or JSON. It aims to minimize runtime memory allocation by using a pool of pre-allocated loggers. 

# Metrics
If you're looking for metrics, check out my <a href="https://github.com/karlseguin/metrics.zig">prometheus library for Zig</a>.

# Installation
This library supports native Zig module (introduced in 0.11). Add a "logz" dependency to your `build.zig.zon`.

## Zig 0.11
Please use the [zig-0.11](https://github.com/karlseguin/log.zig/tree/zig-0.11) branch for a version of the library which is compatible with Zig 0.11.

The master branch of this library follows Zig's master.

# Usage
For simple cases, a global logging pool can be configured and used:

```zig
// initialize a logging pool
try logz.setup(allocator, .{
    .level = .Info, 
    .pool_size = 100,
    .buffer_size = 4096, 
    .large_buffer_count = 8,
    .large_buffer_size = 16384,
    .output = .stdout,
    .encoding = .logfmt,
});
defer logz.deinit();

// other places in your code
logz.info().string("path", req.url.path).int("ms", elapsed).log();

// The src(@src()) + err(err) combo is great for errors
logz.err().src(@src()).err(err).log();
```

Alternatively, 1 or more explicit pools can be created:

```zig
var requestLogs = try logz.Pool.init(allocator, .{});
defer requestLogs.deinit();

// requestLogs can be shared across threads
requestLogs.err().
    string("context", "divide").
    float("a", a).
    float("b", b).log();
```

`logz.Level.parse([]const u8) ?Level` can be used to convert a string into a logz.Level.

The configuration `output` can be `.stdout`, `.stderr` or a `.{.file = "PATH TO FILE}`. More advanced cases can use `logTo(writer: anytype)` instead of `log()`.

The configuration `encoding` can be either `logfmt` or `json`.

# Important Notes
1. Attribute keys are never escaped. logz assumes that attribute keys can be written as is.
2. Logz can silently drop attributes from a log entry. This only happens when the attribute exceeds the configured sized (either of the buffer or the buffer + large_buffer) or a large buffer couldn't be created.
3. Depending on the `pool_strategy` configuration, when empty the pool will either dynamically create a logger (`.pool_strategy = .create`) or return a noop logger (`.pool_strategy = .noop)`. If creation fails, a noop logger will be return and an error is written using `std.log.err`.

## Pools and Loggers
Pools are thread-safe.

The following functions returns a logger:

* `pool.debug()`
* `pool.info()`
* `pool.warn()`
* `pool.err()`
* `pool.fatal()`
* `pool.logger()`
* `pool.loggerL()`

The returned logger is NOT thread safe. 

### Attributes
The logger can log:
* `fmt(key: []const u8, comptime format: []const u8, values: anytype)`
* `string(key: []const u8, value: ?[]const u8)`
* `stringZ(key: []const u8, value: ?[*:0]const u8)`
* `boolean(key: []const u8, value: ?boolean)`
* `int(key: []const u8, value: ?any_int)`
* `float(key: []const u8, value: ?any_float)`
* `binary(key: []const u8, value: ?[]const u8)` - will be url_base_64 encoded
* `err(e: anyerror)` - same as `errK("@err", e)`;
* `errK(key: []const u8, e: anyerror)`
* `stringSafe(key: []const u8, value: ?[]const u8)` - assumes value doesn't need to be encoded
* `stringSafeZ(key: []const u8, value: ?[*:0]const u8)` - assumes value doesn't need to be encoded
* `ctx(value: []const u8)` - same as `stringSafe("@ctx", value)`
* `src(value: std.builtin.SourceLocation)` - Logs an `std.builtin.SourceLocation`, the type of value you get from the `@src()` builtin.

### Log Level
Pools are configured with a minimum log level:

* `logz.Level.Debug`
* `logz.Level.Info`
* `logz.Level.Warn`
* `logz.Level.Error`
* `logz.Level.Fatal`
* `logz.Level.None`

When getting a logger for a value lower than the configured level, a noop logger is returned. This logger exposes the same API, but does nothing.

```zig
var logs = try logz.Pool.init(allocator, .{.level = .Error});

// this won't do anything
logs.info().bool("noop", true).log();
```

The noop logger is meant to be relatively fast. But it doesn't eliminate any complicated values you might pass. Consider this example:

```zig
var logs = try logz.Pool.init(allocator, .{.level = .None});
try logs.warn().
    string("expensive", expensiveCall()).
    log();
```

Although the logger is disabled (the log level is `Fatal`), the `expensiveCall()` function is still called. In such cases, it's necessary to use the `pool.shouldLog` function:

```zig
if (pool.shouldLog(.Warn)) {
    try logs.warn().
        string("expensive", expensiveCall()).
        log();
}
```

### Config
Pools use the following configuration. The default value for each setting is show:

```zig
pub const Config = struct {
    // The number of loggers to pre-allocate. 
    pool_size: usize = 32,

    // Controls what the pool does when empty. It can either dynamically create
    // a new Logger, or return the Noop logger.
    pool_startegy: .create, // or .noop

    // Each logger in the pool is configured with a static buffer of this size.
    // An entry that exceeds this size will attempt to expand into the 
    // large buffer pool. Failing this, attributes will be dropped
    buffer_size: usize = 4096,

    // The minimum log level to log. `.None` disables all logging
    level: logz.Level = .Info,

    // Data to prepend at the start of every logged message from this pool
    // See the Advanced Usage section
    prefix: ?[]const u8 = null,

    // Where to write the output: can be either .stdout or .stderr
    output: Output = .stdout, // or .stderr, or .{.file = "PATH TO FILE"}

    encoding: Encoding = .logfmt, // or .json

    // How many large buffers to create
    large_buffer_count: u16 = 8,

    // Size of large buffers.
    large_buffer_size: usize = 16384,

    // Controls what the large buffer pool does when empty. It can either 
    // dynamically create a large buffer, or drop the attribute
    large_buffer_startegy: .create, // or .drop
};
```

### Timestamp and Level
When using the `debug`, `info`, `warn`, `err` or `fatal` functions, logs will always begin with `@ts=$MILLISECONDS_SINCE_JAN1_1970_UTC @l=$LEVEL`, such as: `@ts=1679473882025 @l=INFO`. With JSON encoding, the object will always have the `"@ts"` and `"@l"` fields.

### Logger Life cycle
The logger is implicitly returned to the pool when `log`, `logTo` or `tryLog` is called. In rare cases where `log`, `logTo` or `tryLog` are not called, the logger must be explicitly released using its `release()` function:

```zig
// This is a contrived example to show explicit release
var l = logz.info();
_  = l.string("key", "value");

// actually, on second thought, I don't want to log anything
l.release();
```

### Method Chaining
Loggers are mutable. The method chaining (aka fluent interface) is purely cosmetic. The following are equivalent:

```zig
// chaining
info().int("over", 9000).log();

// no chaining
var l = info();
_ = l.int("over", 9000);
l.log();
```

### tryLog
The call to `log` can fail. On failure, a message is written using `std.log.err`. However, `log` returns `void` to improve the API's usability (it doesn't require callers to `try` or `catch`).

`tryLog` can be used instead of `log`. This function returns a `!void` and will not write to `std.log.err` on failure.

## Advanced Usage

### Pre-setup
`setup(CONFIG)` can be called multiple times, but isn't thread safe. The idea is that, at the very start, `setup` can be called with a minimal config so that any startup errors can be logged. After startup, but before the full application begins, `setup` is called a 2nd time with the correct config. Something like:

```zig
pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = general_purpose_allocator.allocator();

    // minimal config so that we can use logz will setting things up
    try logz.setup(.{
        .pool_size = 2, 
        .max_size = 4096, 
        .level = .Warn
    });

    // can safely call logz functions, since we now have a mimimal setup
    const config = loadConfig();
    // more startup things here

    // ok, now setup our full logger (which we couldn't do until we read 
    // our config, which could have failed)

    try logz.setup(.{
        .pool_size = config.log.pool_size, 
        .max_size = config.log.max_size,
        .level = config.log.level
    });
    ...
}
```

### Prefixes
A pool can be configured with a prefix by setting the `prefix` field of the configuration. When set, all log entries generated by loggers of this pool will contain the prefix. 

The prefix is written as-is.

```zig
// prefix can be anything []const u8. It doesn't have to be a key=value
// it will not be encoded if needed, and doesn't even have to be a valid string.
var p = try logz.Pool.init(allocator, .{.prefix = "keemun"});
defer p.deinit();

p.info().boolean("tea", true).log();
```

The above will generate a log line: `keemun @ts=TIMESTAMP @l=INFO tea=Y"`

When using `.json` encoding, your prefix must begin the object:

```zig:
var p = try logz.Pool.init(allocator, .{.prefix = "=={"});
defer p.deinit();

p.info().boolean("tea", true).log();
```
The above will generate a log line: `=={"@ts":TIMESTAMP, "@l":"INFO", "tea":true}`

### Multi-Use Logger
Rather than having a logger automatically returned to the pool when `.log()` or `tryLog()` are called, it is possible to flag the logger for "multi-use". In such cases, the logger must be explicitly returned to the pool using `logger.release()`. This can be enabled by calling `multiuse` on the logger. Logs created by the logger will share the same attributes up to the point where multiuse was called:

```zig
var logger = logz.logger().string("request_id", request_id).multiuse();
defer logger.release(); // important

logger.int("status", status_code).int("ms", elapsed_time).level(.Info).log()
...
logger.err(err).string("details", "write failed").level(.Error).log()
```

The above logs 2 distinct entries, both of which will contain the "request_id=XYZ" attribute. Do remember that while the logz.Pool is thread-safe, individual loggers are not. A multi-use logger should not be used across threads.

### Deferred Level
The `logger()` function returns a logger with no level. This can be used to defer the level:

```zig
var logger = logz.logger().
    stringSafe("ctx", "db.setup").
    string("path", path);
defer logger.log();

const db = zqlite.open(path, true) catch |err| {
    _ = logger.err(err).level(.Fatal);
}

_ = logger.level(.Info);
return db;
```

Previously, we saw how an internal "noop" logger is returned when the log level is less than the configured log level. With a log level of `Warn`, the following is largely 3 noop function calls:

```zig
log.info().string("path", path).log();
```

With deferred log levels, this isn't possible - the configured log level is only considered when `log` (or `tryLog`) is called. Again, given a log level of `Warn`, the following **will not** log anything, but the call to `string("path", path)` is not a "noop":

```zig
var l = log.logger().string("path", path);
_ = l.level(.Info);
l.log(); 
```

The `log.loggerL(LEVEL)` function is a very minor variant which allows setting a default log level. Using it, the original deferred example can be rewritten:

```zig
var logger = logz.loggerL(.Info).
    stringSafe("ctx", "db.setup").
    string("path", path);
defer logger.log();

const db = zqlite.open(path, true) catch |err| {
    _ = logger.err(err).level(.Fatal);
}

// This line is removed
// logger.level(.Info);
return db;
```

`errdefer` can be used with deferred logging as a simple and generic way to log errors. The above can be re-written as:

```zig
var logger = logz.loggerL(.Info).
    stringSafe("ctx", "db.setup").
    string("path", path);
defer logger.log();
errdefer |err| _ = logger.err(err).level(.Fatal);

return zqlite.open(path, true);
```

### Allocations
When configured with `.pool_strategy = .noop` and `.large_buffer_strategy = .drop`, the logger will not allocate memory after the pool is initialized.

### Maximum Log Line Size
The maximum possible log entry is: `config.prefix.len + config.buffer_size + config.large_buffer_size + ~35`.  

Th last 35 bytes is for the the @ts and @l attributes, and the trailing newline. The exact length of these can vary by a few bytes (e.g. the json encoder takes a few additional bytes to quote the key).

### Custom Output
The `logTo(writer: anytype)` can be called instead of `log()`. The writer must expose 1 method:

* `writeAll(self: Self, data: []const u8) !void`

A single call to `logTo()` can result in multiple calls to `writeAll`. `logTo` uses a mutex to ensure that a single entry is written to the writer at a time.

## Testing
When testing, I recommend you do the following in your main test entry:

```zig
var leaking_gpa = std.heap.GeneralPurposeAllocator(.{}){};
const leaking_allocator = leaking_gpa.allocator();

test {
    try logz.setup(leaking_allocator, .{.pool_size = 5, .level = .None});

    // rest of your setup, such as::
    std.testing.refAllDecls(@This());
}
```

First, you should not use `std.testing.allocator` since Zig offers no way to cleanup globals after tests are run. In the above, the `logz.Pool` *will* leak (but that should be ok in a test).

Second, notice that we're using a global allocator. This is because the pool may need to dynamically allocate a logger, and thus the allocator must exist for the lifetime of the pool. Strictly speaking, this can be avoided if you know that the pool will never need to allocate a dynamic logger, so setting a sufficiently large `pool_size` would also work.

Finally, you should set the log level to '.None' until the following Zig  issue is fixed [https://github.com/ziglang/zig/issues/15091](https://github.com/ziglang/zig/issues/15091).
