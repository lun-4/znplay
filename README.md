# znplay

a proof of concept for network audio play
using libsoundio and libsndfile in zig

## build

- libsndfile 1.0.29
- libao 1.2.2

```
zig build
```

## use

only http

```
./zig-cache/bin/znplay host.test:port somepath
```
