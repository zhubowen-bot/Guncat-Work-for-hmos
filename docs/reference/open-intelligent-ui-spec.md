# Generated-Answer UI Spec — `open-intelligent-ui` (ChatGPT "Intelligent UI" reimplementation)

Reference repo: `C:\Users\a1519\Documents\GitHub\open-intelligent-ui` (read-only analysis).
Target of reproduction: HarmonyOS ArkUI.

Grounded in: `src/app/shell.css`, `src/lib/response-theme.css`, `src/lib/response-theme.ts`,
`src/lib/route/route.css`, `src/lib/route/root.tsx`, `src/lib/route/store.ts`,
`src/lib/travel/travel.css`, `src/lib/travel/components.tsx`, `src/lib/travel/map.tsx`,
`src/lib/travel/map-utils.ts`, `src/lib/travel/use-street-route.ts`, `src/lib/travel/use-dialog.ts`,
`src/lib/travel/vector-basemap.ts`, `src/app/globals.css`, `src/app/api/wiki/route.ts`,
`src/app/api/street-route/route.ts`, `src/lib/library.ts`, `src/lib/prompt-options.ts`,
`src/app/api/chat/route.ts`, `README.md`, plus the OpenUI library that renders it
(`node_modules/@openuidev/react-ui`).

---

## 0. DOM skeleton (so the CSS numbers have a home)

```
div.openui-agent-container (--mobile below 768px measured container width)
└ div.openui-agent-thread-messages            max-width:816px; padding-inline:24px
  └ div.openui-shell-thread-message-assistant        (flex row, assistant logo + content)
    └ div.openui-shell-thread-message-assistant__content   ← answer lives here
      └ div.openui-card.openui-card-full[.openui-card-card]   ← chat Card wrapper
         style="display:flex;flex-direction:column;gap:var(--openui-space-m)" = 12px
        └ div.openui-response.rt-root                        ← project root card
          └ <RouteStoreProvider> children  (TravelHeading, TravelProse, TravelGallery,
                                            TravelMap slot, TravelItinerary, TravelSuggestions,
                                            TravelProse, Form, …)
          └ nav.tv-sources  (only if props.sources?.length)
```

**Important layout fact:** the OpenUI chat `Card` in `openuiChatLibrary.tsx:192-215` renders
`<OpenUICard width="full" style={{display:"flex",flexDirection:"column",gap:"var(--openui-space-m)"}}>`
→ classes `openui-card openui-card-full`, **no** `openui-card-standard` / `openui-card-sunk`, and gap
12px. The project's `Card` root (`src/lib/route/root.tsx`) replaces only the *schema* + children
(the extra travel component refs and the `tv-sources` strip); it does **not** replace that OpenUI
wrapper. So the visual answer container is the OpenUI card **plus** `.rt-root` inside it.

---

## 1. Answer container & layout

### 1.1 Outer OpenUI card (`.openui-card.openui-card-full`) — from `dist/styles/card.css`

| property | literal value | source |
| --- | --- | --- |
| `display` | `flex` | card.css |
| `flex-direction` | `column` (inline style from chat Card) | openuiChatLibrary.tsx:204 |
| `gap` | `var(--openui-space-m)` = **12px** (inline style wins over the class) | openuiChatLibrary.tsx:207 |
| `border` | `1px solid rgba(0,0,0,0)` (transparent — no visible border) | card.css |
| `box-sizing` | `border-box` | card.css |
| `color` | `var(--openui-text-neutral-primary)` = **`#0d0d0d`** | card.css + theme |
| `font` | `var(--openui-text-body-default)` = **`400 16px/1.5 Inter, sans-serif`** | card.css |
| `letter-spacing` | `var(--openui-text-body-default-letter-spacing)` = **`0`** | card.css |
| `width` | `100%` (`.openui-card-full`) | card.css |
| `padding` | **0** — `.openui-card-card` only sets `box-shadow: none`; padding 0 comes from the global reset | card.css + globals.css |
| `border-radius` | **none** on the `card` variant (only `clear`/`sunk` set it) | card.css |
| `box-shadow` | **none** (`.openui-card-card{box-shadow:none}`) | card.css |
| `background` | **transparent** on the `card` variant | card.css |

Project overrides in `response-theme.css` that *do* apply to other variants but **not** to this one:
`response-theme.css:32` `.openui-response .openui-card{gap:24px}` — lower specificity than the inline
`gap:12px`, so the real gap is **12px**;
`:33` `.openui-card-standard{width:100%}` — the class is absent;
`:34` `.openui-card-sunk{padding:20px}` — absent.

### 1.2 The project root card `.rt-root` (`src/lib/route/route.css`)

```css
.rt-root {
  display: flex; flex-direction: column;
  gap: 24px;
  width: 100%; min-width: 0;
  color: var(--iui-ink, #0d0d0d);
  background: var(--iui-canvas, #fff);
  font: 400 16px/1.6 var(--iui-font, system-ui);
}
@media (max-width: 600px) { .rt-root { gap: 20px; } }
```

Then `travel.css:12` overrides it whenever the answer contains any travel component or the map slot
(true for every travel answer, because of `.tv-heading`):

```css
.rt-root:has(.tv-heading, .tv-prose, .tv-gallery, .tv-itinerary, .tv-suggestions, .tv-map-slot) {
  gap: 16px;
  background: transparent;
  color: var(--iui-ink);
  font-family: var(--iui-font);
}
```

**Effective answer container values:**

| property | value |
| --- | --- |
| padding | **0** (padding comes from the shell: `.openui-agent-thread-messages{padding-inline:24px}`, i.e. 24px each side) |
| max width | **816px** (`.openui-agent-thread-messages, .openui-agent-thread-composer{max-width:816px; padding-inline:24px}` → 768px of content) |
| vertical gap between top-level answer blocks | **16px** (24px on a non-travel answer; **20px ≤600px**) |
| gap between the OpenUI card wrapper and `.rt-root` | 12px |
| background | **transparent** (`.rt-root` background is `#fff` only when no travel child exists) |
| radius | **none** |
| borders | **none** (only the 1px transparent `border` on `.openui-card`) |
| shadow | **none** |
| `min-width` | `0` (so long words/URLs can shrink) |
| text color | `#0d0d0d` |
| font | `400 16px/1.6` Inter → the `.rt-root` `font` shorthand wins over `.openui-card`'s 16px/1.5 |

**Vertical rhythm quirks (must be reproduced):**

* `.tv-map-slot{margin-top:24px}` adds to the 16px flex gap → **40px** of space above the map.
* `.tv-title + .tv-prose{margin-top:-8px}` pulls the intro paragraph 8px closer to the title (net 8px).
* `.tv-stop:first-child{padding-top:0}`, `.tv-stop:last-child{padding-bottom:0;border-bottom:0}`.
* Programmatic scroll offsets: `.tv-stop{scroll-margin-block:104px}`, `.tv-map-slot{scroll-margin-top:96px}`.
* `.tv-sources` separator: `nav.tv-sources` after the last child, flex-wrap gap 8px (see §4.3).

### 1.3 Answer-level sources strip (`root.tsx:21-24`, `travel.css:27-28`)

```css
.tv-sources { display:flex; flex-wrap:wrap; gap:8px; font-size:12px; line-height:18px; }
.tv-sources a { color: var(--iui-muted); border:1px solid var(--iui-border);
                border-radius:999px; padding:4px 10px; }
```

Rendered only when `props.sources?.length`; each item is numbered `"{i+1}. {sourceName||title}"`,
`target="_blank" rel="noreferrer"`, URL gated by `safeUrl` (http/https only) and skipped when invalid.

---

## 2. Typography scale

Font family: `--iui-font` → `--openui-font-body` → **`"Inter", sans-serif`** (theme token
`fontBody` in `response-theme.ts` is the system stack, but `createTheme` emits `--openui-font-body`
from the theme; the shipped `dist/styles/index.css` default is `"Inter", sans-serif` and
`globals.css` sets `body.app-font` to `"Inter", ui-sans-serif, system-ui, -apple-system, "Segoe UI",
Roboto, "Helvetica Neue", Arial, sans-serif`). Weight tokens: `400/500/600`.

Base: `.openui-response{font:400 16px/1.6 var(--iui-font); -webkit-font-smoothing:antialiased}`
(`response-theme.css:28`). `.openui-response:has(.tv-heading){font-size:18px; line-height:28px}`.

| element | font-size | weight | line-height | letter-spacing | color |
| --- | --- | --- | --- | --- | --- |
| `.tv-heading` (shared) | — | **600** | — | **-0.25px** | `inherit` → `#0d0d0d` |
| `.tv-title` (TravelHeading `level:"title"`, `<h1>`) | **21px** | 600 | **30px** | -0.25px | `#0d0d0d` |
| `.tv-section-heading` (`level:"section"`, `<h2>`) | **20px** | 600 | **28px** | -0.25px | `#0d0d0d` |
| `.tv-prose` (`<p>`) | **18px** | 400 | **28px** | inherit | `#0d0d0d`; `overflow-wrap:anywhere` |
| `.tv-prose strong`, `.tv-stop-description strong` | inherits | **600** | | | |
| `.tv-prose > a`, `.tv-stop-description > a` | inherits | 400 | | | `inherit`, `border-bottom:1px dotted var(--iui-faint)` = `#8f8f8f` |
| `.tv-citation` | **10px** | 400 | **16px** | — | `var(--iui-muted)` = `#676767` |
| `.tv-citation:hover` | | | | | `var(--iui-ink)` = `#0d0d0d` |
| `.tv-sources` | **12px** | 400 | **18px** | — | link `#676767` |
| `.tv-stop-time` | **14px** | **500** | **20px** | — | `var(--iui-muted)` = `#676767` |
| `.tv-stop-title` (`<h3>`) | **18px** | **600** | **26px** | **-0.12px** | inherit `#0d0d0d` |
| `.tv-stop-description` (`<p>`) | **18px** | 400 | **28px** | — | inherit |
| `.tv-stop-tag` ("Added") | **11px** | 400 | **18px** | | bg `#0d0d0d`, text `#fff` |
| `.tv-stop-toggle`, `.tv-suggestion-add` | **13px** | **500** | **18px** | — | `#0d0d0d` |
| `.tv-map-pill` (filter / recenter / expand) | **12px** | **500** | **18px** | — | `#0d0d0d` |
| `.tv-map-label` (map pin label) | **12px** | **600** | **15px** | — | `#0d0d0d`, `font-family: Arial, Helvetica, sans-serif`, 4-way white `text-shadow` halo |
| `.tv-map-note`, `.tv-map-error` | **12px** | 400 | **18px** | — | `var(--iui-muted)` |
| `.tv-map-overview` ("Route overview") | **10px** | 400 | **16px** | — | `var(--iui-muted)` |
| `.tv-map-surface .maplibregl-ctrl-attrib` | **8px** | 400 | **10px** | — | `var(--iui-muted)` |

