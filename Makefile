.PHONY: t
t:
	# 2>&1|cat from: https://github.com/ziglang/zig/issues/10203
	zig test src/logz.zig 2>&1|cat
