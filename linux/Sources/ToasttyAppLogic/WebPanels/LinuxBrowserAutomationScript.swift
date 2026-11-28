import Foundation

/// The page side of `toastty browser`: a library evaluated in an isolated
/// script world (`toastty-automation`), so the page cannot see or replace
/// it while it shares the DOM. It keeps element refs across calls, builds
/// the accessibility-style snapshot, checks actionability, and dispatches
/// synthetic (untrusted) DOM events. Each call returns
/// `{ok: true, ...}` or `{ok: false, retry: Bool, error: String}`; Swift
/// retries `retry` failures until the command's timeout.
public enum LinuxBrowserAutomationScript {
    /// The isolated world. WebKit drops a named world once nothing refers
    /// to it (and with it the library and its refs), so the browser keeps
    /// a user script in it.
    public static let worldName = "toastty-automation"

    /// Function body for `webkit_web_view_call_async_javascript_function`.
    static func body(command: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: command, options: [.fragmentsAllowed])
        let json = String(decoding: data, as: UTF8.self)
        return "const tta = globalThis.__toasttyAutomation || (globalThis.__toasttyAutomation = (\(library))());\nreturn await tta.run(\(json));"
    }

    /// Main-world body for `browser eval`: an expression (or a function,
    /// which is called) when it parses as one, otherwise a function body.
    static func evaluationBody(_ code: String, asExpression: Bool) -> String {
        let user = asExpression ? "let __r = await (\n\(code)\n);\nif (typeof __r === 'function') __r = await __r();" : "let __r = await (async () => {\n\(code)\n})();"
        return """
        \(user)
        const __seen = new WeakSet();
        const __plain = (v, depth) => {
          if (v === undefined) return null;
          if (v === null || typeof v === 'number' || typeof v === 'string' || typeof v === 'boolean') return v;
          if (typeof v === 'bigint') return v.toString();
          if (typeof v === 'function') return '[function ' + (v.name || 'anonymous') + ']';
          if (typeof Node !== 'undefined' && v instanceof Node) {
            if (v.nodeType === 1) { const h = v.outerHTML; return h.length > 500 ? h.slice(0, 500) + '…' : h; }
            return v.textContent;
          }
          if (depth > 6) return '[…]';
          if (typeof v === 'object') {
            if (__seen.has(v)) return '[circular]';
            __seen.add(v);
            if (v instanceof Error) return { name: v.name, message: v.message, stack: v.stack };
            if (Array.isArray(v) || (typeof NodeList !== 'undefined' && v instanceof NodeList) || (typeof HTMLCollection !== 'undefined' && v instanceof HTMLCollection)) return Array.from(v, x => __plain(x, depth + 1));
            if (v instanceof Map) return Object.fromEntries(Array.from(v, ([k, x]) => [String(k), __plain(x, depth + 1)]));
            if (v instanceof Set) return Array.from(v, x => __plain(x, depth + 1));
            if (v instanceof Date) return v.toISOString();
            const out = {};
            for (const k of Object.keys(v)) out[k] = __plain(v[k], depth + 1);
            return out;
          }
          return String(v);
        };
        return JSON.stringify({ value: __plain(__r, 0) });
        """
    }

    static let library = #"""
