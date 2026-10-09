# Guncat Work

> [中文](README.md) | English

Guncat Work is a pocket-sized Codex / DeepSeek Harness for HarmonyOS — a native HarmonyOS AI client written from scratch in ArkTS and ArkUI, built around a modular Agent Loop. Three-protocol streaming chat, 45 local tools, 32 deeply customised skills and a sandboxed file workspace: it produces polished PPT, Word, Excel and SVG output directly on the device, can execute JS code on demand, and matches desktop-class agents feature for feature.

Guncat Work ships a full, feature-rich client. Chat Mode includes general-purpose, paper-rewriting, legal / research / source-sifting retrieval and LLM-evaluation agents, and supports all three mainstream API protocols (OpenAI Completions, OpenAI Responses, Anthropic Messages), native Markdown rendering (LaTeX formulas and Mermaid diagrams included), direct image and document upload, CoreSpeechKit read-aloud, on-device voice input and other consumer-facing capabilities. Work Mode adds a sandboxed workspace and tool calling: its 45 built-in tools cover file operations and pattern-based search, task lists, image inspection, downloads, PDF extraction, Office generation with round-trip reading and editing (PPT, Word and Excel each resting on a JSON intermediate layer with lossless read-back and operator-based editing), and a data pipeline for cleaning, transforming and converting between formats — plus run_js, a JSVM-API sandbox for executing code. 32 built-in skills (five routing master skills and seven top-level format branches) load domain knowledge such as PPT design rules, Doc JSON syntax and data-cleaning recipes to the model on demand. Office documents and PDFs are parsed entirely locally, consuming no multimodal quota.

The interface adapts between phone and desktop: on wide screens (≥700vp) it opens a three-column layout of sidebar, conversation column and workspace detail column, falling back to a single column with drawers on narrow screens. Workspace files can be previewed in place and shared in one tap, every generated change carries a line-level diff, and conversations, configuration and read-aloud preferences all persist locally.

Under the hood the project follows MVVM layering, routes all three SSE protocols through a shared protocol adapter, and ships each document generator with a dedicated offline validation harness (Node build, Python structural checks, tsc type checking). At runtime it reads and writes only through the app sandbox (filesDir/workspaces/) and system file pickers, adds no storage permissions, and sends chat requests and attachments only to the model service the user configures.

Current app version: `6.2.0`

## Features

### Native streaming chat

- Processes SSE streams with `@kit.NetworkKit` and `http.requestInStream`.
- Supports three mainstream integration modes: OpenAI Completions (`/chat/completions`), OpenAI Responses (`/responses`, including DeepSeek and Volcengine Ark compatible services), and Anthropic Messages (`/messages`).
- All three integration modes support direct image input; OpenAI Responses additionally uses a hybrid Files API strategy for large images/documents.
- DeepSeek now uses the latest Responses API with native web search and vision-model image input.
- Supports stopping generation, regenerating responses, conversation history, and multiple API profiles.
- Uses throttled UI updates and automatic scrolling during streaming.

### Deep thinking and web search

- The deep-thinking toggle explicitly controls the request per protocol (aligned with the official DeepSeek parameters):
  - OpenAI Completions: `thinking.type = enabled / disabled`, plus `reasoning_effort = high` when enabled
  - Anthropic Messages: `thinking.type = enabled / disabled`, plus `output_config.effort = high` when enabled
  - OpenAI Responses: `reasoning.effort = high / none` (`none` disables thinking)
- The visible toggle takes precedence over extra request-body fields, preventing UI/request mismatches.
- When web search is enabled, the previous assistant's `reasoning_content` is sent back in multi-turn turns (OpenAI Completions) to avoid 400 errors.
- OpenAI Completions / Anthropic Messages also send their corresponding web-search tool; whether it works depends on provider support.
- Deep-thinking and web-search preferences persist across app restarts; new conversations (including the one auto-created on every launch) reset the deep-thinking default by agent name — off in Efficiency Mode, off in Light & Simple Mode, on in Expert Mode.

### Maintenance: per-agent deep-thinking default

New conversations, app launches, and opening empty conversations reset the deep-thinking toggle by agent **name**. Configuration lives in `entry/src/main/ets/viewmodel/ChatViewModel.ets`:

- The `defaultThinkingForAgent()` method: returns a boolean by `agent.name` (`false` = off by default, `true` = on by default); returning `null` leaves the toggle untouched (keeps the previous state)
- Current defaults: Efficiency Mode `false`, Light & Simple Mode `false`, Expert Mode `true`
- To adjust: add or modify an `if (agent.name === '...') return ...;` branch in that method. Matching is by name (not `id`), so future renames are safe.

### Native Markdown

Rendered with the native `@luvi/lv-markdown-in` component, with support for:

- CommonMark and commonly used GFM syntax
- Code blocks and syntax highlighting
- Tables, task lists, blockquotes, and links
- Inline and block LaTeX
- Mermaid flowcharts, sequence diagrams, and other diagrams
- Automatic light/dark theme adaptation

### Image and file attachments

- Adds attachments through the system photo picker or document picker.
- Supports image previews, text extraction, Office documents, and PDFs.
- Attachments can be pre-parsed or sent directly as multimodal OpenAI Responses / Anthropic Messages input.
- OpenAI Responses attachments use a hybrid strategy: small images are inlined as Base64, while large images and Volcengine Ark documents prefer Files API `file_id` uploads.
- Parsing includes status feedback, retries, and concurrency throttling.
- Image attachments render as auto-generated 256px thumbnails; tap to view the full image, keeping memory usage low.

### Quick camera capture

- A camera button sits right of the microphone, launching the system CameraPicker (no camera permission required).
- The captured photo joins the pending attachments and goes through the same parsing pipeline.

### Export to Word

- Export any AI reply to a `.docx` file and choose the destination through the system save panel.
- Faithfully restores the Markdown structure: headings, bold/italic/strikethrough, tables (borders and shaded headers), code blocks, quotes, ordered/unordered lists, links, and embedded images.
- LaTeX formulas become native Word formulas (OMML) that remain editable in Word.
- Images from data URLs or network URLs are auto-scaled to the page width.

### Partial text selection

- A "Select part" action enables cross-paragraph text selection with a long press.
- The selection toolbar provides copy / select-all / cancel, writing the selection to the clipboard.

### Receiving system shares

The app is registered as a HarmonyOS system share target:

- Receives images, text, and general files, up to five items at a time.
- Guncat Work can be selected from the Gallery or file manager share sheet.
- Shared items are added to the current chat's pending attachment area and are never sent automatically; if Work Mode is active, shared files are also copied into that conversation's sandbox workspace (`<filesDir>/workspaces/<convId>`) and picked up by the next task. The preview-area attachments are kept, so they can still be sent as attachments after switching back to Chat Mode.
- Uses Share Kit UTD matching and `systemShare.getSharedData()` for reception.

### CoreSpeechKit read-aloud

The final read-aloud implementation uses HarmonyOS CoreSpeechKit `textToSpeech`. Experimental local VITS, MeloTTS, and sherpa-onnx implementations are not included.

- Queries the voices actually supported by the device and exposes them in the reader controls.
- Prefers a female voice by default and uses a default speed of `1.5×`.
- Persists the selected voice and speed with Preferences.
- Provides pause/resume, close, speed selection, and draggable progress.
- The floating reader control can be repositioned within the page.
- Uses AVSession, an audio playback continuous task, and background TTS parameters for background and screen-off playback.
- After completion, the reader remains available for seeking and replay.

> Voice availability and download requirements depend on the device and system version.

### Voice input

- Uses the native HarmonyOS speech recognition capability.
- Supports starting, stopping, and cancelling voice input.
- Recognition results are placed in the message editor for confirmation before sending.

### Agents and persistence

- Includes general-purpose, paper-writing, legal-search, academic-research, and evaluation agents.
- Conversations, selected agent, API profiles, feature toggles, and reader preferences are stored locally.
- Supports creating, switching, and deleting conversations.
- Follows the system light/dark theme, including system bars and Markdown styles.

### Interactive mode (Intelligent UI)