OpenUI built-ins inside the answer (relevant because the demo ends with a Form):

| element | value | source |
| --- | --- | --- |
| `.openui-header-top-left` | **21px**, `line-height:1.35`, `letter-spacing:-.4px` | response-theme.css:36 |
| `.openui-header-bottom` | **15px**, `line-height:1.6` | :37 |
| `.openui-form-control > .openui-label` | **16px** / **24px**, weight **500** | :181 |
| `.openui-radio-item-label`, `.openui-checkbox-item-label` | **15px** / **22px**, `color:inherit` | :186-187 |
| `.openui-radio-item-description`, `.openui-checkbox-item-description` | **14px** / **21px**, `var(--iui-muted)` | :193-194 |
| `.openui-button-base` | `font:var(--openui-text-label-default)` = 400 16px/1.25, overridden → **`font-weight:500`**, `min-height:38px`, `padding:8px 16px` | :38 |
| `.openui-button-base-small` | `min-height:32px; padding:6px 12px; font-size:13px` | :40 |
| `.openui-button-base-extra-small` | `min-height:28px; padding:4px 10px; font-size:12px` | :39 |
| `.openui-button-base-large` | `min-height:44px; padding:10px 20px` | :41 |
| `.openui-list-item-indicator-number` | 13px, 24×24 circle, `font-variant-numeric:tabular-nums` | :149 |
| `.openui-metric-indicator__main-value` | weight 500, `letter-spacing:-.6px` | :142 |

---

## 3. Color tokens — complete literal palette used by the response UI

Theme tokens are `createTheme({...})` values from `response-theme.ts`; they are emitted as
`--openui-*` CSS variables. The `--iui-*` aliases in `response-theme.css:4-27` bind to them.

### 3.1 `--iui-*` alias → literal (`response-theme.css:4-27`)

| alias | maps to | literal |
| --- | --- | --- |
| `--iui-font` | `--openui-font-body` | `"Inter", sans-serif` |
| `--iui-canvas` | `--openui-background` | **`#ffffff`** |
| `--iui-surface` | `--openui-sunk` | **`#f7f7f8`** |
| `--iui-surface-hover` | `--openui-highlight-strong` | **`#eeeeef`** |
| `--iui-ink` | `--openui-text-neutral-primary` | **`#0d0d0d`** |
| `--iui-muted` | `--openui-text-neutral-secondary` | **`#676767`** |
| `--iui-faint` | `--openui-text-neutral-tertiary` | **`#8f8f8f`** |
| `--iui-border` | `--openui-border-default` | **`#e7e7e7`** |
| `--iui-border-strong` | `--openui-border-interactive` | **`#cecece`** |
| `--iui-radius` | `--openui-radius-3xl` | **`16px`** |
| `--iui-shadow` | `--openui-shadow-xl` | **`0 4px 20px rgb(0 0 0 / 6%)`** |
| `--iui-focus` | literal | **`#0285ff`** |
| `--iui-blue` | literal | **`#0285ff`** |
| `--iui-green` | literal | **`#008764`** |
| `--iui-range-track` | literal | **`#e5e5e5`** |
| `--iui-range-thumb` | literal | **`#303030`** |
| `--iui-control-gap` | literal | **`8px`** |
| `--iui-label-gap` | literal | **`12px`** |
| `--iui-field-gap` | literal | **`24px`** |
| `--iui-section-gap` | literal | **`32px`** |
| `--iui-action-gap` | literal | **`40px`** |

### 3.2 Travel-only tokens (`travel.css:3-9`)

| token | literal | used for |
| --- | --- | --- |
| `--tv-water` | **`#a9dff0`** | map background while tiles load / behind the surface |
| `--tv-photo-empty` | **`#edf5f8`** | empty photo tile background |
| `--tv-photo-empty-icon` | **`#c4d5de`** | placeholder image glyph |
| `--tv-selected` | **`#f1f6fa`** | selected stop row background **and** its 8px outline |
| `--tv-control-shadow` | **`0 1px 3px rgb(0 0 0 / 14%)`** | map control shadow |

### 3.3 Full theme palette (literal values from `response-theme.ts`)

Backgrounds / surfaces:
`background #ffffff`, `foreground #ffffff`, `popoverBackground #ffffff`, `sunkLight #fafafa`,
`sunk #f7f7f8`, `sunkDeep #ececec`, `elevatedLight #f7f7f8`, `elevated #ffffff`,
`elevatedStrong #e7e7e7`, `elevatedIntense #cecece`, `overlay rgb(0 0 0 / 40%)`,
`highlightSubtle #fafafa`, `highlight #f7f7f8`, `highlightStrong #eeeeef`,
`highlightIntense #e3e3e3`, `invertedBackground #0d0d0d`,
`chatUserResponseBg #f4f4f4`, `chatUserResponseText #0d0d0d`.

Text:
`textNeutralPrimary #0d0d0d`, `textNeutralSecondary #676767`, `textNeutralTertiary #8f8f8f`,
`textNeutralLink #0d0d0d`, `textBrand #0d0d0d`, `textAccentPrimary #ffffff`,
`textAccentSecondary #dadada`, `textAccentTertiary #b4b4b4`.

Interactive accent (buttons): `default #0d0d0d`, `hover #2f2f2f`, `disabled #b4b4b4`,
`pressed #454545`.

Borders: `borderDefault #e7e7e7`, `borderInteractive #cecece`,
`borderInteractiveEmphasis #8f8f8f`, `borderInteractiveSelected #0d0d0d`,
`borderAccent #0d0d0d`, `borderAccentEmphasis #8f8f8f`.

Info / success / warning / danger families (background + text + border emphasis):
| family | background | text | border emphasis |
| --- | --- | --- | --- |
| info | `#edf5ff` | `#0068bc` | `#0285ff` |
| success | `#edf9f2` | `#00805d` | `#008764` |
| warning (alert) | `#fff8e7` | `#946200` | `#e2ab23` |
| danger | `#fff0ee` | `#c1322c` | `#e02e2a` |
| purple | `#f4f0ff` | `#7040c1` | — |
| pink | `#fff0f6` | `#b7377c` | — |

Radii: `6px, 8px, 10px, 12px, 14px, 16px, 20px, 24px` (`radiusS…radius5xl`).
Shadows: `shadowS none`, `shadowM none`, `shadowL 0 2px 8px rgb(0 0 0 / 4%)`,
`shadowXl 0 4px 20px rgb(0 0 0 / 6%)`, `shadow2xl 0 8px 32px rgb(0 0 0 / 10%)`,
`shadow3xl 0 16px 48px rgb(0 0 0 / 12%)`.

**Chart series colors:** none. The demo travel answer uses no chart component, and
`response-theme.ts` defines no chart palette. The only chart-related rules in the project are
presentation overrides in `response-theme.css:143-147` (legend dot `8×8` circle, tooltip
`padding:12px; border-radius:12px`, cartesian grid `stroke:var(--iui-border); stroke-dasharray:3 4`).
Chart colors would come from the OpenUI chart defaults, which this theme does not define.

Additional literal colors not covered by tokens:
`#e5e5e5` (scroll/starer borders), `#f9f9f9` (sidebar bg), `#f0f0f0` (sidebar border),
`#ebebeb`/`#eeeeee` (sidebar hover/selected), `#e3e3e3` (composer border), `#c4c4c4` (composer focus),
`#d9d9d9` (disabled submit button bg), `#f7f7f7` (starter hover bg), `#0285ff` (focus ring),
`rgb(2 133 255 / 15%)` (input focus ring), map pin `background var(--iui-canvas)` (= `#fff`) +
`border 1px solid var(--iui-border)` (= `#e7e7e7`) + `box-shadow: 0 1px 4px rgb(0 0 0 / 20%)`,
route line `line-color:#272727`, route line width `3.2px`, expanded-map outline
`24px solid rgb(255 255 255 / 90%)`, expanded-map shadow `0 12px 64px rgb(0 0 0 / 18%)`,
bookmark `background rgb(0 0 0 / 9%)` / color `rgb(255 255 255 / 80%)` → hover/saved
`rgb(0 0 0 / 28%)` / `#fff`, overview chip `rgb(255 255 255 / 92%)`,
attribution `rgb(255 255 255 / 90%)`, `::selection` n/a.

---

## 4. Component anatomy

### 4.1 `Card` root — `src/lib/route/root.tsx` + §1

```tsx
export const RouteCard = defineComponent({
  name: "Card",
  props: base.props.extend({
    children: z.array(z.union([...baseChild.options, TravelGallery.ref, TravelHeading.ref,
      TravelItinerary.ref, TravelSuggestions.ref, TravelMap.ref, TravelProse.ref,
      TravelImage.ref, TravelStop.ref])),
  }),
  component: ({ props, renderNode }) => <RouteStoreProvider>
    <div className="openui-response rt-root">{renderNode(props.children)}
      {!!props.sources?.length && <nav className="tv-sources" aria-label="Response sources">…</nav>}
    </div>
  </RouteStoreProvider>,
});
```

* One `<div class="openui-response rt-root">`; children render in order, vertically, gap 16px (§1.2).
* `openui-response` scopes all `--iui-*` / `--tv-*` variables and every built-in override.
* `RouteStoreProvider` (`store.ts:29-32`) mints `route-${useId()}` as the id namespace for one
  response; `mapId = "route-<id>-map"`, `stopId(k) = "route-<id>-stop-<encodeURIComponent(k)>"`.
* Layout: no padding, no background, no radius, no border, no shadow, `width:100%`, `min-width:0`.

### 4.2 `TravelHeading` — `components.tsx:74-81`

```tsx
props.level === "section"
  ? <h2 className="tv-heading tv-section-heading"><StreamingText text={props.text} /></h2>
  : <h1 className="tv-heading tv-title"><StreamingText text={props.text} /></h1>
```

* 21px/600/30px/-0.25px (`title`) or 20px/600/28px/-0.25px (`section`), color `#0d0d0d`, margins 0.
* `TravelItinerary` / `TravelSuggestions` render their own `title` as `<h2 class="tv-heading
  tv-section-heading">` when non-empty.
* Text is word-faded while streaming (§6).

### 4.3 `TravelProse` — `components.tsx:83-88`

