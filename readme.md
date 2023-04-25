Structured Logging for Zig

logz is an opinionated structured logger that outputs to stdout using the logfmt format. It aims to minimize runtime memory allocation by using a pool of pre-allocated loggers. 

# Installation
This library supports native Zig module (introduced in 0.11). Add a "logz" dependency to your `build.zig.zon`.

# Usage
For simple cases, a global logging pool can be configured and used:

```zig
// initialize a logging pool
try logz.setup(allocator, .{
    .level = .Warn, 
    .pool_size = 100,
    .max_size = 4096, 
});

// other places in your code
logz.info().string("path", req.url.path).int("ms", elapsed).log();
```

(You can use `std.meta.stringToEnum(logz.Level, config.log_level) orelse .Warn` to turn a string into an enum)

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

# Important Notes
1. Attribute keys are never escaped. logz assumes that attribute keys can be written as is.
2. Logz will silently truncate attributes if the log entry exceeds the configured `max_size`. This truncation only happens at the attribute level (not in the middle of a key or value), thus either the whole key=value is written or none of it is.
3. If the pool is empty, logz will attempt to dynamically allocate a new logger. If this fails, a noop logger will be return. The log entry is silently dropped. An error message **is** written using `std.log.err`.

## Pools and Loggers
Pools are thread-safe.

The following functions returns a logger:

* `pool.debug()`
* `pool.info()`
* `pool.warn()`
* `pool.err()`
* `pool.fatal()`
* `pool.logger()`

The returned logger is NOT thread safe. 

### Attributes
The logger can log:
* `string(key: []const u8, value: ?[]const u8)`
* `stringZ(key: []const u8, value: ?[*:0]const u8)`
* `boolean(key: []const u8, value: ?boolean)`
* `int(key: []const u8, value: ?any_int)`
* `float(key: []const u8, value: ?any_float)`
* `binary(key: []const u8, value: ?[]const u8)`
* `err(key: []const u8, e: anyerror)`

Binary values are url_base_64 encoded without padding.

The logger also has a `stringSafe(key []const u8, value ?[]const u8)` and `stringSafeZ(key []const u8, value ?[*:0]const u8)`` which can be used when the caller is sure that `value` does not require escaping.

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

    // The maximum size, in bytes, that each log entry can be.
    // Writing more data than max_size will truncate the log at a key=value 
    // boundary (in other words, you won't get a key or value randomly 
    // truncated, either the entire key=value is written, or it isn't)
    max_size: usize = 4096,

    // The minimum log level to log. `.None` disables all logging
    level: logz.Level = .Info,

    // Data to prepend at the start of every logged message from this pool
    // See the Advanced Usage section
    prefix: ?[]const u8 = null,
};
```

### Timestamp and Level
When using the `debug`, `info`, `warn`, `err` or `fatal` functions, logs will always begin with `@ts=$MILLISECONDS_SINCE_JAN1_1970_UTC @l=$LEVEL`, such as: `@ts=1679473882025 @l=INFO`.


### Logger Life cycle
The logger is implicitly returned to the pool when `log`, `logTo` or `tryLog` is called. In rare cases where `log`, `logTo` or `tryLog` are not called, the logger must be explicitly released using its `release()` function:

```zig
// This is a contrived example to show explicit release
var l = logz.info();
_  = l.string("key", "value");
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

The prefix is written as-is, with no escape and no enforcement of being a key=value.

```zig
// prefix can be anything []const u8. It doesn't have to be a key=value
// it will not be encoded if needed, and doesn't even have to be a valid string.
var p = try logz.Pool.init(allocator, .{.prefix = "keemun"});
defer p.deinit();

p.info().boolean("tea", true).log();
```

The above will generate a log line: `keemun @ts=TIMESTAMP @l=INFO tea=Y"`

### Deferred Level
The `logger()` function returns a logger with no level. This can be used to defer the level:

```zig
var logger = logz.logger().
    stringSafe("ctx", "db.setup").
    string("path", path);
defer logger.log();

const db = zqlite.open(path, true) catch |err| {
    logger.err("err", err).level(logz.Fatal);
}

logger.level(logz.Info);
return db;
```

`level(logz.Level)` isn't chainable (it doesn't return self). This is because `level` is expected to be used as above, where it is the last call in a chain and thus we want to avoid an unused returned value error.

Previously, we saw how an internal "noop" logger is returned when the log level is less than the configured log level. With a log level of `Warn`, the following is largely 3 noop function calls:

```zig
log.info().string("path", path).log();
```

With deferred log levels, this isn't possible - the configured log level is only considered when `log` (or `tryLog`) is called. Again, given a log level of `Warn`, the following **will not** log anything, but the call to `string("path", path)` is not a "noop":

```zig
var l = log.logger().string("path", path);
l.level(logz.Info);
l.log(); 
```

The `log.loggerL(LEVEL)` function is a very minor variant which allows setting a default log level. Using it, the original deferred example can be rewritten:

```zig
var logger = logz.loggerL(logz.Info).
    stringSafe("ctx", "db.setup").
    string("path", path);
defer logger.log();

const db = zqlite.open(path, true) catch |err| {
    logger.err("err", err).level(logz.Fatal);
}

// This line is removed
// logger.level(logz.Info);
return db;
```

`errdefer` can be used with deferred logging as a simple and generic way to log errors. The above can be re-written as:

```zig
var logger = logz.loggerL(logz.Info).
    stringSafe("ctx", "db.setup").
    string("path", path);
defer logger.log();
errdefer |err| logger.err("err", err).level(logz.Fatal);

return zqlite.open(path, true);
```
