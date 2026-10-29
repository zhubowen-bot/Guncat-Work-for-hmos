# Guncat Work

> [中文](README.md) | English

**A native AI workbench on your HarmonyOS phone** — built from scratch in ArkTS / ArkUI, not a client that forwards requests to a cloud runner. **A native `shell`** (mksh + toybox/libarchive/git/ssh/node as HarmonyOS `.so`, no VM, no JIT permission needed) and **native CPython 3.12** (compiled as a HarmonyOS `.so` and run in-process — numpy / pandas / scipy / matplotlib all offline) really run on the device; a Codex-style Agent Loop with **47 tools + 32 skills** closes the loop on-device; both headline forms — **Intelligent UI** (one sentence in, an operable interface out) and **Harness** (multi-turn tool loop + sandboxed workspace) — run on real hardware, producing PPT / Word / Excel / drawings on-device. **Available on HarmonyOS phones, not just HarmonyOS PCs.**

<!-- Demo slot (optional upgrade): a 30–60s real-device screen recording — enter work mode → generate a PPT from one sentence → expand the artifact card → switch to interactive mode and drag a slider to recompute. A moving GIF beats static screenshots. -->

![HarmonyOS](https://img.shields.io/badge/HarmonyOS-API%2024%20(6.1.1)-blue)
![version](https://img.shields.io/badge/version-7.0.0-blue)
![forms](https://img.shields.io/badge/Agent%20Forms-Intelligent%20UI%20%2B%20Harness-blueviolet)
![shell](https://img.shields.io/badge/shell-IEC%20native%20%C2%B7%20no%20VM-orange)
![python](https://img.shields.io/badge/CPython-3.12%20native-3776AB)
![tools](https://img.shields.io/badge/built--in%20tools-47-informational)
![skills](https://img.shields.io/badge/skills-32-informational)
[![license](https://img.shields.io/badge/license-Apache--2.0-green)](LICENSE)
[![CI](https://github.com/zhubowen-bot/Guncat-Work-for-hmos/actions/workflows/ci.yml/badge.svg)](https://github.com/zhubowen-bot/Guncat-Work-for-hmos/actions/workflows/ci.yml)

<p align="center">
  <a href="docs/images/interactive-home.jpg"><img src="docs/images/interactive-home.jpg" width="23%" alt="Interactive Mode home screen" /></a>
  <a href="docs/images/interactive-ui.jpg"><img src="docs/images/interactive-ui.jpg" width="23%" alt="Interactive Mode delivering an operable interface" /></a>
  <a href="docs/images/work-delivery.jpg"><img src="docs/images/work-delivery.jpg" width="23%" alt="Work Mode delivering a long-horizon task" /></a>
  <a href="docs/images/run-js.jpg"><img src="docs/images/run-js.jpg" width="23%" alt="run_js on-device JavaScript sandbox" /></a>
</p>

<p align="center"><sub>Interactive Mode home · an interface delivered by Interactive Mode · a long-horizon task delivered by Work Mode · the <code>run_js</code> on-device JS sandbox　(click any image to enlarge)</sub></p>

## What actually runs on the phone

- ⚡ **A native shell, not a simulated one**: every command is a HarmonyOS native `.so` (mksh, toybox, libarchive, git, dropbear, node) forked and executed directly by the IEC runtime — **no VM, no instruction translation, no JIT permission required**. Pipes, redirections, globbing, `sed`, `awk`, `find`, `tar`, `git` and `ssh` are genuine; a command takes 0.2–1.5 s. The working directory is the **same file system** as the conversation workspace: `cat data/a.csv` and `read_file("data/a.csv")` see the same bytes, not a copy.
- 🐍 **Native CPython 3.12, not emulation**: the interpreter is compiled as a HarmonyOS `.so` and runs inside the app process (no instruction translation — 2–3 orders of magnitude faster than the earlier VM-based execution). numpy / pandas / **scipy** / matplotlib / python-docx / python-pptx / reportlab / sympy ship offline, and CJK charts work out of the box.
- 🧠 **On-device Agent Loop**: 47 built-in tools + 32 skills, multi-turn tool loop, parallel subagents, schedules / goals / session-log search, three-stage context compaction — long-horizon tasks finish on the phone and land in the sandboxed workspace.
- 📊 **On-device deliverables**: PPT / Word / Excel / SVG come from local generators on a JSON intermediate layer (losslessly readable, operator-style editable); PDFs and Office files are parsed entirely locally, **consuming no multimodal quota**.
- ✦ **Intelligent UI**: one sentence in, a draggable / clickable / instantly recomputing native interface out — charts, tables, metric cards, tab sets and form controls all rendered natively.

## Two headline agent forms, both running on-device

| Form | Modelled on | What it looks like in Guncat Work |
| --- | --- | --- |
| ✦ **Interactive Mode** | GPT's **Intelligent UI** | One sentence in, a **draggable, clickable, instantly re-computing** native interface out: charts / tables / metric cards / tab sets / form controls all rendered natively; zero tool calls by default, the whole interface delivered in a single turn |
| 🛠 **Work Mode** | **DeepSeek Harness** (dsh, a Codex-style Agent Loop) | Multi-turn tool loop + a per-conversation sandboxed workspace + 47 built-in tools; long-horizon tasks run autonomously and produce PPT / Word / Excel / SVG on-device, with artifact cards carrying line-level diffs |

The two forms **share the same Agent Loop, the same sandboxed workspace and all 47 tools**. They differ only in behavioural discipline — Work Mode is "multi-turn tool loop + long-horizon delivery", Interactive Mode is "fast lane, interface in one turn". The app starts in Interactive Mode by default; the "Interactive Mode / Work Mode" pill in the empty state switches between them.

Underneath both sits **one on-device execution environment**: a complete Linux `shell` when a real terminal is needed, native CPython when data has to be computed, local Office generators when files have to be delivered — all on the phone, with no remote execution service involved.

Interactive Mode reproduces how GPT's Intelligent UI delivers an answer: the reply is no longer plain text but an **interface program** that the app renders into a native, operable interface — bar / line / area / horizontal bar / donut / radial / radar / stacked bar charts, tables, metric cards, image walls, tab sets / accordions / step bars / card blocks, plus a full set of form controls (slider / toggle / radio / multi-select / dropdown / tag picker / tab picker / text input / text area). Control values can even be sent back to the model to trigger a recomputation. Work Mode ports the core Agent Loop of DeepSeek Harness (dsh) to the device.

The research material on the upstream specs is in the repo too: [open-intelligent-ui spec](docs/reference/open-intelligent-ui-spec.md) · [openui-lang spec](docs/reference/openui-lang-spec.md).

## What this is

Guncat Work is **a native AI workbench on your HarmonyOS phone**: it does not stop at conversation — it moves what "getting work done" needs onto the device, namely a real Linux, a native Python, a tool layer that can read and write the workspace, and a pipeline that delivers the result straight as a file.

Chat mode bundles general-purpose, paper-conversion, legal / research / sift-retrieval and LLM-evaluation agents; it supports the three mainstream protocols (Chat / Responses / Anthropic), native Markdown (including LaTeX formulas and Mermaid diagrams), direct image and document attachment upload, CoreSpeechKit read-aloud and native voice input.

Work Mode brings a sandboxed workspace and tool-calling capability with 47 built-in tools, covering file create/read/update/delete plus pattern-matched search, task lists, image viewing, web downloads, PDF parsing, Office generation and read/write editing (PPT / Word / Excel each built on a JSON intermediate layer, losslessly readable and operator-style editable), data-pipeline cleaning, transformation and format conversion, a JS execution sandbox `run_js` built on JSVM-API, and a **native in-device `shell`** — every command is a HarmonyOS native `.so` (mksh, toybox, libarchive, git, dropbear, node) forked and run by the IEC runtime, with no VM, no instruction translation and no restricted JIT permission; its working directory is the very same conversation workspace. It also ships **native CPython `run_python`** — the interpreter is compiled as a HarmonyOS `.so` and runs in-process, and `python3` inside the shell points at the same interpreter. 32 built-in skills (5 top-level Skill routes + 7 format branches) load domain knowledge on demand — PPT design rules, Doc JSON syntax, data-cleaning recipes. Office documents and PDFs are parsed entirely locally, consuming no multimodal quota.

The UI adapts between phone and desktop: wide screens (≥700vp) expand into a three-column layout (sidebar / conversation column / workspace detail column), narrow screens fall back to a single column plus a drawer. Workspace files can be previewed in place and shared in one tap; generations and edits carry line-level diffs; conversation history, configuration and read-aloud preferences all persist locally. Architecturally the project is layered MVVM, all three protocols' SSE streams converge into one protocol-adapter layer, and every document generator has a dedicated offline verification environment (Node build + Python structural validation + tsc type checking).

Current app version: `7.0.0` · full change history in the [changelog](CHANGELOG.md)

## Capabilities

- **Two headline agent forms**: **Interactive Mode** is modelled on GPT's Intelligent UI — one sentence in, an operable interface out, zero tool calls by default, delivered in one turn, with sliders, toggles and dropdowns recomputing instantly; **Work Mode** is a device-side port of DeepSeek Harness — multi-turn tool loop + sandboxed workspace + long-horizon delivery (artifact cards with line-level diffs).
- **A native shell on the phone**: every `shell` command is a HarmonyOS native `.so` (mksh, toybox, libarchive, git, dropbear, node) forked and executed directly by the IEC runtime — **no VM, no JIT permission required** — so pipes, redirections, globbing, `sed`, `awk`, `find`, `tar`, `git` and `ssh` are genuine; a command takes 0.2–1.5 s with no cold boot. The working directory is the conversation workspace itself (`cat data/a.csv` and `read_file("data/a.csv")` are the same file).
- **Native CPython, no emulation**: `run_python` runs a real CPython 3.12 compiled as a HarmonyOS `.so` inside the app process (2–3 orders of magnitude faster than the earlier VM-based execution); numpy / pandas / scipy / matplotlib / Pillow / lxml / sympy / python-docx / python-pptx / reportlab all ship offline, and CJK charts work out of the box; `python3` in the shell is a separate process on the same bundled interpreter.
- **On-device Office output**: PPT / Word / Excel / SVG are produced by local generators on a JSON intermediate layer, and documents can be read back losslessly and edited operator-style; PDFs and Office files are parsed entirely locally, consuming no multimodal quota.
- **47 built-in tools**: file create/read/update/delete plus pattern-matched search, task lists, image viewing, web downloads, PDF parsing, Office read/write, data-pipeline cleaning / transformation / format conversion, the JSVM-API `run_js` code sandbox (no network, no filesystem access, runs on a background thread with a timeout guard), plus the `shell` / `run_python` execution layer described above.
- **Three protocols**: OpenAI Completions (`/chat/completions`), OpenAI Responses (`/responses`) and Anthropic Messages (`/messages`), all supporting direct image upload; extended thinking and web search are controlled explicitly per protocol.
- **Built-in local web search**: shipped inside the app with no manual toggle; available in both Work Mode and chat mode, so search is not at the mercy of a server-side switch.
- **32 skills**: 5 top-level Skill routes + 7 format branches, loaded on demand when triggered; the PPT / Word / Excel skills use a "gate" discipline and generate a checkable self-report before delivery.
- **Native Markdown**: CommonMark and common GFM syntax, code highlighting, tables, task lists, inline and block LaTeX formulas, Mermaid diagrams, with automatic light/dark theming.
- **Attachments and sharing**: direct or pre-parsed image / document upload, 256px thumbnails, quick camera capture, export a Markdown answer to Word (including LaTeX → native OMML formulas), and receiving HarmonyOS system shares.
- **Voice**: CoreSpeechKit read-aloud (switchable system voices and speed, continues on the lock screen and in the background, draggable control bar) plus native voice input.
- **Adaptive UI**: three columns on wide screens, single column plus drawer on narrow screens; follows the system light/dark theme and keeps the status bar, navigation bar and Markdown styles in sync.

The complete feature inventory and implementation details are in [Features](docs/features.md).

## Quick start

### Requirements

- DevEco Studio 6.0.1 or a compatible version
- HarmonyOS SDK API 24 (`6.1.1`)
- A physical HarmonyOS phone (tablets and 2-in-1 devices work too — wide screens expand into the three-column layout)

### Build

Open the project in DevEco Studio, configure signing and run the `entry` module. Command-line equivalent:

```bash
hvigorw --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap
```

Build steps:

1. Clone or download the project.
2. Open the **repository root** in DevEco Studio.
3. Install and select HarmonyOS SDK API 24.
4. Configure debug or release signing.
5. Connect a physical HarmonyOS device.
6. Run the `entry` module, or build the HAP with the command above.

### Shell tool (IEC native runtime) artifacts

The `shell` tool depends on bundled HarmonyOS native `.so` files (checked into the repo and shipped inside the HAP under `libs/arm64-v8a/`). The execution core itself is `libiec_server.so` (exec/tty service, loader, shim); the command → `.so` → entry table matches `IecRuntime.ets`'s `add(...)` calls one-for-one:

| Command | Bundled `.so` | Entry |
| --- | --- | --- |
| `sh` / `mksh` | `libmksh.so` | `main` |
| `toybox` and 70+ applets (`ls/cat/grep/sed/awk/find/xargs/…`) | `libtoybox.so` | `bsh_toybox_main` |
| `tar` / `bsdtar` | `libbsdtar.so` | `iec_bsdtar_main` |
| `unzip` | `libbsdunzip.so` | `iec_bsdunzip_main` |
| `cpio` / `bsdcpio` | `libbsdcpio.so` | `iec_bsdcpio_main` |
| `zip` | `libzipcmd.so` | `iec_zip_main` |
| `git` / `git-upload-pack` / `git-receive-pack` / `git-upload-archive` | `libgit.so` | `iec_git_main` |
| `git-remote-http` / `git-remote-https` | `libgit-remote-http.so` | `iec_git_remote_http_main` |
| `ssh` / `scp` / `ssh-keygen` / `dbclient` / `dropbearkey` / `dropbearconvert` / `dropbear` | `libdropbear.so` | `iec_dropbear_main` |
| `sftp` | `libsftpcmd.so` | `iec_sftp_main` |
| `jq` | `libjqcmd.so` | `iec_jq_main` |
| `curl` | `libcurlcmd.so` | `iec_curl_main` |
| `bc` | `libbccmd.so` | `iec_bc_main` |
| `nc` | `libnc.so` | `iec_nc_main` |
| `hexdump` / `hd` | `libhexdump.so` | `iec_hexdump_main` |
| `diff` (backend is the bundled git) | `libdiff.so` | `iec_diff_main` |
| `node` / `nodejs` | `libnode.so` | `iec_node_main` |
| `npm` | `libnode.so` | `iec_npm_main` |
| `npx` | `libnode.so` | `iec_npx_main` |
| `python3` / `python` | `libpycmd.so` + `libpython3.12.so` | `iec_python_main` |

`libnode.so` is node 22.19; npm's pure-JS tree lives in `rawfile/tools/npm.tar.gz` and is unpacked into the resource root on first launch. `python3` / `python` share `libpython3.12.so` with `run_python`, but run in a dedicated python-runner process (`libpycmd.so` is only a UDS client).

### First-time configuration

The app settings let you save and switch between multiple API configurations:

1. Protocol (`openai-completions` / `openai-responses` / `anthropic-messages`)
2. Base URL
3. API Key
4. Model
5. Optional parameters such as Temperature, Top P and max output tokens
6. Extra request parameters

Common compatible endpoints:

- DeepSeek Responses: `https://api.deepseek.com`
- DeepSeek Anthropic: `https://api.deepseek.com/anthropic`, or just `https://api.deepseek.com` (the app appends `/anthropic/v1/messages` automatically)
- Volcengine Ark Responses: `https://ark.cn-beijing.volces.com/api/v3`
- Anthropic Messages: `https://api.anthropic.com/v1`

Multimodal pre-parsing can be configured separately with its own model, endpoint and API Key.

### Verification

- **One-command local check (recommended)**: `bash scripts/check-all.sh` (`--fast` skips the slow/environment-dependent items, `--list` prints the 12-item list)
- **IEC hexdump property tests**: `bash third_party/bettersh/iec/tests/hexdump_fuzz/run.sh` (200 random inputs × `-C/-b/-c/-x/-d/-o` × `-n/-s/-v`, compared byte-for-byte with the system `hexdump`; wired into `check-all.sh`, SKIPs when no system `hexdump` is available)
- Pure-logic regression (currently **730 tests**, all green): `cd test/guncat-harness && node setup.mjs && node test-core.mjs`
- Service-layer type check: `cd test/guncat-harness && node check-setup.mjs && npx tsc -p check/tsconfig.json`
- PPT / Word / Excel offline verification environments: `test/pptx-harness`, `test/docx-harness`, `test/xlsx-harness`
- Real ArkTS compilation (requires DevEco locally): `powershell -ExecutionPolicy Bypass -File tools/build-check.ps1`

The last layer is not optional: ArkUI has a set of rules that **only the compiler knows** (no local variable declarations inside a `@Builder` method body, custom component property names must not collide with built-in property names, `@Prop` nulls need an explicit union type), and the Node-side harness only covers the pure TS in `common/**` and `service/**` — it never parses `.ets`.

The first two layers and the three Office generator harnesses **run in CI** on every push and pull request (see the CI badge at the top); the third layer requires DevEco Studio locally, so please run it yourself before submitting.

## Documentation

| Document | Contents |
| --- | --- |
| [Features](docs/features.md) | The complete client feature set and engineering conventions |
| [Work Mode architecture & maintenance guide](docs/architecture/work-mode.md) | Agent Loop, the 47 tools, the PPT / Word generation pipelines, the skill system, the `run_js` sandbox, ArkTS constraints |
| [Shell tool: IEC native runtime](docs/architecture/iec-runtime.md) | Forking command `.so`s, the exec session API, workspace consistency, concurrency and lifecycle, build chain |
| [Interactive Mode architecture (Intelligent UI)](docs/architecture/interactive-mode.md) | The prompt fork, the `guncat-ui lang` contract, streaming into shape, the interaction loop, extension points |
| [Project structure](docs/architecture/project-structure.md) | Directory layout, data flow, core components |
| [Usage guide](docs/guides/usage.md) | Step-by-step instructions per scenario |
| [FAQ](docs/guides/faq.md) | Troubleshooting and known behaviour |
| [Built-in agents](docs/reference/builtin-agents.md) | Agent inventory and differences |
| [Persistence and theming](docs/reference/persistence-and-theme.md) | Local storage and theme implementation |
| [Changelog](CHANGELOG.md) | Every version change from 4.2.0 to 7.0.0 |
| [openui-lang spec](docs/reference/openui-lang-spec.md) | The upstream implementation-level spec `guncat-ui lang` is aligned with |
| [open-intelligent-ui spec](docs/reference/open-intelligent-ui-spec.md) | The upstream Generated-Answer UI spec Interactive Mode is aligned with |

> The deep-dive documents above and the changelog are currently written in Chinese only.

## Permissions & system capabilities

- `ohos.permission.INTERNET`: access to model APIs.
- `ohos.permission.MICROPHONE`: voice input.
- `ohos.permission.KEEP_BACKGROUND_RUNNING`: long-running background audio task for read-aloud.
- Work Mode: all file reads and writes happen inside the app sandbox (`filesDir/workspaces/`), while file picking and saving go through system secure components (DocumentViewPicker) — **no new permissions were added**.
- Shell tool (IEC native runtime): every command is a bundled HarmonyOS native `.so`, forked and executed by the exec service — **no JIT / executable-memory restricted permission** is required; there is no VM and no listening port, networking uses the app's existing `INTERNET` permission, and commands can only see the current conversation workspace.
- Share Kit: receiving images and files shared from other apps.
- CoreSpeechKit: text-to-speech and speech recognition.
- AVSession Kit: background media session.
- ArkData Preferences: local configuration persistence; conversation history is stored in the sandbox file `filesDir/guncat_conversations.json`.

## Privacy

- API Keys and app configuration are stored in the app's local sandbox.
- Chat requests and attachments are only ever sent to the model service you configured.
- Content received through system share is never sent automatically — you have to tap send.
- Original attachments are not copied into app data as permanent files.
- Network requests use HTTPS; the actual data-handling policy is that of your configured model provider.

## FAQ

If something goes wrong, start with the [FAQ](docs/guides/faq.md): invalid API Key, file parsing failures, interrupted streaming, missing entries in the gallery share sheet, and the Interactive Mode interface not appearing / appearing only partially / numbers not changing when you adjust a parameter.

## Contributing

Issues and pull requests are welcome. For the dev environment, coding conventions (ArkTS hard constraints), how to run the three verification layers and the PR flow, see **[CONTRIBUTING.md](CONTRIBUTING.md)** (Chinese).

1. Fork the repository.
2. Create a feature branch.
3. Make your changes following ArkTS coding conventions.
4. Make sure the project passes type checking and the HAP build.
5. Open a pull request describing what changed and how you verified it.

## Notes

This version does not include the local TTS model approaches that were evaluated or trialled and ultimately withdrawn; this README only describes what is actually retained in the current code.

This project is open-sourced under the [Apache License 2.0](LICENSE).

**Third-party components**: the `shell` tool ships the IEC runtime (MIT, from [BetterSH](https://github.com/panedioic/iec)'s `iec`), mksh (MirOS), toybox (0BSD), libarchive (BSD-2-Clause), git (GPL-2.0), dropbear (MIT) and Node.js (MIT) as separate `.so` files. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [`LICENSES/`](LICENSES/).