```tsx
<p className="tv-prose">
  <StreamingText text={props.text} />
  {nodeProps<CitationData>(props.citations).map((c,i) => <Citation key={`${c.url}-${i}`} citation={c} />)}
</p>
```

* 18px/28px, `overflow-wrap:anywhere`, margins 0; `strong` → 600; bare links → `color:inherit`
  with `border-bottom:1px dotted #8f8f8f`, no underline (`text-decoration:none`).
* Inline grammar parsed by `InlineText` (`components.tsx:30-46`) from a single regex
  `/(\*\*([^*]+)\*\*|\[([^\]]+)\]\((https?:\/\/[^\s)]+)\))/g`: `**bold**` → `<strong>`,
  `[label](https://url)` → `<a target="_blank" rel="noreferrer">` with `safeUrl` gating.
  Everything else stays literal text, so **partial model tokens remain readable as text**.
* Followed by zero or more citation pills; because `.tv-citation` is `display:inline-flex` and
  `margin-left:5px`, pills sit inline at the end of the paragraph and wrap with it.

### 4.4 `TravelCitation` — `components.tsx:57-72` + `travel.css:23-26`

```
a.tv-citation[href][title]
├ (img[src=icon] width:12 height:12 border-radius:50% object-fit:contain)   ← when icon is a safe URL
│ or <span aria-hidden="true">emoji</span>                                  ← when icon is not a URL
└ span  (label; ellipsised)
```

```css
.tv-citation { display:inline-flex; align-items:center; gap:5px; max-width:168px;
  padding:2px 7px; margin-left:5px; border-radius:999px; vertical-align:baseline;
  background:var(--iui-surface); color:var(--iui-muted); text-decoration:none;
  font-size:10px; font-weight:400; line-height:16px; white-space:nowrap; }
.tv-citation > span:last-child { overflow:hidden; text-overflow:ellipsis; }
.tv-citation > img { width:12px; height:12px; border-radius:50%; object-fit:contain; }
.tv-citation:hover { background:var(--iui-surface-hover); color:var(--iui-ink); }
```

* Renders `null` when `label` or a safe `url` is missing (partial stream → nothing).
* `:focus-visible` → `outline:2px solid #0285ff; outline-offset:3px`.

### 4.5 `TravelImage` / `Photo` — `components.tsx:92-132`

```
figure.tv-photo                               border-radius:12px; overflow:hidden;
├ (a[href] | nothing)                         background:var(--tv-photo-empty) = #edf5f8
│ └ img | span.tv-photo-placeholder
└ button.tv-bookmark (gallery only)
```

```css
.tv-gallery { display:flex; gap:8px; min-width:0; }
.tv-gallery > .tv-photo { flex:1 1 0; aspect-ratio:1.25; }        /* 5:4 landscape */
.tv-photo { position:relative; min-width:0; overflow:hidden; border-radius:12px;
            background:var(--tv-photo-empty); }
.tv-photo > a { display:block; width:100%; height:100%; }
.tv-photo img { display:block; width:100%; height:100%; object-fit:cover;
                object-position: `${focalX ?? 50}% 50%` (inline style); }
.tv-photo-placeholder { display:flex; width:100%; height:100%; min-height:48px;
  align-items:center; justify-content:center;
  color:var(--tv-photo-empty-icon); background:var(--tv-photo-empty); }
.tv-photo-placeholder svg { width:26px; height:26px; }
```

* **Aspect ratios:** gallery tile **1.25** (5:4); itinerary stop thumb **124×124** (square, 84×84
  ≤520px); suggestion photo **1.5** (3:2).
* `object-fit:cover` always; horizontal crop chosen by `focalX` 0–100 (default 50).
* `<img referrerPolicy="no-referrer">`; `onError` pushes the failing URL into `failedUrls` and the
  component then renders the next candidate.
* **Fallback chain** (`components.tsx:98-118`): `safeUrl(photo.src, true)` (local `/…` allowed) →
  if it fails or is absent and `wikiTitle ||= photo.alt` exists, fetch `/api/wiki?title=…` →
  try primary then each Wikipedia photo in order → first URL not in `failedUrls` wins →
  when exhausted: `span.tv-photo-placeholder` with a 26px picture glyph, **or** `null` when
  `hideIfMissing` is true.
* Bookmark (gallery only, `components.tsx:121-123`):
  `position:absolute; top:9px; right:9px; 34×34; padding:7px; border:0; border-radius:50%;
  background:rgb(0 0 0 / 9%); color:rgb(255 255 255 / 80%); backdrop-filter:blur(12px);`
  svg 20×20 (filled when saved). Hover or `.is-saved`: `color:#fff; background:rgb(0 0 0 / 28%)`.
  Local-only state (`useState`), `aria-pressed`, `aria-label` "Save/Unsave <alt>".

### 4.6 `TravelGallery` — `components.tsx:134-146`

```tsx
<div className="tv-gallery">
  {photos.map((photo,i) => <Photo key={i} photo={photo} bookmark hideIfMissing={!streaming} />)}
</div>
```

* `display:flex; gap:8px` — **deliberately not a fixed 3-column grid**, so a photo with no working
  image drops out and the rest stretch (each tile `flex:1 1 0`, aspect 1.25).
* Schema allows at most 6 images; the prompt asks for three.
* `hideIfMissing` is true **only after streaming ends** (see §6.4).

### 4.7 `TravelStop` / `TravelStopRow` — `components.tsx:160-186` + `travel.css:45-57`

```
article.tv-stop[.is-selected][.is-removed][id]
├ figure.tv-photo            (124×124)
└ div.tv-stop-content
  ├ div.tv-stop-time  (when time || isAdded)   "1:00–2:00 PM" + optional span.tv-stop-tag "Added"
  ├ h3.tv-stop-title  → a[href] | button
  ├ p.tv-stop-description  (when description || story) + citations
  └ button.tv-stop-toggle  "Remove from my route" | "Add back"
```

```css
.tv-stop-list { display:flex; flex-direction:column; }
.tv-stop { display:grid; grid-template-columns:124px minmax(0,1fr); align-items:start;
  gap:14px; padding:22px 0; border-bottom:1px solid var(--iui-border);
  scroll-margin-block:104px; transition:background .18s ease; }
.tv-stop:first-child { padding-top:0; }
.tv-stop:last-child  { padding-bottom:0; border-bottom:0; }
.tv-stop > .tv-photo { width:124px; height:124px; }
.tv-stop.is-selected { background:var(--tv-selected); outline:8px solid var(--tv-selected);
                       border-radius:6px; }
.tv-stop.is-removed > .tv-photo, .tv-stop.is-removed .tv-stop-time,
.tv-stop.is-removed .tv-stop-title, .tv-stop.is-removed .tv-stop-description { opacity:.45; }
```

* Title as a **link** when `stop.link` is safe (`<a target="_blank" rel="noreferrer">`), else a
  **button** that selects the stop and smooth-scrolls the map into view
  (`document.getElementById("${mapId}-travel")?.scrollIntoView({behavior:"smooth",block:"center"})`).
  Both get `border-bottom:1px dotted #8f8f8f`, becoming `solid` on hover.
* `span.tv-stop-tag`: `display:inline-block; margin-left:8px; padding:0 8px; border-radius:999px;
  background:var(--iui-ink); color:var(--iui-canvas); font-size:11px; line-height:18px;
  vertical-align:1px`.
* Toggle button (`travel.css:60-62`):
  `display:inline-flex; align-items:center; justify-content:center; min-height:32px;
  padding:6px 14px; border:1px solid var(--iui-border); border-radius:999px;
  background:var(--iui-canvas); color:var(--iui-ink); font:500 13px/18px inherit;
  cursor:pointer; transition:background .15s ease, border-color .15s ease; margin-top:12px;`
  hover → `background:var(--iui-surface); border-color:var(--iui-border-strong)`.
  `aria-pressed={removed}`; label flips between "Remove from my route" and "Add back".
* **Removed state**: only the photo, time, title and description fade to `opacity:.45` — the
  toggle stays full opacity so it can be clicked again. The row remains in place (no collapse).

### 4.8 `TravelItinerary` — `components.tsx:188-200` + `travel.css:43`

```tsx
const stops = withAdded(nodeProps<TravelStopData>(props.stops), route.getAdded());
<section className="tv-itinerary">
  {props.title && <h2 className="tv-heading tv-section-heading">{props.title}</h2>}
  <div className="tv-stop-list">{stops.map((s,i) => <TravelStopRow key={getStopKey(s) || `pending-${i}`} stop={s} />)}</div>
</section>
```

```css
.tv-itinerary, .tv-suggestions { display:flex; flex-direction:column; gap:16px; }
```

* `withAdded` appends user-added suggestions whose key is not already present, in insertion order;
  a `key` is `stop.id || stop.name || ""`, and rows with no key yet get `pending-${i}` so partial
  stream tokens keep a stable React identity.
* Stop rows are separated by 1px `#e7e7e7` hairlines (except last) with 22px vertical padding.

### 4.9 `TravelSuggestions` — `components.tsx:202-226` + `travel.css:63-71`

```
section.tv-suggestions
├ h2.tv-heading.tv-section-heading (optional)
└ div.tv-suggestion-list
  └ article.tv-suggestion
    ├ figure.tv-photo (aspect 1.5)
    ├ div.tv-suggestion-content → h3.tv-stop-title + div.tv-stop-time
    └ button.tv-suggestion-add  "+ Add to my route" | "Added to route"
```

```css
.tv-suggestion-list { display:grid; grid-template-columns:repeat(auto-fit, minmax(180px,1fr));
                     gap:12px; }
.tv-suggestion { display:flex; flex-direction:column; gap:10px; min-width:0; }
.tv-suggestion > .tv-photo { aspect-ratio:1.5; }
.tv-suggestion-content .tv-stop-title { margin-bottom:2px; }
.tv-suggestion-content .tv-stop-time  { margin-bottom:0; }
```

* Add button default: `border-color:var(--iui-ink); background:var(--iui-ink);
  color:var(--iui-canvas)` (solid black pill), hover →
  `background/border:var(--openui-interactive-accent-hover)` = **`#2f2f2f`**.
* `.is-added`: `border-color:var(--iui-border); background:var(--iui-surface);
  color:var(--iui-muted); cursor:default;` — text "Added to route".
* `disabled` without `.is-added` → `opacity:.5; cursor:default`. Disabled when `!key`, when already
  added, or when `coordinate(stop)` is null (still-streaming coordinates).