Interactive mode is the **second delivery form of the Agent Loop** (the ✦ "Interactive Mode" entry right below 🛠 "Work Mode" in the sidebar's "Agent Mode" group): it **shares the exact same Agent Loop, sandbox workspace, and 45 tools** with work mode, and the only difference is that **the answer is no longer plain text but an interface program** — the app renders it into a native, operable interface: headers/body text, charts (bar / line / area / horizontal bar / pie-donut / radial / radar / stacked bar), tables, metric cards, image galleries, tabs / accordions / steps / card blocks, and the full set of form controls (slider / switch / radio / checkbox / dropdown / chips / tabs / text input / textarea). It mirrors GPT-6's Intelligent UI: say one sentence and get a dashboard you can drag, tap, re-tune, and have recompute instantly.

- **Delivery form**: the model emits **guncat-ui lang** (modelled on the OpenUI Lang design of [open-intelligent-ui](https://github.com/thesysdev/openui)) — a line-based declarative interface language whose entry point is `root = Card([...])`, with positional arguments and forward references. **One answer is that program itself**: the prompt explicitly forbids any text outside the program (no opening, no transition, no summary), and anything worth saying goes into the interface as components such as `CardHeader` / `TextContent` / `Callout`; only a pure question ("what does this mean?") or a genuinely impossible interface falls back to a text answer. Wrapping the program in a ` ```guncat-ui ` fence is accepted just the same.
- **Structure first, shaped while generating**: the program streams line by line and the client **renders as it receives** — the first line `root = Card([...])` makes the shell appear, and later statements fill it in one by one. Because every statement is independent, **a truncation loses only the last unfinished statement** while everything completed is kept (the fundamental improvement over "one big JSON document", where a cut-off voids the whole block).
- **Two-way bound interaction**: a `$variable` in the program is a reactive binding. Bind a control to it (`Slider("amount", "discrete", 0, 200, 5, [30], "金额", $amount)`) and, when the user drags, types, or toggles it, **the interface recomputes immediately with the new value** (expressions such as `"金额 " + $amount + " 万"` re-evaluate) — no request, no waiting for the model.
- **Report-back loop**: when the model needs to change the data or the algorithm, use `Action([@ToAssistant("按 30 天口径重算")])`; **a button with no action** is equivalent to sending its label to the assistant. Submitting a form packs every field value plus the submit button's request into one user message (shaped like「【交互界面回传】季度销售复盘 / - 口径 = customers / 换口径重算」), and the model uses it to **produce the complete updated interface**. Older interfaces are greyed out (only the newest turn is operable).
- **State persists with the message**: the parameters the user tuned are kept in that message as a `]]>guncat-ui:state` trailer, surviving scrolling, conversation switches, and restarts; before the next request that trailer is translated into one plain sentence (`"(用户在当前交互界面上的设置: 金额=45; 口径=customers。)"`) for the model, so it always knows the interface's current state.
- **Fault tolerance first**: unclosed brackets/strings are auto-closed, so even a mid-stream state parses; an undefined reference is simply empty for now (it appears once the definition streams in); **unknown component names are dropped with a diagnostic**, but a missing required argument or a type mismatch **does not drop the component** (it renders with safe defaults) — in a chat scenario "one field missing" is far better than "the whole block disappears".
- **Output shape: the program only, no prose**: the prompt's first hard requirement is "no text outside the program". Early versions allowed 1–2 sentences of lead-in, and the practical result was an extra repetitive, loose chat bubble next to the interface ("I'm… the card below explains…"). Openings / transitions / summaries are now banned and text must be carried by components (`CardHeader` as the title, `TextContent` as the body, `Callout` as a hint, `Buttons`/`OptionCards` as next-step entries); the prompt includes ❌/✅ contrast examples. *(The client does not delete text the model already wrote — that would be losing content; this one is enforced by the prompt.)*
- **Width aligned with the answer body**: interface text keeps a 16vp inset on both sides, lining up with the answer body of the same message (RichTextView's 16vp inset) at the same line width. **Tables and charts share the text width** (deliberately not full-bleed: a table's header fill makes the whole block look shifted left, and charts carry their own tick/legend text so they belong to the "align with the body" group — while a top-level chart going full-bleed and a chart nested in a SectionBlock not doing so made chart left edges wander within one screen). Only purely visual components — image / image gallery / carousel — use a negative margin (`bleed()`) at the top level to take the full width; the same components nested inside a card are left alone (otherwise they overflow the container). Line/area charts also **draw no y-axis tick text** (the extremes appear on their own line below), so the plot's left padding is only 12vp (it used to be 34vp for axis labels, which on device was a big blank area with the plot pushed right).
- **Thinking-effort tiers per mode**: both work mode and interactive mode **force deep thinking on** (the toggle is not shown in the Agent Loop's tool row), and the tier is chosen under "capability presets" in the model popup; but the two sets differ, persist separately, and do not affect each other:
  - **Work mode**: 极高(Max) / 均衡(High) / 快速(Low) — long-horizon tool tasks, so `max` stays;
  - **Interactive mode**: 均衡(High) / 快速(Low) / **关闭(Off)** — the deliverable is an interface and speed matters, so `max` is gone and Off is added.
  "Off" does not change the global `thinkingEnabled` (that would switch deep thinking off for work and chat mode too); it takes effect **when the request is sent**, through three mode-aware getters in `ChatViewModel`: `loopEffort` (which tier the popup highlights), `loopEffortForRequest` (the tier falls back to `low` when Off is selected, so a server-side `reasoning_effort` validation failure is avoided), and `loopThinkingEnabled` (`false` when Off is selected). The service layer needed no change: with `thinkingEnabled=false` the three protocols send `thinking:{type:'disabled'}` (OpenAI-compatible) / `reasoning:{effort:'none'}` (Responses) / `thinking:{type:'disabled'}` without `output_config` (Anthropic). **Subagents** and **context compaction** in interactive mode follow the same tier. (Storage keys: `guncat_reasoning_effort` / `guncat_interactive_effort`.)
- **Relationship to work mode**: the two share the `executeWorkLoop` main loop and the entire tool surface; the system prompt is selected by conversation mode (`AgentLoopService.buildWorkSystemPromptFor(mode)`), and compaction rebuilds history with the mode-specific prompt as well. Full maintenance notes are in "[Interactive mode architecture (Intelligent UI)](#interactive-mode-architecture-intelligent-ui)" below.
- **Activity collapsible bar (thinking + tool calls): interactive-mode-only, merged per turn**. Interactive mode's deliverable is an interface, and process information should not compete with it for space. The Agent Loop produces one assistant message per round (a **fixed** structure: the next request's history is rebuilt from `conv.messages`, so an assistant message must keep its `toolCalls` together — merging the data would show the model "one assistant message that called every tool at once", in the wrong order), so the merge happens **in the rendering layer only**: the consecutive assistant messages after one user task are treated as one **turn**, only the **last** message of the turn renders the bar, and earlier rounds render only their body (skipped entirely when they have none — their thinking and tools are already inside the bar).
  - **Before the answer** the bar stays expanded, showing the thinking marquee and tool rows live; **as soon as the answer starts streaming it collapses** into one「✓ 已完成 · 思考 ×4 · 5 个工具 · 12.4s」line, and one tap expands it again;
  - expanding shows the **whole turn's** activity: each round's thinking is its own **collapsed-by-default**「💡 思考 ⌄」row (only one open at a time; the running round shows its latest sentence as a marquee in the title row, which does not count as expanding), followed by that round's tool rows — earlier rounds as a read-only summary (tool name/duration), the current round in full form (expandable IO/diff cards). Earlier rounds do not expand their tool IO because **ArkUI forbids recursive components** (`WorkTurnView` cannot nest another `WorkTurnView` to reuse the full tool rows) and duplicating a full implementation for that is not worth it;
  - the open/closed state is **purely derived** (`activityOpenNow()`, from `isStreaming` + `message.content`) and never mutates `@State` inside `build()`; a change to `message.content` re-renders the `@ObjectLink` anyway, so the bar collapses naturally as soon as the answer appears. Once the user taps it, `activityTouched` is set and from then on it is entirely up to them;
  - the title and spinner come from `activityRunning()` (streaming and either "the answer has not appeared" or "a tool is still running"), guaranteeing that **"已完成" never appears before the work is actually done**; a manually stopped turn shows「已停止」(detected through `Constants.WORK_STOPPED_NOTE`, produced in `finalizeWorkTurn` and consumed by the bar through the same constant). It deliberately does **not** re-expand when another tool starts running, to avoid flickering open and closed across rounds;
  - work mode is **unaffected** (`section='full'`: thinking row above, tool rows after the answer, each toggling independently). `WorkTurnView`'s `section` is `'full' | 'grouped' | 'content'`, decided by `ChatPage.turnSection()` / `shouldRenderTurn()` / `priorRunMessages()`.

### Work mode (Agent Loop)

Work mode is an **independent identity parallel to the chat agents** — the 🛠 "Work Mode" entry in its own "Agent Mode" group above the "Chat Mode" section header in the drawer. It opens an Agent loop with a per-conversation local sandbox workspace and tool-calling capability, allowing the agent to autonomously complete multi-step, long-horizon tasks. See "[Work mode architecture & maintenance guide](#work-mode-architecture--maintenance-guide)" below.

- **Sandbox workspace**: each work conversation maps to `filesDir/workspaces/<convId>/`, with upload, `.zip` export, and clear actions. Everything stays inside the app sandbox plus system safe components (document picker) — **no new permissions**.
- **45 local tools**: file CRUD (list/read/write/append/delete/create_dir/move/search, with `glob` filename filtering on search_files), task checklist (`todo_write`), image viewing (`view_image`, routed to the main model's multimodal vision), web download (`download_file`, pulls linked files into the workspace), PDF parsing (`parse_document` + automatic `read_file` routing), Office generation (`write_docx` / `write_xlsx` / `write_csv`), data pipeline (`transform_file`, local cleaning/transformation/conversion of large files without entering model context), PPT read/write/edit (`write_pptx` / `read_ppt` / `edit_ppt`, on a Deck JSON intermediate layer), Word read/write/edit (`write_docx` / `read_docx` / `edit_docx`, on a Doc JSON intermediate layer), Excel read/write/edit (`write_xlsx` / `read_xlsx` / `edit_xlsx`, on a Workbook JSON intermediate layer), SVG image generation (`write_svg`, vector output + PNG preview), and the skill system (`list_skills` / `load_skill`, on-demand domain guides). New in 6.1 (DeepSeek Harness port): `glob` / `grep` (pattern-based file lookup and regex content search), `edit` / `str_replace_editor` (exact character-level editing with a diff card), `web_fetch` (fetch page/API source as readable text), `ask_user_question` (ask the user and wait for an answer), `schedule_create/list/delete` (session-local reminders), `goal_create/get/update` (session goal), `subagent` (child-agent delegation), `session_search` (session event-log search). **`run_js` (JSVM-API sandbox)**: the only "execute code" capability in an environment with no shell — see "run_js: on-device JS execution sandbox" below.
- **Skill system**: domain operation guides are packaged under `rawfile/skills/` (main skills live at the top level, branch skills inside their main-skill subdirectory; SKILL.md + reference/*.md). The system-prompt skill section uses the full_index mode and opens with mandatory "skill usage golden rules" (on a hit the first step must be `load_skill`; when unsure, check `list_skills` first; the skill body outranks your default behavior); the model loads skills on demand via `list_skills`/`load_skill`. The bundled `ppt` skill covers the Deck JSON syntax, design guidelines, content discipline, themes, common deck blueprints, and self-check lists; the `docx` skill covers the Doc JSON syntax, Chinese typography rules, document form-factor selection, common document blueprints, and professional-document norms; the `xlsx` skill covers the Workbook JSON syntax, formula-first / number-format conventions, the data-analysis delivery workflow, common report blueprints, and an analysis playbook; the `svg` skill covers SVG authoring rules, the "generate → preview → iterate" workflow, visualization-type selection, infographic blueprints, and recipes for icons/flowcharts/bar charts/timelines; the `data` skill covers the transform_file pipeline ops and expression syntax, data-quality checks, and cleaning/extraction/conversion recipes. **There are now 32 skills total**: in addition to the 10 core skills above (which also include `paper`, `law`, `research`, `sift`, and `llm-eval`), 22 domain skills were ported and adapted from four mainstream AI work platforms — `humanizer` (de-AI/humanize/readability), `prompt-engineering` (prompt engineering), `pdf` (PDF reading/search/scanned-page reading), `translation` (legal/medical translation & terminology consistency), `questionnaire` (survey/in-depth interview/verbatim tagging/quantitative analysis), `content-rewrite` (multi-platform content rewriting & distribution), `html` (single-page HTML development), `paper-reviewer` (academic paper review), `review-agent` (code review), `paper-rebuttal` (reviewer-rebuttal responses), `research-lineage-map` (research lineage/evolution maps), `marketing-plan` (marketing plan proposals), `reference-audit` (reference/citation auditing), and `paper-close-reading` (deep academic-paper reading), `khazix-writer` (WeChat long-form writing), `newmedia-writing` (Xiaohongshu/WeChat/short-video new-media writing), `marketing-material-review` (marketing-material compliance review), `patent-drafting` (patent application drafting), `sentiment-tracker` (public-opinion tracking & tracing), `journal-format` (academic DOCX formatting & repair), `research-proposal` (research proposal/grant application drafting), `industry-analysis` (industry deep research). **Structure reorganization (6.2.0)**: the 25 content/academic/legal/AI branch skills have been physically moved into 5 main-skill subdirectories (`research-intelligence` 7 / `academic-publishing` 7 / `content-writing` 5 / `legal-ip` 4 / `ai-tooling` 2), while the 7 format branches (`docx`/`xlsx`/`ppt`/`svg`/`html`/`pdf`/`data`) stay top-level and direct. `list_skills` now exposes only 12 visible skills; branches are loaded by their original id after routing (physical paths are mapped through `WorkSkillService.skillPath()`).
- **Local parsing engine**: `.docx/.xlsx/.pptx/.pdf` text is extracted entirely on-device — no multimodal parsing API and no quota consumption.
- **Task checklist discipline**: complex tasks start with a `todo_write` checklist; checklist and workspace state reach the model through a "runtime context" snapshot appended to the tail of the conversation. Progress is updated item by item.
- **Codex-style timeline**: each turn is its own message, laid out chronologically as "thinking → tool steps → answer" inside a single-container timeline; tool steps expand to show arguments and results.
- **Codex-style artifacts card**: after a task finishes, generated/modified files are summarized in an "Artifacts" card at the end of the conversation, expanded by default; each file's line-diff thumbnail is collapsed by default and can be expanded individually. The view auto-scrolls to the bottom when the task finishes, so the card is immediately visible.
- **In-place preview & one-click share**: files in the artifacts card, the workspace popover, and the right-hand details panel can be tapped to preview in place via HarmonyOS Preview Kit, or shared directly through the system share panel — no paths, zip archives, or format pickers involved. Formats the system cannot preview (e.g. `.md`) automatically open the system "Open with" chooser, letting you pick an installed app that supports the file.
- **Three-protocol tool calling**: OpenAI Completions / OpenAI Responses / Anthropic Messages all support streaming function calling; the web-search toggle remains in the tool row (the server-side search tool coexists with client tools).

### UI and motion (5.1.0)

- Reworked the deep-thinking (reasoning) bar UI: it now renders as a standalone card above the bubble with uniform corner radii and a neutral light-gray background that blends with the chat area; the loading spinner sits directly to the right of the "Deep Thinking" label, and the separate "Thinking…" text was removed.
- Updated the app icon assets while keeping the original filenames, so existing resource references remain valid (just replace the image files to apply).
- A refreshed, soft modern UI: low-saturation palette, large rounded corners, white soft-elevated buttons, gentle shadows, and no heavy outlines or glow effects.
- Launch fly-in animation: icons fly out from the center in sequence, staying sharp throughout with no blur fade or cross-fade flicker.
- One-shot central icon transition: the launch icon uses a single hero node to smoothly move and scale into the empty-state icon at the page center, avoiding "white flash then clear" artifacts.
- The bottom input area slides in from below the screen edge with no bounce or unnatural top-down drop.
- Side drawers, settings sheets, and about overlays naturally cover the underlying hero icon instead of leaving it floating above overlays.

## Built-in agents

Agents are managed through `resources/rawfile/agents.json` and separate Markdown prompt files. The sidebar supports per-agent custom icons (`icon` field pointing to a PNG named by agent id under `icons/`, falling back to the cat avatar when unset) and dual descriptions: the sidebar shows `shortDescription`, while the new-conversation page shows the full `description`:

| Agent                 | Category   | Purpose                                                                                                                                               |
| --------------------- | ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| 轻简模式 (Light & Simple) | General    | Guncat 3.1-Flash base: Guncat's first Flash-dedicated independent foundation, the lightest agent built for everyday chat and simple knowledge queries |
| 效率模式 (Efficiency)     | General    | Guncat 3.0-Flash base: gap-driven execution for instant responses, answer thoroughness on par with Pro                                                |
| 专家模式 (Expert)         | General    | Guncat 3.0-Pro base: the most powerful monolithic super-agent with full expert capabilities and industry-leading anti-hallucination                   |
| 经典模式 (Classic)        | General    | Based on Guncat 2.5-Lite: mature lightweight general agent, structured CoT for high-quality long outputs                                              |
| 转换专家-论文               | Rewriting  | Based on Guncat Cnvt-Paper: converts non-academic text into academically compliant papers                                                             |
| 检索专家-法律               | Search     | Based on Guncat Srch-Law: SOE legal analysis with mandatory multi-round research and structured opinions                                              |
| 检索专家-研究               | Search     | Based on Guncat Srch-Research: cross-domain retrieval with multi-source cross-validation                                                              |
| 检索专家-筛滤               | Search     | Based on Guncat Srch-Sift: official-source tracing and AI content filtering                                                                           |
| 评估专家-LLM              | Evaluation | Based on Guncat Eval-LLM: LLM evaluation with minimized hallucination                                                                                 |
| Work Mode (virtual)   | Agent Mode | Guncat Harness: local sandbox workspace + 45 tools + multi-turn Agent Loop, autonomously completing long-horizon tasks and producing files             |
| Interactive Mode (virtual) | Agent Mode | Intelligent UI: the same Agent Loop, but answers are delivered as operable native interfaces (charts / tables / cards / forms); tuning recomputes instantly and a button makes the assistant recompute |

## Persistence and themes

The app uses two kinds of local persistence:

- **Conversation history**: serialized as JSON and stored in the sandbox file `filesDir/guncat_conversations.json`. It is no longer subject to the Preferences 16 MB single-value limit. On first launch after upgrading, old conversations are migrated from Preferences automatically.
- **Settings**: `@kit.ArkData` Preferences stores the current conversation, selected agent, multiple API profiles, deep thinking, web search, reader voice, and reader speed.
- Local state is restored when the app restarts.

The theme system uses HarmonyOS resource qualifiers:

- `base/element/color.json` provides light resources.
- `dark/element/color.json` provides dark resources.
- `EntryAbility.onConfigurationUpdate()` observes system theme changes.
- System bars, Markdown, syntax highlighting, and formula colors update together.

## Project structure

```text
entry/src/main/ets/
├── entryability/
│   └── EntryAbility.ets
├── pages/
│   ├── ChatPage.ets                # Main page: chat + Agent Mode timeline (work/interactive) + workspace panel wiring
│   └── TableOcrPage.ets
├── views/
│   ├── ChatBubbleView.ets          # Chat bubble (reasoning bar / tool-step timeline / WorkStepFormat)
│   ├── WorkTurnView.ets            # One turn of the Agent Mode timeline (thinking→tools→answer, no avatar)
│   ├── GuncatUiView.ets            # Interactive-mode renderer: turns a guncat-ui lang program into native operable components
│   ├── GuncatUiCharts.ets          # Interactive-mode charts (bar/line/area/horizontal bar/pie-donut/radial/radar/stacked bar)
│   ├── GuncatUiIcons.ets           # Interactive-mode icons (Unicode glyphs, so a missing SymbolGlyph name cannot fail silently)
│   ├── WorkspaceBar.ets            # Agent Mode workspace panel (list/upload/export/clear)
│   ├── RichTextView.ets
│   ├── MessageInputView.ets
│   ├── AgentDrawerView.ets
│   ├── SettingsPanel.ets
│   ├── AboutPanel.ets
│   ├── FlyInLaunchView.ets
│   ├── ToastView.ets
│   ├── FilePreviewBar.ets
│   └── ImageLightbox.ets
├── viewmodel/
│   └── ChatViewModel.ets           # Chat state + Agent Loop driver (shared by work/interactive mode; note: .ets)
├── service/
│   ├── ChatService.ts              # Three-protocol SSE (parsers exported for AgentLoopService)
│   ├── AgentLoopService.ts         # Agent Loop: per-turn tool-calling request + per-mode system prompt (static, cache red line)
│   ├── WorkToolRunner.ets          # Unified tool dispatch (capabilities requiring .ets modules)
│   ├── WorkFileService.ts          # Sandbox workspace + file/skill tools + tool schemas (toolDefs)
│   ├── WorkSkillService.ts         # Skill registry (registry) + rawfile skill-doc loading (list/load)
│   ├── OfficeReader.ts             # Local docx/xlsx/pptx text extraction (zlib unpack + XML scan)
│   ├── PdfTextExtractor.ts         # Local PDF text extraction (byte-level objects/pages/ToUnicode)
│   ├── Flate.ts                    # Pure-TS DEFLATE/zlib inflate (SDK zlib is file-level only)
│   ├── MultimodalService.ts
│   ├── FileService.ts
│   ├── FileUploadService.ts
│   ├── AgentLoader.ts
│   ├── TableOcrService.ts
│   ├── TextReaderService.ets
│   ├── BackgroundReaderService.ets
│   └── VoiceInputService.ets
├── export/
│   ├── DocxExporter.ets            # Markdown→docx (includes buildDocxBytes for work mode)
│   ├── DocModel.ets                # Word intermediate layer: Doc JSON parse/validate/MdToDoc/DocOps (pure logic)
│   ├── DocxBuilder.ets             # Doc→.docx renderer (heading sizes, images, embedded docProps/doc.json source)
│   ├── DocxImporter.ets            # .docx→Doc (lossless from embedded source / XML import + word/media extraction)
│   ├── XlsxExporter.ets            # Table→xlsx (includes buildXlsxFromRows for transform_file)
│   ├── XlsxModel.ets               # Excel intermediate layer: Workbook JSON parse/validate/MdToXlsx/XlsxOps (pure logic)
│   ├── XlsxBuilder.ets             # Workbook→.xlsx renderer (multi-sheet/header style/formulas/numFmt/colWidth/freeze/embedded source)
│   ├── XlsxImporter.ets            # .xlsx→Workbook (lossless from embedded source / XML import)
│   ├── CsvWriter.ts                # Rows→CSV (RFC 4180 escaping + optional BOM, pure logic)
│   ├── DeckModel.ets               # PPT intermediate layer: Deck JSON parse/validate/edit ops (pure logic, no Kit API)
│   ├── PptxThemes.ets              # 8 theme presets + semantic-color resolution (pure logic)
│   ├── PptxCharts.ets              # Chart part XML (bar/line/area/pie/doughnut, pure logic)
│   ├── PptxImage.ets               # Image resolution (workspace/data URL/http + dimension probing)
│   ├── PptxBuilder.ets             # Deck→pptx renderer (13 layouts / embedded deck source / notes)
│   ├── PptxImporter.ets            # pptx→Deck (lossless restore from embedded source / XML import)
│   ├── OoxmlBuilder.ets / MarkdownParser.ets / OmmlConverter.ets / TableHtmlParser.ets / XmlUtil.ets
│   └── ZipWriter.ts                # STORE-method zip writer (.ts: reusable from TS modules)
├── data/
│   └── StorageManager.ts
├── model/
│   ├── Message.ts / Conversation.ts / Attachment.ts / ToolCallRecord.ts
│   └── Agent.ts / ApiConfig.ts / ApiProfile.ts / MultimodalConfig.ts
└── common/
    ├── Constants.ts / Types.ts / Utils.ts / MarkdownSanitizer.ts
    ├── GuncatUiLang.ts              # Interactive-mode language core: guncat-ui lang lexer/parser/evaluator/fence splitting
    ├── GuncatUiLibrary.ts           # Interactive-mode component library, single source of truth (signature/description/positional-args table → prompt)
    ├── GuncatUiPrompt.ts            # Interactive-mode system prompt (syntax / component-selection priority and richness / interaction / streaming order / examples / anti-patterns / mode duty)
    ├── GuncatUiRuntime.ts           # Interactive-mode runtime: $binding state / Action execution / state trailer and report-back copy
    ├── GuncatUiPaint.ts             # Interactive-mode chart geometry and number formatting (pure logic, unit-testable)
    └── GuncatUiParts.ts             # Message-body splitting: Markdown text segments + guncat-ui interface-program segments

entry/src/main/resources/rawfile/
├── agents.json + *_prompt*.md      # Chat agent definitions and prompt files
└── skills/                         # Work-mode skills (5 main skills + 7 format branches at top level, 25 branches inside main-skill subdirs; see "3.3 Skill system")
    ├── ppt/
    │   ├── SKILL.md                # PPT skill body (workflows / quick reference / self-check list)
    │   └── reference/              # deck-dsl.md / design-guide.md / themes.md / troubleshooting.md / deck-blueprints.md / visual-components.md / style-guidelines.md
    ├── docx/
    │   ├── SKILL.md                # Word skill body (create/edit workflows / block quick reference / typography rules)
    │   └── reference/              # doc-dsl.md / design-guide.md / troubleshooting.md / document-blueprints.md / professional-docs.md / chatgpt-design-presets.md
    ├── xlsx/
    │   ├── SKILL.md                # Excel skill body (create/edit workflows / formula-first / quick reference)
    │   └── reference/              # workbook-dsl.md / format-guide.md / troubleshooting.md / report-blueprints.md / analysis-playbook.md
    ├── data/
    │   ├── SKILL.md                # Data-pipeline skill (transform_file ops/expression syntax/data quality/cleaning·extraction·conversion recipes)
    │   └── reference/              # data-pipeline.md / data-quality.md / recipes.md
    ├── svg/
    │   ├── SKILL.md                # SVG image-generation skill (generate→preview→iterate workflow / self-check)
    │   └── reference/              # svg-craft.md / svg-recipes.md / infographic-blueprints.md
    ├── research-intelligence/ academic-publishing/ content-writing/ legal-ip/ ai-tooling/   # 5 main-skill routing entries (each has SKILL.md + ROUTING.md + branch subdirs)
    └── …/                          # plus html/pdf format branches and 25 branches under the 5 main skills; registry = 37 entries = 32 original + 5 main routing

test/
├── pptx-harness/                   # Offline verification for PPT/CSV/Word/Excel services (Node build + python checks + tsc)
├── docx-harness/                   # Word generator/importer harness (Node build + python-docx checks)
└── xlsx-harness/                   # Excel generator/importer harness (Node build + openpyxl checks)
```

The project follows an MVVM-like separation:

- View: ArkUI pages and components.
- ViewModel: chat, attachment, configuration, work-mode loop, and persistence state.
- Service: SSE, Agent Loop, tool execution, local document parsing, system sharing, TTS, and ASR.
- Model: messages, conversations, attachments, tool-call records, agents, and API profiles.

> **File extension = dependency rule**: ArkTS forbids `.ts` files from importing `.ets` files (`.ets` may import `.ts`). Decide the extension before creating/moving a file based on dependency direction — capabilities referenced by `.ets` modules such as `ChatViewModel.ets` / `WorkToolRunner.ets` (e.g. Office generation, multimodal) must live in `.ets` files; pure logic (e.g. ZipWriter, PDF/Office parsing) can stay in `.ts` and be used from both sides.

### Data flow

```text
[Chat mode]
ChatService (SSE)
  → ChatViewModel
  → @Observed Message
  → @ObjectLink ChatBubbleView
  → RichTextView

[Work mode] per loop turn
User task → ChatViewModel.executeWorkLoop
  → AgentLoopService.runTurn (three-protocol SSE + streamed tool-call accumulation)
  → WorkToolRunner.execute → WorkFileService.executeTool
      → OfficeReader / PdfTextExtractor (reading)
      → DocxExporter / XlsxExporter (generation)
      → PptxBuilder / PptxImporter / PptxImage / DeckOps (PPT write/read/edit, see "3.1")
      → WorkSkillService (list_skills / load_skill, see "3.3")
  → Tool results written back to ToolCallRecord → injected into next request history
  → one @Observed Message per turn (thinking/tools/answer)
  → ChatPage.buildWorkTimeline → WorkTurnView
```

### Core components

1. **ChatViewModel**
   
   - Manages conversations, agent selection, API profiles, and editor state.
   - Handles sending, streaming responses, attachment parsing, and regeneration.
   - Coordinates persistence and state restoration.
   - Work mode: `executeWorkLoop` drives the Agent loop (one message per turn, tool execution, image injection, history trimming; the loop body is driven by `WorkLoopDriver` by default — see 2.1).

2. **ChatService**
   
   - Implements SSE streaming and request cancellation.
   - Supports Chat Completions and Responses API.
   - Parses response deltas and handles network/server errors.

3. **AgentLoopService / WorkToolRunner / WorkFileService / WorkSkillService (work-mode quartet)**
   
   - `AgentLoopService`: one LLM turn — three-protocol request bodies (tool definitions, image messages), streamed tool-call accumulation, and the work-mode system prompt.
   - `WorkToolRunner`: unified tool dispatch entry implementing capabilities that require `.ets` modules (write_docx/xlsx, write_pptx/read_ppt/edit_ppt, parse_document).
   - `WorkFileService`: all sandbox workspace file operations, file-tool implementations, tool schemas (`toolDefs()`), and workspace zip export.
   - `WorkSkillService`: the skill registry (`registry()`) and rawfile skill-doc loading for `list_skills`/`load_skill`.

4. **MultimodalService**
   
   - Processes images, text, PDFs, and Office documents.
   - Supports pre-parsing, retries, and concurrency control.
   - Supports direct Responses API image/file input.

5. **OfficeReader / PdfTextExtractor / Flate (local parsing engine)**
   
   - `OfficeReader`: unpacks OOXML and extracts `w:t`/`a:t`/`sharedStrings` text with tag-boundary checks.
   - `PdfTextExtractor`: byte-level object table + ObjStm expansion + page-tree resource inheritance + ToUnicode CMap + content-stream text.
   - `Flate`: pure-TS DEFLATE/zlib inflate (the SDK zlib only offers file-level APIs).

6. **StorageManager**
   
   - Wraps local persistence: conversation history lives in `filesDir/guncat_conversations.json`; settings/toggles/reader preferences use Preferences.
   - Persists conversations, profiles, toggles, and reader preferences.

7. **TextReaderService / BackgroundReaderService**
   
   - Discovers and manages CoreSpeechKit voices.
   - Controls reading, pause, seeking, and speed.
   - Uses AVSession and a continuous task for background audio.

## Work mode architecture & maintenance guide

Work mode is a standalone agent execution environment: a virtual agent + a per-conversation sandbox workspace + a multi-turn tool-calling loop. This section targets maintainers and covers module responsibilities, data flow, and extension recipes.

> **Maintenance doc map** (which doc to read for which change):
> 
> - This section (README) — architecture, plus the design and extension recipes for the four systems: tools, skills, and the PPT/Word/Excel pipelines.
> - `ITERATION_LOG.md` — per-round Agent Loop core changes and verification (R1–R42).
> - `BACKLOG.md` — current open items and completed audit dimensions.
> - `PORT_NOTES.md` — dsh port map and subsequent core-layer iteration notes.
> - `test/pptx-harness/README.md` — the offline verification harness for the PPT pipeline and CSV writer (Node build + python-pptx checks + PNG review). Mandatory after touching anything under `export/`.
> - `entry/src/main/resources/rawfile/skills/` — the **model-facing** operation guides (5 main skills: `research-intelligence` / `academic-publishing` / `content-writing` / `legal-ip` / `ai-tooling`, each with `SKILL.md` + `ROUTING.md` + branch subdirs; 7 format branches stay top-level and direct: `ppt` / `docx` / `xlsx` / `svg` / `data` / `html` / `pdf`; `list_skills` exposes only these 12 visible skills, and the 25 branches are loaded by their original id after routing). They evolve in lockstep with the tools and double as reusable assets portable to other agent frameworks.

### 1. Identity and conversation model

- **Virtual agent**: `Constants.WORK_AGENT_ID = 'work'`. Injected at the top of the agent list on launch by `ChatViewModel.buildWorkAgent()`; `AgentDrawerView` splits it into its own "Agent Mode" group above the "Chat Mode" section header, parallel to the chat agents, with a 🛠 badge (special case for `id === 'work'`).
- **Enter/exit**: tapping "Work Mode" in the drawer = `selectAgent('work')`; tapping any real agent exits (the tool-row Work Mode pill exits back to `lastChatAgentId`, the most recently used real agent).
- **Conversation binding**: `Conversation.mode = 'chat' | 'work'`; work conversations keep `agentId = 'work'`, migrated automatically for legacy data on launch. Deleting a work conversation also deletes its sandbox workspace directory.
- **Toggle differences**: entering work mode force-enables deep thinking (the toggle is hidden from the tool row); web search stays available (the server-side search tool is sent alongside client function tools); uploads and camera captures go into the workspace instead of chat attachments.
- **Persistence**: conversation JSON gains `mode` and `Message.toolCalls` (`ToolCallRecord[]` with arguments/results/duration — the timeline and the LLM history are restored from these after restart). Conversation archives (`filesDir/guncat_conversations.json`) and workspace files themselves live in the sandbox `filesDir`, not in Preferences.

### 2. Agent Loop (`ChatViewModel.executeWorkLoop`)

```text
for step in 1..WORK_MAX_STEPS(200, runaway safeguard):
  1. Create a new assistant message (this turn's thinking/tools/answer attach to it)
  2. Budget check: when over 850K tokens (1M×0.85, usage-anchored), prune oversized early
     tool results first, then compress older history into a state digest (model call only if pruning is not enough)
  3. Append the "runtime context" snapshot (date + file tree + task checklist) to the tail of
     the history (skipped when unchanged)
  4. AgentLoopService.runTurnWithRetry (three-protocol streaming request with tool definitions;
     429/5xx/network/empty responses retried with exponential backoff)
  5. No tool calls → this turn is the final answer, stop
  6. Tool calls → consecutive read-only calls run concurrently, the rest sequentially
     (WorkToolRunner); results written back into ToolCallRecord
     - Mutating tools refresh the workspace file panel
     - A successful view_image injects a multimodal user message (in-memory only)
  7. This turn (assistant + tool results) enters the request history; continue
```

- **Loop driver engine (enabled by default)**: `WORK_USE_DRIVER_LOOP=true`; `executeWorkLoop` dispatches to `executeWorkLoopDriver`, which uses `WorkLoopDriverBridge.runWithStep` + `runDriverStep` to drive the loop-level state machine/planner. The legacy `executeWorkLoop` path remains for rollback (set the flag back to `false`).
- **One message per turn** is the foundation of the timeline UI: the message list is naturally the chronological "thinking→tools→answer" stream, instead of one big aggregated message.
- **Automatic context compaction (cache-aware, aligned with DeepSeek Harness)**: the budget is anchored to the previous request's real prompt tokens (usage-anchored) against `WORK_CONTEXT_WINDOW_TOKENS`×0.85 (1M×0.85 = 850K tokens), falling back to the session's measured chars→tokens ratio when usage data is absent. When over budget, a two-stage pipeline runs: first a model-free prune of oversized early tool results (head/tail excerpts with precise omission notices); if that is not enough, older history is summarized by the model into a compact "state digest" (≤2400 chars, keeping the most recent 12 messages verbatim) — the summarization request reuses the full prefix (static system prompt + tool definitions + history), so it is a continuation of the last real request for the model-side KV cache and the prefix is billed as cache hits. If the digest fails or the history is still over budget, the loop falls back to trimming oldest-first. If a request fails outright with a context-overflow error, the history is force-compacted and the request retried once. The task checklist and workspace files are never compacted and can always be re-read via `read_file` — this is what lets long tasks survive context limits. The timeline shows an "early history compacted" note.
- **Prefix-cache design**: the system prompt is fully static (built once, never rebuilt); date / file tree / task checklist travel in a "runtime context" snapshot user message appended to the tail of the history, and only when its content changes; history grows strictly append-only (compaction is the only operation that rewrites it) — consecutive requests therefore share a byte-identical prefix, the model-side KV cache hits across turns, and only a small tail needs recomputation after file writes.
- **Cancellation**: `stopStreaming()` calls both `ChatService.abort()` and `AgentLoopService.abort()`; an interrupted turn with no output is removed, otherwise a "⏹ Task stopped" note is appended.
- **Step safeguard**: `WORK_MAX_STEPS(200)` exists purely as a runaway guard (preventing endless tool-call loops from burning tokens); normal long tasks never reach it — when triggered, a "send 'continue' to proceed" note is appended to the last message.

### 2.1 Core-layer pure-logic iteration (R13–R64, for maintainers)

Since 6.1, the Agent Loop core has been iterated systematically: decision-making and testable parts were extracted into pure-logic modules under `common/`, with the runtime doing only IO injection. When touching loop logic, read these files first:

- **Decision / orchestration**: `ToolScheduler` (scheduling groups + `SchedulerSummary`), `RepeatDetector` (repeat protection), `LoopDecisions` (snapshot dedup / overflow compaction / max-tokens / invalid-step), `WorkLoopPlanner` (per-turn TOOL/FINISH/ABORT/COMPACT + human-readable `describe`), `WorkLoopSimulator` (full-loop regression), `WorkLoopDriver` (pure loop driver: state machine + planner + retry/compact callbacks), `WorkLoopDriverBridge` + `LoopTurnInfoMapper` + `WorkLoopStepInfoBuilder` (real-loop bridge / pure step-info construction), `WorkLoopStateMachine` (idle/running/paused/awaiting_user/aborting).
- **Protocol layer**: `LLMProtocol` (single source for protocol/endpoints), `ToolDefAdapter` (three-protocol tool shapes), `SSEProtocolAdapter` + `SSEAdapterFactory` (unified SSE pipeline shared by Work and Chat modes).
- **Errors / retry**: `RetryPolicy` (exponential backoff + jitter + retry-after + retryable kinds), `RetryAfterParser` (Retry-After header parsing), `ToolRetryPolicy` (per-tool retry), `LoopError` (explicit `retryable`/`userMessage`, pure and unit-testable).
- **Plugins / skills**: `ToolRegistry` (single source for tool+skill metadata), `PluginManifestLoader` (manifest parse/apply/unload), `PluginHotLoader` (rawfile hot load / reloadAll), `PluginToolExecutor` (declarative plugin tool handlers), `SkillDirectoryFormatter` (full_index/trigger_only A/B).
- **Observability**: `LoopMetrics` (retry/compact/max-tokens counters), `SessionLogAggregator` (protocol dimension + tool latency p50/p90/p99 + cross-session aggregation), `PromptBudget` (token budget estimation).
- **Testing**: `test/guncat-harness` pure-logic suite is **277/277 green**; after touching `common/`, run `node setup.mjs && node test-core.mjs`, then `node check-setup.mjs && tsc -p check/tsconfig.json`, then an `assembleHap` device build.

Each round's changes and verification are recorded in `ITERATION_LOG.md`; open items live in `BACKLOG.md`; the dsh port map is in `PORT_NOTES.md`.

### 3. Tool system (45 tools)

Dispatch chain: `ChatViewModel` → `WorkToolRunner.execute()` (.ets entry) → Office generation/parse_document/PPT/transform_file implemented locally, everything else delegated to `WorkFileService.executeTool()` (.ts); the 6.1 tools fall through to `HarnessTools.dispatch()` (.ts).

| Tool                                                    | Implementation                                                          | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ------------------------------------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `todo_write`                                            | WorkFileService.toolTodoWrite                                           | Writes `.todo.json`; accepts an array or an embedded JSON string                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `list_files`                                            | WorkFileService.toolList                                                | Recursive listing, dirs first, with sizes                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `read_file`                                             | WorkFileService.toolRead                                                | Plain text direct read; `.docx/.xlsx/.pptx`→OfficeReader, `.pdf`→PdfTextExtractor                                                                                                                                                                                                                                                                                                                                                                                                           |
| `write_file` / `append_file`                            | WorkFileService.toolWrite                                               | Overwrite/append text (512KB cap, parent dirs auto-created)                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `delete_file` / `create_dir` / `move_file`              | toolDelete / toolMkdir / toolMove                                       | Recursive delete / mkdir / move (moveFileSync/moveDirSync)                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `search_files`                                          | WorkFileService.toolSearch                                              | Case-insensitive substring search over text files, with line numbers; optional `glob` filename filter (`*`/`?`, comma-separated patterns), directories still recursed                                                                                                                                                                                                                                                                                                                       |
| `view_image`                                            | WorkFileService.toolViewImage                                           | Image→dataUrl (≤8MB); the loop injects it as the next multimodal message                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `download_file`                                         | WorkToolRunner.toolDownloadFile                                         | Downloads an http(s) file into the workspace (≤20MB; type sniffing + html warning; auto or explicit naming)                                                                                                                                                                                                                                                                                                                                                                                 |
| `parse_document`                                        | WorkToolRunner.toolParseDocument                                        | Full PDF text (local, 3× output cap)                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `search_pdf` / `pdf_to_images`                          | WorkToolRunner.toolSearchPdf / toolPdfToImages                          | Keyword search in the PDF text layer (page + excerpt, ≤50 hits); scanned / image-only PDFs are rendered page by page into `pdf_images/<name>/` for `view_image`                                                                                                                                                                                                                                                                                                                              |
| `write_docx`                                            | toolWriteDocx → DocxBuilder.buildFromMarkdown/buildDocxBytes            | **Doc JSON / doc file / Markdown → Word** (see the next section; optional title/style; images from workspace/data URL/http, svg rasterized automatically)                                                                                                                                                                                                                                                                                                                                   |
| `read_docx`                                             | toolReadDocx → DocxImporter.import                                      | .docx → Doc JSON source (lossless restore for app-generated files, approximate import otherwise; word/media images extracted to `docx_images/`)                                                                                                                                                                                                                                                                                                                                             |
| `edit_docx`                                             | toolEditDocx → DocxImporter + DocOps + DocxBuilder                      | Read back → apply ops (title/style/block CRUD/move/replace-text) → rebuild (foreign files backed up first)                                                                                                                                                                                                                                                                                                                                                                                  |
| `write_xlsx`                                            | toolWriteXlsx → XlsxBuilder.buildXlsxBytes                              | **Workbook JSON / workbook file / Markdown·CSV·TSV → Excel** (see the next section; multi-sheet/headers/formulas/numFmt/colWidth/freeze; optional name/style)                                                                                                                                                                                                                                                                                                                               |
| `read_xlsx`                                             | toolReadXlsx → XlsxImporter.import                                      | .xlsx → Workbook JSON source (lossless restore for app-generated files, approximate import otherwise: numbers/text/formulas restored)                                                                                                                                                                                                                                                                                                                                                       |
| `edit_xlsx`                                             | toolEditXlsx → XlsxImporter + XlsxOps + XlsxBuilder                     | Read back → apply ops (rename/add/delete/move sheets, row CRUD, set cell, replace text) → rebuild (foreign files backed up first)                                                                                                                                                                                                                                                                                                                                                           |
| `write_csv`                                             | toolWriteCsv → CsvWriter.buildCsvBytes                                  | Markdown table/CSV/TSV→CSV (RFC 4180 escaping, UTF-8 BOM by default; input parsing goes through CsvParser, quoted fields handled correctly)                                                                                                                                                                                                                                                                                                                                                 |
| `transform_file`                                        | WorkToolRunner.toolTransformFile → DataPipeline                         | **Local data pipeline** (data never enters model context): CSV/TSV/MD/JSON/JSONL/lines input; filter/derive/regex-extract/split/dedupe/sort plus CSV↔TSV↔JSON↔MD↔XLSX conversion; restricted DSL (whitelisted ops + expression evaluator, no I/O), preview before write; syntax via `load_skill("data")`; ≤2MB/100k rows/30 steps                                                                                                                                                           |
| `write_pptx`                                            | toolWritePptx → PptxBuilder.buildPptxBytes                              | **Deck JSON / deck file / outline → PPT** (see the next section)                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `read_ppt`                                              | toolReadPpt → PptxImporter.import                                       | .pptx → Deck JSON source (lossless restore for app-generated files, approximate import otherwise)                                                                                                                                                                                                                                                                                                                                                                                           |
| `edit_ppt`                                              | toolEditPpt → PptxImporter + DeckOps + PptxBuilder                      | Restore → apply ops → rebuild (foreign files are backed up first)                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `write_svg`                                             | WorkToolRunner.toolWriteSvg → SvgUtil                                   | SVG source → workspace .svg + rasterized PNG preview; xmlns/no-script validation, missing width/height auto-filled from viewBox (required by the device engine), precise diagnostics on decode failure                                                                                                                                                                                                                                                                                      |
| `list_skills` / `load_skill`                            | WorkFileService.dispatchTool → WorkSkillService                         | Skill list and on-demand skill-doc loading (12 visible skills under rawfile/skills/: 5 main + 7 format; 25 branches inside main-skill subdirs; registry = 37 entries = 32 original + 5 main routing)                                                                                                                                                                                                                                                                                        |
| `glob`                                                  | HarnessTools.toolGlob → FileSearchCore                                  | Find files by glob pattern (`**`/`*`/`?`/`{a,b}`/`[...]`; top-level commas don't break `{}` branches); returns relative paths with sizes (≤500)                                                                                                                                                                                                                                                                                                                                             |
| `grep`                                                  | HarnessTools.toolGrep → FileSearchCore                                  | Regex search over text files, returning `file:line: text` (≤200 hits; optional `glob` filename filter and `ignore_case`; invalid patterns fail with a clear error)                                                                                                                                                                                                                                                                                                                          |
| `edit`                                                  | HarnessTools.toolEdit → DiffUtil                                        | Exact character-level replacement (multiple matches rejected; `replace_all` overrides); the result carries line-level diff hunks (meta persisted with the session, rendered as a diff card)                                                                                                                                                                                                                                                                                                 |
| `str_replace_editor`                                    | HarnessTools.toolEdit                                                   | view/create/str_replace/insert editor (view reuses read_file's line paging; insert adds lines after a given line)                                                                                                                                                                                                                                                                                                                                                                           |
| `web_fetch`                                             | HarnessTools.toolWebFetch → WebFetchService                             | GET ≤2MB page/API source; HTML stripped to readable text (script/style/comments removed, block tags → newlines, entities decoded); JSON/text returned as-is (truncation noted)                                                                                                                                                                                                                                                                                                              |
| `local_web_search` / `record_search`                    | WorkFileService.toolSearchWeb → LocalWebSearch / toolRecordSearch       | **On-device fallback web search** (the phone talks to search engines directly; the server-side `web_search` is the default and this is used only when it is unavailable, returns nothing, or the user asks for it — the old name `search_web` still dispatches) plus recording server-side search conclusions into `.searches.md` for traceability                                                                                                                                    |
| `ask_user_question`                                     | HarnessTools.toolAskUser → AskUserBridge                                | Pauses execution for a user answer; the UI card supports single/multi select plus free text, submitted via one "Submit" button; unanswered for 5 minutes resolves as cancelled; loop abort resolves all pending asks                                                                                                                                                                                                                                                                        |
| `schedule_create` / `schedule_list` / `schedule_delete` | HarnessTools → ScheduleService                                          | Session-local reminders (persisted in `.schedule.json`; one-shot `after_seconds` or recurring `every_seconds`≥300s); when due, a user message wakes the loop (steered mid-task)                                                                                                                                                                                                                                                                                                             |
| `goal_create` / `goal_get` / `goal_update`              | HarnessTools → GoalService                                              | Session goal (`.goal.json`) injected via the runtime snapshot; `bump_round` counts rounds, auto-pausing at the cap                                                                                                                                                                                                                                                                                                                                                                          |
| `subagent`                                              | HarnessTools → SubagentService (via the `WorkFileService.subagentHook`) | In-process child agent: shares the workspace, isolated context (toolset excludes subagent/ask_user/schedule/goal/todo_write), ≤40 steps; can be dispatched in parallel (global cap 4), and each child gets an isolated output directory `subagents/sa_<timestamp>_<seq>/` by default (override with `output_dir`); it can read the whole workspace, while writes are auto-redirected into that directory; the final report is returned as the tool result and includes the output directory |
| `session_search`                                        | HarnessTools.toolSessionSearch → SessionLogService                      | Search the session event log (JSONL) to recover details lost to context compaction                                                                                                                                                                                                                                                                                                                                                                                                          |
| `run_js`                                                | HarnessTools → JsCodeService → native `libguncatjs.so` (JSVM-API)       | **On-device JS execution sandbox**: arbitrary small-program processing (computation / regex / JSON reshaping / statistics / programmatic generation) plus explicit file in/out (`files` is preloaded read-only, `write()` lands on disk); see the next section                                                                                                                                                                                                                              |

Path safety: every tool path passes through `resolveSafe()` — absolute paths, drive letters, and `..` traversal are rejected; operations stay inside `filesDir/workspaces/<convId>/`.
`run_js` input/output goes through `resolveSafe()` as well: the script itself has no filesystem capability, and everything crosses that ArkTS-side check.

### 3.1 PPT pipeline (Deck JSON intermediate layer)

The design mirrors open-kimi-ppt-skill's PPTD philosophy: **the AI-editable intermediate layer is decoupled from the exporter**. The AI only ever faces the Deck JSON layer — "generate a PPT" = write a Deck → render; "edit a PPT" = restore the Deck → apply ops → rebuild. The exporter knows nothing about prompts, only about the Deck structure, so its behavior is fully deterministic and testable offline.

```text
write_pptx ──┐                                      ┌─ write_pptx (rebuild the pptx)
deck JSON ───┼→ PptxBuilder (renders 13 layouts) → .pptx │
             │    └─ embedded docProps/deck.json source  │
read_ppt  ───┤                                     └─ edit_ppt (DeckOps apply ops then rebuild)
             └─→ PptxImporter (lossless restore from embedded source / approximate XML import)
```

#### Module responsibilities & public API (entry/src/main/ets/export/)

| File               | Responsibility                                                                                                                                                                                 | Key public members                                                                                                                                                                              |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DeckModel.ets`    | Intermediate-layer model + JSON parsing/validation + edit ops (**pure logic, no Kit API**)                                                                                                     | `Deck/DeckSlide/DeckBullet/DeckChart/DeckTable/DeckElement/DeckBackground`, `DeckParser.parse`, `DeckOutline.parse` (legacy outline compat), `DeckOps.apply`, `DECK_LAYOUTS`, `DECK_MAX_SLIDES` |
| `PptxThemes.ets`   | 8 theme presets + semantic/hex color resolution (**pure logic**)                                                                                                                               | `PptxThemes.resolve` (Deck→ThemeColors), `resolveColor(colors, spec, fallback)` (primary/accent/bg/surface/title/body/sub/faint/onPrimary/white/dark/light or hex), `ThemeColors`               |
| `PptxCharts.ets`   | Chart part XML (bar/line/area/pie/doughnut, data embedded as numCache/strCache, **pure logic**)                                                                                                | `PptxCharts.buildXml(chart, colors)`                                                                                                                                                            |
| `PptxImage.ets`    | Image reference resolution: workspace path / data URL / http(s), mime sniffing + PNG/JPEG/GIF/BMP dimension probing                                                                            | `PptxImage.resolve(src, workspaceRoot)` → `PptxImagePart`                                                                                                                                       |
| `PptxBuilder.ets`  | Deck → pptx full-part rendering (two passes: resolve images/charts first, then render pages)                                                                                                   | `PptxBuilder.buildPptxBytes(deck, resolveImage)`; also defines `PptxImagePart`/`ImageResolver` (types live here to avoid a PptxBuilder→PptxImage compile-time dependency)                       |
| `PptxImporter.ets` | pptx → Deck: reads the embedded `docProps/deck.json` first (lossless), otherwise parses slide XML into custom layouts (text/tables/image positions preserved, charts become placeholder notes) | `PptxImporter.import(absPath, cacheDir)` → `PptxImportResult{deck, embedded, slideCount}`                                                                                                       |

**Dependency direction** (`.ts` must not import `.ets`): `DeckModel ← PptxThemes/PptxCharts/PptxBuilder`; `PptxBuilder ← WorkToolRunner.ets`; `PptxImage → WorkFileService.ts` (only `resolveSafe`, legal direction); no cycles. Draw this map before adding any new file.

**SVG auto-rasterization**: `WorkToolRunner.imageResolver` rasterizes `.svg` source files at 1024px width through the device image engine before they enter the render pipeline — outputs of `write_svg` can be referenced by `write_pptx` directly (together with the svg skill's authoring rules), no manual conversion needed.

#### Deck JSON contract (three places to sync on every field change)

The model-facing field documentation = **the ppt skill's `reference/deck-dsl.md`**. The authoritative implementation is `DeckModel.ets`. When changing any field, all three of the following must be updated, otherwise the model generates from stale docs and error rates rise:

1. `DeckModel.ets` (parsing + validation: `parseSlide`/`validateSlide` error messages must include the page number and state what is missing, so the AI can self-correct);
2. The skill docs `rawfile/skills/ppt/reference/deck-dsl.md` (field tables) and `SKILL.md` (quick-reference example);
3. `test/pptx-harness/test-build.mjs` (samples must cover the field, negative cases must cover the new validation).

Structure overview: top level `{title, theme, themeOverride{8 color slots}, slides[]}`; page cap `DECK_MAX_SLIDES(80)`; common page fields `{layout, title, subtitle, notes, background{color|image, fit, overlay}}`; the 13 layouts each have their own fields (bullets / columns / image / table / chart / elements / text/author / imageSide…); limits: table ≤20 rows, one image ≤10MB (`WORK_PPT_IMAGE_MAX_BYTES`), whole deck ≤40 images (`WORK_PPT_MAX_IMAGES`).

#### pptx parts & relationship numbering conventions (read before touching PptxBuilder)

- Per-slide rels: `rId1` is always the slideLayout; then rId2… are allocated **in media → chart order**; the rIds in `renderChart`/background images/`renderCustom` are **computed** from this rule (`'rId' + (2 + mediaParts.length)`) — keep the same algorithm when adding elements that consume relationships.
- Chart global numbering is allocated during the **first scan pass** (`ctx.chartNos`) and shared by `[Content_Types].xml` and slide rels — never re-count at render time.
- Notes pages `ppt/notesSlides/`: the notesMaster **always exists** (regardless of notes), which keeps presentation rels stable; each notesSlide's rels back-reference its owning slide number.
- The embedded source `docProps/deck.json` (Override application/json) is what makes `read_ppt`/`edit_ppt` lossless — rendering changes must not touch it; it is generated by `JSON.stringify(deck)` in the build pass.
- The notesSlide rels' `../slides/slideN.xml` back-reference must receive the correct page number (`notesSlideRelsXml(i + 1)`).

#### Dark-background auto lightening (contrast red line)

`isDarkBg(slide, colors)`: background image with `overlay ≥ 0.3`, or a resolved background color with luminance < 0.55 → dark surface. When it applies:

- **Page text** (titles/bullets/captions/page numbers) goes through `TextScheme` (computed once in `renderSlide`, passed to every layout renderer), lightened to FFFFFF / E2E8F0 / A9B6C6 / 7E8CA0;
- **Charts** use a `lightened(colors)` copy: axis labels, legend, and data labels lighten while the **series palette stays unchanged**;
- **Table cells** always use theme `bg`/`surface` fills + theme `body` text — fills follow the theme rather than the page background, so every theme × page-background combination stays readable (this once caused a rework; do not change it back to hardcoded FFFFFF).

When writing a new layout renderer, **always take text colors from `ts` (TextScheme), never from `colors`** — that is how the rule above is enforced.

#### Extension recipes

**Adding a layout** (4 places):

1. Register the name in `DeckModel.DECK_LAYOUTS` → add field parsing in `parseSlide` → add required-field validation in `validateSlide` (errors include the page number);
2. Add a switch branch in `PptxBuilder.renderSlide` → write `renderXxx(slide, …, ts, …)`: geometry constants go at the top of the file (EMU, 1pt = 12700), text uses `ts`, decoration uses `colors.primary/accent`;
3. Add a sample page to `fullDeck` in `test/pptx-harness/test-build.mjs` → run the full verification chain (below);
4. Sync the skill docs: the `deck-dsl.md` field table + the layout table in `SKILL.md`.

**Adding a theme**: add a branch in `PptxThemes.preset()` (primary/accent/bg/surface/title/body/sub/faint/onPrimary/dark + a 6-color `series` palette) → add a row to `themes.md`. Unknown theme names fall back to brand-blue (do not throw — the model will correct itself).

**Adding a chart type**: add a branch in `PptxCharts.buildXml`. Mind the OOXML `CT_*Ser` child order `idx→order→tx→spPr→marker→dLbls→cat→val`; `dLblPos` is only valid for bar/line/pie (not doughnut — do not add it there) → sync `deck-dsl.md`.

#### Verification loop (mandatory after touching the generator; commands in test/pptx-harness/README.md)

```bash
node setup.mjs && node test-build.mjs        # all-layout/multi-theme/edit-ops/negative builds → gen/out_*.pptx
python validate.py gen\out_all.pptx …        # zip CRC/all-part XML/relationship consistency/content-types/python-pptx
python deep-check.py                         # python-pptx chart data + embedded source round-trip
node check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json   # service-layer type check
```

Visual review (on machines with PowerPoint): export PNGs with `export-png.ps1` and inspect page by page — focus on text overflow, dark-page lightening, chart label readability, and table contrast (all three historical visual bugs were these categories).

### 3.2 Word pipeline (Doc JSON intermediate layer)

Isomorphic to the PPT pipeline: an **AI-editable intermediate layer separated from the renderer**. "Generate Word" = write Doc JSON → render; "Edit Word" = restore Doc → apply ops → rebuild. The renderer only knows the Doc structure, never the prompt, so behavior is deterministic and testable offline.

```text
write_docx ──┐                                  ┌─ write_docx(rebuild docx)
doc JSON ────┼→ DocxBuilder(render)→ .docx      │
             │    └─ embeds docProps/doc.json   │
read_docx ───┤                                 └─ edit_docx(DocOps applied, then rebuild)
             └─→ DocxImporter(embedded source restore / foreign XML approximate import + word/media image extraction)
```

#### Module responsibilities & public API (entry/src/main/ets/export/)

| File               | Responsibility                                                                                                                                                           | Key public members                                                                                                             |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| `DocModel.ets`     | Intermediate model + JSON validation + Markdown conversion + edit ops (**pure logic, no Kit API**)                                                                       | `Doc/DocBlock/DocListItem`, `DOC_STYLES`, `DocStylePalette.of(style)`, `DocParser.parse`, `MdToDoc.convert`, `DocOps.apply`    |
| `DocxBuilder.ets`  | Doc → docx full-part render (two-pass: resolve images first, then render block by block; embeds the doc.json source)                                                     | `DocxBuilder.buildDocxBytes(doc, resolveImage)`, `buildFromMarkdown(md, title, resolveImage)`, `DocxImagePart`                 |
| `DocxImporter.ets` | docx → Doc: reads embedded `docProps/doc.json` first (lossless), otherwise parses document.xml (headings/lists/tables/images; images extracted to `docx_images/<base>/`) | `DocxImporter.import(absPath, cacheDir, imageOutDir, imageOutRelBase)` → `DocxImportResult{doc, embedded, blockCount, images}` |

**Dependency direction**: `DocModel ← DocxBuilder`; `DocxBuilder/DocxImporter ← WorkToolRunner.ets`; independent of the PPT pipeline (shares MarkdownParser/OmmlConverter/XmlUtil/ZipWriter only). Draw this graph before adding new files.

**Typography & images**: styles.xml sizes headings H1→H6 at 22→12pt bold 黑体 with per-theme palette colors (default/academic/minimal), body defaults to 12pt 宋体 with 1.5 line spacing; both image blocks and inline images accept workspace paths / data URLs / http, svg rasterized automatically, ≤10MB per image and ≤40 images per doc (`WORK_DOC_*` constants); tables support captions and header shading.

#### Doc JSON contract (the three places to sync when changing a field)

The AI-facing field documentation = **the docx skill's `reference/doc-dsl.md`**. The authoritative implementation lives in `DocModel.ets`. Changing any field requires syncing:

1. `DocModel.ets` (parsing + validation: error messages carry the block index and say exactly what is missing, so the AI can self-correct);
2. Skill docs `rawfile/skills/docx/reference/doc-dsl.md` (field tables) and `SKILL.md` (quick-reference examples);
3. `test/docx-harness/test-build.mjs` (samples covering the field, negatives covering the new validation).

Structure overview: top-level `{title, subtitle, author, date, style, cover, toc, blocks[]}`; block cap `WORK_DOC_MAX_BLOCKS(400)`; block types `heading(1~6)/paragraph/list(ordered/unordered)/table/image/quote/code/divider/pagebreak`; inline formatting `**bold** *italic* \`code\` [link](url) $math$ ![](inline image)`; limits: tables ≤20 cols/500 rows, ≤10MB per image, ≤40 images per doc.

#### Verification loop (mandatory after touching the generator; commands in test/docx-harness/README.md)

```bash
python makepng.py > png.b64
node setup.mjs && node test-build.mjs          # all-block-types/cover-TOC/markdown path/edit ops/foreign import/negatives
python validate.py gen\out_all.docx …          # zip CRC/all-part XML/relationship consistency/style-size grading/python-docx/image embedding
python deep-check.py gen\out_all.docx …        # embedded doc.json round-trip + body/table/image/H1-order checks
node check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json   # service-layer type check (pptx-harness)
```

Visual review (on machines with Word/WPS): open `gen/out_all.docx` and check the cover page, heading size grading, and image/table layout.

#### Excel pipeline (Workbook JSON intermediate layer, isomorphic with PPT/Word)

The design mirrors PPT/Word: **a model-editable intermediate layer separated from the exporter**. The model only ever talks to Workbook JSON — "generate Excel" = write Workbook → render; "edit Excel" = restore Workbook → apply ops → rebuild. The exporter knows nothing about prompts, only Workbook structure, so its behavior is fully deterministic and testable offline.

```text
write_xlsx ──┐                                   ┌─ write_xlsx(rebuild xlsx)
workbook JSON ┼→ XlsxBuilder(render)→ .xlsx      │
             │    └─ embedded docProps/workbook.json │
read_xlsx ───┤                                  └─ edit_xlsx(XlsxOps apply → rebuild)
             └─→ XlsxImporter(lossless from embedded source / foreign XML import)
```

#### Module responsibilities & public API (entry/src/main/ets/export/)

| File               | Responsibility                                                                                                                                                              | Key public members                                                                                                                      |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `XlsxModel.ets`    | Intermediate model + Workbook JSON parse/validate + Markdown/CSV/TSV conversion + edit ops (**pure logic, no Kit API**)                                                     | `XlsxWorkbook/XlsxSheet/XlsxCell`, `XLSX_STYLES`, `XlsxStylePalette.of(style)`, `XlsxParser.parse`, `MdToXlsx.convert`, `XlsxOps.apply` |
| `XlsxBuilder.ets`  | Workbook → xlsx all-part rendering (multi-sheet / bold header fills in 3 themes / `=formulas` / number formats / column widths / freeze panes; embeds workbook.json source) | `XlsxBuilder.buildXlsxBytes(workbook)`                                                                                                  |
| `XlsxImporter.ets` | xlsx → Workbook: reads the embedded `docProps/workbook.json` first (lossless), else parses workbook.xml+rels+sharedStrings+sheets (numbers/text/formulas/colWidth/freeze)   | `XlsxImporter.import(absPath, cacheDir)` → `XlsxImportResult{workbook, embedded, sheetCount, rowCount}`                                 |

**Dependency direction**: `XlsxModel ← XlsxBuilder`; `XlsxBuilder/XlsxImporter ← WorkToolRunner.ets`; independent of the PPT/Word pipelines (shares XmlUtil/ZipWriter; XlsxModel reuses CsvParser for table-text parsing). `XlsxExporter.buildXlsxFromRows` still serves transform_file's XLSX output, keeping its single-sheet, no-format semantics.

**Spreadsheet capabilities**: the `workbook` source supports multiple sheets (≤20), bold header fills (default/academic/minimal), formulas (cell values starting with `=`, e.g. `"=SUM(B2:B9)"`, cross-sheet `"=假设!B2"`), per-column number formats (`money` ¥ thousands + 2 decimals / `int` / `percent` 0.0% / `year` / `date` / `number` / `text`), column widths 1–255, and freeze panes (`freeze: "A2"`); data rows are rectangular (≤1000 rows/60 cols, `WORK_XLSX_*` constants). **Formula-first**: derived values (totals/ratios/shares) must be formulas, never hardcoded numbers — the number-format and negative/zero display conventions (amount negatives in parentheses `(¥1,234.00)`, zero as `-`) draw on the MiniMax xlsx reference skill; the model-facing guide is `load_skill("xlsx")`.

#### Workbook JSON contract (three places to sync when changing a field)

The authoritative field doc from the model's perspective = **the xlsx skill's `reference/workbook-dsl.md`**. The authoritative implementation of the Workbook structure lives in `XlsxModel.ets`. Changing any field means syncing:

1. `XlsxModel.ets` (parse + validate: error messages carry sheet/row/col numbers so the model can self-correct);
2. The skill docs `rawfile/skills/xlsx/reference/workbook-dsl.md` (field tables) and `SKILL.md` (quick-reference examples);
3. `test/xlsx-harness/test-build.mjs` (samples cover the field; negatives cover the new validation).

Structure overview: top-level `{name, style, sheets[]}`; per sheet `{name, headers?, rows, colWidths?, freeze?, formats?}`; cell values = number | string | `"=formula"`. `read_xlsx` restores app-generated files losslessly (embedded source); foreign xlsx files get an approximate import (sheet order/numbers/text/formulas restored, styles/merges lost); `edit_xlsx` automatically backs up foreign files as `*_原版备份.xlsx` before rebuilding.

#### Verification loop (mandatory after touching the generator; commands in test/xlsx-harness/README.md)

```bash
node setup.mjs && node test-build.mjs          # multi-sheet/formulas/numFmt/colWidth/freeze + markdown path + edit ops + foreign import + negatives
python validate.py gen\out_all.xlsx …          # zip CRC/all-part XML/relationship consistency/openpyxl/header bold/formulas/numFmt/freeze/colWidth
python deep-check.py gen\out_all.xlsx …        # embedded workbook.json round-trip + per-cell checks (incl. formulas)
node check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json   # service-layer type check (pptx-harness)
```

Visual review (on machines with Excel/WPS): open `gen/out_all.xlsx` and check header fills, money formats, formula linkage (change B2 and watch D2 recalc), and the freeze pane.

### 3.3 Skill system (reusable domain operation guides)

A skill = an **id-organized, pure-Markdown domain operation guide** (no code) that the model loads on demand when a matching task arrives. The problem it solves: domain knowledge (Deck JSON syntax, design guidelines, …) must not go into the system prompt — the system prompt has to stay byte-stable (the KV-cache red line), while skill docs can be added, changed, and layered at any time **without touching a line of prompt code**.

#### Structure conventions

```text
entry/src/main/resources/rawfile/skills/
├── ROUTE_INDEX.md               ← global routing index (added; not part of any original skill body)
├── research-intelligence/       ← main skill: research & intelligence analysis (routing entry)
│   ├── SKILL.md                 ← main-skill body: load first, then route by intent
│   ├── ROUTING.md               ← branch routing list
│   └── research/ sift/ llm-eval/ sentiment-tracker/
│       industry-analysis/ research-lineage-map/ questionnaire/
│                                ← 7 branch-skill subdirs (original ids still work in load_skill)
├── academic-publishing/         ← main skill: academic writing & paper lifecycle (routing entry)
│   ├── SKILL.md / ROUTING.md
│   └── paper/ paper-close-reading/ paper-reviewer/ paper-rebuttal/
│       research-proposal/ reference-audit/ journal-format/   ← 7 branches
├── content-writing/             ← main skill: content creation & marketing copy (5 branches)
│   ├── SKILL.md / ROUTING.md
│   └── khazix-writer/ newmedia-writing/ content-rewrite/ humanizer/ marketing-plan/
├── legal-ip/                    ← main skill: legal/IP/compliance (4 branches)
│   ├── SKILL.md / ROUTING.md
│   └── law/ patent-drafting/ translation/ marketing-material-review/
├── ai-tooling/                  ← main skill: AI engineering & prompts (2 branches)
│   ├── SKILL.md / ROUTING.md
│   └── prompt-engineering/ review-agent/
├── ppt/                         ← format branch (stays top-level and direct)
│   ├── SKILL.md                 ← skill body (required): when-to-use / toolchain / workflows / quick ref / self-check
│   └── reference/              ← deep-dive material, loaded file by file (optional)
│       ├── deck-dsl.md         # field-level syntax
│       ├── design-guide.md     # design guidelines
│       ├── themes.md           # theme catalog
│       └── troubleshooting.md  # symptom→fix lookup
├── docx/ xlsx/ data/ svg/ html/ pdf/
│                                ← the other 6 format branches stay top-level and direct
└── …/
```

The registry lives in `WorkSkillService.registry()` (**the code is the registry, no config file**). Each `SkillInfo = { id, name, description, files: SkillFileInfo[] }`; `files` is the whitelist of files `load_skill` may read (`SKILL.md` is always allowed), guarding against path probing. **Unregistered skills are invisible to the model** — dropping docs into the directory without registering them does nothing.

**Physical nesting + original-id loading**: branch skills have been moved out of the top-level `skills/` directory into their main-skill subdirectories, but `load_skill` still uses the original ids — `WorkSkillService.skillPath()` maps an id to its nested directory (e.g. `research` → `research-intelligence/research`), so the model never needs to know file locations. **Visibility**: `list_skills` returns only 12 visible skills (5 main skills + 7 format branches); the 25 branch skills are not listed directly and are loaded by their original id after routing through the main skill's `ROUTING.md`. The registry now contains 37 entries = 32 original skills + 5 main-skill routing entries.

#### Loading chain (progressive disclosure)

```text
System prompt "Skill library" section (default full_index: skill list + skill usage golden rules, static)
  → the model calls list_skills()            → WorkSkillService.listText()
      returns: 12 visible skills (5 main + 7 format) id + name + trigger semantics + file index
  → hit a main-skill domain → load_skill("<main skill>") → read SKILL.md/ROUTING.md, route to a branch
  → load_skill("research")                   → skillPath() maps to research-intelligence/research, reads SKILL.md
  → load_skill("ppt", "reference/deck-dsl.md") → load deep-dive file by file
Dispatch: WorkFileService.dispatchTool() (pure TS, no .ets needed); both are registered in isReadOnlyTool() and may run concurrently.
Results follow the normal tool rules: over 12K chars they are truncated head+tail (WORK_SKILL_MAX_CHARS is the hard cap on the loading side).
```

#### SKILL.md writing conventions (reusable skeleton)

```markdown
---
name: <id>
description: <one-line trigger semantics, see below>
---
# <Skill name>

## When to use      ← trigger scenario list (the model decides whether to load from this)
## Toolchain        ← which tools, how to pass arguments, hard constraints such as image sources
## Workflow A/B     ← numbered steps per scenario, one action per step; include a minimal runnable example
## Quick reference  ← table/JSON samples (keep the most-used 20%; push the long tail into reference)
## Pre-delivery self-check list ← checkbox list the model runs before delivering
```

- Split `reference/` files by topic; **each file under 12K chars** (longer files get truncated in the middle — the lost middle makes them useless);
- Code examples must be **minimal samples that run as-is**, consistent with the current tool implementation;
- Length budget: keep SKILL.md at 4–6K chars and leave details to reference.

#### How to write the description (trigger semantics)

The description plays two roles: the expansion of the system-prompt trigger line and the display text in `list_skills`. Formula = **enumerate task keywords + name the tools involved + state "load first"**:

- ✅ `Load when creating/modifying/beautifying presentations (.pptx): the full Deck JSON syntax (13 layouts/charts/tables/images/notes), 8 themes, design guidelines, and the self-check list. Load before any write_pptx / read_ppt / edit_ppt task.`
- ❌ `PPT skill` (the model cannot tell when to load it — as good as unwritten)

#### Adding a new skill (docs + 1–2 code touch points)

1. Create `rawfile/skills/<id>/SKILL.md` (+ `reference/*.md` as needed) following the skeleton above;
2. Register the entry in `WorkSkillService.registry()`: id / name / description / files whitelist (every reference file must be registered, otherwise it cannot be loaded);
3. If proactive triggering is wanted, add a sentence to the "Skill system" section of `AgentLoopService.buildWorkSystemPrompt()` (appending lines does not break the static red line);
4. **No toolDefs/dispatchTool changes needed**: `list_skills`/`load_skill` are generic tools that automatically cover new skills;
5. Self-test: in work mode run `list_skills` → `load_skill` every file to confirm nothing is truncated → run a real matching task and check the model follows the skill.
6. If the new skill is a **branch skill**: place its directory under the matching main skill, add the id→subdirectory mapping in `WorkSkillService.skillPath()`, and add it to that main skill's `ROUTING.md`. If it is a new **main skill**: create `SKILL.md` + `ROUTING.md`, register it in `ROUTE_INDEX.md`, and add the entry in `registry()`.

#### Maintenance red lines & portability

- Skill docs **evolve in lockstep with the tools**: change a Deck field/tool parameter → sync the skill doc → then the system prompt (if affected);
- description wording = trigger behavior; treat changes seriously (flag them separately in commit messages);
- Skill docs are a **cross-agent reusable asset**: the frontmatter (name/description) deliberately follows the standard Agent Skills convention (same structure as open-kimi-ppt-skill's SKILL.md). Copy the whole directory into another agent framework's skills directory (e.g. `~/.claude/skills/<id>/`) and SKILL.md-aware frameworks will pick it up — no rewriting required.

### 3.4 run_js: on-device JS execution sandbox (JSVM-API)

Work mode has no shell, terminal, or PTC, so deterministic processing could only use fixed tools; `run_js` uses the **JSVM-API** (`libjsvm.so`, an NDK C interface available since API 11, syscap `SystemCapability.ArkCompiler.JSVM`) to embed a standard JS engine in the app and add the general "write a few lines of code and compute it" capability — date/number/unit conversion, regex cleaning, JSON reshaping and merging, statistical aggregation, algorithm try-outs, and programmatic bulk generation of structured data (produce JSON, then hand it to `write_docx`/`write_xlsx`/`write_pptx`).

**Chain**: `HarnessTools.dispatch('run_js')` → `JsCodeService.run()` (.ts) → native `libguncatjs.so` (`entry/src/main/cpp`) → a JSVM engine instance.

- ArkTS side (`JsCodeService.ts`): argument validation, input-file preloading (`resolveSafe` + text/binary detection), output landing, giving up on timeout, result rendering.
- Native side (`jsvm_sandbox.cpp` + `napi_init.cpp`): create a VM + context per execution → inject the sandbox → compile and execute → take the completion value → tear down in reverse order; execution runs on a Node-API async task (worker thread).

**Sandbox capabilities** (every execution is a brand-new engine instance, so no state leaks between scripts):

| JS side                                            | Description                                                                                                                                                                     |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `inputs["path"]` / `read("path")`                     | Read-only input (`files` preloading: ≤6 files, ≤512KB each, ≤1MB total); key names drop the `./` prefix and collapse duplicate slashes, and the result lists the actual key names; without `files`, `read()` reports an error directly |
| `write("path", content)`                              | Declares output; **lands on disk only if execution succeeds**, and the path goes through `resolveSafe()` again                                                                   |
| `console.log/info/warn/error/debug`, `print`, `log` | Collected as stdout (≤64KB, ≤8KB per line)                                                                                                                                      |
| Return value                                        | The completion value of the script's last expression (same semantics as eval); objects/arrays come back as JSON, strings as-is                                                     |
| Other built-ins                                     | Standard V8 built-ins (JSON/Math/Date/RegExp/Map/Set/Intl…); **no network, no filesystem, no module loading** (JSVM does not support ES Modules)                                  |

**Design points**:

- **File access must be explicit**: the native side makes no path decisions at all; every path is validated by the ArkTS side's `resolveSafe()` before any read or write — the workspace boundary is implemented in exactly one place, and JS itself has no escape capability.
- **A fresh engine instance per execution**: no state leaks between scripts, and a script that wrecks its engine does not affect the next one.
- **Execution runs on an async task**: JS is synchronously blocking, and putting it on the UI thread freezes the interface outright (the official docs state that `execute` is non-interruptible and offers no async support).
- **A timeout can only "give up waiting"**: the JSVM-API has no `TerminateExecution`-style interface, so `while(true)` cannot be terminated from outside. The ArkTS side waits `Promise.race`-style: on timeout it hands the error back to the model while that code keeps running on the background thread; after `WORK_JS_MAX_ABANDONED` (2) accumulated cases, `run_js` is disabled for the session (better to degrade at this step than to keep the app pegging every core and draining the battery). **When debugging a timeout, look at infinite loops and loop sizes first.**
- **Resource caps**: 256MB VM heap (`JSVM_CreateVMOptions.maxOldGenerationSize`), source ≤128KB, single-file output ≤512KB (matching `WORK_WRITE_MAX_BYTES`), total output ≤4MB, ≤16 files; every cap is clamped again on the native side (out-of-range values are taken to the boundary), so abusing arguments cannot break the boundary. **The heap is a hard boundary**: generating an oversized array/string in one go can terminate the process, so scripts should process in chunks instead of expanding an entire data set into one huge structure.

**Maintenance notes (the native part)**:

- The official rules must be followed or it crashes: `OH_JSVM_Init` succeeds only once per process (repeat calls return `JSVM_GENERIC_FAILURE`, meaning "already initialized", which is normal); scopes must be closed in reverse order (HandleScope → EnvScope → VMScope → DestroyEnv → DestroyVM); a `JSVM_Value` may only be created inside a HandleScope and must not be used after the scope closes; a `JSVM_CallbackStruct` must outlive its `JSVM_Env` (this implementation uses file-level static objects); and every JSVM-API failure must clear the pending exception, or it pollutes later calls.
- If the heap parameters of `JSVM_CreateVMOptions` are not accepted, it falls back to the default configuration automatically (so the tool never becomes entirely unusable because of a heap setting).
- Adding an ABI requires syncing `externalNativeOptions.abiFilters` in `entry/build-profile.json5` (currently `arm64-v8a` / `x86_64`, matching the project's other native dependencies).
- `libguncatjs.so` depends on the system library `libjsvm.so` (shipped with the system since API 11, not packaged in the HAP). The ArkTS side uses a static `import` (matching the official sample), so **if a target device lacks that system library, the native module fails to load and work mode startup is affected with it**; for full isolation, switch to a dynamic `import()` at the call site.
- After changing native code you **must build for a real device**: `hvigor assembleHap` drives CMake/Ninja and packages `libs/<abi>/libguncatjs.so`; the Node-side `test/guncat-harness` can only do type-level checking (`libguncatjs.so` is replaced by the `jsvm-shim.ts` stub).
- On-device self-check: `run_js` returns `1+1 → 2`; output from `write()` is visible in the workspace; syntax errors / runtime exceptions return a readable error (with `run_js.js:line`); `while(true){}` reports an error after the timeout without freezing the UI; `engineStatus()` returning an empty string means the engine is usable (when it is not, the tool reports the reason directly).

### 4. Adding a new tool (6 places)

1. `WorkFileService.toolDefs()`: register the schema (name/description/parameters) — this is what the model sees; use `props0`/`props1`/`props2`/`props3` to build property maps.
2. `WorkFileService.dispatchTool()`: add the dispatch branch (for capabilities requiring `.ets` modules, dispatch from `WorkToolRunner.execute()` instead).
3. Implement the executor returning a `ToolExecResult` (`ok`/`output`; `imageDataUrl` is reserved for view-image-style tools).
4. `AgentLoopService.buildWorkSystemPrompt()`: document the tool and its discipline (stay byte-static; do not put large bodies of domain knowledge here — make it a skill, see 3.3).
5. If it mutates the workspace, register it in `WorkFileService.isMutatingTool()`; read-only tools go into `isReadOnlyTool()` (they may run concurrently). Tools delegated to `HarnessTools` are registered in `HarnessTools.isMutating()/isReadOnly()`.
6. `ChatBubbleView`: add a case to `toolIcon()` and `displayName()` (without it the row falls back to a generic wrench icon plus the raw name).
7. When native capability is needed (as with `run_js`): add `entry/src/main/cpp/{CMakeLists.txt,*.cpp}` + `types/lib<name>/index.d.ts` (+ `oh-package.json5`), declare the CMake path and `abiFilters` in `externalNativeOptions` of `entry/build-profile.json5`, and `import { … } from 'lib<name>.so'` on the ArkTS side.

> Content that "teaches the model how to use the new tool" (DSL syntax, format specs, workflows) should become a skill doc rather than being stuffed into the tool description or the system prompt — the description states the purpose in one line, and the details are fetched via `load_skill` on demand.

### 5. Local parsing engine and the memory/main-thread red lines

**Parsing chain**: `OfficeReader` (zlib.decompressFile unpacks OOXML → XML text-node extraction), `PdfTextExtractor` (byte-level object table → ObjStm sequential-value expansion → page-tree resource inheritance → ToUnicode CMap for CJK → content-stream `Tj/TJ` parsing → raw-stream fallback with diagnostics), `Flate` (pure-TS DEFLATE/zlib inflate).

Three red lines learned from production incidents:

1. **Never build large strings via per-character concatenation** (`s += x` loops are O(n²)) — this OOM'd the shared heap. Large fragments go through `bytesToString()`: bytes are copied into a UTF-16LE buffer and decoded natively with `util.TextDecoder`; `arrayBufferToBase64` likewise generates bytes numerically and decodes natively.
2. **Heavy CPU parsing must yield the main thread in stages** — a fallback scan over every stream (including font programs) once triggered a THREAD_BLOCK_6S appfreeze. `PdfTextExtractor` uses `yieldNow()` (setTimeout 0) after the object table, between pages, and between fallback streams.
3. **Every fragment conversion must be capped**: dict 64KB, ObjStm 2MB, CMap 1MB, content stream 4MB, single text decode 128KB, line buffer 100K chars, whole file 16MB — preventing pathological/malicious files from exhausting memory.

### 6. ArkTS constraints learned the hard way

- **`.ts` must not import `.ets`** (compile error 10605999). Draw the dependency direction before choosing an extension: `ChatViewModel.ets` needs Office generation/multimodal modules, so the ViewModel itself must be `.ets`; `WorkFileService.ts` can only depend on `.ts` (ZipWriter was therefore converted from .ets to .ts).
- **`.ets` forbids anonymous object literal types** (arkts-no-obj-literals-as-types). Use named classes for cross-module structures (`ParsedFileResult`, `ToolExecResult`).
- **Closures do not inherit null narrowing**: after `let conv: X | null` is null-checked, lambdas may still report "possibly null" — capture a non-null local (e.g. `let emptyConv: Conversation = conv`) before the closure.
- **The directory-listing API is `listFileSync`** (this SDK has no `readdirSync`); `mkdirSync(path, true)` creates directories recursively.
- **Imports must precede all other statements** (comments excepted).
- Rewriting source files through PowerShell pipes re-encodes UTF-8 as GBK and corrupts Chinese text — always edit source files with an editor, never shell redirection.

### 7. UI (Codex-style timeline)

- `ChatPage.buildWorkTimeline`: in work mode the whole conversation renders as a **single-container timeline** — a unique 🛠 "Work Mode" header (with execution status) followed by user task cards (brand-colored) and `WorkTurnView` entries in message order.
- `WorkTurnView` (`@ObjectLink Message`): CLI-style inline thinking row (`icon + label`, spinner/marquee while streaming, the label gains a static "· 持续了几秒" suffix once done, no fill) → CLI-style inline tool rows (`tool icon + short name · arg summary + status/duration`, no filled background; tap to expand arguments and results, the expanded block hangs off a thin left rule) → answer body (RichTextView); thinking/tool rows carry a 16vp horizontal inset so their width matches the body text; action buttons appear only on the final turn; a 33ms flush timer syncs text and step states during streaming.
- Chat mode keeps using `ChatBubbleView` (its thinking bar uses the same fill-free inline style); the two render paths do not interfere.
- `WorkspaceBar`: workspace popup (file list + upload/export zip/delete); file rows map the extension to a category icon (`sys.symbol`: image/table/slides/PDF/archive/code/audio/video etc.), unknown types fall back to a generic doc icon.

## Interactive mode architecture (Intelligent UI)

Interactive mode is not a second loop: it is the **second delivery form of the same Agent Loop**. Keep this boundary in mind when maintaining it: **the loop, the tools, the sandbox workspace, and context compaction are all reused; only the "system prompt" and the "answer rendering" fork by mode.**

### 1. Identity and conversation model

- **Virtual agent**: `Constants.INTERACTIVE_AGENT_ID = 'interactive'`, injected by `ChatViewModel.buildInteractiveAgent()` as the **second** entry in the `agents` list (right after `work`); `AgentDrawerView` / `DswSidebar` group it with work mode under "Agent Mode" (`workAgents()` matches both ids).
- **Conversation binding**: `Conversation.mode = 'chat' | 'work' | 'interactive'`, with `agentId` fixed to `'interactive'`; the mode derivation in `startNewConversation()` / `selectAgent()` / `deleteConversation()` goes through `Constants.MODE_*` uniformly.
- **UI follows the mode**: `ChatPage` uses `vm.agentLoopMode` (work or interactive) instead of the old `vm.workMode` to pick the timeline, the workspace panel, the upload landing path, and other shared capabilities; only copy differs, through five getters: `loopModeTitle` / `loopModeHint` / `loopModeInputPlaceholder` / `loopModeEmptyDescription` / `loopToolLabel`.
- **Deep thinking**: as in work mode, forced on as soon as you enter (the toggle is not shown in the tool row).

### 2. Prompt forking

```text
ChatViewModel.executeWorkLoop(conv)
  → AgentLoopService.buildWorkSystemPromptFor(conv.mode)
      mode === 'interactive' → buildInteractiveSystemPrompt()   // cached in cachedInteractivePrompt
      mode === 'work'        → buildWorkSystemPrompt()
```

`buildInteractiveSystemPrompt()` = `GuncatUiPrompt.promptSection()` (guncat-ui lang syntax + component list + **richness / component-selection priority** + interaction loop + output-order discipline + examples + anti-patterns) + the shared Agent Loop prompt (tool directory / skill directory / workflow, byte-identical to work mode) + `GuncatUiPrompt.INTERACTIVE_DUTY` (the interactive-mode duty, appended last so it overrides the "delivery format" section of the shared prompt). The three parts are **fully static** once concatenated and cached in-process, so the KV-cache prefix is as byte-stable as work mode's.

**The "richness" section (`GuncatUiPrompt.RICHNESS`, ~3.3k characters) is the main lever that pushes the model toward complex interfaces**: writing only "a paragraph plus a table" is perfectly legal syntax but equals falling back to ordinary chat, and that is where a model is most likely to cut corners, so it gets its own section with strong contrasts. It contains four parts:

1. **Component-selection priority table**: each row is "what you want to express → prefer → do not degrade to". For example key numbers and year-over-year change use `OverviewCardBlock` + `MetricIndicatorInline` instead of being written into a sentence; composition uses `PieChart`/`SingleStackedBarChart`, trends use `LineChart`/`AreaChart`, rankings use `HorizontalBarChart`, attainment uses `RadialChart`, multi-dimensional comparison uses `BarChart`/`RadarChart`, and a table is only for "cases that need exact row-by-row verification" and must have a comprehensible layer above it.
2. **Layered recipe**: header (`CardHeader`) → conclusions (metric cards / `Callout`) → visualization (charts / image gallery / `Steps` / `TagBlock`) → detail (`Table` / `EntityList` / `ListBlock`) → actions (`Form` / `OptionCards` / `Buttons`); **8–14 components is the norm**.
3. **Anti-padding**: do not say the same data three times over — metric cards give totals and year-over-year change, charts give trend and distribution, tables give row-by-row detail, and the three must complement each other (this exists so that "richer" does not swing to the opposite extreme of "repetitive").
4. **A "fails vs. passes" contrast for the same data**: ❌ only `TextContent` + `Table`; ✅ header / metric cards / line chart / donut / detail table / form layered together.

**Converging the "next step" entry point**: every turn still offers a next step, but it **must be a concrete action directly related to the current data** (`Buttons` / `OptionCards`, 1–2 of them is enough). "You might also ask" follow-up suggestions such as `FollowUpBlock` / `FollowUpItem` are **not to be used by default** (the user explicitly said they dislike every card ending with q1/q2/q3). They were therefore taken out of the prompt in eight places: the syntax section's D block now recommends `Buttons`/`OptionCards` and states "do not use by default"; the richness priority table and the layered recipe drop them; the anti-pattern list gains a named entry; example 2 switches to `Buttons`; item 4 of `INTERACTIVE_DUTY` becomes "the entry point must be concrete"; the two repair prompts converge as well; and the component list marks both components **not recommended**. **The components themselves stay in the registry** — deleting them would turn already-generated follow-up blocks in past messages into "unknown component" diagnostics. 8 assertions guard this.

Related changes: the old "do not write a 6-element interface as 20 elements" in `STREAMING` became "fewer components is not better; 8–14 clearly layered components is the goal"; `ANTI_PATTERNS` gained three entries (lazy text+table combination, structured metrics stuffed into prose, duplicated data for richness); `INTERACTIVE_DUTY` gained "lean toward richer by default"; and `REPAIR_SYSTEM`/`REPAIR_INSTRUCTION` (used when the main answer produced no program) moved from "3–5 elements" to requiring layering and charts. **17 prompt assertions** in `test/guncat-harness/test-core.mjs` hold all of this in place so a future prompt edit cannot silently delete it.

Context compaction (`compactWorkHistoryIfNeeded`) re-reads the system prompt with the **same `loopMode`** when rebuilding history, so modes never bleed into each other after compaction.

### 3. Language: guncat-ui lang (the contract the model sees = the contract we parse)

`common/GuncatUiLang.ts` is the **language core** (lexer → parser → evaluator → fence splitting) and `common/GuncatUiLibrary.ts` is the **single source of truth for the component library** (component names / groups / descriptions / **positional-argument tables**). One component table drives three things at once: the **component list in the system prompt**, the **argument mapping and type coercion during parsing**, and the **legality checks during rendering**. Because all three share the table, "what the model sees" equals "what we parse" equals "what we can draw".

The design follows OpenUI Lang in the reference project [open-intelligent-ui](https://github.com/thesysdev/openui) (see `docs/reference/openui-lang-spec.md`): **line-based statements + positional arguments + forward references**.

```text
root = Card([header, lead, kpis, chart, detail, tune])      ← line 1: the shell appears first
header = CardHeader("季度销售复盘", "2024 Q1–Q4")
$metric = "revenue"                                          ← $variable = reactive binding
lead = TextContent("全年营收 **1,284 万**, 同比增长 18.6%。")
kpis = OverviewCardBlock([kpi1, kpi2])                       ← forward reference: kpi1 is defined below
chart = BarChart(["Q1","Q2"], [s1, s2], "grouped", "季度")
s1 = Series("2023", [241, 268])
tune = Form("tune", tuneBtn, [tuneField])
tuneField = FormControl("按哪个口径看?", RadioGroup("metric", [RadioItem("营收","","revenue")], "revenue", $metric))
tuneBtn = Buttons([Button("换口径重算", Action([@ToAssistant("按客户数口径重新分析")]), "primary")])
```

**Syntax rules** (given one by one in the prompt; the model copies them)

| Rule | Description |
| --- | --- |
| Statements | Each line is `identifier = expression`; `root = Card([...])` must exist and be the first line |
| Arguments | **Positional** (order is the signature order). Write `CardHeader("标题")`, **never** `CardHeader(title: "标题")` |
| Expressions | String / number / `true`·`false` / `null` / array `[...]` / object `{key: value}` / component call / reference |
| References | Forward references allowed (hoisting); **every identifier you define must be referenced**, or it will not render |
| Operators | `+ - * / %`, `== != > < >= <=`, `&& \|\| !`, ternary `a ? b : c`, member `obj.f`, index `arr[0]` |
| Bindings | `$variable = default`; pass the `$variable` to a control's binding parameter for two-way binding |
| Built-ins | `@Count @Sum @Avg @Min @Max @Round @Abs @Floor @Ceil @Len @Join @Upper @Lower @Pct @Coalesce @Filter @Sort`, plus `@Each(arr, "item", template)` to expand item by item |
| Actions | `Action([@ToAssistant("text"), @Set($x, value), @Reset($x), @OpenUrl("https://…")])` |
| Comments | `//` or `#` line comments (stripped) |

The component library holds **70 components** in 9 groups: root and content / layout / tables and data / charts / metrics and text / card blocks / lists and follow-ups / forms / buttons and icons. The renderer provides a native ArkUI implementation for every one of them:

| Group | Components |
| --- | --- |
| Root and content | `Card` `CardHeader` `TextContent` `MarkDownRenderer` `Callout` `TextCallout` `Image` `ImageBlock` `ImageGallery` `CodeBlock` `Separator` `InlineHeader` `TagBlock` `Tag` `EntityList` |
| Layout | `SectionBlock` `SectionItem` `Tabs` `TabItem` `Accordion` `AccordionItem` `Carousel` `Steps` `StepsItem` |
| Tables and data | `Table` `Col` (columnar: each column carries its own data) |
| Charts | `BarChart` `LineChart` `AreaChart` `HorizontalBarChart` `PieChart` `RadialChart` `SingleStackedBarChart` `Series` `RadarChart` |
| Metrics and text | `Text` `BoldText` `IconText` `ImageText` `MetricIndicatorInline` `MetricIndicatorWithStrikethrough` |
| Card blocks | `SnippetCardBlock` `OverviewCardBlock` `ContextCardBlock` `CompositeCardBlock` `VisualCardBlock` (and their respective Items) |
| Lists and follow-ups | `ListBlock` `ListItem` `FollowUpBlock` `FollowUpItem` |
| Forms | `Form` `FormControl` `Input` `TextArea` `Select` `SelectItem` `DatePicker` `Slider` `RadioGroup` `RadioItem` `CheckBoxGroup` `CheckBoxItem` `SwitchGroup` `SwitchItem` `Chips` `ChipItem` `OptionCards` `OptionCard` |
| Buttons and icons | `Button` `Buttons` `IconButton` `Icon` |

**Fault tolerance and limits** (`UiLimits`): source ≤200k characters, ≤400 statements, expression nesting ≤24, arrays ≤600, child elements ≤200, copy ≤4000 characters, ≤64 bindings.

Model habits we deliberately accommodate (all of them occurred in practice and used to produce an empty shell or a vanished block):

| What the model writes | How it is handled |
| --- | --- |
| Truncated output (last line unfinished) | Unclosed brackets/strings are **auto-closed** (`UiAutoClose`), the unfinished statement is dropped, and **everything completed is kept** |
| A reference to a variable not yet defined | The value is empty for now and appears once the definition streams in (no error, no interruption) |
| A missing `root` | Fall back to "the first component statement" as the entry point; only **zero component statements** counts as a broken interface and triggers one regeneration |
| Arguments written as key/value, `CardHeader(title: "x")` | Positional arguments are the contract; key/value is not supported, and the prompt plus anti-pattern list correct the model |
| An unregistered component name (`Chart` / `markdown` / `Card2`) | **Drop that component and record a diagnostic** (keeping it would render a puzzling empty card that is harder to debug); the bottom of the interface expands "diagnostics" to show the exact name |
| A missing required argument or a type mismatch | **Do not drop the component**: numeric strings become numbers, a single value is wrapped into an array, a missing required argument gets a safe default, and the diagnostic records it (in a chat scenario "one field missing" is far better than "the whole block disappears") |
| Prose or junk lines mixed into the statements | Lines that are not of the form `identifier = expression` are silently skipped and the remaining statements render as usual |
| The same statement written twice | The later one wins (matching the reference implementation) |
| The program wrapped in a ` ```guncat-ui ` or ` ```openui-lang ` fence | Accepted just the same; fences in other languages (` ```json ` / ` ```python `) render as ordinary Markdown code blocks |

> One **deliberate deviation** from the reference implementation: when a required argument is missing, the reference implementation **drops the whole component** (using the validation error to push the model toward correctness). In a chat scenario that hides the content from the user outright, so here it renders with safe defaults + a diagnostic instead.

### 4. Rendering and streaming shape-up

```text
assistant Message.content (the whole interface program, or a ```guncat-ui fence plus surrounding prose)
  → GuncatUiParts.build(content, finalized)        // common/GuncatUiParts.ts
      ├─ TEXT segment → RichTextView (Markdown rendering)
      └─ UI segment   → GuncatUiView (@Prop programText + complete + truncated + locked + stateJson + onInteract)
```

- **From "one JSON block" to "a program"**: the old implementation delivered ` ```guncat-ui ` plus strict JSON, so a cut-off output limit made the **whole block void** (recoverable only through an extra JSON Output request). With line-based statements, truncation costs only the last unfinished statement and the **main body of the interface still renders** — auto-continue/redo drops from the main path to a fallback.
- **Width convention**: the root container of `GuncatUiView` keeps an `edge()=16vp` inset on both sides so the **text** inside the interface lines up with the answer body of the same message (RichTextView's 16vp) — otherwise interface text runs wider than the body and looks like it "overflowed to the bubble edge". **Tables deliberately do not go full-bleed** (the header fill and every column start at the far left, so being wider than the body makes the whole block look "shifted left / crooked"); only charts / images / image galleries / carousels — components that "have no left-aligned text of their own" — use `bleed(topLevel)` at the **top level** to cancel that inset and take the full width. `topLevel` in `renderNode(el, topLevel)` is `true` only for direct children of the root Card (the same components nested inside a card are not pushed out). The footer area (truncation notice / diagnostics / raw output) gets the same inset to stay left-aligned.
- **ArkUI refresh mechanics (a pitfall you must read before changing the code)**: when ArkUI re-renders, `ForEach` compares old and new keys first: **an item whose key is unchanged reuses the existing child component and does not even re-run the item builder**. "A binding value changed → re-materialize a new tree" (the materialized tree lives in the plain field `this.root`, not in observable state) can therefore only propagate through a key change. On device this showed up as a selection state that did not change after tapping `Chips` / a radio / a checkbox, becoming correct only after switching to another conversation and back (which destroys and rebuilds the component).
  The key is now a **render fingerprint**: `GuncatUiLang.elementSignature(el, values)` — a djb2 hash over `type` + sorted props + nested elements/arrays, where **bound props use their live value**, plus the live value of the element's state key (a `Chips`-style control bound by `name` keeps its selection only in state, so leaving it out would bring back the "selection does not refresh" bug). Key = `child.key + '#' + fingerprint`, so an item whose rendering really changed gets a new key and is rebuilt (live update), while an unchanged item keeps its key and is reused. `rev` / `sigTick` are only **read** inside `itemKey()` / `wake()` to register the ForEach dependency; they are not part of the key value.
  **How binding values refresh (five device rounds to pin down — read this before touching it)**: a value change re-materializes a **new tree** (`root` is `@State`). What actually makes the interface follow is **each value node repainting itself**, **not** "change the ForEach key ⇒ rebuild that item" — that route never proved reliable on this device: the `.id(rev)` trigger, reading `@State` inside a method, wrapping the whole tree in a constant-true `if`, making `root` `@State` plus reading the top-level list on the spot, and the dragged-chain fingerprint snapshot were all tried and none of them worked consistently. What does work:
  - `live(el)` (inside the view): reads `sigTick` to **register the dependency** (the read happens inside an attribute / component-argument expression, the form that is tracked), then looks the element up **by key** in `this.root` — falling back to the stale object only when the lookup fails;
  - **234 value reads** across the view are wrapped in `this.live(...)`. So during a drag each throttled refresh (`revalue()`: swap the tree + `sigTick++`) is enough for metric cards, charts and list rows to follow, and **no ForEach item is rebuilt** ⇒ the Slider being dragged is never destroyed, so **no freeze/snapshot machinery is needed** (it has been removed).
  - **Precondition (learned the hard way)**: `GuncatUiLang.assignKeys` must cover **all three** shapes that hold child elements — the `children` list, element-array props, and **single-element props** (e.g. `OverviewCardItem(top, bottom)`'s top/bottom, `FormControl`'s control). Miss the third and a batch of elements ends up with an **empty key** ⇒ `live()` cannot locate them ⇒ those nodes show stale values forever (on device 7 of 19 nodes had empty keys, which is also why chain lookups sometimes worked and sometimes did not).
  - Values baked into Records (`EntityList` rows, `Table` cells) are captured by closure from the old object, so they need `liveRow` / `liveCell` to fetch by index from the current tree.
  - **A Slider is the one exception**: its own bound `value` **does not enter the fingerprint** (a permanent exemption, not a drag-time one — a drag-time exemption changes the key the instant the drag starts and thereby triggers a rebuild). Since fingerprints are **recursive**, letting `value` in makes the key of the Slider *and every ancestor item* (`FormControl` → `SectionItem` → `SectionBlock`…) change while dragging → ForEach rebuilds those items → the Slider being dragged is destroyed and the gesture is lost (on-device symptom: tap-to-jump works, the handle does not follow). Its displayed value is `live()`'s job. Selection controls (`Chips` / radio / checkbox) must **not** be exempted, or their highlight stops refreshing.
  - Ending a drag: `End`/`Click` → `finishDrag()`; since `End` does not always arrive on device, an **idle timer** (`DRAG_IDLE_MS` = 220ms without a new `Moving` counts as release) backs it up. Do **not** attach `.onTouch` to a Slider — it interferes with touch dispatch and the control becomes "tap-to-jump only, does not follow the finger".
  **Two epochs, two jobs**: `rev` is incremented by `rebuild()`/`rematerialize()` and read by `.id()` → the whole component re-runs (each child then decides reuse vs. rebuild from its fingerprint); `sigTick` is incremented by `revalue()` **during a drag** (values only, id untouched) → it only makes children recompute fingerprints, while the frozen chain keeps keying off the snapshot, so "siblings refresh live" and "the gesture is never interrupted" hold at the same time.
  **A Slider being dragged needs special handling**: the fingerprint mechanism works by "key changed ⇒ rebuild", and a dragged Slider's `value` changes continuously, so a plain fingerprint would rebuild it and kill the gesture on the spot. Hence the **`dragFreeze` ancestor-chain fingerprint snapshot**: on `Begin`, `GuncatUiLang.pathToKey()` yields the whole `root → dragged control` chain and each element's fingerprint at that moment is snapshotted; during the drag those elements key off the snapshot — **byte-identical** to before the drag, so nothing is rebuilt. Note it must not be implemented as "return a constant fingerprint when hit": that changes the key the instant `Begin` fires, which rebuilds the item anyway (merely postponing the loss by one refresh). Freezing only the control is not enough either — an ancestor's fingerprint covers its subtree, so one changing sibling re-keys the ancestor. Release runs `finishDrag()`: drop the snapshot + `rematerialize()` (`rev` changes → the whole tree re-runs, flushing everything held back during the drag) + report state.
  Trade-offs and fallbacks: ① while dragging, changes that depend on the current value **inside** the frozen chain do not refresh live (siblings still do) and are flushed on release; ② finishing cannot rely on `SliderChangeMode.End` (it does not always arrive on device) — but it must **not** be backed up with `.onTouch` on the Slider either: on device that interferes with its touch dispatch and the control becomes "tap-to-jump only, does not follow the finger" (cannot be dragged at all). Use an **idle timer** instead: every `Moving` re-arms it, and `DRAG_IDLE_MS` (220ms) without a new `Moving` counts as release (`finishDrag` is idempotent — one gesture reports state once); ③ live refreshing during the drag is throttled to 80ms, and the numeric label inside the frozen item repaints on its own by reading `sigTick` in `sliderValueText()` (ArkUI's per-element dependency tracking, the same mechanism that already drives collapse/tabs in this file); ④ **safety check**: if `pathToKey()` cannot find the `root → control` chain when the drag starts (a tree shape beyond expectations), live refreshing during the drag is switched off and it falls back to "refresh on release" — better to refresh less than to rebuild the Slider being dragged because the freeze did not take effect.
- **ArkUI layout squeezing (a pitfall)**: inside a `Row`, a "fixed-size element + `layoutWeight` text" combination sometimes measures the fixed-size element's layout width as **0**, so the text shifts left and overlaps it (on-device screenshot: a small round icon sitting on the first character of the title). Every such combination therefore has three safeguards: ① the fixed-size element gets `.flexShrink(0)` + `.constraintSize({minWidth, minHeight})`; ② spacing does not come from `Row({space})` but from an explicit `.margin({left})` on the text column; ③ icon-like elements **encapsulate all three inside the component** (`GuncatUiIcon` / `GuncatUiChevron` / `GuncatUiIconBadge`), so every usage gets them automatically instead of each call site having to remember. Hardened so far: `IconText`, `ImageText`, `Callout`, `ListBlock(variant=image)`, `SwitchGroup`, `EntityList`, the Slider label row, chart legend dots, and ordered-list number dots.
- **Chart drawing: `Path.commands` is px while other attributes are vp (read before touching charts)**: in ArkUI, `Shape`'s **layout** (width/height) and attributes such as `strokeWidth` are in **vp**, while `Path.commands` path commands are in **physical pixels (px)** ([confirmed on the official forum](https://bbs.itying.com/topic/682aec1c062dc60098c28a3c)). Two unit systems inside one component produce "completely wrong proportions", and all three on-device symptoms came from it:
  - line/pie charts with coordinates written in vp → drawn at about 1/3 scale, huddled in the top-left with a large empty box (the screenshot showed "line chart too small with a big empty area below");
  - a radial chart radius of 28 (written in vp) = 28px while the 8vp ring width ≈ 26px → the stroke is thicker than the radius, becoming a solid blob with the percentage pushed outside the ring;
  - using `viewPort` to scale makes the shape size right but does not scale `strokeWidth` → the pie chart drew a 100vp-wide giant ring that the container clipped into a half circle.
  The conventions now:
  - geometry is written **entirely in vp** (readable, unit-testable) and multiplied by `UiChartGeom.unit` centrally **when serializing to a path string** (= `vp2px(1)`, set by `GuncatUiChartUnit.ensure()` in each chart's `aboutToAppear`); attributes such as `strokeWidth` keep their vp value and **must not be multiplied**;
  - **no `viewPort`**: fixed-size charts (pie / donut / radial / radar) use a fixed vp box with absolute coordinates; the width-adaptive line/area charts measure their width with `onAreaChange` (self-calibrating the unit from "measured height ÷ known vp height", so it does not depend on whether `Area` reports vp or px) and take an explicit height from `chartHeight` (160vp by default) instead of deriving it with `aspectRatio`;
  - the pie uses a **filled wedge** (`wedgeAt`) rather than filling with strokeWidth; the donut strokes an arc (`arcAt`) at the mid-radius with the ring width as the stroke width; the radial uses a `circleAt` track plus an `arcAt` progress arc;
  - geometry lives in `common/GuncatUiPaint.ts` (pure logic, unit-testable): `linePath/areaPath/gridPaths/points` accept a `UiBox`, plus `arcAt/wedgeAt/circleAt`; `UiChartGeom.n()` is the single unit-conversion point.
- **Local tuning does not touch the scroll position**: interface callbacks come in two kinds — `kind='action'` (the model must recompute) appends a user message and scrolls to the bottom; `kind='state'` (drag / toggle / fill in a form) **neither re-renders the page nor scrolls** (`ChatViewModel.persistUiState()` deliberately does not call `notifyUIChange()`, and `ChatPage` only does `refreshTick++` / `scrollToBottomDelayed()` for `action`), otherwise the page gets yanked to the bottom while the user is operating inside a card.
- **Output-shape discipline**: the prompt forbids the model from writing text outside the program (see the same-named bullet in the "Interactive mode" section above); the design only constrains via the prompt and **never deletes text the model already wrote** — that would be losing content, and "content vanishing into thin air" is exactly the experience this project avoids.
- **Progressive rendering**: `GuncatUiParts.build()` re-parses and re-materializes the whole tree every time new text arrives; the first line `root = Card([...])` makes the shell appear and later statements fill it in one by one. While unfinished, `complete=false` and controls are greyed out.
- **Text and unfenced programs coexist**: `GuncatUiParts` first uses the component library to decide whether a body of text is an "interface program" (requiring at least 2 lines of `identifier = componentName(...)`, or 1 line shaped like `root = ...`); if so, a lead-in **before** the program is kept as a text segment. That way both "the model wrote 1–2 sentences of lead-in plus a program" and "the whole message is the program" render correctly.
- **Ordinary answers must still display (a past incident)**: an early version of `ChatBubbleView.buildAIContent()` skipped the whole render when "the message has no guncat-ui fence", so in chat mode **the answer body of any message without an interface showed not a single character**. Both views now guarantee that `GuncatUiParts.build()` **always emits at least one text segment**, and the view side keeps the `uiSegs.length === 0 → RichTextView` fallback branch.
- **Truncated output still ends gracefully**: `GuncatUiParts.build(content, finalized)` uses `finalized` (from `!isStreaming`) to tell "still writing" from "finished but never closed": the latter marks `truncated` and the bottom of the interface shows "界面未写完，以上为已生成的部分" instead of spinning forever.
- **Repair (fallback)**: at the end of a turn, if the last assistant message has **no renderable interface at all** (`GuncatUiParts.needsRepair` = the text looks like a program but `root` is empty), the main loop sends one repair request through `AgentLoopService.generateUiProgram()` **without tools and at a low reasoning tier**, asking the model for a complete program again; once it arrives, `isUsableProgram` validates it before it is appended as a new message (marked "（界面已重新生成）"). At most `UI_CONTINUE_MAX_ROUNDS = 2` rounds; if the repair also fails, it falls back to "text continuation". **Note that the repair request no longer uses `response_format: json_object`** — JSON mode pushes the model into thinking in terms of "one JSON object" and actually prevents it from writing a multi-statement structure.
- **Raw output and diagnostics are always available**: the bottom of the interface has a "view raw output" toggle (clickable whenever source exists, with forced character wrapping and scrolling); when parsing produced diagnostics (unknown component / missing argument) an extra "diagnostics · N" collapsible panel appears. The user can see exactly what the model wrote.
- **When to rebuild**: `WorkTurnView` / `ChatBubbleView` rebuild their segments only when the answer body changes (an identical body returns immediately, avoiding a 33ms busy loop); `GuncatUiView` receives the source through `@Prop @Watch('onProgramChanged') programText` — **a string, not a nested object** (string `@Prop` change notification is the most reliable thing in ArkUI, while a nested object goes through a deep copy that is both slow and prone to losing state).
- **Two kinds of key, two refresh rhythms** (both learned the hard way):
  - **Text segments** (the body before/after a card) bump their own `renderKey` when their content changes, forcing that `RichTextView` to rebuild. Otherwise on device the body after a card shows only one or two characters until a refresh (the rendering library reused the same instance and never re-laid-out the new content).
  - **Interface segment keys contain no program text**, only semantics (`uiSegsShape()` = each segment's type + closed + unfinished). Putting the source into the key would mean destroying and rebuilding the whole interface every 33ms while streaming → flicker plus a text input losing focus. Likewise, `ForEach` keys inside `GuncatUiView` are the **element's own stable identity** (the variable name for named statements, the position for anonymous inline elements) **plus that subtree's render fingerprint** (early versions appended the global `rev`, which rebuilt every child at once — see "ArkUI refresh mechanics" above).
- **Binding changes propagate through an `@State` wake-up plus a fingerprint key change**: the materialized element tree lives in the plain field `this.root` (not observable state), so assigning to `@State rev` / `sigTick` starts the re-render; `itemKey()` / `wake()` each read them (only to register the dependency — they are not part of the key), and re-running the key function lets each child decide "reuse or rebuild" from its new fingerprint.
- **Self-healing finalization**: on device, the "stream ends → the component rebuilds with finished semantics" step may not fire (`@Watch` / parent property updates are unreliable in the real-device timeline). Both views therefore carry their own `startUiSettleTimer()`: it samples the message body every 250ms, treats two identical samples in a row as the end of output, rebuilds the segments in place with `finalized`, falls back after an 8-second timeout, and cleans up in `aboutToDisappear`. **A component finalizes itself and depends on no external notification.**
- **Maintenance note**: render data derived inside a component always uses arrays/primitive `@State` with whole-value assignment; when you need to "force a child component to re-render", change its key, but **the key must bind semantics, not a refresh counter**.
- **Where an interface belongs**: interactive mode goes through `ChatPage.buildWorkTimeline()` → `WorkTurnView` (the shared timeline with thinking/tool rows), chat mode goes through `ChatBubbleView`, and both paths wire up `GuncatUiView` (in chat mode an interface can be tuned locally, but an action that "reports back to the model" tells you to switch to interactive mode).

### 5. Interaction loop (local recompute + report back to the model)

Interactions inside an interface come in two kinds, and this is the core design of the whole feature:

```text
A. Local interaction (no request; the interface recomputes immediately)
   declare a $variable → bind a control to it → the user drags/picks
   → GuncatUiState.set() → GuncatUiLang.render(program, bindings) re-materializes the whole tree
   → $variables in expressions are recomputed with the new values ("金额 " + $amount + " 万" updates at once)
   → GuncatUiEvent{kind:'state'} → only persist the binding values, no new turn

B. Report back to the assistant (send a message, start a new turn)
   Button/Action([@ToAssistant("按 30 天口径重算")]) or a form submit
   → GuncatUiEvent{kind:'action', message, stateJson}
   → ChatBubbleView/WorkTurnView.onUiInteract(messageId, ev)
   → ChatViewModel.sendUiInteraction(messageId, ev)
       ├─ first write the latest binding values back into that message (trailer) — the model sees "settings + request"
       ├─ verify messageId === the last assistant message (older interfaces are archived; notify only, do not send)
       ├─ loop idle → executeWorkLoop(conv) recomputes and re-renders the interface immediately
       └─ loop running → push into workSteerQueue and inject as a "user supplement" after this turn's tools finish
```

- **Form submit**: `GuncatUiRuntime.formMessage()` builds an item-by-item list of every `FormControl`'s label and current value, prefixed with "【交互界面回传】<interface title>"; the submit button's own `@ToAssistant` text is appended after it (as in "… / - 口径 = customers / 换口径重算").
- **A button with no action** is equivalent to sending the button's text to the assistant (matching the reference implementation).
- **Choosing the state key**: if a control has a binding (its `value` received `$x`) then `$x` is the state key, otherwise it falls back to the control's own `name`; `GuncatUiRuntime.stateKeyOf()` unifies this rule.
- **State persists with the message**: binding values are appended to the end of the message body as `]]>guncat-ui:state` plus one line of JSON (matching the reference implementation's `]]>openui:context`). `GuncatUiParts` / `plainSummary` strip it first, so the user never sees it.
- **Translating it into plain language for the next turn**: when assembling loop history, `ChatViewModel.assistantLoopContent()` replaces that trailer with `(用户在当前交互界面上的设置: 金额=45; 口径=customers。)` (labels come from `FormControl.label` / `Slider.label`, so the model sees the same words the user saw). It **also removes the trailer itself** — it is noise to the model.
- **Greying-out rule**: `vm.pendingUiMessageId` gives the id of "the message that is currently interactive"; every other interface (earlier turns, in-flight intermediate states) has `locked=true`; `GuncatUiView.interactive() = complete && !locked` and every control and button uses it uniformly.

### 6. Extension and maintenance entry points

| What you want to change | Where to change it |
| --- | --- |
| Add a component | Add one entry to `definitions()` in `common/GuncatUiLibrary.ts` (name/group/description/positional-argument table) → add a dispatch branch in `views/GuncatUiView.ets`'s `renderNode()` plus the matching `@Builder`. **The prompt follows automatically** (the component list is generated from this table) |
| Change the language syntax | `common/GuncatUiLang.ts` (`UiLexer` lexing / `UiParser` parsing / `GuncatUiMaterializer` evaluation) + `GuncatUiPrompt.SYNTAX` (the syntax description the model gets); the two must stay in sync |
| Change interface copy / guidance | `GuncatUiPrompt`'s `SYNTAX` / `RICHNESS` (richness and component-selection priority) / `INTERACTION` / `STREAMING` / `EXAMPLES` / `ANTI_PATTERNS` / `INTERACTIVE_DUTY` |
| Add a chart | `common/GuncatUiPaint.ts` (pure geometry, unit-testable) + `views/GuncatUiCharts.ets` (declarative Shape/Path or Row/Column) → register it in `GuncatUiLibrary` and dispatch it in `GuncatUiView.buildChart()` |
| Add a control | Register it in `GuncatUiLibrary` + `isControl()` / `buildControl()` in `views/GuncatUiView.ets`; register binding parameters with `bind()` (the parser records variable names and the renderer reads/writes state through them) |
| Add an icon | The `glyph()` map in `views/GuncatUiIcons.ets` (**use Unicode glyphs, not SymbolGlyph**: the set of available SymbolGlyph names differs across ROMs, and a missing one renders blank and fails silently). The one exception is the collapse chevron `GuncatUiChevron`: characters like `⌃`/`⌄` vary wildly in size and baseline across fonts — on device it looked like "a tiny tip in the bottom-right that isn't aligned" — so that one deliberately uses `sys.symbol.chevron_up/down` |
| Interactive-mode-only copy | `ChatViewModel`'s `loopModeTitle` / `loopModeHint` / `loopInputPlaceholder` / `loopEmptyDescription` / `loopToolLabel` |
| Mode constants | `Constants.INTERACTIVE_AGENT_ID` / `MODE_*` / `UI_BLOCK_LANG` / `UI_CONTINUE_MESSAGE` / `UI_CONTINUE_MAX_ROUNDS` |

> **Regression guardrails (three layers, none optional)**
> 1. Pure-logic checks: `cd test/guncat-harness && node setup.mjs && node test-core.mjs` (479 checks covering guncat-ui lang lexing/parsing/forward references/streaming auto-close/binding recompute/`@Each`/built-in functions/`Action`/segment splitting/state serialization/chart geometry/component library and prompt).
> 2. Service-layer type check: `node check-setup.mjs && npx tsc -p check/tsconfig.json`.
> 3. **Real ArkTS compile**: `powershell -ExecutionPolicy Bypass -File tools/build-check.ps1` (drives DevEco's bundled hvigor).
> Layer 3 cannot be skipped: ArkUI has a set of rules **only the compiler knows** — a `@Builder` body may not declare local variables, a custom component's property name may not collide with a built-in (`size` / `scale`), and a `@Prop` null needs an explicit union type. None of these are detectable in the Node-side harness (the harness only covers the pure TS under `common/**` and `service/**` and does not parse `.ets`).

## Build requirements

- DevEco Studio 6.0.1 or a compatible version
- HarmonyOS SDK API 24 (`6.1.1`)
- A HarmonyOS phone

Open the project in DevEco Studio, configure signing, and run the `entry` module. Example command-line build:

```bash
hvigorw --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap
```

### Build steps

1. Clone or download the project.
2. Open the `GuncatAI_HMOS-APP` directory in DevEco Studio.
3. Install and select HarmonyOS SDK API 24.
4. Configure debug or release signing.
5. Connect a HarmonyOS device.
6. Run the `entry` module or build the HAP with the command above.

## Configuration

Multiple API profiles can be saved and switched in the app:

1. Integration mode (`openai-completions` / `openai-responses` / `anthropic-messages`)
2. Base URL
3. API Key
4. Model
5. Optional temperature, Top P, and maximum output tokens
6. Extra request-body fields

Common compatible endpoints:

- DeepSeek Responses: `https://api.deepseek.com`
- DeepSeek Anthropic: `https://api.deepseek.com/anthropic`, or simply `https://api.deepseek.com` (the app appends `/anthropic/v1/messages` automatically)
- Volcengine Ark Responses: `https://ark.cn-beijing.volces.com/api/v3`
- Anthropic Messages: `https://api.anthropic.com/v1`

Multimodal pre-parsing has a separate model, endpoint, and API key configuration.

## Usage guide

### Basic chat

1. Open Settings after the first launch.
2. Create or select an API profile and enter the integration mode, Base URL, API key, and model.
3. Select an agent from the drawer.
4. Enter and send a message.

### Adding images or files

1. Tap the attachment button beside the editor.
2. Select content from the photo or document picker.
3. Wait for pre-parsing; when pre-parsing is disabled, attachments are passed directly to a compatible multimodal endpoint.
4. Review pending attachments and explicitly tap Send.

You can also select content in Gallery or a file manager and choose Guncat Work from the system share sheet. The app stages the items as attachments and does not submit a request automatically; if Work Mode is active at the time, the shared files are also copied into the sandbox workspace so tasks can read them.

#### Attachment strategy

- OpenAI Completions: small images are inlined with `image_url`; large images are uploaded through the Files API and referenced as `file` + `file_id`; documents use `file_url`.
- Anthropic Messages: small images are inlined as base64 `image` content blocks; large images are uploaded through the Files API and referenced as `source.type = file` + `file_id`; documents are sent as `document` blocks.
- OpenAI Responses:
  - Small images (≤4MB): sent inline as Base64.
  - Large images (>4MB): uploaded through the Files API and referenced as `input_image.file_id`.
  - Documents: uploaded through the Files API and referenced as `input_file.file_id`, or inlined with `input_file.file_data`.
  - If an upload fails, the app automatically falls back to Base64.
- If a provider does not support a particular image/document block, the server returns an error; the app displays it instead of silently dropping the attachment.

### Deep thinking

- OpenAI Completions: off sends `thinking: { "type": "disabled" }`; on sends `thinking: { "type": "enabled" }` plus `reasoning_effort: "high"`.
- Anthropic Messages: off sends `thinking: { "type": "disabled" }`; on sends `thinking: { "type": "enabled" }` plus `output_config: { "effort": "high" }`.
- OpenAI Responses: on sends `reasoning: { "effort": "high" }`; off sends `reasoning: { "effort": "none" }`.
- New conversations reset the toggle by agent name: off in Efficiency Mode, on in Expert Mode.

### Work mode

1. Tap the 🛠 "Work Mode" entry at the top of the drawer; the page title and empty state switch to work mode.
2. Use the workspace panel's "Upload" to add files (or the camera button — photos go straight into the workspace).
3. Describe the task in the editor; for complex tasks the agent first builds a task checklist, then executes it step by step with tool calls visible in the timeline.
4. Deliverables come out in phone-readable formats: reports→`docx`, tables→`xlsx`, presentations→`pptx` (themes, charts, and editing of existing PPTs are supported; the agent automatically loads the built-in PPT skill and follows its guidelines).
5. Tap any tool step to expand its arguments and results; "Export" packages the whole workspace into a `.zip`.
6. When finished, the agent outputs a detailed summary (including produced file paths); switching to another agent exits work mode — the work conversation and workspace files are preserved.

### Interactive mode (Intelligent UI)

1. In the sidebar's "Agent Mode" group, tap ✦ "Interactive Mode" (right below "Work Mode").
2. The model pill at the top switches models and, under "capability presets", picks the **thinking tier**: 均衡(High) / 快速(Low) / 关闭(Off). Interactive mode has no 极高(Max) (the deliverable is an interface, so long thinking pays off little), and choosing "Off" makes answers faster; the tier is saved separately from work mode's and the two do not affect each other.
3. Just ask normally — e.g. "work out the monthly payment on a 300k mortgage at different rates", "compare the returns of these three plans and let me tune the parameters", or "turn this data into a table I can filter".
4. Instead of a long text answer, the agent **emits an interface program**, which the app renders as a native interface: headers/body text, charts (bar / line / area / horizontal bar / pie-donut / radial / radar / stacked bar), tables, metric cards, image galleries, tabs / accordions / steps, and the full set of form controls.
5. **Local interaction takes effect immediately**: drag a slider, flip a switch, pick an option, or fill a text input — a `$variable` in an expression is recomputed with the new value right away and the interface (charts and number copy included) refreshes with it, **without a request and without waiting for the model**.
6. **Tap a button when a recompute is needed**: a button such as "recompute with another basis" packs your settings + your request into one message back to the agent, which immediately produces the **complete updated interface**; submitting a form carries every field value along.
7. While it generates, the interface **shapes up progressively** (the first line `root = Card([...])` makes the shell appear and later statements fill it in) and controls are greyed out until it is finished; if the output is truncated, the completed part still renders, with "界面未写完" noted at the bottom.
8. Only the newest interface is interactive (older ones are greyed out and archived) so you cannot edit stale parameters; the parameters you tuned are saved with the message, surviving scrolling, conversation switches and restarts, and they are reported to the model on the next turn.
9. Need materials? Same as work mode: upload files through the pill's "Interactive UI" panel (they land in the sandbox workspace) and the agent can read, compute, and chart them with the same 45 tools.
10. Need a real file (Word / Excel / PPT)? Just ask — the agent writes it out as usual; interactive mode does not remove file capability.
11. To check what the model actually wrote, the "查看原始输出" (view raw output) control at the bottom expands the source; when parsing produced diagnostics it also shows "诊断 · N 条" (N diagnostics).

### Read-aloud

1. Tap the read-aloud action on an assistant message.
2. Pause/resume, change speed, or select a voice from the floating control.
3. Drag the progress control to continue from the corresponding text position.
4. Drag an empty area of the control to reposition it.
5. Tap Close to end reading and dismiss the control.

### Conversation and message actions

- Create, switch, and delete conversations from the drawer.
- Copy assistant message content.
- Regenerate an assistant response.
- Tap images for full-screen preview.
- Stop the active request while it is generating.

## Permissions and system capabilities

- `ohos.permission.INTERNET`: model API access.
- `ohos.permission.MICROPHONE`: voice input.
- `ohos.permission.KEEP_BACKGROUND_RUNNING`: continuous background audio for read-aloud.
- Work mode: all file I/O happens inside the app sandbox (`filesDir/workspaces/`); picking/saving files uses system safe components (DocumentViewPicker) — **no new permissions**.
- Share Kit: receiving images and files from other apps.
- CoreSpeechKit: text-to-speech and speech recognition.
- AVSession Kit: background media session.
- ArkData Preferences: local configuration persistence; conversation history is stored in `filesDir/guncat_conversations.json`.

## Privacy

- API keys and app settings are stored in the app's local sandbox.
- Chats and attachments are sent only to model services configured by the user.
- Items received from the system share sheet are never sent automatically; the user must tap Send.
- Original attachments are not copied into permanent app storage.
- Requests use HTTPS. Data-processing policies still depend on the configured model provider.

- **Live refresh while dragging a bound control (same-day item 13)**: an on-device defect — dragging a `Slider` two-way bound to `$amount` moved the handle, but every node referencing that variable (`Text`, metric cards, chart series) **did not refresh at all** until you switched to another conversation and back (remounting the component). It came down to three things, all of which were needed: ① **`assignKeys` only walked the `children` list and element-array props and missed single-element props** (`OverviewCardItem(top, bottom)`, `FormControl(control)`…) → **7 of 19 nodes had an empty key** on device → every "locate an element by key" mechanism worked only sometimes (that is why `frz` was 5 one round and 0 the next); ② making the interface follow **cannot rely on "change the ForEach key ⇒ rebuild that item"** (the `.id(rev)` trigger, reading `@State` inside a method, wrapping the whole tree in a constant-true `if`, making `root` `@State` with a fresh top-level list, and the dragged-chain fingerprint snapshot were all tried and none proved stable on this device) — it relies on **each value node repainting itself**: `live(el)` reads `sigTick` to register the dependency and looks the element up by key in the current tree, and 234 value reads across the view are wrapped in it; ③ for the **Slider itself** the opposite is required — fingerprints are recursive, so letting its `value` in re-keys the Slider *and every ancestor item* on every drag step and the gesture dies instantly, hence the Slider's bound value and state value are **permanently exempt** from the fingerprint. Also, `SliderChangeMode.End` does not always arrive on device, so release is backed up by a 220ms **idle timer** (`End`/`Click` are signals too, and `finishDrag` is idempotent); do **not** attach `.onTouch` to a Slider — it interferes with touch dispatch and the control becomes "tap-to-jump only, does not follow the finger". 18 new assertions, unit tests 479 → 497.

## Version 6.3.0 (Interactive Mode · Intelligent UI)

> Interactive mode was reworked **twice** within 6.3.0: the initial release (a strict JSON DSL), then a **full rewrite** to the declarative `guncat-ui lang`. Both belong to 6.3.0 — there is **no 6.4.0**, and the app version stays `6.3.0` / versionCode 710. The entries below are merged newest-first.

### Rewrite: guncat-ui lang (aligned with open-intelligent-ui)

> The interactive-mode delivery format was **rewritten from scratch** — from "one strict JSON object" to a declarative interface language (`guncat-ui lang`, modelled on the OpenUI Lang design of [open-intelligent-ui](https://github.com/thesysdev/openui)) — and the renderer grew from 11 element kinds to 70 native components. The old `common/GuncatUiSpec.ts` (JSON DSL + parser + salvage chain + JSON Output repair) was deleted outright.

- **Delivery format: JSON → line-based statements.** The old format was one big strict JSON document: cut off by the output limit and the **whole block was void** (the only recovery was a separate `response_format: json_object` request to redo it). In the new format every statement stands on its own line: `root = Card([header, chart])` / `header = CardHeader("标题")` / `chart = BarChart([...], [s1], "grouped")`. A truncation only loses the **last unfinished statement**; everything before it is kept and renders as usual — "repair" drops from the main path to a fallback.
- **70 native components** (9 groups): `Card` `CardHeader` `TextContent` `MarkDownRenderer` `Callout` `Image` `ImageGallery` `CodeBlock` `TagBlock` `EntityList` / `SectionBlock` `Tabs` `Accordion` `Carousel` `Steps` / `Table`+`Col` / 8 chart kinds (bar · line · area · horizontal bar · pie/donut · radial · radar · stacked bar) / metrics and text / 5 card-block families / lists and follow-ups / the full set of form controls / buttons and icons. Every chart is drawn on the spot with declarative `Shape`+`Path` and `Row`/`Column` — no chart library, no image files.
- **Two-way binding (`$variable`) — the key to "it's tunable"**: bind a control to a `$variable` and, when the user drags or toggles it, the interface **immediately re-evaluates the whole tree with the new value** (`"金额 " + $amount + " 万"` changes), without a request and without waiting for the model. When the model needs to change the data or the algorithm, the user taps a button (`Action([@ToAssistant("…")])`) or submits a form, which packs the settings + the request into one message back to the model; the model then produces the **complete updated interface**.
- **State persists with the message**: the parameters the user tuned are stored in that message as a `]]>guncat-ui:state` trailer (surviving scrolling / conversation switches / restarts), and before the next request that trailer is translated into one plain sentence (`(用户在当前交互界面上的设置: 金额=45; 口径=customers。)`) for the model — the same approach as the reference project's `]]>openui:context` rewrite.
- **Answers no longer have a "card shell"**: the old implementation wrapped the interface in a card with a border, a shadow, and a status badge (`可交互`/`生成中…`), so it looked like "a widget embedded in the chat". `Card` is now just a vertical container with 16 spacing; the rhythm comes from spacing and each component's own padding — the most visible improvement of this change.
- **Component library as the single source of truth**: one table in `common/GuncatUiLibrary.ts` generates the **component list in the system prompt**, the **argument mapping and type coercion at parse time**, and the **legality checks at render time**, so the three can no longer drift apart.
- **Prompt rewrite**: `common/GuncatUiPrompt.ts` provides the syntax rules, the component list, the interaction loop (local interaction vs. reporting back to the model), the **output-order discipline** (`root` first line → `$variable` → blocks → data details, because order decides how streaming feels), the **output-shape discipline** (no text outside the program + ❌/✅ contrast examples), 3 complete examples, and a list of common mistakes.
- **Fault-tolerance policy (a deliberate deviation from the reference implementation)**: unclosed brackets/strings are auto-closed; a reference to a not-yet-defined variable is simply empty for now; **unknown component names are dropped with a diagnostic**; but a missing required argument or a type mismatch **no longer drops the component** (it renders with safe defaults + a diagnostic) — in a chat scenario "one field missing" is far better than "the whole block disappears".
- **Three pre-existing defects fixed along the way**:
  1. `ChatBubbleView.buildAIContent()` used to skip the whole render when "the message has no guncat-ui fence", which meant **in chat mode the answer body of any message without an interface showed not a single character** (now backed by an `uiSegs.length === 0 → RichTextView` fallback, plus a guarantee that `GuncatUiParts` always emits at least one text segment);
  2. interface binding values used to live only inside the component and were **never persisted** (lost on scroll / conversation switch); they now persist with the message and are reported back to the model;
  3. "Regenerate" tested the mode with the string literal `conv.mode === 'work'`, so interactive mode did not go through the Agent Loop; at the same time **session-title generation**, **copy as plain text**, and **export to Word** all carried the raw interface source out. All four now go through `GuncatUiParts.plainSummary()` (body text + the text the user can actually see inside the interface, with tables restored as Markdown tables).
- **A third regression guardrail**: `tools/build-check.ps1` runs a **real ArkTS compile** through DevEco's bundled hvigor. The Node-side harness only covers the pure TS under `common/**` and `service/**`, so it cannot catch ArkUI compile-time rules (`@Builder` bodies may not declare local variables; custom-component property names may not collide with built-ins such as `size`/`scale`; a `@Prop` null needs an explicit union type) — this layer is what caught 8 compile errors during the rewrite. Pure-logic checks grew from 376 to **430**.
- Two implementation-level specs for the reference project and the language live in `docs/reference/` (`open-intelligent-ui-spec.md`, `openui-lang-spec.md`).
- **Look-and-feel fix (same day)**: ① interface text gets a 16vp inset on both sides so it lines up with the answer body (tables share the text width; charts/images/carousels go full-bleed at the top level); ② the prompt now demands **"no text outside the program"** — it previously allowed 1–2 sentences of lead-in, which in practice produced a repetitive, loose chat bubble next to the interface; openings/transitions/summaries are now banned and text must live inside the interface as components, with ❌/✅ contrast examples in the prompt. Pure-logic checks 430 → 433.
- **Interaction fixes (same-day item 2)**: ① the `SectionBlock` / `Accordion` chevron switches to the system vector symbol `sys.symbol.chevron_up/down` (the Unicode `⌃`/`⌄` glyphs differ wildly in size and baseline across fonts — on device it looked like "a tiny tip in the bottom-right that isn't aligned with the title"), vertically centred with the title; ② **tables are no longer full-bleed** (the header fill made the whole block look shifted left); ③ fixed the on-device **selection state not refreshing after a tap** — the root cause is that ArkUI's `ForEach` reuses child components directly when keys are unchanged and does not even re-run the item builder, so every `ForEach` key inside `GuncatUiView` now carries the page version `rev`; the price is that a Slider only re-materializes on release (rebuilding mid-drag destroys the component being dragged and the gesture is lost); ④ **operating inside a card no longer jerks the view to the bottom** — local tuning (`kind='state'`) neither re-renders the page nor scrolls, and only an `action` that needs the model appends a message and scrolls down.
- **Chart fixes (same-day item 3)**: three on-device chart rendering problems fixed from screenshots; the **shared root cause is that ArkUI's `Path.commands` is in physical pixels (px) while component width/height and `strokeWidth` are in vp** (two unit systems inside one component). ① **Line chart too small with a tall, empty box**: writing coordinates in vp drew only about 1/3 scale → measure the width via `onAreaChange` and convert units centrally with `UiChartGeom.unit` (= `vp2px(1)`) when serializing to px; the height is now given explicitly as 160vp instead of being derived with `aspectRatio`; ② **Pie chart cut off** (sliced in half): `viewPort` scales the content but not `strokeWidth`, so `strokeWidth(100)` drew a 100vp-wide giant ring → replaced with a **filled wedge** (`wedgeAt`); ③ **Radial chart proportions wrong** (a small fat blob with the number pushed outside): radius 28 (written in vp) is 28px while the 8vp ring width is ≈26px, i.e. the stroke is thicker than the radius → absolute coordinates + unit conversion, ring radius 28vp / ring width 8vp, percentage centred inside. "`commands` is px, everything else is vp" and "do not use `viewPort`" are now hard conventions (see the architecture section). Pure-logic checks 443 → 448.
- **Thinking-effort tiers (same-day item 4)**: interactive mode's "capability presets" changed from 极高(Max)/均衡(High)/快速(Low) to **均衡(High)/快速(Low)/关闭(Off)** — `max` is gone (interactive mode delivers an interface, so long thinking has little payoff) and Off is new (faster answers). The two modes **persist their tiers separately and do not affect each other** (new key `guncat_interactive_effort`); work mode keeps 极高/均衡/快速. "Off" does not touch the global `thinkingEnabled`; it is applied when the request is sent, through three mode-aware getters (`loopEffort` / `loopEffortForRequest` / `loopThinkingEnabled`), so the service layer needed no change; subagents and context compaction in interactive mode follow the same tier.
- **Prompt "richness" tuning (same-day item 5)**: a new `GuncatUiPrompt.RICHNESS` section (~3.3k characters) pushes the model away from "a paragraph plus a table" toward richer component compositions: a **component-selection priority table** (what you want to express → prefer → do not degrade to, covering dozens of chart/card/structural/action alternatives), a **layered recipe** (header → key metrics → visualization → detail → actions, typically 8–14 components), **anti-padding** (never say the same data three times; metric cards, charts, and tables must complement each other), and a **"fails vs. passes" contrast example** for the same data set. Related changes: `STREAMING` drops "fewer elements is better"; `ANTI_PATTERNS` gains three entries (lazy text+table combination / stuffing structured metrics into prose / duplicating data for richness); `INTERACTIVE_DUTY` gains "lean toward richer by default"; `REPAIR_*` moves from "3–5 elements" to requiring layering and charts. 17 new prompt assertions; pure-logic checks 448 → 465.
- **Activity collapsible bar (same-day item 6)**: in interactive mode the **thinking and all tool calls** that precede the answer collapse after the answer starts streaming into **one** bar reading「✓ 已完成 · 思考 + 3 个工具 · 12.4s」 (tap to see the full thinking and tool IO). It stays expanded before the answer so progress is visible; the open/closed state is purely derived (`activityOpenNow()`), and once the user taps it, it is entirely under their control; the title/spinner come from `activityRunning()`, so "done" never appears while work is still running. Work mode is unaffected.
- **Activity bar merging (same-day item 7)**: one user task often runs several rounds, and there used to be **one bar per round** (on device this showed four stacked "已完成" bars). They now merge **per turn**: only the last message of a turn renders the bar, earlier rounds render only their body (and are skipped entirely when they have none), and expanding shows the whole turn's activity (earlier rounds as a read-only summary). The merge is **render-layer only** — one assistant message per round is a fixed part of the Agent Loop (the next request's history is rebuilt from `conv.messages`, and an assistant message must keep its `toolCalls` together), so merging the data would make the model see "one assistant message that called every tool at once". A new "stopped" state (`Constants.WORK_STOPPED_NOTE`, shared by producer and consumer) keeps a manually stopped turn from claiming "已完成".
- **Follow-up suggestions deprecated (same-day item 8)**: user feedback: they dislike a set of "you might also want to ask" follow-ups (`FollowUpBlock` / q1·q2·q3) hanging at the end of every card. The prompt now converges on "only concrete actions directly related to the current data" (`Buttons` / `OptionCards`, 1–2 of them) in 8 places: the syntax section, the richness priority table and layered recipe, the anti-pattern list, example 2, `INTERACTIVE_DUTY`, both repair prompts, and a **not recommended** note in the component list. The components stay in the registry — removing them would turn already-generated follow-up blocks in past messages into "unknown component" diagnostics. 8 new assertions; pure-logic checks 465 → 473.
- **Per-round thinking collapsed by default (same-day item 9)**: once the bars were merged, expanding one spread **every** round's thinking text out at once — a wall of text. Each round now gets its own「💡 思考 ⌄」sub-row, **all collapsed by default** (`expandedThinkingId` acts as an accordion, only one open at a time; the running round shows its latest sentence as a marquee in the title row, which does not count as expanding). The `ForEach` key for earlier rounds encodes the expansion slot (`'pm' + id + '#' + slot`) — ArkUI's `ForEach` reuses child components and skips the item builder when keys are unchanged, so the expansion state must be part of the key to rebuild reliably.
- **Charts no longer full-bleed (same-day item 10)**: on-device feedback that "some charts are shifted left, like the tables used to be". The cause: **top-level charts** go through `bleed()` (negative margins, 16vp×2 wider than text) while charts nested in a SectionBlock/Tabs have `topLevel=false` and are not bled — so within one screen the chart's left edge wandered, which is exactly the "sometimes". Charts now share the text width like tables (`bleed` is reserved for the purely visual image / image gallery / carousel, since the user had explicitly said "it's fine for the other components to be wider"). The line/area chart's left padding was also cut from 34vp to 12vp: this project **draws no y-axis tick text** (the extremes appear on their own line below), so 34vp of left whitespace was just a big blank area on device with the plot pushed right; 12/8 is nearly symmetric. 1 new assertion; pure-logic checks 473 → 474.
- **Button styling unified (same-day item 11)**: user feedback that "the dark-blue background with white text is ugly". Button styling now lives in `GuncatUiView`'s `buttonBg` / `buttonTextColor` / `buttonBorderColor`:
  - `primary` = `brand_light` background + `brand` text (the same language as the "Interactive UI" pill and the "Preview/Share" buttons);
  - `secondary` = `raised_surface` background + 1px `divider` border + primary text colour (**the border is required**: in dark mode `raised_surface` equals the card background, so without a border the button is invisible);
  - `destructive` = `danger_light` background + `danger` text (new `danger_light` colour, added to both the light and dark sets);
  - `tertiary` = transparent background + `brand` text;
  - `IconButton` now takes its icon colour straight from `buttonTextColor()` (it used to hard-code "solid background → white icon"), and `GuncatUiIcon.color` was widened from `string` to `ResourceColor` so callers can pass either a hex literal or `$r('app.color.*')` — dark mode only follows the latter;
  - a **single button no longer stretches across the row** (`layoutWeight` only splits evenly with 2+ buttons) — one long coloured strip was part of what looked bad; it is now left-aligned at its content width;
  - note: **selection states** (Tabs / Chips / Select options) are still solid brand + white text, which is the strong "selected" semantics and a different layer from buttons; `OptionCards` uses `brand_light` + a `brand` border. The user raised no objection, so they were left alone.
- **Web search: server-side by default, the on-device tool demoted to a fallback (same-day item 12)**: the local tool used to be called `search_web`, which differs from the built-in server-side `web_search` by **nothing but word order**, so the model readily treated it as "the search tool"; on top of that, 20+ places in the skill docs said "verify with `search_web`", and in practice it became the first choice. Now:
  - **Renamed** `search_web` → `local_web_search` (`LOCAL_SEARCH_TOOL_NAME`); the `local_` prefix makes it clear that it "runs on the phone and consumes the phone's network plus your own engine keys", so it is no longer confused with the server-side tool. The **old name is kept as a dispatch alias** (`LOCAL_SEARCH_LEGACY_TOOL_NAME` + `isLocalSearchToolName()`): the old calls the model itself wrote in past messages, and old plugin scripts, still execute instead of becoming "unknown tool".
  - **Description demoted** (the fallback variant used when server-side search is on now reads "【fallback tool】… server-side web search is ENABLED for this request …call this only in cases ①②③"); it also removes a hidden incentive: the local search writes `.searches.md` automatically while server-side search needs a separate `record_search` — the wording now states that "that is one step, not a reason to pick this tool".
  - **Hard rules in the prompt**: `PromptBuilder.capability()` gains a "web-search priority" line and `toolsDirectory()` gains a `local_web_search` entry (including "when server-side search is not enabled it is the only channel", because the system prompt must stay byte-stable and cannot fork on the toggle).
  - **Skill-doc correction applied at delivery time**: the skill prose is imported content (20+ occurrences of the old name); rather than editing the prose — which the next import would bring back — a single "web-search convention" note is prepended to every `load_skill` result (`WorkFileService.LOAD_SKILL_SEARCH_NOTE`).
  - Also: the timeline now shows this tool as "Local Search" with a circled magnifier (it previously fell through to the default branch and displayed the raw tool name); `AgentLoopService.buildWorkSystemPromptLegacy()` is marked `@deprecated` (the live prompt is assembled by `PromptBuilder`, so this only prevents future edits to the wrong file). 5 new assertions; pure-logic checks 474 → 479.

### Initial: JSON DSL (interactive mode launch)

- Added **a third Agent Mode entry: Interactive Mode (Intelligent UI)**, shown in parallel with Work Mode under the sidebar's "Agent Mode" group. It shares the same Agent Loop, sandbox workspace, and 45 tools, but **answers are not plain text — they are operable interfaces**: metric cards, progress bars, tables, horizontal bar / line / donut charts, plus sliders, switches, dropdowns, text inputs, and choice buttons.
- **Interaction loop**: drag a parameter, flip a switch, or pick an option and tap "Submit"; every value is packed into one message back to the model, which then **recomputes and re-renders the updated interface**. The interface becomes a reusable dashboard instead of a static picture. Choice buttons report back on a single tap, no submit needed.
- **Native rendering, no extra dependencies**: the strict JSON inside a ` ```guncat-ui ` fence was parsed by `GuncatUiSpec` and rendered by `GuncatUiView` into native ArkUI components. Line and donut charts are drawn on the fly with Shape + Path — no chart library and no image files.
- **Streaming shape-up and fail-safe parsing**: a UI block renders progressively from the parts already parsed (showing "生成中…" and disabling interaction until the JSON closes). Unknown kinds and alternative spellings are normalized, JSONC comments / trailing commas / full-width quotes are cleaned up, a single top-level element or an object-shaped `elements` still renders, truncated output is salvaged (chopped re-parse, then a text-level rescue that rebuilds a submittable form), and a block that truly cannot be parsed keeps its raw text visible.
- **Truncated output still lands**: a UI block was treated as "a stream that can be cut off by the model's output limit at any moment". `GuncatUiParts.build(content, finalized)` distinguishes "still writing" (`生成中…`) from "finished but never closed" (`未完成` + whatever was completed), so a card never spins forever. The salvage chain was: clean-up + brace repair → per-element scan → progressively chopped re-parse → text-level rescue (scan the title and any `"name"` controls out of the raw text and build a **submittable form**). A 「查看原始输出」 toggle exposes the model's raw output at any time.
- **Single-source prompt**: the interactive-mode system prompt (DSL contract + anti-patterns + mode duty) lived in the same file as the parser (`common/GuncatUiSpec.ts`), so the documented contract and the parsed contract could not drift. Context compaction rebuilt history with the same mode-specific prompt.
- Interactive mode reuses all work-mode infrastructure: task checklist, tool timeline, workspace upload, artifacts card, forced deep thinking, and three-protocol streaming function calling. Word / Excel / PPT output still works whenever you ask for a real file.
- App version bumped to `6.3.0` (versionCode 710).
- **Empty-card-shell fix (same day)**: on device the interface card was once "just an empty box with two grey bars". The root cause was small model-output defects (a single element treated as the top-level document, a `kind` using an unregistered name, JSON with comments or a trailing comma) that broke parsing, degrading the card to an untitled skeleton. Three layers of hardening were added: the tokenizer decides real closing fences by **bracket balance** (a code fence inside the block no longer truncates the JSON); the parser accepts `items/blocks/…`, normalizes near-synonym `kind`s, strips comments / trailing commas / full-width quotes, and falls back to a form for controls; and the card header **always renders**, showing the **model's raw output** when no element can be parsed. That eliminated the "nothing at all" empty card.
- **Truncated-output fix (same-day item 2)**: the card no longer sits on "生成中…" forever. A UI block is now handled as "a stream that the model's output limit can cut at any moment": when it is unclosed and generation has ended, it shows **`未完成`** and renders what was completed, along with a「查看原始输出」 option; the salvage chain chops the tail and retries parsing level by level, and can even assemble a **submittable form** when nothing but control definitions survived. In the extreme case (output cut within the first 100 characters) you still get `未完成` + the raw text, never a spinning empty skeleton.
- **DeepSeek JSON Output integration (same-day item 4)**: interface output was hardened according to DeepSeek's official JSON Output documentation (`response_format={'type':'json_object'}`). When a UI block is truncated, the app re-generates an interface JSON with a **JSON-only request** (no tools, generous `max_tokens`, a tightly constrained schema) and appends it to the conversation as a canonical UI block; the prompt also gained a **length discipline** (2–4 elements by default, ≤6; copy ≤60 characters) to reduce truncation at the source. The failure mode documented by DeepSeek ("JSON mode occasionally returns empty content") is covered too: failure falls back to text continuation.

## Version 6.2.0 (New Skill System)

- Added a **Codex-style artifacts card** in Work Mode: after a task finishes, generated/modified files are summarized in an "Artifacts" card at the end of the conversation, expanded by default; each file's line-diff thumbnail is collapsed by default and can be expanded individually. The view auto-scrolls to the bottom when the task finishes, so the card is immediately visible.
- Added **in-place file preview & one-click share**: files in the artifacts card, the workspace popover, and the right-hand details panel can be tapped to preview in place via HarmonyOS Preview Kit, or shared directly through the system share panel — no paths, zip archives, or format pickers involved. `write_file` / `append_file` and other text-generation tools now also produce line diffs, so both the artifacts card and expanded tool cards show add/delete changes.
- The full set of Office skills for Work Mode is now officially available! You can now professionally process and generate PPT, Word, Excel, and other office documents, handling everyday office tasks all in one place.
- The Paper Conversion Expert, Legal, Research, and Screening/Retrieval Experts, and LLM Evaluation Expert are now packaged as Skills embedded in Work Mode. No need to switch chat engines—use them directly in Work Mode!
- Added local web search (built into the software, no manual toggle required). It can be invoked in both Work Mode and Chat Mode, so web access is no longer limited by the server-side web access toggle!
- Fixed occasional parameter passing errors and text-too-long truncation issues in the Anthropic API protocol.
- Added a suffix completion toggle. You can now disable suffix completion to allow access via non-standard addresses.
- Work Mode is now more stable and smarter overall: it automatically retries on rate limits or network hiccups instead of making you start over; when a task gets long, it summarizes earlier history so important information is not lost; tool calls have better timeout, cancellation, and argument checks so failures are caught sooner; plugins and skills can be loaded on demand to extend capabilities; each tool call's duration, integration, and retry status are recorded for easier troubleshooting; error messages are friendlier; and every change is covered by automated tests so fixing one thing won't silently break another.
- Work Mode's core loop now runs on a new "driver engine" (enabled by default): every step is scheduled by a unified state machine and planner, and the logs show each step's decision plus an end-of-loop summary, making long tasks more controllable and easier to diagnose. If anything goes wrong, you can flip one flag back to the legacy loop and keep using the app normally.
- **Office skills fully upgraded (V3, version stays 6.2.0)**: the PPT / Word / Excel skills now use a gate-style structure — you must first `load_skill` to fully load SKILL.md plus all reference files (no cherry-picking); before creating a new deck/document/workbook, the agent asks a consolidated `ask_user_question` (purpose, length, style, materials, etc.); and before delivery it must produce a verifiable QA report (`ppt_qa_report.md` / `docx_qa_report.md` / `xlsx_qa_report.md`) and include a self-check summary in the final answer.
- **Much richer PPT output (V3.1)**: default length raised to 20+ slides; every slide must have both a decorative SVG/texture background and a content visual (flowchart, timeline, architecture diagram, comparison, simple illustration, infographic) — text-only slides automatically convert part of their content into diagrams; a visual-style catalog (tech, classic Chinese, minimalist, magazine, business, academic, launch, etc.) with texture/outline/pattern recipes replaces plain color-only default templates.
- **Skill library expansion (V3 port, version stays 6.2.0)**: Work Mode gains 22 reusable domain skills, fully ported from four mainstream AI work platforms and adapted to this project's available tools (unavailable platforms/tools were cleaned up) — `humanizer` (de-AI/humanize/readability), `prompt-engineering` (prompt engineering), `pdf` (PDF reading/search/scanned-page reading), `translation` (legal/medical translation & terminology consistency), `questionnaire` (survey/in-depth interview/verbatim tagging/quantitative analysis), `content-rewrite` (multi-platform content rewriting & distribution), `html` (single-page HTML development), `paper-reviewer` (academic paper review), `review-agent` (code review), `paper-rebuttal` (reviewer-rebuttal responses), `research-lineage-map` (research lineage/evolution maps), `marketing-plan` (marketing plan proposals), `reference-audit` (reference/citation auditing), `paper-close-reading` (deep academic-paper reading), `khazix-writer` (WeChat long-form writing), `newmedia-writing` (Xiaohongshu/WeChat/short-video new-media writing), `marketing-material-review` (marketing-material compliance review), `patent-drafting` (patent application drafting), `sentiment-tracker` (public-opinion tracking & tracing), `journal-format` (academic DOCX formatting & repair), `research-proposal` (research proposal/grant application drafting), `industry-analysis` (industry deep research). Together with the original 10 skills, there are now 32 skills, all loaded on demand via `load_skill`.
- **Parallel subagent dispatch (version stays 6.2.0)**: Work Mode's `subagent` tool can now dispatch multiple child agents concurrently (global cap 4, same as the read-only pool); cancelling the parent task also aborts all running child agents; set `WORK_ALLOW_PARALLEL_SUBAGENTS=false` in `Constants.ts` to return to sequential dispatch.
- **Parallel results appear as soon as they finish (version stays 6.2.0)**: tools in a parallel group now fill in their results and refresh the UI as soon as they finish, no longer waiting in model order; the right-side status label is based on whether a call has actually started — multiple running child agents show "executing…" at the same time.
- **web_fetch parallelism (version stays 6.2.0)**: `web_fetch` keeps using the read-only parallel pool with up to 4 concurrent fetches by default; no extra cap was added.
- **Child-agent workspace isolation (R67, version stays 6.2.0)**: each child agent gets its own output directory `subagents/sa_<timestamp>_<seq>/` by default (or use `output_dir`); the child can still read/search the entire main workspace, but all writes/creates/moves/deletes are automatically redirected or restricted into its own output directory (bare paths are auto-prefixed, `delete_file` clearing the workspace root is blocked, and `run_js` outputs land there too); the final report header includes the output directory — parallel child agents no longer overwrite each other's same-named files and cannot pollute, clobber, or delete main-loop files. Feedback is explicit: out-of-bounds writes show an "already redirected to…" notice before the tool result, and deleting/moving main-workspace files is blocked with a clear "out-of-bounds" error instead of "path not found".
- **Conversation history moved to file storage (version stays 6.2.0)**: conversations no longer use a single Preferences value; they are saved to `filesDir/guncat_conversations.json`, removing the Preferences 16 MB single-value limit. Long work-mode tasks or many history conversations no longer disappear after restarting. On first launch after upgrading, existing Preferences conversations are migrated automatically and the legacy key is cleaned up.
- **Fixed sidebar not refreshing immediately after delete/new (version stays 6.2.0)**: deleting a history conversation now removes the item from the sidebar/drawer immediately, and newly created conversations appear right away — no need to switch entries or close the drawer to force a refresh.
- **Open unsupported file types with other apps (version stays 6.2.0)**: when HarmonyOS Preview Kit cannot preview a file (e.g. `.md`), tapping the file now directly opens the system "Open with" chooser, letting you pick an installed app that supports the file — no longer just an "unsupported preview" toast.
- **Skill ecosystem reorganization: main skill → branch-skill subdirectories (version stays 6.2.0)**: to reduce overlapping skills and improve routing accuracy, 25 content/academic/legal/AI branch skills were physically moved into 5 main-skill subdirectories — `research-intelligence` (7 branches) / `academic-publishing` (7 branches) / `content-writing` (5 branches) / `legal-ip` (4 branches) / `ai-tooling` (2 branches); the 7 format branches (`docx`/`xlsx`/`ppt`/`svg`/`html`/`pdf`/`data`) remain top-level and direct. Added a global routing index `ROUTE_INDEX.md`; every main-skill directory ships `SKILL.md` + `ROUTING.md`.
- **Branch skills no longer appear directly in the skill list (version stays 6.2.0)**: `list_skills` now exposes only 12 visible skills (5 main skills + 7 format branches). The 25 branch skills are loaded by their original id after routing (`load_skill("research")` still works — physical paths are mapped via `WorkSkillService.skillPath()`, so the model never needs to know file locations). The registry now has 37 entries = 32 original skills + 5 main-skill routing entries.
- **Skill priority boost: skill usage golden rules (version stays 6.2.0)**: the system-prompt skill section now opens with mandatory golden rules — load on hit (the first step must be `load_skill`), check `list_skills` when unsure, main skill first, skill body outranks default behavior, and skipping a skill on a covered task counts as a violation. The `load_skill`/`list_skills` tool descriptions, the "skill-first" step of the four-step method, and the main-skill trigger words were all strengthened to raise the probability the model follows the skills.
- **Fixed system-shared files not reaching the Work Mode sandbox (version stays 6.2.0)**: files/images shared into the app through the system share sheet previously landed only in the pending-send preview area while in Work Mode — they were never written to the sandbox workspace, so work tasks could not read them. Shared files are now also copied into the current conversation's workspace (`<filesDir>/workspaces/<convId>`, reusing the upload path so original file names are kept), and the next task send automatically injects the "files uploaded to workspace" note. The preview area is kept as-is, so shared files can still be sent as attachments after switching back to Chat Mode; sharing while in Chat Mode behaves unchanged (preview only).

## Version 6.1.2 (New agent: Guncat 3.1-Flash)

- Added **Guncat 3.1-Flash (Light & Simple Mode)**: Guncat's first Flash-dedicated independent foundation — a brand-new design that inherits no architecture from the 2.0/2.5/3.0 series, purpose-built for everyday conversation and lightweight information tasks; it takes over 3.0-Mini's place as the lightest entry in the family and is listed first in the agent list. It stands parallel to Efficiency Mode (3.0-Flash), not as its upgrade: Efficiency Mode handles all-purpose task execution, while Light & Simple Mode handles everyday conversation and simple knowledge queries.
- rawfile adds `Guncat 3.1-Flash_prompt_ZH_CN.md` / `_EN.md`, updates `agents.json` (3.1-Flash listed first) and `icons/guncat-3.1-flash.png`; the "Play with the App" panel now includes the Light & Simple Mode (3.1-Flash base) guide; the 3.0-Mini prompt files and icon are kept in rawfile but no longer appear in the default agent list.
- Bumped to version 6.1.2 (`AppScope/app.json5` versionName 6.1.2 / versionCode 612 synced).

## Version 6.1.0 (DeepSeek Harness port)

This release ports the core Agent Loop capabilities of DeepSeek Harness (dsh) into Work Mode: a batch of purely local tools, scheduling upgrades in the loop, and a three-column desktop UI for wide screens. Version bumped to 6.1.0 (`Constants.APP_VERSION` and `AppScope/app.json5` versionName 6.1.0 / versionCode 610 in sync). See `PORT_NOTES.md` for the full port map.

- **New tools (11)**: `glob` (path search with `**`/`{a,b}`/`[...]` patterns), `grep` (regex search over text content), `edit` (exact unique-match replacement returning a line diff), `str_replace_editor` (view/create/str_replace/insert editor), `web_fetch` (fetch pages/APIs, HTML stripped to readable text), `ask_user_question` (pauses the loop for an answer; the UI card supports single/multi select plus free-text, submitted via one "Submit" button), `schedule_create/list/delete` (session-local reminders that wake the agent when due, recurring ≥300s), `goal_create/get/update` (session goal injected via the runtime snapshot), `subagent` (in-process child agent: shared workspace, isolated context, ≤40 steps, returns a final report as the tool result), `session_search` (search the session event log).
- **Agent Loop upgrades**: append-only session event log (JSONL at `<filesDir>/sessions/<convId>.jsonl`); user steering — messages sent while a task runs no longer get rejected, they are injected as a "user supplement" into the next request; bounded parallel tool pool (consecutive read-only calls run concurrently, max 4, committed in model order; mutating calls act as barriers); sticky max-tokens (turn finalizes with a "send 继续" hint when output hits the ceiling); spill store (tool results over ~12K chars are fully saved to workspace `.spill/` while the model receives head+tail excerpts with a locator); LLM session titles (generated in the background after the first task, once per session).
- **Three-column desktop UI**: at ≥700vp the layout becomes sidebar (brand row / new session / engines & conversations / bottom actions, collapsible to a 56vp icon rail) | conversation | workspace details panel (task stats / goal / file management, auto-opened once on wide screens); design tokens align with the dsh web UI — neutral-bluish dark palette with the DeepSeek blue accent, white light theme. Narrow screens keep the original single-column + drawer interaction.
- **Tool row visuals**: dsh-style 24px single-line rows (icon + title + separator dot + args summary + status/duration) expanding into IN/OUT detail cards (long content scrolls inside its slot); `edit` renders a diff card (+adds −dels with stats); `todo_write` renders a checklist; the final answer gains a stats line (output speed / cache hit rate / tool time).
- **Performance & fixes**: sidebar/drawer now receive a lightweight conversation projection (fixes the stutter from deep-copying all messages when opening the drawer); the workspace details panel refreshes in real time (after every tool result + every 3s while streaming + a manual refresh button); fixed tool rows momentarily filling the whole page, long results overflowing detail cards, a stray streaming cursor under the answer text, and ask_user single-select submitting before confirmation.
- **Sandbox unchanged**: the workspace is still confined to `<filesDir>/workspaces/<convId>` (`resolveSafe` rejects absolute paths and `..` traversal); files cross the boundary only via system pickers (DocumentViewPicker) with no new storage permissions; the new `.spill/` directory is excluded from the runtime snapshot tree.
- **Full PC adaptation**: all pages are adapted to a PC wide-screen style — a three-column desktop layout with the sidebar on the left, the conversation in the middle, and the workspace details on the right; the sidebar collapses to a 56vp icon rail and the columns stretch adaptively when the window is resized or maximized; settings/about overlays become centered floating panels; list items and buttons gain mouse hover states with wheel-scroll polish; narrow screens (phones/folded state) automatically fall back to the single-column + drawer interaction, both forms sharing the same UI code.
- **Third-party upgrade**: the `@luvi/lv-markdown-in` Markdown rendering engine is upgraded to the latest 3.4.6 version.
- **Visual polish**: improved the display of several screens — conversation whitespace and bubble spacing, input-bar/tool-row alignment, and consistent palette details across dark/light themes.
- **Mermaid diagram polish**: improved the rendering of Mermaid diagrams for clearer graphics and more stable layouts.
- **New answer-bubble actions**: the AI answer bubble gains "Copy" and "Copy to input box" — copy the whole answer with one tap, or drop it into the input box for quick edits and resend.
- **Action icon refinements**: refreshed the icons for copy and a few other answer actions, with a more consistent style and clearer meaning.
- **Free text selection & copy**: message text can now be freely selected and copied directly, with no need to tap "Select part" first.
- **New "Play with the App" guide**: tapping the "About" button opens the Play-with-the-App panel, which gathers feature walkthroughs and usage tips so you can browse each function's guide in detail.

## Version 6.0.0 (Work mode, Agent Loop)

Alongside chat mode, this release adds an independent work mode: the 🛠 "Work Mode" virtual agent (top of the agent list, parallel to other agents) opens a conversation bound to a sandbox workspace, where the agent completes long-horizon tasks through a multi-turn tool-calling loop. Version bumped to 6.0.0 (`Constants.APP_VERSION` and `AppScope/app.json5` versionName 6.0.0 / versionCode 600 in sync).

- **Identity and entry**: the `work` virtual agent is injected at the top of the list; the page title, empty state, and new-conversation ownership follow the selected agent automatically; work conversations use `agentId='work'` (legacy data migrated automatically) and deleting one cleans up its workspace.
- **Agent Loop**: one message per turn (thinking→tools→answer in chronological order), three-protocol streaming function calling, a 200-turn runaway safeguard, request-level automatic retries (429/5xx/network/empty responses with exponential backoff and jitter), two-stage compaction of over-budget history (model-free prune first, then prefix-reusing summarization, falling back to oldest-first trimming), cancellation annotations, and empty-output cleanup; tool results are truncated head+tail before being sent back to the model.
- **Task checklist**: the `todo_write` tool maintains `.todo.json`; checklist and workspace state reach the model through a "runtime context" snapshot appended to the conversation tail (only when it changes) — plan first for complex tasks and progress item by item.
- **25 local tools**: file CRUD/search (with `glob` filename filtering on `search_files`), `view_image` (images are sent to the main model's multimodal vision), `parse_document` (local PDF), Office generation (`write_docx`/`write_xlsx`/`write_csv`), data pipeline (`transform_file`), the PPT read/write/edit trio (`write_pptx`/`read_ppt`/`edit_ppt`), web download (`download_file`), SVG image generation (`write_svg`), and the skill system (`list_skills`/`load_skill`).
- **Data pipeline transform_file**: the dedicated tool for large files and non-standard data — CSV/TSV/Markdown-table/JSON/JSONL/lines input, filter/derive/map/regex-extract/split/dedupe/sort/replace/numeric-cast plus CSV↔TSV↔JSON↔MD↔XLSX conversion, **data never enters model context**. Restricted-DSL design: ops go through a whitelist dispatch and expressions through a self-contained evaluator (no I/O, bounded steps, termination guaranteed by construction), with a "preview 3 rows → write → spot-check" workflow mirroring the SVG loop. Full syntax lives in the `data` skill. Two new pure-TS modules — `CsvParser` (RFC 4180 parsing + Markdown/TSV/CSV auto-detection, also benefits write_csv/write_xlsx) and `DataPipeline` — are wired into the pptx-harness verification chain (54 unit tests).
- **Material acquisition & image generation**: `download_file` pulls network images/files into the workspace (type sniffing, html warning, ≤20MB); `write_svg` lets the model hand-write SVG for icons/diagrams/infographics — validated automatically (xmlns/viewBox/no script) and rasterized to a PNG preview via the device image engine, forming a "generate → preview → iterate" loop with `view_image`; `write_pptx` can reference `.svg` directly (rasterized automatically on export). `search_files` gains a `glob` filename filter (`*.md`, `*.png,*.jpg`). `write_csv` adds explicit CSV support (RFC 4180 escaping + UTF-8 BOM).
- **PPT pipeline (Deck JSON intermediate layer)**: aligned with open-kimi-ppt-skill's PPTD design — the AI writes a structured Deck source, and `PptxBuilder` renders 13 layouts (cover/TOC/section/bullets/two-column/image-text/image/full-bleed image/table/chart/quote/closing/free-form), 8 themes + custom palettes, charts (bar/line/area/pie/doughnut with embedded data), tables, images (workspace/data URL/http), and speaker notes; exported files embed a `docProps/deck.json` source so `read_ppt` restores them losslessly and `edit_ppt` applies operator-style edits (foreign pptx files are imported approximately and automatically backed up before rebuild); dark backgrounds lighten text and chart labels automatically. Five new modules (`DeckModel/PptxThemes/PptxCharts/PptxImage/PptxImporter`) plus a rewritten `PptxBuilder`; comes with the offline verification harness `test/pptx-harness/` (Node builds of all layouts + negatives, python-pptx structural checks, PowerPoint-rendered PNG reviews).
- **Excel pipeline (Workbook JSON intermediate layer)**: an intermediate layer isomorphic to PPT/Word — the AI writes a structured Workbook source (multi-sheet / bold header fills in 3 themes / `=formulas` / number formats money·int·percent·year·date·number / column widths / freeze panes), `XlsxBuilder` renders all parts (embedding a `docProps/workbook.json` source), `read_xlsx` restores losslessly, and `edit_xlsx` applies operator-style edits (rename / add-delete-move sheets, row CRUD, set cell, replace text; foreign xlsx files are imported approximately and automatically backed up before rebuild). **Formula-first** plus the number-format and negative/zero display conventions draw on the MiniMax xlsx reference skill; the model-facing guide is the `xlsx` skill. Three new modules (`XlsxModel/XlsxBuilder/XlsxImporter`); `write_xlsx` keeps the `table` text fast path; comes with the offline verification harness `test/xlsx-harness/` (Node builds + openpyxl structural checks + embedded-source round-trip).
- **Skill system**: domain operation guides are organized under `rawfile/skills/<id>/` (SKILL.md + reference/) and loaded progressively via `list_skills`/`load_skill`; the system prompt keeps only a one-line trigger, so the KV-cache prefix stays byte-stable. The bundled `ppt` skill covers Deck JSON syntax / design guidelines / content discipline / themes / deck blueprints / self-check lists, the `docx` skill covers Doc JSON syntax / typography rules / document form-factor selection / document blueprints / professional-document norms, the `xlsx` skill covers Workbook JSON syntax / formula-first / number formats / data-analysis delivery / report blueprints / analysis playbook / edit integrity, the `svg` skill covers authoring rules / the "generate → preview → iterate" workflow / visualization-type selection / infographic blueprints / recipes for icons, flowcharts, bar charts, and timelines, and the `data` skill covers pipeline ops / expression syntax / data-quality checks / cleaning-extraction-conversion recipes / capability boundaries; the skill format follows the standard Agent Skills convention and is portable across agent frameworks. Adding a skill = writing docs + registering it in `WorkSkillService.registry()` (see architecture guide 3.3).
- **Local parsing engine**: new `OfficeReader` (OOXML text extraction, fixing the `<w:t` prefix mismatch that leaked XML), `PdfTextExtractor` (byte-level object table / ObjStm expansion / page-tree resource inheritance / ToUnicode CJK mapping / content-stream parsing / fallback scan with diagnostics), and `Flate` (pure-TS DEFLATE inflate). The multimodal parsing API is no longer required.
- **Codex-style timeline UI**: a single-container timeline (unique 🛠 header + task cards + per-turn "thinking→tools→answer"); tool steps expand to show arguments and results; intermediate turns hide action buttons; the workspace panel supports upload / zip export / clear.
- **Stability fixes**: PDF parsing OOM (whole-file latin1 concatenation replaced with byte-level scanning + native utf-16le decoding); main-thread block appfreeze (parsing yields in stages and the fallback scan skips fonts/images/oversized streams with caps and pre-checks); the same O(n²) concatenation in `arrayBufferToBase64` was fixed as well.
- The system prompt now follows the Guncat 3.0 discipline: planner/executor/final-verifier roles, gap-driven convergence, anti-hallucination, pre-delivery verification, and the output richness principle.
- **Agent prompts add an "opening Mermaid structure diagram"**: the Guncat 3.0-Pro and 3.0-Flash prompts (Chinese and English) are upgraded in sync — the first element of every formal answer is fixed to a Mermaid mindmap outlining the content structure of the answer body (root node = the answer's topic; second/third-level nodes map one-to-one onto the body's major sections and key points); `mindmap` syntax by default, falling back to `flowchart TD` when unsupported; effective in all modes, with only pure-greeting ultra-short interactions exempt; the time-baseline statement now comes right after the diagram, and the pre-output self-check checklist gains a matching item.

## Version 5.2.1

- Added **Guncat 3.0-Mini (Light & Simple Mode)** and placed it first in the agent list: further streamlined from 3.0-Flash, removing the Output Richness Principle in favor of the Task-Adaptive Output Principle (answer length decided by task complexity and user needs — light conversation is naturally concise, standard tasks are medium-length, and complex tasks are fully elaborated); fully retains the three-layers-in-one architecture, the two-tier modes, the tool-calling methodology, and the anti-hallucination system.
- Bumped to version 5.2.1: rawfile adds `Guncat 3.0-Mini_prompt_ZH_CN.md` / `_EN.md`, `agents.json` (3.0-Mini listed first) and `icons/guncat-3.0-mini.png`; `Constants.APP_VERSION` and `AppScope/app.json5` (versionName 5.2.1 / versionCode 521) updated in step.
- New-conversation deep-thinking default extended: Light & Simple Mode defaults off (same as Efficiency Mode).

## Version 5.2.0

- The deep-thinking toggle now explicitly controls the request per protocol (aligned with the official DeepSeek parameters): OpenAI Completions uses `thinking.type` + `reasoning_effort`, Anthropic Messages uses `thinking.type` + `output_config.effort`, OpenAI Responses uses `reasoning.effort = high/none` (`none` disables thinking); when web search is enabled, the previous assistant's `reasoning_content` is sent back in multi-turn turns (OpenAI Completions) to avoid 400 errors.
- New conversations reset the deep-thinking default by agent name: off in Efficiency Mode (3.0-Flash), on in Expert Mode (3.0-Pro); the toggle resets on every app launch.
- Synced the Guncat 3.0-series agent foundations: added "Efficiency Mode" (Guncat 3.0-Flash) and "Expert Mode" (Guncat 3.0-Pro), with "Classic Mode" carrying over the 2.5-Lite foundation; domain experts unified under the "Conversion / Search / Evaluation Expert - Domain" naming scheme; removed the 2.0-series prompt files — the rawfile prompt library is fully aligned with Web for API 5.2.0.
- Per-agent sidebar icons: a new `icon` field in `agents.json` (pointing to a PNG named by agent id under `rawfile/icons/`); `AgentDrawerView` loads them dynamically via `$rawfile`, falling back to the default cat avatar when unset.
- Dual descriptions: a new `shortDescription` field — the sidebar shows the short version while the new-conversation welcome page shows the full one, falling back to each other when unset; `AgentLoader` and the `Agent` model extended accordingly.
- Version governance: the About panel now references `Constants.APP_VERSION` as the single source of truth, consistent with `AppScope/app.json5` and the READMEs.

## Version 5.1.1

- Today's date automatically prepended to system prompts: when loading an agent's prompt, the device's local date is fetched at runtime (e.g., "Today's date is 2026-08-24.") and prepended to the beginning of the prompt, updating automatically across days; applies uniformly to all three access methods — OpenAI Completions / OpenAI Responses / Anthropic Messages.

## Version 5.1.0

- New deep-thinking (reasoning) display: the reasoning content of AI replies is shown in a collapsible card that is collapsed by default and expands on tapping the header; incremental parsing supports all three protocols — OpenAI Completions (`reasoning_content` / `reasoning`), OpenAI Responses (`reasoning_text` / `reasoning_summary_text`), and Anthropic Messages (`thinking_delta`).
- Live stats on the reasoning bar: the right side shows the token speed (tok/s) in real time during streaming and then the API-derived exact token speed plus cache hit rate once the stream ends (the cache hit rate only appears when the API returns cache-token usage; otherwise it stays hidden).
- Reworked the deep-thinking bar UI: a standalone card above the bubble with uniform corner radii and a neutral light-gray background; the spinner sits to the right of the "Deep Thinking" label and the separate "Thinking…" text was removed.

## Version 5.0.0

- Unified API integration into three mainstream protocols: OpenAI Completions, OpenAI Responses, and Anthropic Messages; removed standalone DeepSeek / Volcengine Ark presets with automatic migration for old configs.
- Upgraded DeepSeek to the latest Responses API, including native web search, vision-model image input, and hybrid Files API `file_id` uploads.
- Added Anthropic Messages support, compatible with the DeepSeek Anthropic endpoint (`https://api.deepseek.com/anthropic`), including image input and web search.
- Table recognition now lists all main and multimodal models from every API profile (deduplicated) for direct selection; improved DeepSeek vision output handling (thinking disabled, full-width angle bracket normalization, Markdown table fallback).
- Improved the model-switch menu: equal item widths, centered text, rounded corners, and a softer shadow.
- Improved the drawer shadow: a fixed full-screen scrim keeps the right side shaded during the slide, and tapping the blank area closes the drawer.
- Updated the app icon assets while keeping the original filenames, so existing resource references remain valid (just replace the image files to apply).
- Refreshed the UI with a soft modern style: low-saturation palette, large rounded corners, white soft-elevated buttons, gentle shadows, and no heavy outlines or glow effects.
- Added a launch fly-in animation: icons fly out from the center in sequence, staying sharp throughout with no blur fade or cross-fade flicker.
- Added an one-shot central icon transition: the launch icon uses a single hero node to smoothly move and scale into the empty-state icon at the page center, avoiding "white flash then clear" artifacts.
- Added a bottom input slide-in animation: it slides in from below the screen edge with no bounce or unnatural top-down drop.
- Side drawers, settings sheets, and about overlays naturally cover the underlying hero icon instead of leaving it floating above overlays.

## Version 4.4.0

- New table recognition: a "Table Recognition" entry in the answer action bar opens a dedicated page that converts tables in images to HTML via a multimodal model, preserving merged cells (rowspan/colspan), headers and reserved writing-line heights.
- New Excel export: recognized tables can be exported as `.xlsx` via the system save panel; the native parsing/export engine mirrors the Web version and requires no upload.
- Split table-recognition credentials: the Zhipu option references the multimodal parsing-engine config, while the Volcano Ark (Doubao) option references the native-multimodal main-model config; the two platforms keep independent API keys.
- Auto new conversation on launch: reopening the app creates a new conversation automatically; if the agent's latest conversation is still empty it is reused instead, so no duplicate empty conversations are created.

## Version 4.3.1

- Fixed a crash when rendering Markdown tables: the @luvi/lv-markdown-in rendering library threw an uncaught exception while iterating undefined data for structurally broken tables (empty header cells, header/separator column-count mismatch, header-only tables, or a message truncated at the table), killing the process; re-rendering saved history on cold start always reproduced it.
- Added pre-render table normalization: structurally valid tables are padded to a consistent column count with closed pipes and preserved alignment; unrepairable degenerate tables degrade to plain text without losing content.
- Normalization touches table blocks only; code fences, lists, blockquotes and other Markdown syntax are unaffected.

## Version 4.3.0

- Added one-tap Word export: AI replies export to `.docx` with headings, bold/italic, tables, code blocks, quotes, lists, links, and embedded images; LaTeX formulas convert to native Word formulas (OMML).
- Added quick camera capture: a camera button next to the microphone launches the system CameraPicker (no camera permission required).
- Added partial text selection: the "Select part" action enables long-press cross-paragraph text selection and copying.
- Fixed the white screen when swiping up to review history during streaming: auto-scroll pauses while touching and resumes on release.
- Fixed an intermittent out-of-memory crash with large image attachments: persistence now strips oversized image bytes and attachments render as 256px thumbnails.
- Tidied the input bar: the microphone and camera buttons are compact and vertically aligned.

## Version 4.2.1

- Added the Guncat Eval-LLM evaluation agent: LLM evaluation intelligence analysis based on a 12-step workflow and eight anti-hallucination mechanisms.

## Version 4.2.0

- Expanded CoreSpeechKit read-aloud with voice discovery and selection, a preferred female voice, `1.5×` default speed, and persistent preferences.
- Added a movable reader control with pause/resume, close, speed controls, and seeking.
- Added AVSession and an audio playback continuous task for background and screen-off reading.
- Added HarmonyOS system share reception so images and files can be placed directly in pending attachments.
- Corrected Volcengine Ark deep-thinking semantics: Off sends `disabled`; On sends `enabled`.
- Retained native voice input, multiple API profiles, and Responses API multimodal passthrough.

## FAQ

### Invalid API key

- Check for leading or trailing whitespace.
- Confirm that model, integration mode, and Base URL match.
- Check account balance, API access, and network connectivity.

### File parsing failed

- Confirm that the format and size are supported by the model endpoint.
- Verify the multimodal configuration.
- Disable pre-parsing and use a Responses API model that accepts attachments directly.

### Streaming response stopped

- Check network stability and server rate-limit messages.
- Try another API profile.
- Disable deep thinking for simple tasks to reduce response latency.

### Guncat Work is missing from the Gallery share sheet

- Confirm that the latest HAP with Share Kit UTD declarations is installed.
- Reopen the Gallery share sheet after updating so the system refreshes share targets.

### The interactive interface hasn't appeared / only part of it appeared / it says「界面未写完」

- **The interface shapes up while it is being written**: the first line `root = Card([...])` renders the shell first and later statements fill it in one by one, so "it hasn't appeared yet" usually just means it has only started.
- **It shows「界面未写完，以上为已生成的部分」**: the model's output was truncated or interrupted, and **every completed statement still renders as usual** (the core advantage of line-based statements over one JSON block). Most of the time you do not need to do anything — if the model produced no usable interface at all, the app automatically requests one separately (the conversation then shows「（界面已重新生成）」). If it is still incomplete, reply "continue" or "regenerate a shorter interface"; repeated truncation means a single output is too long, so ask for fewer components or split it across two turns.
- **The interface is empty (only「这段界面没能渲染成可交互组件，可以让我重新生成一次。」)**: open the「查看原始输出」(view raw output) control at the bottom to see what the model actually wrote; if a「诊断 · N 条」(N diagnostics) panel is there, open it for the specific reason — the most common one is **using a component name that is not in the component list** (unknown components are dropped so they cannot render as a puzzling empty card).
- **Common authoring mistakes** (they appear in the diagnostics): forgetting the first line `root = Card([...])`; writing arguments as key/value, `CardHeader(title: "x")` (they must be positional); defining a variable and forgetting to put it into `root`'s child array (unreferenced statements do not render); a component name that is not in the list.
- **A control does not respond to a tap**: only the **newest** interface is interactive (older ones are greyed out and archived), and controls are grey while the interface is unfinished; on top of that, an action that "reports back to the model" only works in interactive mode (an interface that shows up in chat mode can only be tuned locally).
- **A parameter is tuned but the numbers do not change**: only a control bound to a `$variable` recomputes live (`Slider(..., $amount)`), and the expression must actually reference it (`"金额 " + $amount`). Just ask the model to "make this value adjustable too".

## Background reading stops

- Ensure notifications and background activity are not restricted for the app.
- Background policy and available system voices vary by device.

## Contributing

Issues and Pull Requests are welcome.

1. Fork the repository.
2. Create a feature branch.
3. Follow ArkTS coding conventions.
4. Ensure the project passes type checks and HAP compilation.
5. Open a Pull Request describing the change and verification performed.

## Note

This release does not include local TTS model approaches that were evaluated or prototyped and later reverted. The README describes only functionality present in the current codebase.
