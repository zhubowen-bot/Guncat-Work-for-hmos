# node-ohos — IEC-specific pieces of the Node.js port

This directory contains the sources that belong to IEC rather than to upstream
Node.js. The build itself is `../build_node.sh` (download, verify, configure,
ninja, re-link, pack npm).

```
iec_node_entry.cc        C entry points exported by libnode.so
patches/                 diffs against the upstream Node.js source
```

`patches/` contains only diffs against upstream. The entry source is kept
separate because it does not change when Node is upgraded.

## Entry points

The IEC exec service loads a command object and calls a C symbol. Node's entry
is C++ (`node::Start(int, char**)`), so the wrapper provides:

| Symbol | Purpose |
| --- | --- |
| `iec_node_main` | run node |
| `iec_npm_main` | `[node, <sysroot>/npm/bin/npm-cli.js, args...]` |
| `iec_npx_main` | the same for npx |

The wrapper is self-contained and reads configuration from the environment:

- `IEC_NODE_JITLESS` = `on|off|auto` (the legacy `BSH_NODE_JITLESS` is also
  accepted). `on` adds `--jitless --no-expose-wasm`; `auto` probes whether
  writable-executable memory is available.
- `IEC_SYSROOT` locates `npm/` (the legacy `BSH_SYSROOT` is also accepted).

The launchers in the application bootstrap should point at these symbols.

## Patches

| Patch | Purpose |
| --- | --- |
| `0001-jit-prctl-sandwich.patch` | V8 needs the JitFort prctl sandwich around executable mappings |
| `0002-exec-path-from-argv0.patch` | `process.execPath` must use argv[0], not the host appspawn |
| `0003-make-unique-for-overwrite-cxx20.patch` | V8 12.4 with the SDK's clang 15 |
| `0004-smallvector-avoid-std-pair.patch` | same toolchain workaround |
| `0005-zlib-crc32-clang15-target-attr.patch` | zlib CRC32 target attribute under clang 15 |

Patch application is best-effort: a patch that is already applied is skipped.
When bumping `NODE_VER`, re-create the patches from the new source tree.