* Click: `route.addStop(stop); route.selectStop(key);` — no scroll (unlike the itinerary title).
* Schema: max 4 suggestions; the prompt asks for 2–3 extra places **not** in the itinerary, each
  with a `+1 hr`-style duration.

### 4.10 `TravelMap` — see §5.

### 4.11 OpenUI built-ins actually used in the demo answer

Only these are emitted by the model in the travel answer (per `prompt-options.ts:12-32`):
`Form`, `FormControl`, `RadioGroup`, `RadioItem`, `CheckBoxGroup`, `CheckBoxItem`, `Button`,
`Buttons`. Everything below is what they actually render.

**`Form`** (`genui-lib/Form/index.tsx:17-31`):

```tsx
<div role="form" style={{display:"flex", flexDirection:"column", gap:"16px"}}>
  {renderNode(props.fields)}
  {renderNode(props.buttons)}
</div>
```

* DOM: `<div role="form">` with fields first, then the `Buttons` group as the **last child**.
* Project override (`response-theme.css:50-51`):
  ```css
  .openui-response [role="form"]:has(> .openui-form-control) { gap: var(--iui-field-gap) !important; } /* 24px */
  .openui-response [role="form"] > .openui-buttons:last-child { margin-top: calc(var(--iui-action-gap) - var(--iui-field-gap)); } /* 40-24 = 16px */
  ```
  → field-to-field gap **24px**, and the button row sits **40px** below the last field
  (16px margin + the 24px flex gap). Note the rule only matches when the form's direct children are
  `.openui-form-control` elements — the project's prompt requires each field to be its own
  `FormControl` reference, so it does.