function () {
  'use strict';
  const refs = new Map();          // "e12" -> WeakRef(element)
  const refOf = new WeakMap();     // element -> "e12"
  let nextRef = 1;

  class Failure extends Error {
    constructor(message, retry) { super(message); this.retry = retry; }
  }
  const retryable = (message) => new Failure(message, true);
  const fatal = (message) => new Failure(message, false);

  const norm = (s) => (s || '').replace(/[\s ]+/g, ' ').trim();
  const clip = (s, n) => (s.length > n ? s.slice(0, n - 1) + '…' : s);
  const hasLayout = () => window.innerWidth > 0 && window.innerHeight > 0;

  function refFor(el) {
    let ref = refOf.get(el);
    if (!ref) {
      ref = 'e' + nextRef++;
      refOf.set(el, ref);
      refs.set(ref, new WeakRef(el));
    }
    return ref;
  }

  // ---- Tree walking (shadow roots, slots, same-origin iframes) ----

  function childNodesOf(node) {
    if (node.nodeType === 1) {
      if (node.shadowRoot) return Array.from(node.shadowRoot.childNodes);
      if (node.tagName === 'SLOT') {
        const assigned = node.assignedNodes({ flatten: true });
        if (assigned.length) return assigned;
      }
      if (node.tagName === 'IFRAME') {
        try { const doc = node.contentDocument; if (doc && doc.body) return [doc.body]; } catch (e) {}
        return [];
      }
    }
    return Array.from(node.childNodes);
  }

  function* allElements(root) {
    const stack = [root];
    while (stack.length) {
      const node = stack.pop();
      if (node.nodeType === 1) yield node;
      const kids = childNodesOf(node);
      for (let i = kids.length - 1; i >= 0; i--) {
        if (kids[i].nodeType === 1 || kids[i].nodeType === 11) stack.push(kids[i]);
      }
    }
  }

  function composedParent(node) {
    if (node.assignedSlot) return node.assignedSlot;
    if (node.parentNode && node.parentNode.nodeType === 11 && node.parentNode.host) return node.parentNode.host;
    if (node.parentNode) return node.parentNode;
    const view = node.ownerDocument && node.ownerDocument.defaultView;
    return view && view.frameElement ? view.frameElement : null;
  }

  function composedContains(ancestor, node) {
    for (let n = node; n; n = composedParent(n)) if (n === ancestor) return true;
    return false;
  }

  function deepActiveElement() {
    let el = document.activeElement;
    while (el) {
      if (el.shadowRoot && el.shadowRoot.activeElement) { el = el.shadowRoot.activeElement; continue; }
      if (el.tagName === 'IFRAME') {
        try { const inner = el.contentDocument && el.contentDocument.activeElement; if (inner && inner !== el.contentDocument.body) { el = inner; continue; } } catch (e) {}
      }
      break;
    }
    return el;
  }

  // ---- Visibility ----

  function style(el) { return el.ownerDocument.defaultView.getComputedStyle(el); }

  function isHiddenSubtree(el) {
    if (el.getAttribute('aria-hidden') === 'true') return true;
    if (el.hidden) return true;
    const s = style(el);
    return s.display === 'none';
  }

  function isVisible(el) {
    if (!el.isConnected) return false;
    if (el.tagName === 'OPTION' || el.tagName === 'OPTGROUP') {
      const select = el.closest('select');
      return select ? isVisible(select) : false;
    }
    for (let n = el; n && n.nodeType === 1; n = composedParent(n)) {
      if (n.hidden) return false;
      const s = style(n);
      if (s.display === 'none') return false;
    }
    const s = style(el);
    if (s.visibility !== 'visible') return false;
    if (s.display === 'contents') return Array.from(el.children).some(isVisible);
    if (!hasLayout() || el.ownerDocument !== document) return true;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }

  // ---- Roles and names ----

  const landmarkScoped = (el) => !el.closest('article, aside, main, nav, section');

  function implicitRole(el) {
    const tag = el.tagName;
    switch (tag) {
      case 'A': case 'AREA': return el.hasAttribute('href') ? 'link' : null;
      case 'BUTTON': return 'button';
      case 'SUMMARY': return 'button';
      case 'INPUT': {
        const type = (el.getAttribute('type') || 'text').toLowerCase();
        if (type === 'hidden') return null;
        if (['button', 'submit', 'reset', 'image', 'file'].includes(type)) return 'button';
        if (type === 'checkbox') return 'checkbox';
        if (type === 'radio') return 'radio';
        if (type === 'range') return 'slider';
        if (type === 'number') return 'spinbutton';
        if (el.hasAttribute('list')) return 'combobox';
        if (type === 'search') return 'searchbox';
        return 'textbox';
      }
      case 'TEXTAREA': return 'textbox';
      case 'SELECT': return (el.multiple || el.size > 1) ? 'listbox' : 'combobox';
      case 'OPTION': return 'option';
      case 'OPTGROUP': return 'group';
      case 'IMG': return el.getAttribute('alt') === '' ? null : 'img';
      case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': return 'heading';
      case 'UL': case 'OL': case 'MENU': return 'list';
      case 'LI': return 'listitem';
      case 'NAV': return 'navigation';
      case 'MAIN': return 'main';
      case 'ASIDE': return 'complementary';
      case 'HEADER': return landmarkScoped(el) ? 'banner' : null;
      case 'FOOTER': return landmarkScoped(el) ? 'contentinfo' : null;
      case 'FORM': return 'form';
      case 'SECTION': return (el.hasAttribute('aria-label') || el.hasAttribute('aria-labelledby')) ? 'region' : null;
      case 'ARTICLE': return 'article';
      case 'DIALOG': return 'dialog';
      case 'TABLE': return 'table';
      case 'TR': return 'row';
      case 'TD': return 'cell';
      case 'TH': return el.getAttribute('scope') === 'row' ? 'rowheader' : 'columnheader';
      case 'FIELDSET': return 'group';
      case 'DETAILS': return 'group';
      case 'P': return 'paragraph';
      case 'BLOCKQUOTE': return 'blockquote';
      case 'CODE': return 'code';
      case 'PRE': return 'code';
      case 'HR': return 'separator';
      case 'PROGRESS': return 'progressbar';
      case 'METER': return 'meter';
      case 'IFRAME': return 'iframe';
      case 'DL': return 'list';
      case 'DT': return 'term';
      case 'DD': return 'definition';
    }
    if (el.isContentEditable && !(el.parentElement && el.parentElement.isContentEditable)) return 'textbox';
    return null;
  }

  function roleOf(el) {
    const explicit = norm(el.getAttribute('role')).split(' ')[0];
    if (explicit && explicit !== 'presentation' && explicit !== 'none') return explicit;
    if (explicit) return null;
    return implicitRole(el);
  }

  const nameFromContent = new Set(['button', 'link', 'heading', 'cell', 'columnheader', 'rowheader', 'option', 'tab',
    'menuitem', 'menuitemcheckbox', 'menuitemradio', 'checkbox', 'radio', 'switch', 'treeitem', 'tooltip', 'term']);

  function textOf(el) {
    if (hasLayout() && el.ownerDocument === document && typeof el.innerText === 'string') return norm(el.innerText);
    return norm(el.textContent);
  }

  function idText(el, ids) {
    return norm(ids.split(/\s+/).map((id) => {
      const target = el.getRootNode().getElementById ? el.getRootNode().getElementById(id) : el.ownerDocument.getElementById(id);
      return target ? textOf(target) : '';
    }).join(' '));
  }

  function nameOf(el, role) {
    const labelledBy = el.getAttribute('aria-labelledby');
    if (labelledBy) { const t = idText(el, labelledBy); if (t) return t; }
    const label = norm(el.getAttribute('aria-label'));
    if (label) return label;
    const tag = el.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || tag === 'METER' || tag === 'PROGRESS') {
      const type = (el.getAttribute('type') || '').toLowerCase();
      if (tag === 'INPUT' && ['button', 'submit', 'reset'].includes(type)) {
        return norm(el.value) || (type === 'submit' ? 'Submit' : type === 'reset' ? 'Reset' : '');
      }
      if (tag === 'INPUT' && type === 'image') return norm(el.getAttribute('alt')) || 'Submit';
      if (el.labels && el.labels.length) {
        const t = norm(Array.from(el.labels).map((l) => {
          // A wrapping label's text without the control's own value.
          const clone = l.cloneNode(true);
          clone.querySelectorAll('input, select, textarea').forEach((c) => c.remove());
          return norm(clone.textContent);
        }).join(' '));
        if (t) return t;
      }
      return norm(el.getAttribute('title')) || norm(el.getAttribute('placeholder'));
    }
    if (tag === 'IMG' || tag === 'AREA') return norm(el.getAttribute('alt')) || norm(el.getAttribute('title'));
    if (tag === 'FIELDSET') { const legend = el.querySelector(':scope > legend'); if (legend) return textOf(legend); }
    if (tag === 'TABLE') { const caption = el.querySelector(':scope > caption'); if (caption) return textOf(caption); }
    if (tag === 'svg' || tag === 'SVG') {
      const title = el.querySelector('title');
      return title ? norm(title.textContent) : '';
    }
    if (role && nameFromContent.has(role)) { const t = textOf(el); if (t) return t; }
    return norm(el.getAttribute('title'));
  }

  function describe(el) {
    const role = roleOf(el);
    const name = clip(nameOf(el, role), 60);
    if (role) return role + (name ? ' "' + name + '"' : '');
    let d = el.tagName.toLowerCase();
    if (el.id) d += '#' + el.id;
    if (el.classList && el.classList.length) d += '.' + Array.from(el.classList).slice(0, 2).join('.');
    const t = clip(textOf(el), 40);
    return t ? d + ' "' + t + '"' : d;
  }

  // ---- Snapshot ----

  const skippedTags = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'META', 'LINK', 'BR', 'WBR']);

  function isClickableGeneric(el) {
    if (el.hasAttribute('onclick')) return true;
    if (el.tabIndex >= 0 && el.hasAttribute('tabindex')) return true;
    if (!hasLayout()) return false;
    const s = style(el);
    if (s.cursor !== 'pointer') return false;
    const parent = composedParent(el);
    return !(parent && parent.nodeType === 1 && style(parent).cursor === 'pointer');
  }

  function stateProps(el, role) {
    const props = [];
    const aria = (name) => el.getAttribute('aria-' + name);
    if (['checkbox', 'radio', 'switch', 'menuitemcheckbox', 'menuitemradio'].includes(role)) {
      const checked = el.tagName === 'INPUT' ? (el.indeterminate ? 'mixed' : el.checked) : (aria('checked') === 'mixed' ? 'mixed' : aria('checked') === 'true');
      if (checked === 'mixed') props.push('checked=mixed'); else if (checked) props.push('checked');
    }
    if (el.disabled || aria('disabled') === 'true') props.push('disabled');
    if (el.tagName === 'DETAILS' ? el.open : aria('expanded') === 'true') props.push('expanded');
    if (el.tagName === 'SUMMARY' && el.parentElement && el.parentElement.tagName === 'DETAILS') {
      props.push(el.parentElement.open ? 'expanded' : 'collapsed');
    } else if (aria('expanded') === 'false') props.push('collapsed');
    if ((el.tagName === 'OPTION' && el.selected) || aria('selected') === 'true') props.push('selected');
    if (aria('pressed') === 'true') props.push('pressed');
    if (aria('current') && aria('current') !== 'false') props.push('current');
    if (role === 'heading') {
      const level = Number(aria('level')) || Number((el.tagName.match(/^H(\d)$/) || [])[1]) || 2;
      props.push('level=' + level);
    }
    if (el.required || aria('required') === 'true') props.push('required');
    if (aria('invalid') === 'true') props.push('invalid');
    if (el === deepActiveElement()) props.push('focused');
    return props;
  }

  function valueOf(el, role) {
    if (el.tagName === 'SELECT') {
      return Array.from(el.selectedOptions).map((o) => norm(o.label || o.textContent)).join(', ');
    }
    if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
      const type = (el.getAttribute('type') || '').toLowerCase();
      if (['button', 'submit', 'reset', 'image', 'checkbox', 'radio', 'file', 'hidden'].includes(type)) {
        if (type === 'file' && el.files && el.files.length) return Array.from(el.files, (f) => f.name).join(', ');
        return null;
      }
      if (type === 'password') return el.value ? '•'.repeat(Math.min(el.value.length, 8)) : null;
      return el.value === '' ? null : el.value;
    }
    if (role === 'textbox' && el.isContentEditable) return textOf(el) || null;
    if (['slider', 'spinbutton', 'progressbar', 'meter', 'scrollbar'].includes(role)) {
      return el.getAttribute('aria-valuetext') || el.getAttribute('aria-valuenow') || (el.value !== undefined ? String(el.value) : null);
    }
    return null;
  }

  function linkTarget(el) {
    const href = el.getAttribute('href');
    if (!href) return null;
    try {
      const url = new URL(href, el.baseURI);
      return url.origin === location.origin ? url.pathname + url.search + url.hash : url.href;
    } catch (e) { return href; }
  }

  function buildChildren(node) {
    const out = [];
    for (const child of childNodesOf(node)) {
      if (child.nodeType === 3) {
        const t = norm(child.nodeValue);
        if (t) out.push({ text: t });
        continue;
      }
      if (child.nodeType === 11) { out.push(...buildChildren(child)); continue; }
      if (child.nodeType !== 1) continue;
      const tag = child.tagName;
      if (skippedTags.has(tag.toUpperCase())) continue;
      if (isHiddenSubtree(child)) continue;
      if (style(child).visibility !== 'visible' && child.ownerDocument === document) {
        // Children may opt back into visibility.
        out.push(...buildChildren(child));
        continue;
      }
      if (tag.toLowerCase() === 'svg') {
        const name = nameOf(child, 'img');
        if (name || child.getAttribute('role') === 'img') out.push({ el: child, role: 'img', name, props: [], children: [] });
        continue;
      }
      if (tag === 'INPUT' && (child.getAttribute('type') || '').toLowerCase() === 'hidden') continue;
      let role = roleOf(child);
      if (!role && isClickableGeneric(child)) role = 'generic';
      const kids = (tag === 'SELECT' || tag === 'TEXTAREA') ? [] : buildChildren(child);
      if (!role) { out.push(...kids); continue; }
      const name = nameOf(child, role);
      const node = { el: child, role, name, props: stateProps(child, role), value: valueOf(child, role), children: kids };
      if (role === 'link') node.url = linkTarget(child);
      if (role === 'generic') node.props.push('cursor=pointer');
      // Content that only repeats the name (button "Save" > text "Save").
      if (name && nameFromContent.has(role) && kids.every((k) => k.text)) node.children = [];
      if (role === 'generic' && name === '' && kids.every((k) => k.text)) { node.name = clip(textOf(child), 80); node.children = []; }
      out.push(node);
    }
    // Merge adjacent text runs.
    const merged = [];
    for (const item of out) {
      const last = merged[merged.length - 1];
      if (item.text && last && last.text) last.text += ' ' + item.text; else merged.push(item);
    }
    return merged;
  }

  function quote(s) { return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"'; }

  function render(items, depth, lines, limit) {
    for (const item of items) {
      if (lines.length >= limit) return false;
      const pad = '  '.repeat(depth);
      if (item.text) { lines.push(pad + '- text: ' + clip(item.text, 300)); continue; }
      let line = pad + '- ' + item.role;
      if (item.role === 'generic' && item.name) line += ' ' + quote(clip(item.name, 80));
      else if (item.name) line += ' ' + quote(clip(item.name, 120));
      for (const p of item.props) line += ' [' + p + ']';
      line += ' [ref=' + refFor(item.el) + ']';
      if (item.url) line += ' -> ' + clip(item.url, 120);
      const onlyText = item.children.length === 1 && item.children[0].text;
      if (item.value != null && item.value !== '') {
        line += ': ' + quote(clip(String(item.value), 200));
        lines.push(line);
        if (item.children.length) render(item.children, depth + 1, lines, limit);
      } else if (onlyText && item.role !== 'generic') {
        lines.push(line + ': ' + clip(item.children[0].text, 300));
      } else if (item.children.length) {
        lines.push(line + ':');
        if (!render(item.children, depth + 1, lines, limit)) return false;
      } else {
        lines.push(line);
      }
    }
    return true;
  }

  function snapshot(args) {
    const limit = args.maxLines || 1500;
    let roots;
    if (args.target) {
      roots = [resolveOne(args.target, { visible: false })];
    } else {
      roots = [document.body || document.documentElement];
    }
    const items = [];
    for (const root of roots) {
      if (args.target) {
        const role = roleOf(root) || (isClickableGeneric(root) ? 'generic' : null);
        const kids = buildChildren(root);
        if (role) items.push({ el: root, role, name: nameOf(root, role), props: stateProps(root, role), value: valueOf(root, role), children: kids });
        else items.push(...kids);
      } else {
        items.push(...buildChildren(root));
      }
    }
    const lines = [];
    render(items, 0, lines, limit);
    const truncated = lines.length >= limit;
    return { ok: true, url: location.href, title: document.title, snapshot: lines.join('\n'), truncated };
  }

  // ---- Locators ----

  function textMatches(haystack, needle, exact) {
    if (exact) return norm(haystack) === needle;
    return norm(haystack).toLowerCase().includes(needle.toLowerCase());
  }

  function unquote(raw) {
    const m = raw.match(/^"(.*)"$/s) || raw.match(/^'(.*)'$/s);
    return m ? { value: m[1], exact: true } : { value: raw.trim(), exact: false };
  }

  function elementOwnText(el) {
    if (el.tagName === 'INPUT') {
      const type = (el.getAttribute('type') || '').toLowerCase();
      if (['button', 'submit', 'reset'].includes(type)) return el.value;
      return '';
    }
    return textOf(el);
  }

  function queryAll(selector) {
    const root = document;
    const results = [];
    const seen = new Set();
    const visit = (scope) => {
      let found;
      try { found = scope.querySelectorAll(selector); } catch (e) { throw fatal('invalid selector: ' + selector); }
      for (const el of found) if (!seen.has(el)) { seen.add(el); results.push(el); }
    };
    visit(root);
    // Open shadow roots and same-origin frames.
    for (const el of allElements(document.documentElement)) {
      if (el.shadowRoot) visit(el.shadowRoot);
      if (el.tagName === 'IFRAME') { try { if (el.contentDocument) visit(el.contentDocument); } catch (e) {} }
    }
    return results;
  }

  function locate(target) {
    const raw = String(target).trim();
    if (/^e\d+$/.test(raw)) {
      const weak = refs.get(raw);
      const el = weak && weak.deref();
      if (!el || !el.isConnected) throw fatal('ref ' + raw + ' is not on the page any more; take a new snapshot');
      return [el];
    }
    const prefixed = raw.match(/^(text|role|label|placeholder|testid|css|xpath|alt|title)=(.*)$/s);
    if (!prefixed) {
      if (raw.startsWith('//') || raw.startsWith('(//')) return xpathAll(raw);
      return queryAll(raw);
    }
    const kind = prefixed[1];
    const rest = prefixed[2];
    if (kind === 'css') return queryAll(rest);
    if (kind === 'xpath') return xpathAll(rest);
    if (kind === 'testid') {
      const v = unquote(rest).value;
      return queryAll('[data-testid="' + v + '"], [data-test-id="' + v + '"], [data-test="' + v + '"]');
    }
    if (kind === 'placeholder' || kind === 'alt' || kind === 'title') {
      const { value, exact } = unquote(rest);
      const attr = kind;
      return Array.from(allElements(document.documentElement)).filter((el) => el.hasAttribute(attr) && textMatches(el.getAttribute(attr), value, exact));
    }
    if (kind === 'text') {
      const { value, exact } = unquote(rest);
      const needle = value.toLowerCase();
      const matches = Array.from(allElements(document.body || document.documentElement)).filter((el) => {
        if (skippedTags.has(el.tagName)) return false;
        // Cheap prefilter before layout-based innerText.
        if (el.tagName !== 'INPUT' && !norm(el.textContent).toLowerCase().includes(needle)) return false;
        return textMatches(elementOwnText(el), value, exact);
      });
      // The innermost matches: drop an element when a descendant matches too.
      const innermost = matches.filter((el) => !matches.some((other) => other !== el && composedContains(el, other)));
      return innermost;
    }
    if (kind === 'label') {
      const { value, exact } = unquote(rest);
      return Array.from(allElements(document.documentElement)).filter((el) => {
        const role = roleOf(el);
        if (!role || !['textbox', 'searchbox', 'checkbox', 'radio', 'combobox', 'listbox', 'slider', 'spinbutton', 'switch', 'button'].includes(role)) return false;
        if (role === 'button' && !(el.tagName === 'INPUT' && el.type === 'file')) return false;
        return textMatches(nameOf(el, role), value, exact);
      });
    }
    if (kind === 'role') {
      const m = rest.match(/^([a-z]+)\s*(?:\[\s*name\s*=\s*(.*)\])?$/is);
      if (!m) throw fatal('role locator must look like role=button or role=button[name="Save"]');
      const wanted = m[1].toLowerCase();
      const name = m[2] !== undefined ? unquote(m[2].trim()) : null;
      return Array.from(allElements(document.documentElement)).filter((el) => {
        const role = roleOf(el);
        if (role !== wanted) return false;
        return !name || textMatches(nameOf(el, role), name.value, name.exact);
      });
    }
    return [];
  }

  function xpathAll(expression) {
    let result;
    try { result = document.evaluate(expression, document, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null); }
    catch (e) { throw fatal('invalid xpath: ' + expression); }
    const out = [];
    for (let i = 0; i < result.snapshotLength; i++) { const n = result.snapshotItem(i); if (n.nodeType === 1) out.push(n); }
    return out;
  }

  // The first visible match (or the first match when `visible` is false).
  let lastMatchCount = 0;
  function resolveOne(target, opts) {
    const all = locate(target);
    lastMatchCount = all.length;
    if (!all.length) throw retryable('no element matches ' + target);
    if (opts && opts.visible === false) return all[0];
    const visible = all.find(isVisible);
    if (!visible) throw retryable(target + ' matches ' + all.length + ' element' + (all.length === 1 ? '' : 's') + ', none visible (' + describe(all[0]) + ')');
    return visible;
  }

  // ---- Actionability ----

  function isDisabled(el) {
    if (el.disabled) return true;
    for (let n = el; n && n.nodeType === 1; n = composedParent(n)) {
      if (n.getAttribute('aria-disabled') === 'true') return true;
      if (n.tagName === 'FIELDSET' && n.disabled && !(n.querySelector(':scope > legend') || { contains: () => false }).contains(el)) return true;
    }
    return false;
  }

  function isEditable(el) {
    if (el.isContentEditable) return true;
    if (el.tagName === 'TEXTAREA') return !el.readOnly;
    if (el.tagName === 'INPUT') {
      const type = (el.getAttribute('type') || 'text').toLowerCase();
      if (['button', 'submit', 'reset', 'image', 'checkbox', 'radio', 'file', 'hidden', 'range', 'color'].includes(type)) return false;
      return !el.readOnly;
    }
    return false;
  }

  function scrollIntoView(el) {
    if (!hasLayout() || el.ownerDocument !== document) return;
    const r = el.getBoundingClientRect();
    if (r.top >= 0 && r.left >= 0 && r.bottom <= window.innerHeight && r.right <= window.innerWidth) return;
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
  }

  function deepElementFromPoint(x, y) {
    let el = document.elementFromPoint(x, y);
    while (el && el.shadowRoot) {
      const inner = el.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === el) break;
      el = inner;
    }
    return el;
  }

  function center(el) {
    const r = el.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  }

  // Throws when another element would receive a click at el's center.
  function checkHitTarget(el) {
    if (!hasLayout() || el.ownerDocument !== document) return;
    const { x, y } = center(el);
    if (x < 0 || y < 0 || x > window.innerWidth || y > window.innerHeight) return;
    const hit = deepElementFromPoint(x, y);
    if (!hit || hit === el || composedContains(el, hit)) return;
    if (hit.tagName === 'LABEL' && hit.control === el) return;
    const label = hit.closest && hit.closest('label');
    if (label && label.control === el) return;
    throw retryable(describe(el) + ' is covered by ' + describe(hit));
  }

  function actionable(target, opts) {
    const el = resolveOne(target);
    if (opts.force) return el;
    if (opts.enabled && isDisabled(el)) throw retryable(describe(el) + ' is disabled');
    if (opts.editable && !isEditable(el)) {
      if (isDisabled(el) || el.readOnly) throw retryable(describe(el) + ' is not editable');
      throw fatal(describe(el) + ' is not a text field (use select, check or upload)');
    }
    scrollIntoView(el);
    if (opts.hit) checkHitTarget(el);
    return el;
  }

  // ---- Events ----

  const modifierState = (mods) => ({
    ctrlKey: mods.includes('Control'), shiftKey: mods.includes('Shift'),
    altKey: mods.includes('Alt'), metaKey: mods.includes('Meta'),
  });

  function mouseInit(el, extra, mods) {
    const view = el.ownerDocument.defaultView;
    const c = hasLayout() ? center(el) : { x: 0, y: 0 };
    return Object.assign({
      bubbles: true, cancelable: true, composed: true, view,
      clientX: c.x, clientY: c.y, screenX: c.x, screenY: c.y,
      button: 0, buttons: 0, detail: 1, pointerId: 1, pointerType: 'mouse', isPrimary: true,
    }, modifierState(mods || []), extra);
  }

  function fire(el, type, init, Ctor) {
    const event = new (Ctor || Event)(type, init);
    return el.dispatchEvent(event);
  }

  function hover(el, mods) {
    fire(el, 'pointerover', mouseInit(el, {}, mods), PointerEvent);
    fire(el, 'pointerenter', mouseInit(el, { bubbles: false }, mods), PointerEvent);
    fire(el, 'mouseover', mouseInit(el, {}, mods), MouseEvent);
    fire(el, 'mouseenter', mouseInit(el, { bubbles: false }, mods), MouseEvent);
    fire(el, 'pointermove', mouseInit(el, {}, mods), PointerEvent);
    fire(el, 'mousemove', mouseInit(el, {}, mods), MouseEvent);
  }

  function focusable(el) {
    for (let n = el; n && n.nodeType === 1; n = composedParent(n)) {
      if (n.tabIndex >= 0 || n.isContentEditable || ['INPUT', 'SELECT', 'TEXTAREA', 'BUTTON'].includes(n.tagName) || (n.tagName === 'A' && n.hasAttribute('href'))) return n;
    }
    return null;
  }

  function focusElement(el) {
    const target = focusable(el);
    if (target && deepActiveElement() !== target) target.focus({ preventScroll: true });
    return target;
  }

  function click(el, opts) {
    const mods = opts.modifiers || [];
    const count = opts.count || 1;
    const right = opts.button === 'right';
    const middle = opts.button === 'middle';
    const button = right ? 2 : middle ? 1 : 0;
    const buttons = right ? 2 : middle ? 4 : 1;
    hover(el, mods);
    for (let i = 1; i <= count; i++) {
      const down = fire(el, 'pointerdown', mouseInit(el, { button, buttons, detail: i }, mods), PointerEvent);
      const mouseDown = down && fire(el, 'mousedown', mouseInit(el, { button, buttons, detail: i }, mods), MouseEvent);
      if (mouseDown && !right) focusElement(el);
      fire(el, 'pointerup', mouseInit(el, { button, detail: i }, mods), PointerEvent);
      fire(el, 'mouseup', mouseInit(el, { button, detail: i }, mods), MouseEvent);
      if (right) fire(el, 'contextmenu', mouseInit(el, { button, detail: i }, mods), MouseEvent);
      else if (middle) fire(el, 'auxclick', mouseInit(el, { button, detail: i }, mods), MouseEvent);
      else fire(el, 'click', mouseInit(el, { button, detail: i }, mods), MouseEvent);
    }
    if (count === 2 && !right && !middle) fire(el, 'dblclick', mouseInit(el, { detail: 2 }, mods), MouseEvent);
  }

  function nativeSetValue(el, value) {
    const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
    setter.call(el, value);
  }

  function inputEvent(el, data, inputType) {
    fire(el, 'input', { bubbles: true, cancelable: false, composed: true, data, inputType: inputType || 'insertText' }, InputEvent);
  }

  function changeEvent(el) { fire(el, 'change', { bubbles: true }); }

  const valueOnlyTypes = ['date', 'time', 'datetime-local', 'month', 'week', 'color', 'range'];

  function selectContents(el) {
    if (el.isContentEditable) {
      const selection = el.ownerDocument.getSelection();
      selection.selectAllChildren(el);
      return;
    }
    try { el.select(); } catch (e) {}
  }

  function fill(el, value) {
    const doc = el.ownerDocument;
    focusElement(el);
    const type = (el.getAttribute('type') || '').toLowerCase();
    if (el.tagName === 'INPUT' && valueOnlyTypes.includes(type)) {
      nativeSetValue(el, value);
      inputEvent(el, value, 'insertReplacementText');
      changeEvent(el);
      return;
    }
    selectContents(el);
    let ok = false;
    try { ok = value === '' ? doc.execCommand('delete', false) : doc.execCommand('insertText', false, value); } catch (e) {}
    const current = el.isContentEditable ? el.textContent : el.value;
    if (!ok || current !== value) {
      if (el.isContentEditable) el.textContent = value; else nativeSetValue(el, value);
      inputEvent(el, value, 'insertReplacementText');
    }
    if (!el.isContentEditable) changeEvent(el);
  }

  // ---- Keyboard ----

  const keyCodes = {
    Backspace: 8, Tab: 9, Enter: 13, Shift: 16, Control: 17, Alt: 18, Escape: 27, ' ': 32, PageUp: 33, PageDown: 34,
    End: 35, Home: 36, ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40, Insert: 45, Delete: 46, Meta: 91,
  };
  const keyAliases = { Esc: 'Escape', Return: 'Enter', Space: ' ', Up: 'ArrowUp', Down: 'ArrowDown', Left: 'ArrowLeft', Right: 'ArrowRight', Del: 'Delete', Ctrl: 'Control', Cmd: 'Meta', Command: 'Meta', Option: 'Alt' };

  function parseChord(chord) {
    const parts = chord === '+' ? ['+'] : chord.split('+').filter((p) => p !== '');
    if (chord.endsWith('++')) parts.push('+');
    const names = parts.map((p) => keyAliases[p] || (p.length === 1 ? p : p[0].toUpperCase() + p.slice(1)));
    const key = names.pop();
    return { key, modifiers: names };
  }

  function keyInit(key, mods) {
    let code = key;
    let keyCode = keyCodes[key] || 0;
    if (key.length === 1) {
      const upper = key.toUpperCase();
      if (/[A-Z]/.test(upper)) { code = 'Key' + upper; keyCode = upper.charCodeAt(0); }
      else if (/[0-9]/.test(key)) { code = 'Digit' + key; keyCode = key.charCodeAt(0); }
      else if (key === ' ') { code = 'Space'; }
      else { keyCode = key.charCodeAt(0); }
    } else if (/^F\d+$/.test(key)) { keyCode = 111 + Number(key.slice(1)); }
    return Object.assign({ key, code, keyCode, which: keyCode, bubbles: true, cancelable: true, composed: true }, modifierState(mods));
  }

  function tabbables(doc) {
    const all = Array.from(allElements(doc.body || doc.documentElement)).filter((el) =>
      el.tabIndex >= 0 && !isDisabled(el) && isVisible(el) && !(el.tagName === 'INPUT' && el.type === 'hidden'));
    const positive = all.filter((el) => el.tabIndex > 0).sort((a, b) => a.tabIndex - b.tabIndex);
    return positive.concat(all.filter((el) => el.tabIndex === 0));
  }

  function defaultButton(form) {
    return Array.from(form.elements).find((el) =>
      (el.tagName === 'BUTTON' && (el.type || 'submit') === 'submit') || (el.tagName === 'INPUT' && ['submit', 'image'].includes(el.type)));
  }

  function insertText(el, text) {
    const doc = el.ownerDocument;
    let ok = false;
    try { ok = doc.execCommand('insertText', false, text); } catch (e) {}
    if (!ok && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA')) {
      const start = el.selectionStart != null ? el.selectionStart : el.value.length;
      const end = el.selectionEnd != null ? el.selectionEnd : el.value.length;
      nativeSetValue(el, el.value.slice(0, start) + text + el.value.slice(end));
      try { el.setSelectionRange(start + text.length, start + text.length); } catch (e) {}
      inputEvent(el, text, 'insertText');
    }
  }

  // Emulates what the browser would do for an untrusted key event that
  // was not cancelled (synthetic key events have no default action).
  function keyDefault(el, key, mods) {
    const editable = isEditable(el);
    const ctrl = mods.includes('Control') || mods.includes('Meta');
    if (ctrl && key.toLowerCase() === 'a') {
      if (editable) selectContents(el); else el.ownerDocument.execCommand('selectAll');
      return;
    }
    if (ctrl) return;
    switch (key) {
      case 'Enter':
        if (el.tagName === 'TEXTAREA' || el.isContentEditable) { insertText(el, '\n'); return; }
        if (el.tagName === 'INPUT' && el.form) {
          const button = defaultButton(el.form);
          if (button) { if (!isDisabled(button)) click(button, {}); }
          else if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit();
          return;
        }
        if (el.tagName === 'A' || el.tagName === 'BUTTON' || el.tagName === 'SUMMARY' || roleOf(el) === 'button' || roleOf(el) === 'link') click(el, {});
        return;
      case 'Tab': {
        const list = tabbables(el.ownerDocument);
        if (!list.length) return;
        const i = list.indexOf(el);
        const next = mods.includes('Shift') ? list[(i <= 0 ? list.length : i) - 1] : list[(i + 1) % list.length];
        next.focus();
        if (isEditable(next)) selectContents(next);
        return;
      }
      case 'Backspace':
      case 'Delete':
        if (editable) {
          const doc = el.ownerDocument;
          let ok = false;
          try { ok = doc.execCommand(key === 'Backspace' ? 'delete' : 'forwardDelete', false); } catch (e) {}
          if (!ok && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA')) {
            let start = el.selectionStart, end = el.selectionEnd;
            if (start === end) { if (key === 'Backspace') start = Math.max(0, start - 1); else end = Math.min(el.value.length, end + 1); }
            nativeSetValue(el, el.value.slice(0, start) + el.value.slice(end));
            try { el.setSelectionRange(start, start); } catch (e) {}
            inputEvent(el, null, key === 'Backspace' ? 'deleteContentBackward' : 'deleteContentForward');
          }
        }
        return;
      case 'ArrowUp':
      case 'ArrowDown':
        if (el.tagName === 'SELECT' && !el.multiple) {
          const next = el.selectedIndex + (key === 'ArrowDown' ? 1 : -1);
          if (next >= 0 && next < el.options.length) { el.selectedIndex = next; inputEvent(el, null, 'insertReplacementText'); changeEvent(el); }
        }
        return;
    }
    if (key.length === 1 && editable) insertText(el, key);
  }

  // Runs `dispatch` and reports whether WebKit's own default handling did
  // something (WebKit runs some defaults for untrusted key events, such as
  // implicit form submission on Enter), so emulation does not repeat it.
  function browserReacted(el, dispatch) {
    const doc = el.ownerDocument;
    let reacted = false;
    const note = () => { reacted = true; };
    const types = ['click', 'submit', 'beforeinput', 'input'];
    for (const type of types) doc.addEventListener(type, note, true);
    const activeBefore = deepActiveElement();
    let result;
    try { result = dispatch(); } finally { for (const type of types) doc.removeEventListener(type, note, true); }
    return { result, reacted: reacted || deepActiveElement() !== activeBefore };
  }

  function press(el, chord) {
    const { key, modifiers } = parseChord(chord);
    const init = keyInit(key, modifiers);
    const printable = key.length === 1 && !modifiers.includes('Control') && !modifiers.includes('Meta');
    const down = browserReacted(el, () => {
      const proceed = fire(el, 'keydown', init, KeyboardEvent);
      let pressed = true;
      if (proceed && (printable || key === 'Enter')) {
        pressed = fire(el, 'keypress', Object.assign({}, init, { charCode: key === 'Enter' ? 13 : key.charCodeAt(0) }), KeyboardEvent);
      }
      return proceed && pressed;
    });
    if (down.result && !down.reacted && key !== ' ') keyDefault(el, key, modifiers);
    // Space activates on key up.
    const up = browserReacted(el, () => fire(el, 'keyup', init, KeyboardEvent));
    if (down.result && !down.reacted && !up.reacted && key === ' ') {
      const role = roleOf(el);
      if (['button', 'checkbox', 'radio', 'switch'].includes(role) || el.tagName === 'SUMMARY') click(el, {});
      else if (isEditable(el)) insertText(el, ' ');
    }
  }

  function typeText(el, text) {
    for (const ch of Array.from(text)) {
      if (ch === '\n') { press(el, 'Enter'); continue; }
      const init = keyInit(ch, []);
      const down = browserReacted(el, () =>
        fire(el, 'keydown', init, KeyboardEvent) && fire(el, 'keypress', Object.assign({}, init, { charCode: ch.charCodeAt(0) }), KeyboardEvent));
      if (down.result && !down.reacted) insertText(el, ch);
      fire(el, 'keyup', init, KeyboardEvent);
    }
  }

  function keyTarget(target) {
    if (target) return actionable(target, { enabled: true, hit: false });
    return deepActiveElement() || document.body;
  }

  function placeCaretAtEnd(el) {
    if (el.isContentEditable) {
      const selection = el.ownerDocument.getSelection();
      selection.selectAllChildren(el);
      selection.collapseToEnd();
    } else if (el.setSelectionRange) {
      try { el.setSelectionRange(el.value.length, el.value.length); } catch (e) {}
    }
  }

  // ---- Commands ----

  function checkedState(el) {
    if (el.tagName === 'INPUT' && (el.type === 'checkbox' || el.type === 'radio')) return el.checked;
    const aria = el.getAttribute('aria-checked');
    if (aria === 'true') return true;
    if (aria === 'false') return false;
    const inner = el.querySelector && el.querySelector('input[type=checkbox], input[type=radio]');
    if (inner) return inner.checked;
    if (el.tagName === 'LABEL' && el.control) return el.control.checked;
    throw fatal(describe(el) + ' is not a checkbox, radio or switch');
  }

  function fileList(files) {
    const transfer = new DataTransfer();
    for (const f of files) {
      const bytes = Uint8Array.from(atob(f.base64), (c) => c.charCodeAt(0));
      transfer.items.add(new File([bytes], f.name, { type: f.type || 'application/octet-stream', lastModified: Date.now() }));
    }
    return transfer.files;
  }

  const commands = {
    snapshot,

    click(args) {
      const el = actionable(args.target, { enabled: true, hit: true, force: args.force });
      click(el, args);
      return { element: describe(el) };
    },

    hover(args) {
      const el = actionable(args.target, { hit: true, force: args.force });
      hover(el, args.modifiers || []);
      return { element: describe(el) };
    },

    focus(args) {
      const el = resolveOne(args.target);
      const target = focusElement(el) || el;
      if (target.focus) target.focus();
      return { element: describe(target) };
    },

    fill(args) {
      const el = actionable(args.target, { enabled: true, editable: true, force: args.force });
      fill(el, String(args.value));
      return { element: describe(el), value: el.isContentEditable ? el.textContent : el.value };
    },

    type(args) {
      const el = keyTarget(args.target);
      if (args.target) { focusElement(el); placeCaretAtEnd(el); }
      typeText(el, String(args.text));
      return { element: describe(el), value: el.value !== undefined ? el.value : null };
    },

    press(args) {
      const el = keyTarget(args.target);
      if (args.target) focusElement(el);
      for (const chord of args.keys) press(deepActiveElement() && !args.target ? deepActiveElement() : el, chord);
      return { element: describe(el) };
    },

    select(args) {
      let el = actionable(args.target, { enabled: true, hit: false, force: args.force });
      if (el.tagName === 'LABEL' && el.control) el = el.control;
      if (el.tagName !== 'SELECT') throw fatal(describe(el) + ' is not a <select>; click its options instead');
      const options = Array.from(el.options);
      const chosen = args.values.map((v) => {
        const option = options.find((o) => o.value === v) || options.find((o) => norm(o.label) === v || norm(o.textContent) === v)
          || options.find((o) => norm(o.label).toLowerCase() === v.toLowerCase());
        if (!option) throw fatal('no option "' + v + '" in ' + describe(el) + '; options: ' + options.map((o) => JSON.stringify(norm(o.label) || o.value)).join(', '));
        return option;
      });
      if (!el.multiple && chosen.length > 1) throw fatal(describe(el) + ' takes one value');
      focusElement(el);
      for (const o of options) o.selected = chosen.includes(o);
      inputEvent(el, null, 'insertReplacementText');
      changeEvent(el);
      return { element: describe(el), values: chosen.map((o) => o.value) };
    },

    check(args) {
      const el = actionable(args.target, { enabled: true, hit: true, force: args.force });
      if (checkedState(el) === args.checked) return { element: describe(el), changed: false };
      click(el, {});
      if (checkedState(el) !== args.checked) throw fatal('clicking ' + describe(el) + ' did not ' + (args.checked ? 'check' : 'uncheck') + ' it');
      return { element: describe(el), changed: true };
    },

    upload(args) {
      let el = resolveOne(args.target, { visible: false });
      if (el.tagName === 'LABEL' && el.control) el = el.control;
      if (!(el.tagName === 'INPUT' && el.type === 'file')) {
        const inner = el.querySelector && el.querySelector('input[type=file]');
        if (!inner) throw fatal(describe(el) + ' is not a file input');
        el = inner;
      }
      el.files = fileList(args.files);
      inputEvent(el, null, 'insertReplacementText');
      changeEvent(el);
      return { element: describe(el), files: Array.from(el.files, (f) => f.name) };
    },

    scroll(args) {
      if (args.target && args.dx == null && args.dy == null) {
        const el = resolveOne(args.target);
        el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
        return { element: describe(el), x: window.scrollX, y: window.scrollY };
      }
      const scroller = args.target ? resolveOne(args.target) : (document.scrollingElement || document.documentElement);
      scroller.scrollBy({ left: args.dx || 0, top: args.dy || 0, behavior: 'instant' });
      return { x: window.scrollX, y: window.scrollY, element: args.target ? describe(scroller) : null };
    },

    text(args) {
      const el = args.target ? resolveOne(args.target, { visible: false }) : (document.body || document.documentElement);
      return { text: el.innerText !== undefined ? el.innerText : el.textContent, element: describe(el) };
    },

    html(args) {
      const el = args.target ? resolveOne(args.target, { visible: false }) : document.documentElement;
      return { html: args.inner ? el.innerHTML : el.outerHTML, element: describe(el) };
    },

    attribute(args) {
      const el = resolveOne(args.target, { visible: false });
      const props = { value: el.value, checked: el.checked, disabled: el.disabled };
      const value = el.hasAttribute(args.name) ? el.getAttribute(args.name) : (args.name in props ? props[args.name] : null);
      return { element: describe(el), value: value === undefined ? null : value };
    },

    count(args) {
      const all = locate(args.target);
      return { count: all.length, visible: all.filter(isVisible).length };
    },

    probe(args) {
      // One check for `browser wait`; never throws a retryable failure.
      switch (args.kind) {
        case 'text': return { met: (document.body ? document.body.innerText : '').includes(args.value) };
        case 'text-gone': return { met: !(document.body ? document.body.innerText : '').includes(args.value) };
        case 'visible': { const all = locate(args.value); return { met: all.some(isVisible), count: all.length }; }
        case 'hidden': { const all = locate(args.value); return { met: !all.some(isVisible), count: all.length }; }
        case 'ready': return { met: document.readyState === 'complete' };
      }
      throw fatal('unknown wait kind ' + args.kind);
    },
  };

  return {
    async run(args) {
      try {
        const handler = commands[args.op];
        if (!handler) throw fatal('unknown browser command ' + args.op);
        const result = handler(args) || {};
        if (result.ok === undefined) result.ok = true;
        if (args.target && result.matches === undefined && /^(click|hover|fill|type|press|select|check|focus)$/.test(args.op)) result.matches = lastMatchCount;
        return JSON.stringify(result);
      } catch (e) {
        if (e instanceof Failure) return JSON.stringify({ ok: false, retry: e.retry, error: e.message });
        return JSON.stringify({ ok: false, retry: false, error: String(e && e.message || e) });
      }
    },
  };
}
"""#
}
