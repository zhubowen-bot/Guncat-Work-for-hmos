(function () {
    const term = new Terminal({
        cursorBlink: true,
        // 内置字体优先，回退等宽
        fontFamily: '"JetBrains Mono", "Fira Code", "Source Code Pro", monospace',
        fontSize: 14,
        theme: {
            background: '#000000',
            foreground: '#E6E6E6',
            cursor: '#5DD46E',
            cursorAccent: '#000000',
            selectionBackground: '#3A4A5A',
            black: '#0E0E0E',
            brightBlack: '#666666'
        },
        scrollback: 5000
        // 注意:删掉 convertEol: true
        // SoftPty 的 ldisc 已经做了 ONLCR (\n -> \r\n)
        // 再叠 convertEol 会导致某些命令输出 \r\n\n 双换行
    });
    const fit = new FitAddon.FitAddon();
    term.loadAddon(fit);
    term.open(document.getElementById('terminal'));
    fit.fit();

    // 首次尺寸上报:等 bridge 就绪后再发
    function reportInitialSize() {
        if (window.hbridge && window.hbridge.resize) {
            window.hbridge.resize(term.cols, term.rows);
        } else {
            // bridge 尚未就绪,50ms 后重试
            setTimeout(reportInitialSize, 50);
        }
    }
    reportInitialSize();

    window.addEventListener('resize', () => {
        fit.fit();
        // fit 后如果 bridge 已就绪,汇报尺寸
        if (window.hbridge && window.hbridge.resize) {
            window.hbridge.resize(term.cols, term.rows);
        }
    });

    // ---- ArkTS -> xterm (文本直写,老接口) ----
    window.termWrite   = (s) => term.write(s);
    window.termWriteln = (s) => term.writeln(s);
    window.termClear   = () => term.clear();

    // ---- ArkTS -> xterm (base64 二进制通道,新接口) ----
    // native 侧 xchan 把输出编成 base64 发过来,这里解回 Uint8Array
    // 用 requestAnimationFrame 合帧,防止高频小写卡 UI
    let feedBuffer = [];
    let feedScheduled = false;

    function drainFeed() {
        feedScheduled = false;
        if (feedBuffer.length === 0) return;
        const chunks = feedBuffer;
        feedBuffer = [];
        let total = 0;
        for (const c of chunks) total += c.length;
        const merged = new Uint8Array(total);
        let off = 0;
        for (const c of chunks) { merged.set(c, off); off += c.length; }
        term.write(merged);
    }

    function base64ToU8(b64) {
        const bin = atob(b64);
        const n = bin.length;
        const arr = new Uint8Array(n);
        for (let i = 0; i < n; i++) arr[i] = bin.charCodeAt(i);
        return arr;
    }

    window.__bshFeed = function (b64) {
        if (!b64) return;
        feedBuffer.push(base64ToU8(b64));
        if (!feedScheduled) {
            feedScheduled = true;
            requestAnimationFrame(drainFeed);
        }
    };

    // ---- 用户输入 -> ArkTS ----
    // bridge 建立会稍晚于 term.onData 首次触发,先 pending
    let pending = '';
    term.onData((data) => {
        if (window.hbridge && window.hbridge.input) {
            window.hbridge.input(data);
        } else {
            pending += data;
        }
    });
    window.flushPendingInput = () => {
        if (pending && window.hbridge && window.hbridge.input) {
            window.hbridge.input(pending);
            pending = '';
        }
    };

    // ---- 让 ArkTS 能读取初始尺寸 ----
    window.getTermSize = () => JSON.stringify({ cols: term.cols, rows: term.rows });

    // ---- 设置项(ArkTS 设置面板调用)----
    function setOpt(key, val) {
        if (term.options.update) { term.options.update({ [key]: val }); }
        else { term.options[key] = val; }
    }
    window.setTermFontSize = (n) => {
        setOpt('fontSize', n);
        try { fit.fit(); } catch (e) { /* ignore */ }
        if (window.hbridge && window.hbridge.resize) {
            window.hbridge.resize(term.cols, term.rows);
        }
    };
    window.setTermCursorBlink = (b) => { setOpt('cursorBlink', !!b); };
    // 字体样式:传 'Default' 用内置字体栈,否则用指定字体 + 等宽兜底(设置面板调用)
    const DEFAULT_FONT_FAMILY = '"JetBrains Mono", "Fira Code", "Source Code Pro", monospace';
    window.setTermFontFamily = (name) => {
        setOpt('fontFamily', (name && name !== 'Default') ? `"${name}", monospace` : DEFAULT_FONT_FAMILY);
        try { fit.fit(); } catch (e) { /* ignore */ }
        if (window.hbridge && window.hbridge.resize) {
            window.hbridge.resize(term.cols, term.rows);
        }
    };
    // 光标样式:BLOCK / BEAM / UNDERLINE -> xterm 的 block / bar / underline
    window.setTermCursorStyle = (shape) => {
        setOpt('cursorStyle', shape === 'BEAM' ? 'bar' : (shape === 'UNDERLINE' ? 'underline' : 'block'));
    };

    // ---- 右键:复制 / 粘贴(免剪贴板权限)----
    // 症状:原来"粘贴"是页面发起(hbridge.ctxPaste)→ ArkTS 读剪贴板,而读剪贴板要么声明
    // 受限权限 ohos.permission.READ_PASTEBOARD(还要进签名 profile 的 ACL),要么由用户点一下
    // 安全控件 PasteButton —— 点它的那一刻系统才临时授权。
    // 修法:页面这一侧不再读剪贴板,只负责"决定这次右键做什么",两条模式(由
    // `bshutil set right-click menu|smart` 决定,ArkTS 通过 window.setRightClickMode 告知):
    //   menu  —— 什么都不做,只压掉内核菜单;菜单由 ArkTS 侧提供(宿主是一层只在 menu
    //            模式存在的透明覆盖层),复制走 hbridge.ctxCopy、粘贴点菜单里的 PasteButton;
    //   smart —— 不弹菜单:有选区就把选中文本交给 hbridge.ctxCopy(写剪贴板免权限),
    //            没有选区就调 hbridge.ctxSmartPaste 让 ArkTS"试着粘贴"一次 ——
    //            没有读剪贴板权限时那次尝试必然失败,ArkTS 只提示一句,不会弹菜单。
    // ArkTS 的 PasteButton 读到剪贴板后经 window.termPaste 把文本递回来。
    let rightClickMode = 'menu';
    window.setRightClickMode = (m) => { rightClickMode = (m === 'smart') ? 'smart' : 'menu'; };

    // ArkTS 的 PasteButton 读到剪贴板后把文本递回来走这里。用 xterm 自己的 paste():它会把
    // \r\n 归一成 \r,并在前台程序开了 bracketed paste(DECSET 2004,如 vim)时自动包
    // \x1b[200~ … \x1b[201~ —— 自己拼字符串会丢掉这层语义。
    window.termPaste = (text) => { if (text) term.paste(text); };

    const termEl = document.getElementById('terminal');

    // 右键按下时先把选区记一份:菜单弹出/关闭这段时间里 xterm 有可能把选区清掉,等到
    // ArkTS 的菜单项来问选区时,还能给出用户"当时选中的东西"。capture 阶段只读,
    // 不干扰 xterm 的 mousedown。
    let selOnRightDown = '';
    termEl.addEventListener('mousedown', (e) => {
        if (e.button === 2) selOnRightDown = term.getSelection() || '';
    }, true);

    // ArkTS 菜单项「复制」来问选区(结果按 JSON 文本回给 runJavaScript)
    window.termGetSelection = () => term.getSelection() || selOnRightDown;

    // 右键本体。capture 阶段一律 preventDefault + stopPropagation:压掉内核自带菜单
    // (ArkTS 侧 onContextMenuShow 返回 true 是另一层)。ArkUI 的右键菜单已不再"绑上就弹",
    // 它只在 menu 模式绑,所以这里不会和它叠出第二个菜单。
    termEl.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        e.stopPropagation();
        if (rightClickMode !== 'smart') return;
        const sel = term.getSelection() || selOnRightDown;
        if (sel) {
            // 有选区 → 直接复制(写剪贴板不需要权限)
            if (window.hbridge && window.hbridge.ctxCopy) window.hbridge.ctxCopy(sel);
        } else {
            // 没有选区 → 试着粘贴。没有权限时 ArkTS 只 toast 一句提示 —— 那是这条路的
            // 正常结果(读剪贴板必须用户点 PasteButton 授权),不是错误、也不会弹菜单。
            if (window.hbridge && window.hbridge.ctxSmartPaste) window.hbridge.ctxSmartPaste();
        }
    }, true);
})();