* Fields stream in one at a time (`openuiLibrary` note: "Define EACH FormControl as its own
  reference"), as does the Form itself.

**`FormControl`** (`genui-lib/FormControl/index.tsx:22-48`):

```tsx
<div class="openui-form-control" style="display:flex;flex-direction:column;gap:var(--openui-space-s)">  /* 8px default */
  <label class="openui-label text-sm font-medium" for={fieldName}>Label</label>
  {input}
  {error ? <div class="openui-hint openui-hint-error">…</div> : hint ? <div class="openui-hint">…</div> : null}
</div>
```

* Project override: `gap: var(--iui-label-gap)` = **12px**; label becomes
  `font-size:16px; line-height:24px; font-weight:500` (overriding Tailwind's `text-sm font-medium`).
* No `rules.required` in the travel form, so no asterisk and no error hint.

**`RadioGroup`** (`genui-lib/RadioGroup/index.tsx:27-83`, `components/RadioGroup/RadioGroup.tsx:20-32`):
Radix `Radio.Root` with classes `openui-radio-group openui-radio-group-clear`
(`variant` defaults to `"clear"`). Base `.openui-radio-group` is a **column** flex,
`gap:var(--openui-space-xs)` = 6px, `border:1px solid`, `border-radius:var(--openui-radius-xl)` = 12px;
`.openui-radio-group-clear` zeroes border color/background and sets `padding:var(--openui-space-000)` = 0.

Project override makes it a **wrapping row of pills** (`response-theme.css:182-194`):

```css
.openui-response .openui-radio-group-clear,
.openui-response .openui-checkbox-group-clear {
  display:flex; flex-direction:row; flex-wrap:wrap; gap:var(--iui-control-gap);   /* 8px */
}
.openui-response .openui-radio-group-clear > .openui-radio-item-container,
.openui-response .openui-checkbox-group-clear > .openui-checkbox-item-container {
  position:relative; width:auto; min-height:42px; padding:9px 16px;
  border:1px solid var(--iui-border); border-radius:999px; background:#fff; cursor:pointer;
}
.openui-response .openui-radio-item-label,
.openui-response .openui-checkbox-item-label { font-size:15px; line-height:22px; color:inherit; }
.openui-response :is(.openui-radio-group-clear, .openui-checkbox-group-clear) > label:has([aria-checked="true"]) {
  border-color:var(--iui-ink); background:var(--iui-ink); color:#fff;
}
.openui-response :is(…) > label:has(:focus-visible) { outline:2px solid var(--iui-focus); outline-offset:3px; }
.openui-response :is(…) > label:not(:has(.openui-radio-item-description, .openui-checkbox-item-description)) > button {
  position:absolute; inset:0; width:100%; height:100%; opacity:0;   /* fat hit target */
}
```

* **DOM for one item** (`components/RadioItem/RadioItem.tsx:19-62`):
  ```html
  <label class="openui-radio-item-container" for={id}>
    <button class="openui-radio-item-root" role="radio" aria-checked="true|false" id={id}>
      <svg class="openui-radio-item-svg" width=16 height=16>…3 paths…</svg>
    </button>
    <div class="openui-radio-item-content">
      <label class="openui-radio-item-label" for={id}>Label</label>
      <p class="openui-radio-item-description">Description</p>   <!-- only when non-empty -->
    </div>
  </label>
  ```
* **Short labels with empty descriptions** (what the travel prompt demands): the Radix button is
  invisible but stretched to fill the pill (`inset:0; opacity:0`), so the whole pill is the control;
  the visible text comes from `.openui-radio-item-label` at 15px/22px, and the base
  `.openui-radio-item-root` 16×16 circle is hidden behind the pill. Selected pill =
  black background (`#0d0d0d`) + white text.
* **With a description** (not used in the travel answer, but the CSS supports it): the label becomes
  `flex:1 1 180px; align-items:flex-start; padding:14px 16px; border-radius:14px`, selected state is
  a quiet `background:var(--iui-surface)` + `color:var(--iui-ink)` instead of black; description is
  14px/21px `#676767`.
* Hover: there is **no** project hover rule for these pills (base `.openui-radio-item-root` hover
  states apply to the invisible 16px circle only) — pills change appearance on selection only.
* Stream behaviour: `disabled={isStreaming}` on the group; the field writes through
  `useStateField(props.name, props.value)` and the default comes from
  `RadioGroup(name, items, defaultValue)` (the prompt requires the default to exactly match an option
  value; e.g. `"full-day"`, `"transit"`).
* Loading/empty: `if (!items.length) return null` — a RadioGroup with no streamed items renders
  nothing.

**`CheckBoxGroup`** (`genui-lib/CheckBoxGroup/index.tsx:32-88`, `components/CheckBoxGroup/CheckBoxGroup.tsx:20-31`):
renders `div.openui-checkbox-group.openui-checkbox-group-clear` — same pill treatment as RadioGroup.
Item DOM (`components/CheckBoxItem/CheckBoxItem.tsx:22-60`):

```html
<label class="openui-checkbox-item-container" for={id}>
  <button class="openui-checkbox-item-root" role="checkbox" aria-checked=… data-state="checked|unchecked" id={id}>
    <span class="openui-checkbox-item-indicator"><svg width=10 height=8>✓</svg></span>
  </button>
  <div class="openui-checkbox-item-content">
    <label class="openui-checkbox-item-label">Label</label>
    <p class="openui-checkbox-item-description">…</p>
  </div>
</label>
```

* Base checkbox square is 16×16, `border-radius:var(--openui-radius-xs)` = **4px**, border
  `1px solid var(--openui-border-interactive)`; `[data-state=checked]` →
  `background:var(--openui-interactive-accent-default)` = `#0d0d0d`.
  Project override: `.openui-response .openui-checkbox-item-root{border-radius:5px}`.
* Multi-select; value is an aggregate `Record<name, boolean>` in one state field
  (`field.setValue({...getAggregate(), [name]: val})`). `defaultChecked` per item; the travel example
  pre-checks "Landmarks".
* Same selected-pill CSS via `label:has([aria-checked="true"])` → black pill + white text; same
  invisible-button stretch when there is no description.

**`Button` / `Buttons`** (`genui-lib/Buttons/index.tsx:14-23`, `genui-lib/Button/index.tsx:24-67`):

```tsx
<div class="openui-buttons openui-buttons-horizontal">   /* direction "row" default; column → -vertical */
  <button class="openui-button-base openui-button-base-primary openui-button-base-medium">…</button>
</div>
```
* `.openui-buttons{display:flex;width:100%;gap:var(--openui-space-m)}` = **12px**;
  `-horizontal` row + wrap, `-vertical` column.
* Base `.openui-button-base{border-radius:var(--openui-radius-l) /*10px*/; border:1px solid
  transparent; font:var(--openui-text-label-default) /*400 16px/1.25*/; cursor:pointer;
  transition:all .12s ease; display:flex; gap:var(--openui-space-xs) /*6px*/; align-items:center}`.
* Project overrides (`response-theme.css:38-44`): `border-radius:999px; box-shadow:none;
  font-weight:500; justify-content:center; min-height:38px; padding:8px 16px`;
  `.openui-button-base-primary{border-color:transparent}`;
  `.openui-button-base-secondary{border-color:var(--iui-border); background:var(--iui-canvas)}`
  with hover `background:var(--iui-surface)`.
* Primary colors: `background:var(--openui-interactive-accent-default)` = **`#0d0d0d`**,
  `color:var(--openui-text-accent-primary)` = **`#ffffff`**; hover → `#2f2f2f`; active → `#454545`;
  disabled → `background:#b4b4b4; cursor:not-allowed`. (`box-shadow:var(--openui-shadow-m)` in the
  base is cancelled by the project's `box-shadow:none`; the theme sets `shadowM: "none"` anyway.)
* **Disabled while streaming**: `disabled={isStreaming}` (`Button/index.tsx:40`).
* **Click behaviour** (`Button/index.tsx:41-62` + `react-lang/dist/exports-Cab8UG5o.mjs:475-543`):
  for a `primary` variant with an `ActionPlan` containing a `ToAssistant` step, the form is validated
  first (`formValidation.validateForm()`; returns early if invalid — no required rules in this demo,
  so it always passes). Then `triggerAction(label, formName, action)`:
  * `ToAssistant` step → `onAction({ type: ContinueConversation, params: step.context ? {context} : {},
    humanFriendlyMessage: step.message, formState: getFormPayload(formName), formName })`.
  * `getFormPayload` returns `{ [formName]: raw }` for the form in scope — **only that form's field
    values**, while the response-level `routeRemoved/routeAdded/routeSelected` fields ride along in
    the persisted message context (§7).
* The demo emits exactly one primary button:
  `Button("Personalize my trip", Action([@ToAssistant("Customize my Lisbon itinerary with these preferences")]), "primary")`.

---

## 5. The map

### 5.1 DOM (`map.tsx:196-218`)

```html
<div class="tv-map-slot" id="route-<id>-map-travel">
  <div class="tv-map-wrap[ is-expanded]" role="region|dialog" aria-modal? aria-label="Sightseeing route map" tabindex?>
    <div class="tv-map-surface" />                             <!-- MapLibre canvas -->
    <div class="tv-map-top-left">                              <!-- z-index:500; top:12 left:12 -->
      <label class="tv-map-pill tv-map-filter">
        <select aria-label="Filter map groups"> all | <category> … </select>
        <svg 16×16 chevron/>
      </label>
      <button class="tv-map-pill tv-map-recenter" aria-label="Show entire route"><svg 24×24/></button>
      <button class="tv-map-info" aria-label="About this map" aria-expanded><svg 20×20/></button>
    </div>
    <button class="tv-map-pill tv-map-expand" aria-expanded>Expand|Collapse <svg 20×20/></button>
    {infoOpen && <div class="tv-map-note">Drag to explore. …{routeNote}</div>}
    {routeKind==="overview" && <div class="tv-map-overview" title="…">Route overview</div>}
    <span class="tv-map-status" role="status">{routeStatus}</span>
    {mapError && <div class="tv-map-error" role="status">Map tiles are temporarily unavailable. Your stops and route are still shown.</div>}
  </div>
</div>
```

### 5.2 Sizing / container CSS

```css
.tv-map-slot { margin-top:24px; min-height:400px; scroll-margin-top:96px; }
.tv-map-wrap { position:relative; height:400px; overflow:hidden; border-radius:20px;
               background:var(--tv-water); isolation:isolate; }
.tv-map-surface { position:absolute; inset:0; z-index:0; background:var(--tv-water); }
.tv-map-wrap.is-expanded { position:fixed; inset:24px; height:auto; z-index:1500;
  outline:24px solid rgb(255 255 255 / 90%); box-shadow:0 12px 64px rgb(0 0 0 / 18%); }
.tv-map-top-left { position:absolute; z-index:500; top:12px; left:12px;
                   display:flex; align-items:center; gap:8px; }
.tv-map-pill { display:inline-flex; align-items:center; gap:6px; min-height:34px;
  padding:6px 12px; color:var(--iui-ink); background:var(--iui-canvas);
  border:1px solid var(--iui-border); border-radius:999px;
  box-shadow:var(--tv-control-shadow); font:500 12px/18px inherit; cursor:pointer; }
.tv-map-filter { position:relative; padding:0; }
.tv-map-filter select { appearance:none; border:0; border-radius:999px;
  padding:8px 30px 8px 12px; max-width:180px; background:transparent; color:inherit;
  font:inherit; cursor:pointer; }
.tv-map-filter > svg { position:absolute; right:10px; width:14px; height:14px; pointer-events:none; }
.tv-map-recenter { width:34px; height:34px; padding:6px; justify-content:center; }
.tv-map-recenter svg { width:22px; height:22px; }
.tv-map-info { display:grid; place-items:center; width:22px; height:22px; padding:3px;
  border-radius:7px; color:var(--iui-muted); background:var(--iui-canvas);
  border:1px solid var(--iui-border-strong); box-shadow:var(--tv-control-shadow); cursor:pointer; }
.tv-map-info svg { width:16px; height:16px; }
.tv-map-expand { position:absolute; top:12px; right:12px; z-index:500;
  min-height:28px; padding:4px 10px; }
.tv-map-expand svg { width:14px; height:14px; }
.tv-map-pill:hover, .tv-map-info:hover { background:var(--iui-surface); }
.tv-map-note, .tv-map-error { position:absolute; top:56px; left:12px; z-index:500;
  max-width:275px; padding:12px; border:1px solid var(--iui-border); border-radius:12px;
  color:var(--iui-muted); background:var(--iui-canvas); box-shadow:var(--iui-shadow);
  font:400 12px/18px; }
.tv-map-error { top:auto; bottom:28px; }
.tv-map-overview { position:absolute; bottom:22px; left:12px; z-index:500; padding:2px 7px;
  border-radius:6px; background:rgb(255 255 255 / 92%); color:var(--iui-muted);
  font:400 10px/16px; }
.tv-map-status { position:absolute; width:1px; height:1px; padding:0; margin:-1px;
  overflow:hidden; clip:rect(0,0,0,0); white-space:nowrap; border:0; }   /* SR-only */
```

Attribution / navigation controls:

```css
.tv-map-surface .maplibregl-ctrl-attrib { max-width:calc(100% - 50px); padding:1px 4px;
  background:rgb(255 255 255 / 90%); color:var(--iui-muted); font:400 8px/10px; }
.tv-map-surface .maplibregl-ctrl-group { border:1px solid var(--iui-border);
  border-radius:10px; overflow:hidden; box-shadow:var(--tv-control-shadow);
  opacity:0; transition:opacity .15s ease; }
.tv-map-wrap:hover .maplibregl-ctrl-group, .tv-map-wrap:focus-within .maplibregl-ctrl-group { opacity:1; }
.tv-map-surface .maplibregl-ctrl-group button { width:28px; height:28px; }
```

### 5.3 Basemap (`vector-basemap.ts`)

* `loadMapLibre()` lazily `import("maplibre-gl")` and calls
  `lib.setWorkerUrl(new URL("maplibre-gl/dist/maplibre-gl-worker.mjs", import.meta.url).toString())`
  so Next emits a versioned same-origin worker.
* `vectorStyle`: OpenFreeMap vector tiles (`https://tiles.openfreemap.org/planet`, glyphs from
  `https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf`). Layers, in order:
  `background #f4f2f0`; `landcover` fill `#bce9b0 @0.8` (wood/grass); `parks #b7e7aa`;
  `school/university/hospital #ede8d7`; `water #a2dff5`; `waterways` line `#91d6ef` width 1;
  `buildings #e9e6e2` (minzoom 14); `streets` line `#cdd1d9` (width interpolate 9→0.3, 12→1.5,
  14→2.8, 17→8) excluding rail/transit/ferry/motorway/trunk/primary; `main-roads #b1b9c8`
  (9→0.7, 12→3, 14→5, 17→12); `ferries #89cfe9` width 0.8; `neighborhood-labels` (minzoom 10,
  maxzoom 15, uppercase 10px `#687078`, halo `#fff` 1.2); `city-labels` (minzoom 7, maxzoom 13,
  14px `#50545a`, halo `#fff` 1.5).
  One attribution: `© OpenStreetMap · OpenFreeMap`.
* `rasterStyle` (fallback): ArcGIS `World_Street_Map` raster tiles, `tileSize:256`, `maxzoom:19`,
  attribution `Tiles © Esri — OpenStreetMap contributors`.
* Map init options: `center:[0,20], zoom:1, minZoom:0, scrollZoom:false, dragRotate:false,
  pitchWithRotate:false, touchPitch:false, attributionControl:false`;
  `touchZoomRotate.disableRotation()`;
  `AttributionControl({compact:false})` at **bottom-left**;
  `NavigationControl({showCompass:false})` at **bottom-right**.
  Comment in code: *"Zoom levels are one lower than Leaflet's: MapLibre uses 512px tiles."*
* Fallback trigger: on `error`, if a `sourceId` exists and isn't `"places"`, ignore; otherwise
  `fellBack = true; instance.setStyle(rasterStyle)`. A second error sets `mapError` (renders
  `.tv-map-error`); `sourcedata` with `isSourceLoaded` clears it.
* `style.load` (fires for both styles) re-creates the `route` GeoJSON source and the line layer if
  absent, calls `setLine(instance, linePoints.current)` and sets `ready = true`.

### 5.4 Pins

* **Created only for "ready" stops** (`map.tsx:49`):
  ```ts
  const readyStops = stops.filter((stop) => stop.name && coordinate(stop) && (!streaming || !!stop.emoji));
  ```
  `coordinate()` requires finite `lat`/`lng` within ±90/±180. During streaming a stop additionally
  needs an `emoji`, because — as the comment says — *"Emoji follows both coordinates in the schema,
  so its presence marks complete coordinate tokens. Numeric prefixes such as `-1` / `-12` must not
  move the map."* This is the key anti-flicker rule for streamed pins.
* **Geometry** (`map-utils.ts:46-62`): the marker is a `div.tv-map-marker[role=button][tabindex=0]`
  containing `div.tv-map-marker-content` → `span.tv-map-pin` + `span.tv-map-label`.
  MapLibre is constructed with `new lib.Marker({ element, anchor:"top", offset:[0,-17] })` so the
  **pin's centre**, not the label below it, sits on the coordinate.
* **Emoji resolution** (`map-utils.ts:38-43`): `Intl.Segmenter(undefined,{granularity:"grapheme"})`
  takes the first grapheme of `value.trim()` and returns it only if
  `/\p{Extended_Pictographic}/u` matches; otherwise the default **`📍`**. A word, letter, number or
  symbol from the model can never overflow the pin.
* **Pin visual**:

```css
.tv-map-marker { cursor:pointer; }
.tv-map-marker-content { position:relative; display:flex; width:34px; flex-direction:column;
                         align-items:center; animation:tv-pin-in 104ms cubic-bezier(.2,.7,.3,1) both;
                         transform-origin:50% 17px; }
.tv-map-pin { display:flex; align-items:center; justify-content:center; width:34px; height:34px;
  flex-shrink:0; background:var(--iui-canvas); border:1px solid var(--iui-border);
  border-radius:50%; box-shadow:0 1px 4px rgb(0 0 0 / 20%); font-size:18px; line-height:1; }
.tv-map-pin.is-selected { outline:3px solid var(--iui-focus); }   /* #0285ff */
.tv-map-label { display:block; max-width:160px; margin-top:3px; color:var(--iui-ink);
  font-family:Arial, Helvetica, sans-serif; font-size:12px; font-weight:600; line-height:15px;
  text-align:center; white-space:nowrap;
  text-shadow:0 1px 2px white, 0 -1px 2px white, 1px 0 2px white, -1px 0 2px white; }
```

  → **a 34×34 white circle** (border `#e7e7e7`, shadow `0 1px 4px rgb(0 0 0 / 20%)`) with an
  18px emoji centred in it, and a 12px/600 Arial label underneath with a 4-way white halo,
  capped at 160px wide (120px + ellipsis ≤520px). Selected pin adds a **3px `#0285ff` outline**.
* **Reconciliation** (`map.tsx:108-144`): keys are `getStopKey = id || name || ""`. Removed keys have
  their marker `.remove()`d; existing markers are updated **in place**
  (`setLngLat`, `title`, `aria-label`, `pin.textContent`, `label.textContent`,
  `pin.classList.toggle("is-selected")`, `element.style.zIndex = selected===key ? "2" : ""`).
  The effect depends on `[lib, ready, stopSignature, group, selected, version]` where
  `stopSignature = JSON.stringify(readyStops.map(s => [key, name, lat, lng, emoji, category]))` and
  `version = JSON.stringify([removedKeys, addedStops.map(getStopKey)])` — *"Object identities change
  each token. Reconcile completed primitive values only."*
* **Initial camera** (`map.tsx:138-142`): on the first ready pin, if not yet anchored,
  `jumpTo({ center: firstStop, zoom: 10.5 })` — *"Begin with a steady city overview; subsequent
  points do not move the camera."* `anchored` is never reset except on unmount, so the camera stays
  put while pins stream in.
* **Interaction**: click or Enter/Space on the marker calls (`map.tsx:118-123`)

  ```ts
  route.selectStop(key);
  const wasExpanded = expandedNow.current;
  if (wasExpanded) setExpanded(false);            // collapse the dialog first
  window.setTimeout(() => document.getElementById(route.stopId(key))
      ?.scrollIntoView({ behavior:"smooth", block:"center" }),
    wasExpanded ? 80 : 0);                        // wait for the dialog to close before scrolling
  ```
  `:focus-visible` on the marker → `outline:2px solid #0285ff; outline-offset:3px`.

### 5.5 Category filtering

* Options come from the stops themselves:
  `categories = Array.from(new Set(stops.map(s => s.category).filter(Boolean)))` — so the `<select>`
  always starts with `<option value="all">All groups</option>` and then one option per distinct
  category in **first-appearance order**.
* `visibleStops = readyStops.filter(s => !route.isRemoved(getStopKey(s)) && (group==="all" || s.category===group))`
  — the filter and the "removed" state compose; removed stops also get no pin.
* Changing the group (a) re-reconciles pins, (b) clears the route line:
  `linePoints.current = []; setLine(map.current, [])` — comment: *"A filter change must not keep
  displaying the previous group's route."* then (c) re-frames the camera to the new group and
  (d) redraws. The `fitSignature` guard (`JSON.stringify([group, routingKey])`) prevents redundant
  flights, where `routingKey = visibleStops.map(s => lngLat(coordinate(s)).join(",")).join(";")`.
* Street routing only applies to the unfiltered view:
  `suppliedPath = group==="all" && Array.isArray(path) && path.filter(coordinate).length > 1` and
  `useStreetRoute(routingKey, !suppliedPath)`; a filtered group draws **straight connections**
  between its stops (`routeKind` becomes `"street"` only if OSRM returns points).

### 5.6 Route line

* Source/layer created on every `style.load`:
  ```ts
  instance.addSource("route", {type:"geojson", data:{type:"FeatureCollection", features:[]}});
  instance.addLayer({ id:"route", type:"line", source:"route",
    layout:{ "line-cap":"round", "line-join":"round" },
    paint:{ "line-color":"#272727", "line-width":3.2 } });
  ```
  (`ROUTE = "route"`.)
* **Geometry priority** (`map.tsx:169`):
  `suppliedPath ? path.map(coordinate).filter(Boolean) : streetPoints?.length ? streetPoints : fitPoints.current`
  → model-supplied `TravelMap.route` coordinates win; otherwise OSRM street geometry; otherwise the
  stops connected in visiting order.
* `useStreetRoute` (`use-street-route.ts`): fires only when enabled, when the key contains `";"`, and
  when not cached; **debounced 700ms**; 10s `AbortController` timeout; parses
  `{points: [[lat,lng],…]}` through `coordinate()`; requires ≥2 points. Returns `LatLng[]` (ok),
  **`null` (failed)**, or **`undefined` (loading)**. Client cache is a `Map` capped at 64 entries.
* **Route kinds and their visible copy** (`map.tsx:57, 191-194`):

  | condition | `routeKind` | info-note text | SR status |
  | --- | --- | --- | --- |
  | supplied `route` array, group "all" | `supplied` | "The line shows the supplied sightseeing route." | "Supplied route shown." |
  | OSRM returned ≥2 points | `street` | "Street geometry by OSRM / OpenStreetMap. This road overview is not turn-by-turn or mixed-mode travel guidance." | "Street route loaded." |
  | OSRM returned `null` | `overview` | "The line connects stops in visiting order. Street routing is unavailable or still loading; this is a route overview, not turn-by-turn directions." | "Street routing unavailable. Showing direct connections between stops." |
  | still loading | `loading` | (same text as overview) | "Street route loading. Showing direct connections between stops." |

  `routeKind === "overview"` additionally renders the `Route overview` chip at bottom-left.

* **Draw animation** (`map.tsx:165-184`):
  1. waits for framing (`framedKey === routingKey`) and `!streaming`;
  2. sets `linePoints.current = positions.length > 1 ? positions : []`;
  3. **immediately** draws the full line and sets `lineDrawn` when there are <2 points, when the line
     was already drawn, or when reduced motion is preferred;
  4. otherwise animates over `DRAW_MS = 760ms` inside `requestAnimationFrame`, with easing
     `t < 0.5 ? 2t² : 1 - (-2t+2)²/2` (ease-in-out quad) feeding `partialLine(positions, eased)`.
     `partialLine` (`map-utils.ts:23-34`) walks the polyline accumulating segment lengths and cuts it
     at `progress` of the **total length**, interpolating within the final segment.
  5. cleanup cancels the frame and re-sets the full line.

### 5.7 Framing / bounds

```ts
const FRAME_PADDING = { top:70, left:42, bottom:50, right:52 };
const FLY_MS = 920;
```

* `boundsOf(points)` (`map-utils.ts:15-18`) → MapLibre `[[minLng,minLat],[maxLng,maxLat]]`.
* Fly-to-fit runs only when `ready && !streaming && fitPoints.length`:
  ```ts
  const nextFit = JSON.stringify([group, routingKey]);
  if (fitSignature.current === nextFit) return;     // no redundant flights
  fitSignature.current = nextFit;
  linePoints.current = []; setLine(map.current, []);  // drop the previous group's line
  if (userMoved.current || reducedMotion()) {
    if (!userMoved.current) map.current.fitBounds(bounds, {padding:FRAME_PADDING, maxZoom:12.2, animate:false});
    setFramedKey(routingKey); return;
  }
  map.current.fitBounds(bounds, {padding:FRAME_PADDING, maxZoom:12.2, duration:FLY_MS, linear:false});
  const timer = window.setTimeout(() => setFramedKey(routingKey), FLY_MS + 40);  // 960ms
  ```
  Comment: *"fitBounds may not emit moveend when the viewport already matches."*
  `userMoved` is set on `dragstart` and then **the camera is never moved again automatically** unless
  reduced motion is on (in which case a plain non-animated `fitBounds` is still applied).
* Recenter button re-fits with a different, tighter padding:
  `{top:55, left:34, bottom:35, right:40}, maxZoom:14` (animated — no `animate:false`).
* `ResizeObserver` on the surface calls `instance.resize()` only — *"A resize must never reframe the
  camera during streaming or user panning."* `expanded` changes trigger a single `rAF` resize.

### 5.8 Expansion / dialog

* Button toggles `expanded`; label flips `Expand` ⇄ `Collapse`, `aria-expanded` mirrors it.
* `.tv-map-wrap.is-expanded{position:fixed; inset:24px; height:auto; z-index:1500;
  outline:24px solid rgb(255 255 255 / 90%); box-shadow:0 12px 64px rgb(0 0 0 / 18%)}`
  → the 24px white outline acts as the dialog's surround.
* `role` flips `region` → `dialog`, `aria-modal={expanded || undefined}`, `tabIndex={expanded ? -1 : undefined}`.
* `useDialog(container, expanded, () => setExpanded(false))` (`use-dialog.ts`):
  saves `document.activeElement`, sets `document.body.style.overflow = "hidden"`, focuses the
  container, traps `Tab`/`Shift+Tab` among visible
  `button, select, a[href], [tabindex="0"]` inside the container, closes on `Escape`; on cleanup it
  restores the previous overflow and re-focuses the previously active element. The effect
  deliberately depends only on `[open]` — *"`close` only flips state; re-running on its identity
  would steal focus."*
* Reduced motion: the 760ms draw and the fly-to are skipped; the resize still happens.

---

## 6. Progressive streaming behaviour

`useIsStreaming()` from `@openuidev/react-lang` is true for the **last** assistant message while the
thread is running (`GenUIAssistantMessage.tsx:31`: `isRunning && lastAssistantId === message.id`), so
every component below reacts to one flag.

### 6.1 Word fade (`TravelHeading`, `TravelProse`, `TravelStop` description)

`InlineText` (`components.tsx:30-46`) splits text on `/(\s+)/` and wraps every non-whitespace token:

```tsx
<span className="tv-stream-word" style={{"--word-delay": `${(i % 12) * 12}ms`}}>{word}</span>
```

```css
@keyframes tv-fade-in { from { opacity:0; filter:blur(2px); } to { opacity:1; filter:blur(0); } }
.tv-stream-word { animation: tv-fade-in 320ms ease-out both;
                  animation-delay: var(--word-delay, 0ms); }
```

* **320ms** duration, `ease-out`, `both` fill, blur 2px→0, opacity 0→1.
* Delay cycles **0, 12, 24, … 132ms** (`(i % 12) * 12ms`, where `i` is the word index **within that
  text run**), so a fresh chunk cascades in over ~132ms.
* **Only while streaming, and only for the message that entered while streaming**:
  ```tsx
  const streaming = useIsStreaming();
  const [enteredWhileStreaming] = useState(streaming);   // latch, never updated
  return <InlineText text={text} animate={enteredWhileStreaming} />;
  ```
  Comment: *"Keep token wrappers stable after completion so existing words never flash again."*
  A completed message re-rendered (e.g. after a reload from history) has `enteredWhileStreaming =
  false` and renders plain text strings — no spans, no animation.
* Whitespace between words is preserved as raw text; `strong` and `a` contents get the same word
  treatment; delimiters are handled by the `**`/`[]()` regex, so a half-arrived `**bold` or
  `[label](ht` simply renders as literal characters until it completes.
* `prefers-reduced-motion: reduce` disables the animation entirely (`.tv-stream-word { animation:none }`).

### 6.2 Pins during the stream, route line after it

| | while streaming | after the stream ends |
| --- | --- | --- |
| stops rendered as pins | only those with `name`, valid coordinates **and** an `emoji` | all with `name` + valid coordinates |
| camera | `jumpTo(firstStop, zoom 10.5)` once; never moves again | `fitBounds(allStops, FRAME_PADDING, maxZoom 12.2, duration 920ms)` once per `[group,routingKey]` |
| route line | never drawn (`if (streaming) return`) | cleared, then drawn: street/supplied geometry, or straight `fitPoints` fallback |
| line animation | — | 760ms eased `partialLine` progress (skipped for reduced motion) |
| `fitSignature` | untouched | set to `JSON.stringify([group, routingKey])` |

So the visual story is: *pins pop in one by one around a static city view; when the answer finishes,
the camera flies to fit the whole route and the dark 3.2px line draws itself along it.*

### 6.3 Partial / undefined data

* Unknown string props stream as partial values; `InlineText` returns `null` when `text` is not a
  string, so a not-yet-arrived paragraph renders nothing rather than `undefined`.
* `nodeProps()` (`components.tsx:20-27`) flattens children arrays, tolerating `{props:{…}}` wrappers
  and dropping anything that is not an object → lists grow as elements arrive.
* Stops lacking an `id`/`name` still key as `` `pending-${i}` `` so React keeps their identity
  while the definition streams.
* Citations and gallery images with missing label/URL return `null`.
* `RadioGroup`/`CheckBoxGroup` return `null` until at least one item exists
  (`if (!items.length) return null`).
* Every interactive control is `disabled` while `isStreaming`
  (Button, RadioGroup, CheckBoxGroup), except the map's own controls and the photo bookmark.
* `TravelMap` only animates/derives from *completed* values (see the `stopSignature` comment).

### 6.4 Placeholder handling & the gallery "hide if no working image" rule

* Photo placeholder: `span.tv-photo-placeholder` (flex-centred 26px picture glyph on
  `#edf5f8`, icon `#c4d5de`, `min-height:48px`) with `role="img"` and
  `aria-label={photo.alt || "Photograph loading"}` — shown while a URL is still streaming or while
  the Wikipedia fallback is in flight.
* `TravelGallery` passes `hideIfMissing={!streaming}` (`components.tsx:143`):
  `Photo` returns `null` only when `exhausted && hideIfMissing`, where
  `exhausted = !src && !primaryOk && (!wikiTitle || wikiImages?.title === wikiTitle)` — i.e.
  there is no usable URL left **and** Wikipedia has already answered (or there is no title to ask
  about). Consequences:
  * **While streaming:** a tile with no working image keeps its placeholder, so the layout does not
    jump as URLs arrive.
  * **After streaming:** a tile with no working image is **removed entirely**, and the remaining
    tiles stretch to fill the row (`.tv-gallery > .tv-photo { flex:1 1 0 }`). This is why the gallery
    is flex rather than a fixed 3-column grid.
  * A tile whose image fails in a **finished** message disappears on the `onError` state update.
* Itinerary/suggestion photos never hide (`hideIfMissing` defaults to `false`) — they fall back to
  the placeholder box.

### 6.5 Streaming vs complete — other differences

* `useStreetRoute` fetches as soon as the routing key is stable, but the line effect is gated on
  `!streaming`, so a route fetched mid-stream is used the moment the answer ends (cache hit).
* `Buttons`/`Button` become enabled exactly when `isStreaming` flips false.
* `Form` validation registers fields only when `!isStreaming` (both RadioGroup and CheckBoxGroup
  register/unregister in an effect gated on `isStreaming`).

---

## 7. State & reactivity model

### 7.1 Per-response store (`src/lib/route/store.ts`)

```ts
const RouteNamespace = createContext<string | null>(null);
export function RouteStoreProvider({children}) {
  const id = useId();
  return createElement(RouteNamespace.Provider, { value: `route-${id}` }, children);
}

export function useRouteStore() {
  const removed  = useStateField<string[]>("routeRemoved", []);
  const added    = useStateField<StopData[]>("routeAdded", []);
  const selected = useStateField<string | null>("routeSelected", null);
  …
}
```

* `useStateField` resolves against the OpenUI **response store** (`useOpenUI().store`), which
  `Renderer` creates per response with `useMemo(() => createStore(), [])` and initialises from the
  message's persisted `initialState`. So the three fields are scoped to **one assistant message**.
* Field names are global within that store — all route components in one answer share them.
* `RouteNamespace` gives a stable DOM-id prefix for the whole response:
  `mapId = \`${namespace}-map\``, `stopId(key) = \`${namespace}-stop-${encodeURIComponent(key)}\``.
  (Without a `RouteStoreProvider`, `useRouteStore` falls back to `route-${useId()}`.)
* Values are read defensively: `removed.value ?? []`, `added.value ?? []`, `selected.value ?? null`.
* `version = JSON.stringify([removedKeys, addedStops.map(getStopKey)])` — used as the map's pin
  reconciliation dependency so any edit re-runs it.

### 7.2 Operations

| op | effect |
| --- | --- |
| `selectStop(key)` | `selected.setValue(key)` |
| `toggleStop(key)` | appends `key` to `routeRemoved`, or removes it if present (no-op on `""`) |
| `addStop(stop)` | no-op without a key or if already added; copies **only plain stop fields** (`id, name, wikiTitle, lat, lng, time, story, beforeYouGo, category, photos, imageUrl, imageFocalX, emoji, description, link`) into `routeAdded`; if the key was in `routeRemoved`, it is removed from there |
| `isRemoved(key)` / `isAdded(key)` | membership tests used for `is-removed` / `is-selected` / `Added` tag / button labels |
| `getAdded()` | the added list, appended by `withAdded()` to both the itinerary and the map's stop list |

Comment in code: *"Only plain stop fields: this is saved with the message."* — the added list is
serialized into the transcript, so it must stay JSON-plain.

### 7.3 What is saved with the message

`GenUIAssistantMessage.tsx:57-67` persists on **every** state change:

```ts
const handleStateUpdate = (state) => {
  const hasState = Object.keys(state).length > 0;
  const contentPart = wrapContentWithHeader(content ?? "", contentHeader);
  const fullMessage = hasState ? contentPart + wrapContext(JSON.stringify([state])) : contentPart;
  updateMessage({ ...message, content: fullMessage });
};
```

* `wrapContentWithHeader` → `` `]]>openui:content\n<openui-lang>` `` (preserving the original header
  line verbatim so `libraryVersion`/telemetry attrs survive the round trip).
* `wrapContext(json)` → `` `\n]]>openui:context\n<json>` `` — the state is wrapped in an array:
  `[{routeRemoved:{value:[…],componentType:…}, routeAdded:{value:[…]}, routeSelected:{value:"…"}}]`.
* On reload, `separateContentAndContext` splits the two sections and `initialState = parsed[0]`, so
  the edits survive a page reload together with the thread.
* Note the marker set (`sentinelParser.ts:1-9`): `]]>openui:content`, `]]>openui:context`,
  `]]>openui:end`. Partial marker prefixes at the tail of a streaming chunk are trimmed so a
  half-arrived token never flashes as raw text; a bare `]]>openui:end` marks a well-formed end and is
  stripped. A legacy `<content>`/`<context>` XML envelope is still parsed for old persisted messages.

### 7.4 How edits reach the model on the next turn

There are **two** channels:

1. **Full state, as context, on any subsequent user turn.**
   The browser sends the whole message list to `/api/chat`, and the persisted assistant content still
   ends with `]]>openui:context\n[{…}]`. The route handler rewrites it
   (`src/app/api/chat/route.ts:80-91`):

   ```ts
   const CONTEXT_MARKER = "]]>openui:context";
   function describeRouteEdits(content: string): string {
     const at = content.indexOf(CONTEXT_MARKER);
     if (at < 0) return content;
     let state: Record<string, { value?: unknown }> = {};
     try { state = (JSON.parse(content.slice(at + CONTEXT_MARKER.length).trim()))[0] ?? {}; }
     catch { return content.slice(0, at); }
     const removed = Array.isArray(state.routeRemoved?.value) ? state.routeRemoved.value : [];
     const added = Array.isArray(state.routeAdded?.value)
       ? state.routeAdded.value.map((s) => s?.name || s?.id).filter(Boolean) : [];
     const edits = [
       removed.length && `removed stops (by id): ${removed.join(", ")}`,
       added.length && `added stops: ${added.join(", ")}`,
     ].filter(Boolean);
     return content.slice(0, at) + (edits.length ? `\n\n(User's edits to this route: ${edits.join("; ")}.)` : "");
   }
   ```

   * Applied **only to assistant messages** (`toInput`, line 103).
   * Removed stops are listed **by id** (raw keys); added stops are listed **by `name` (falling back
     to `id`)**.
   * The whole `]]>openui:context` block — including `routeSelected` and the raw JSON — is stripped
     and replaced by the single sentence, or by nothing when there are no edits. A JSON parse failure
     also just truncates at the marker.
   * `routeSelected` is therefore **not** reported to the model; only removed/added stops are.
   * Everything before the marker (the OpenUI-Lang program itself) is preserved verbatim.
   * The prompt (`prompt-options.ts:39`) tells the model: *"an earlier answer may end with
     `(User's edits to this route: ...)` listing TravelStop ids the user removed and places they
     added. Treat that edited route as the current one in follow-ups and rebuilt itineraries."*
   * `toInput` keeps only `user`/`assistant` messages with string/array content and slices the last
     `MAX_ITEMS = 60`; body is capped at `MAX_BODY_BYTES = 1_000_000` (413 beyond that).

2. **Form submission via the button.** A click on the primary button builds its own user message in
   `handleAction` (`GenUIAssistantMessage.tsx:70-95`):

   ```ts
   const messageCtx = [`User clicked: ${event.humanFriendlyMessage}`];
   if (event.formState) messageCtx.push(event.formState);
   processMessage({ role: "user", content: wrapContent(event.humanFriendlyMessage) + wrapContext(JSON.stringify(messageCtx)) });
   ```

   So the next turn's user message is
   `]]>openui:content\nCustomize my Lisbon itinerary with these preferences` plus
   `]]>openui:context\n["User clicked: …", { customize: { time: {value:"full-day",…}, travel: …, interests: … } }]`.
   It is a natural-language request, and the form values ride along as JSON context. `formState`
   contains **only the named form's fields**; response-level fields such as the route edits are *not*
   duplicated here.

The parent agent should note: the `]]>openui:context` note rewriting lives **only** in
`src/app/api/chat/route.ts`; the OpenUI packages merely produce/consume the sentinel
(`react-ui/src/utils/sentinelParser.ts`, `components/OpenUIChat/GenUIAssistantMessage.tsx`).

---

## 8. The exact interaction closed loop

### 8.1 Click a pin on the map

1. User clicks `div.tv-map-marker` (or presses Enter/Space on it).
2. `route.selectStop(key)` → `selected.setValue(key)` in the response store →
   `onStateUpdate(store.getSnapshot())`.
3. `GenUIAssistantMessage.handleStateUpdate` rewrites the message content to
   `]]>openui:content…\n]]>openui:context\n[{routeSelected:{value:"belem"},…}]` and calls `updateMessage`.
4. React re-renders every consumer of `useRouteStore()`: the selected pin gains `.is-selected`
   (3px `#0285ff` outline) and `z-index:2` (it sits above other pins), and the matching
   `article.tv-stop` gains `.is-selected` (`background:#f1f6fa; outline:8px solid #f1f6fa;
   border-radius:6px`).
5. If the map was expanded, `setExpanded(false)` runs first, the dialog's `useDialog` cleanup
   restores body scroll and focus, and after **80ms** the itinerary row is smooth-scrolled into view
   (`scroll-margin-block:104px` keeps it clear of the sticky header). Unexpanded, the scroll starts
   immediately (0ms).
6. No network request. This is a purely local, persisted visual state.

### 8.2 Click "Remove from my route" / "Add back"

1. `route.toggleStop(key)` mutates `routeRemoved`.
2. Persisted into the message context as above.
3. `version` changes → the map's reconcile effect drops (or re-adds) the pin; the row keeps its place
   but its photo/time/title/description drop to `opacity:.45` (or return to 1), and the button label
   flips. The route line is **not** recomputed by a removal, because `routingKey` is built from
   `visibleStops` — so it *is* recomputed: `visibleStops` excludes removed stops, so `routingKey`
   changes, `useStreetRoute` refetches (debounced 700ms), the camera refits and the line redraws
   through the remaining stops. (`fitSignature` differs, so the fly-to runs again.)

### 8.3 Click "+ Add to my route" on a suggestion

1. `route.addStop(stop)` appends a sanitized plain-field copy to `routeAdded` (and clears the key
   from `routeRemoved` if present); then `route.selectStop(key)`.
2. Icon: the button becomes `.is-added` → `"Added to route"`, `disabled`, quiet styling; a new pin
   appears on the map (animation `tv-pin-in 104ms`); a new `article.tv-stop` is appended to the
   itinerary with a `span.tv-stop-tag` "Added" next to its time, and it becomes `.is-selected`
   (so the map and the new row are highlighted together).
3. Route/camera/line update exactly as in 8.2.
4. Persisted into `]]>openui:context` with the message.

### 8.4 Click a stop title (non-link stops)

`route.selectStop(key)` then
`document.getElementById(`${mapId}-travel`)?.scrollIntoView({behavior:"smooth", block:"center"})` —
the inverse of the pin click: it selects the stop and scrolls **the map** into view. (Stops with a
safe `stop.link` render an `<a target="_blank" rel="noreferrer">` instead and just open the link.)

### 8.5 Adjust the map

* **Filter**: `setGroup(value)` → §5.5.
* **Recenter**: `fitBounds(fitPoints, {top:55,left:34,bottom:35,right:40}, maxZoom:14)` (animated).
* **Info**: toggles `.tv-map-note` (`aria-expanded`).
* **Expand/Collapse**: §5.8.
* **Drag**: sets `userMoved` permanently, so later automatic framing is suppressed (only the
  recenter button moves the camera afterwards).

### 8.6 Fill the form and press the primary button

1. Each `RadioGroup`/`CheckBoxGroup` write-through `setFieldValue(formName, …, name, wrappedValue)`;
   the wrapped `{value, componentType}` objects accumulate in the store under the form name; every
   write persists the message context.
2. Click "Personalize my trip" → `Button` validates the form (no required rules here → passes), then
   `triggerAction("Personalize my trip", "customize", Action([@ToAssistant("Customize my Lisbon
   itinerary with these preferences")]))`.
3. The `ToAssistant` step calls `onAction({type: ContinueConversation,
   humanFriendlyMessage:"Customize my Lisbon itinerary with these preferences",
   formState:{customize:{…}}, formName:"customize"})`.
4. `handleAction` builds the user message
   `]]>openui:content\nCustomize my Lisbon itinerary with these preferences` +
   `]]>openui:context\n["User clicked: Customize my Lisbon itinerary with these preferences",{customize:{…}}]`
   and calls `processMessage({role:"user", content})`.
5. The thread store appends the user message, sets `isRunning`, and POSTs the whole conversation to
   `/api/chat`.
6. `/api/chat` validates `content-type: application/json`, size ≤1MB, `messages` non-empty; maps to
   `ResponseInputItem[]` keeping only user/assistant text and slicing the last 60 items; rewrites any
   assistant `]]>openui:context` tail into `(User's edits to this route: removed stops (by id): …;
   added stops: ….)`; then calls `client.responses.create({model, instructions, input, tools, store:false,
   reasoning?, stream:true})` and relays the upstream events as SSE
   (`data: {json}\n\n`, `text/event-stream`, `Cache-Control: no-cache, no-transform`); errors become a
   JSON error response with the upstream status (or 502) and a trailing `{type:"error"}` SSE event.
7. The browser parses the SSE with `openAIResponsesAdapter()`; the thread store appends a **new**
   assistant message; `Renderer` parses it incrementally with `createStreamingParser`, and the new
   answer streams in: headline and prose words fade in, gallery tiles appear and fill in, pins pop in
   around a static city view, the Form fields appear one at a time — then, when the stream ends, the
   map flies to fit the route and draws the line, and the form controls become interactive.
8. This new message gets its own `RouteStoreProvider` namespace and its own response store, so the
   old answer keeps its own edits and the new one starts clean.

---

## 9. Responsive behaviour

| breakpoint | trigger | what changes |
| --- | --- | --- |
| **768px** | `Container` measures its own width: `isMobile = width > 0 && width < 768` (and `isFullScreen = width > 768`) → adds `openui-agent-container--mobile` | sidebar becomes an overlay drawer (294px wide, `position:absolute; left:0`, slides via `left` transition 400ms); mobile header shown; compact composer padding `12px 12px max(16px, env(safe-area-inset-bottom))`; thread messages `padding-inline:16px`; welcome screen `padding:24px`; welcome title 30px→**28px** with `letter-spacing:-0.6px` |
| **600px** | `@media (max-width:600px)` in `route.css`, `response-theme.css`, `shell.css`(implicit) | `.rt-root{gap:20px}` (from 16px); `.openui-header-top-left{font-size:19px}` (from 21px); `.openui-card-sunk{padding:16px}`; `.openui-table-cell/.openui-table-head{padding:11px 12px}`; `.openui-tabs-trigger{padding:8px 11px}`; `.openui-accordion{padding:14px 14px 0}`; pie/radial charts with a stacked row legend switch to `flex-direction:column; max-height:none` with a full-width legend |
| **520px** | `@media (max-width:520px)` in `travel.css` | `.tv-prose, .tv-stop-description{font-size:16px; line-height:25px}` (from 18/28); `.tv-stop{grid-template-columns:84px minmax(0,1fr); gap:12px}`; `.tv-stop > .tv-photo{width:84px; height:84px}`; `.tv-stop-title{font-size:16px; line-height:23px}`; `.tv-stop-time{font-size:12px; line-height:18px}`; `.tv-map-wrap, .tv-map-slot{min-height:320px; height:320px}`; `.tv-map-wrap.is-expanded{height:auto; inset:12px; outline-width:12px}`; `.tv-map-label{max-width:120px; overflow:hidden; text-overflow:ellipsis; font-size:10px}`; `.tv-bookmark{width:28px; height:28px; padding:5px; top:6px; right:6px}` |

Container/layout constants that are **not** breakpoint-dependent:

* `.chat-shell{width:100%; height:100dvh; overflow:hidden}`.
* `.openui-agent-thread-messages, .openui-agent-thread-composer{max-width:816px; padding-inline:24px}`
  → the answer is always centred in an 816px column, 24px in from each edge.
* `.openui-agent-welcome-screen{max-width:816px; padding:24px 24px 80px; gap:32px}`.
* `.openui-agent-thread-message-user__content{max-width:85%; padding:12px 20px; border-radius:24px}`.
* Map height is a fixed `400px` (320px ≤520px) regardless of width; the map's own controls do not
  reflow, except the pin label cap and the expanded inset.
* `.tv-gallery` never changes column count (it is a flex row at every width), and
  `.tv-suggestion-list` is `repeat(auto-fit, minmax(180px,1fr))`, so the suggestion grid reflows
  naturally with the container rather than at a named breakpoint.

Two motion-related media queries:

* `response-theme.css:175-177` — under `prefers-reduced-motion: reduce`, everything inside
  `.openui-response` gets `animation-duration:.01ms !important;
  animation-iteration-count:1 !important; transition-duration:.01ms !important;
  scroll-behavior:auto !important`.
* `travel.css:115-118` — additionally removes the `.tv-stop` background transition, and sets
  `animation:none` for `.tv-stream-word`, `.tv-map-marker-content` and `.tv-photo img`.
* `shell.css:206-210` — composer border/shadow transitions are disabled.

---

## 10. Motion / timing cheat-sheet

| animation | duration | easing / delay | source |
| --- | --- | --- | --- |
| streamed word fade | **320ms** | `ease-out`, `both`; `animation-delay:(i%12)*12ms` | `travel.css:112` |
| photo fade-in | **300ms** | `ease-out`, `both` | `travel.css:113` |
| pin pop-in | **104ms** | `cubic-bezier(.2,.7,.3,1)`, `both`, `transform-origin:50% 17px`, from `scale(.75)` | `travel.css:111,114` |
| route line draw | **760ms** | ease-in-out quad (`t<0.5 ? 2t² : 1-(-2t+2)²/2`) over polyline length | `map.tsx:16,176-182` |
| camera fly-to-fit | **920ms** | `linear:false`; window for `setFramedKey` = **960ms** | `map.tsx:15,159-161` |
| stop background (selection) | **180ms** | `ease` | `travel.css:45` |
| toggle / suggestion-add background+border | **150ms** | `ease` | `travel.css:60` |
| map control group opacity | **150ms** | `ease` | `travel.css:102` |
| composer border/shadow | **150ms** | `ease` | `shell.css:95` |
| street-route fetch debounce | **700ms** | then a 10s abort timeout | `use-street-route.ts:18-19,35` |
| scroll after pin click in an expanded dialog | **80ms** delay | then `scrollIntoView({behavior:"smooth",block:"center"})` | `map.tsx:122` |
