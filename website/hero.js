/* Toastty hero video: an HTML recreation of the app driven by one timeline (t, in seconds). */
(function () {
  try {
    var D = 24;
    var stage = document.getElementById('stage');
    var wrap = document.getElementById('wrap');
    var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    // The sidebar stays on its Needs you view: a row shows only while it waits on the user.
    // POSTER is the still used for reduced motion, the README, and the social card: Toasty has
    // just said why checkout-redesign is ready, its row is in Ready to review with its PR chip,
    // and the docs fix is visible in the right panel.
    var POSTER = 16.4;
    var t = reduce ? POSTER : 0, playing = !reduce, last = null, onScreen = true;

    // On narrow screens the window is shown through a portrait crop (VW design px wide). It shows
    // the sidebar and the coordinator's dock, and pans to the right panel for the docs preview.
    var VW = 1200;
    var viewportEl = document.getElementById('viewport');
    function fit() {
      VW = wrap.clientWidth < 700 ? 600 : 1200;
      var s = wrap.clientWidth / VW;
      stage.style.transform = 'scale(' + s + ')';
      stage.style.width = VW + 'px';
      viewportEl.style.width = VW + 'px';
      wrap.style.height = (740 * s) + 'px';
    }
    window.addEventListener('resize', fit);
    fit();

    function $(id) { return document.getElementById(id); }
    var timed = Array.prototype.slice.call(stage.querySelectorAll('[data-at],[data-until]'));
    var ANNO = 'Still shows the v1 payload. Update for v2.';
    var annoBtn = $('anno-btn'), annoBar = $('anno-bar'), abCount = $('ab-count'), abSend = $('ab-send');
    var abClear = annoBar.querySelector('.ab-clear'), annoMenu = $('anno-menu'), annoItem = $('anno-item'), annoRect = $('anno-rect');
    var annoPop = $('anno-pop'), annoTyped = $('anno-typed'), annoAdd = $('anno-add'), annoToast = $('anno-toast');
    var cam = $('cam');
    var site = $('site'), para = $('para'), codeBlock = $('code-block');
    var wasV2 = false;
    var viewEls = { lumen: $('view-lumen'), child: $('view-child'), docs: $('view-docs') };
    var cardLumen = $('card-lumen'), cardDocs = $('card-docs'), rowDocs = $('row-docs'), rowSub = $('row-sub');
    var docsIc = $('docs-ic'), docsBkt = $('docs-bkt'), docsHc = $('docs-hc'), segY = $('seg-y'), segRev = $('seg-rev');
    var crChips = Array.prototype.slice.call(stage.querySelectorAll('.tl-cr'));
    var wtitle = $('wtitle'), phead = $('phead');
    var dockSt = $('dock-st'), dockWk = $('dock-wk'), dockWkT = $('dock-wk-t'), dockF = $('dock-f'), dockPh = $('dock-ph'), dockTyped = $('dock-typed'), dockSend = $('dock-send');
    var tabs = Array.prototype.slice.call(document.querySelectorAll('#rtabs .rtab'));
    var views = {};
    Array.prototype.forEach.call(document.querySelectorAll('.rv'), function (v) { views[v.getAttribute('data-view')] = v; });
    var cursor = $('cursor');
    var fade = $('fade');
    var beats = Array.prototype.slice.call(document.querySelectorAll('#beats .beat'));

    // Replacing innerHTML every frame restarts the spinner animation; only write on change.
    function setHTML(el, html) { if (el.__html !== html) { el.innerHTML = html; el.__html = html; } }
    function setText(el, s) { if (el.__text !== s) { el.textContent = s; el.__text = s; } }
    function inside(a, b) { return t >= a && t < b; }
    function offsetIn(el) {
      var x = 0, y = 0, n = el;
      while (n && n !== stage) { x += n.offsetLeft; y += n.offsetTop; n = n.offsetParent; }
      return { x: x, y: y, w: el.offsetWidth, h: el.offsetHeight };
    }
    function ease(p) { return p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2; }
    function seg(a, b) { return ease(Math.max(0, Math.min(1, (t - a) / (b - a)))); }
    function counts(y, b, run, idle) {
      return (y ? '<span class="y"><i></i>' + y + '</span>' : '') + (b ? '<span class="bl"><i></i>' + b + '</span>' : '')
        + (run ? '<span><span class="spin"></span>' + run + '</span>' : '') + (idle ? '<span><i></i>' + idle + '</span>' : '');
    }

    var REQUEST = 'Build the checkout redesign from the mockup in lumen. Check it at 390 and 1280 px.';
    var MERGE_IT = 'merge it';
    // The coordinator's turns: it works while the dock shows its working row.
    var DOCK_TURNS = [[2.9, 3.9], [15.0, 15.4], [19.9, 20.6]];
    var READY = 15.0, MERGING = 20.8, MERGED = 22.5;
    // docs-site's Codex session finishes a turn at DOCS_DONE: unread, it needs the user. Opened at
    // DOCS_OPEN, it stays in place while it is selected, and leaves when Codex works again.
    var DOCS_DONE = 8.0, DOCS_OPEN = 8.9, DOCS_WORK = 13.3, DOCS_FIXED = 14.4;
    var MERGE_ICON = '<svg viewBox="0 0 24 24"><path d="M12 3v7c0 3-5 5-5 8v3"/><path d="M12 10c0 3 5 5 5 8v3"/><path d="m8.5 6.5 3.5-3.5 3.5 3.5"/></svg>';

    function render() {
      timed.forEach(function (el) {
        var a = parseFloat(el.getAttribute('data-at') || '-1');
        var u = parseFloat(el.getAttribute('data-until') || '999');
        el.classList.toggle('show', t >= a && t < u);
      });

      // which workspace is on screen: lumen; the task space, opened from Toasty's reply; docs-site,
      // opened from the sidebar; then the task space again, opened from its row
      var ws = t < 4.6 ? 'lumen' : t < DOCS_OPEN ? 'child' : t < 17.6 ? 'docs' : 'child';
      Object.keys(viewEls).forEach(function (key) { viewEls[key].classList.toggle('show', key === ws); });

      // The coordinator's dock: the field types the request and "merge it"; Toasty works between them.
      var dockWorking = DOCK_TURNS.some(function (r) { return inside(r[0], r[1]); });
      dockSt.style.display = dockWorking ? '' : 'none';
      dockWk.classList.toggle('show', dockWorking);
      if (dockWorking) {
        var turn = DOCK_TURNS.filter(function (r) { return inside(r[0], r[1]); })[0];
        setText(dockWkT, 'working · ' + Math.max(1, Math.round((t - turn[0]) * 4)) + 's');
      }
      var typed = '';
      if (inside(0.7, 2.8)) typed = REQUEST.slice(0, Math.round(Math.max(0, Math.min(1, (t - 0.7) / 1.9)) * REQUEST.length));
      else if (inside(19.1, 19.8)) typed = MERGE_IT.slice(0, Math.round(Math.max(0, Math.min(1, (t - 19.1) / 0.4)) * MERGE_IT.length));
      setText(dockTyped, typed);
      var dockFocused = inside(0.5, 2.8) || inside(18.95, 19.8);
      dockPh.style.display = typed || dockFocused ? 'none' : '';
      dockF.classList.toggle('focus', dockFocused);
      dockSend.classList.toggle('on', typed.length > 0);
      dockSend.classList.toggle('stop', dockWorking);

      // The task space under lumen: starting, working, ready to review, merging, done.
      var ready = inside(READY, MERGING), merging = inside(MERGING, MERGED), done = t >= MERGED;
      var starting = inside(4.0, 4.9) || inside(5.8, 7.0);
      var working = !ready && !done;
      // Toasty's chips for the task follow it, as the app's do: its stage mark and, once it has one, its PR.
      crChips.forEach(function (c) {
        c.classList.toggle('run', working && !starting && t >= 4.0);
        c.classList.toggle('rev', ready);
        c.classList.toggle('done', done);
        c.classList.toggle('has-pr', ready || merging || done);
      });
      // The Needs you list. The task lists in lumen while it waits for review; the merge makes it
      // Running, so it leaves even while selected, and lumen, with nothing else, leaves with it.
      cardLumen.style.display = ready ? '' : 'none';
      // docs-site lists while its finished turn is unread, and stays while it is selected. Read,
      // the row counts as idle, so its group says 0, as the app draws it.
      var docsUnread = inside(DOCS_DONE, DOCS_OPEN);
      cardDocs.style.display = inside(DOCS_DONE, DOCS_WORK) ? '' : 'none';
      rowDocs.classList.toggle('ready', docsUnread);
      setHTML(docsIc, docsUnread ? '<span class="mk dot ready"></span>' : '');
      setText(docsBkt, 'NEEDS YOU ' + (docsUnread ? 1 : 0));
      setHTML(docsHc, counts(docsUnread ? 1 : 0, 0, 0, 0));
      setText(segY, String(1 + (docsUnread ? 1 : 0)));
      segRev.style.display = ready ? '' : 'none';
      var docsWorking = inside(DOCS_WORK, DOCS_FIXED);

      var annoMode = inside(9.8, 13.3);
      annoBtn.classList.toggle('on', annoMode);
      annoBar.classList.toggle('show', annoMode);
      var added = t >= 12.4;
      abCount.classList.toggle('show', added);
      abClear.classList.toggle('show', added);
      abSend.classList.toggle('on', added);
      // para's offsetParent is .site, which also holds the annotation overlays
      var box = { x: para.offsetLeft - 6, y: para.offsetTop - 5, w: para.offsetWidth + 12, h: codeBlock.offsetTop + codeBlock.offsetHeight - para.offsetTop + 10 };
      var drag = Math.max(0, Math.min(1, (t - 10.4) / 0.6));
      annoRect.classList.toggle('show', inside(10.4, 13.3));
      annoRect.style.left = box.x + 'px';
      annoRect.style.top = box.y + 'px';
      annoRect.style.width = Math.max(4, box.w * drag) + 'px';
      annoRect.style.height = Math.max(4, box.h * drag) + 'px';
      annoPop.classList.toggle('show', inside(11.1, 12.4));
      annoPop.style.left = Math.max(8, Math.min(box.x + box.w - 200, site.offsetWidth - 272)) + 'px';
      annoPop.style.top = (box.y + box.h + 8) + 'px';
      var ka = Math.max(0, Math.min(1, (t - 11.2) / 0.8));
      annoTyped.textContent = ANNO.slice(0, Math.round(ka * ANNO.length));
      annoAdd.classList.toggle('press', inside(12.3, 12.45));
      var sendBox0 = { x: annoBar.offsetLeft + abSend.offsetLeft, y: annoBar.offsetTop + annoBar.offsetHeight + 4 };
      annoMenu.style.left = (sendBox0.x - annoBar.offsetWidth / 2) + 'px';
      annoMenu.style.top = sendBox0.y + 'px';
      annoMenu.classList.toggle('show', inside(12.9, 13.25));
      annoItem.classList.toggle('hi', t >= 13.1);
      annoToast.classList.toggle('show', inside(13.3, 14.5));
      var v2 = t >= 14.4;
      site.classList.toggle('v2', v2);
      if (v2 && !wasV2) { para.classList.remove('flash'); void para.offsetWidth; para.classList.add('flash'); }
      wasV2 = v2;

      // selection
      cardLumen.classList.toggle('sel', ws === 'child');
      rowSub.classList.toggle('sel', ws === 'child');
      cardDocs.classList.toggle('sel', ws === 'docs');
      rowDocs.classList.toggle('sel', ws === 'docs');
      var mergeLabel = done ? '<span class="mergeb done">Done · PR #128</span>'
        : merging ? '<span class="mergeb busy"><span class="spin"></span>Merging PR #128…</span>'
        : '<span class="mergeb"><span>' + MERGE_ICON + 'Merge PR #128</span><span>⌄</span></span>';
      setHTML(wtitle, ws === 'child' ? '<b>checkout-redesign</b>' + (t < READY ? '<span>1 running</span>' : mergeLabel)
        : ws === 'docs' ? '<b>docs-site</b><span>' + (docsWorking ? '1 running' : 'idle') + '</span>'
        : '<b>lumen</b><span>idle</span>');
      setText(phead, ws === 'child' ? (t < 7.0 ? 'Claude Code · lumen' : 'Claude Code · lumen-checkout-redesign') : ws === 'docs' ? 'Codex · docs-site' : 'Claude Code · lumen');

      // right panel tabs belong to a workspace; each workspace has one active tab
      // The task space gains its report and PR tabs as its agent makes them.
      var ACTIVE = { lumen: 'mock', docs: 'docsweb', child: t < 12.6 ? 'mock' : 'verify' };
      tabs.forEach(function (tb) {
        var key = tb.getAttribute('data-tab');
        tb.classList.toggle('show', tb.getAttribute('data-ws').split(' ').indexOf(ws) >= 0 && t >= parseFloat(tb.getAttribute('data-from') || '0'));
        tb.classList.toggle('on', key === ACTIVE[ws]);
      });
      Object.keys(views).forEach(function (key) { views[key].classList.toggle('on', key === ACTIVE[ws]); });

      // camera: the desktop shows the whole window. The phone crop shows the sidebar and the dock;
      // it pans to Toasty's reply and the task's terminal while the task moves into its worktree,
      // and zooms the 380px right panel to fill the crop for the docs preview.
      var Z = 1, tx = 0, ty = 0;
      if (VW < 1200) {
        var toTask = seg(4.6, 5.2) - seg(7.6, 8.2), right = seg(9.0, 9.6) - seg(14.4, 14.9);
        var dockX = offsetIn(dockF.parentNode).x;
        if (toTask > 0) {
          // the dock's left edge to the terminal's right edge (580px) fills the crop
          Z = 1 + (VW / 580 - 1) * toTask;
          tx = -dockX * Z * toTask;
        } else {
          Z = 1 + (VW / 380 - 1) * right;
          tx = -(1200 * Z - VW) * right;
          ty = -40 * Z * right;
        }
      }
      cam.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + Z + ')';

      // cursor path
      var rest3 = { x: 700, y: 600 };
      var subBox = offsetIn(rowSub), docsBox = offsetIn(rowDocs), fieldBox = offsetIn(dockF), chipBox = offsetIn(crChips[0]);
      var onChip = { x: chipBox.x + chipBox.w / 2, y: chipBox.y + chipBox.h / 2 }, nearChip = { x: onChip.x + 110, y: onChip.y + 60 };
      var btnBox = offsetIn(annoBtn), siteBox = offsetIn(site), addBox = offsetIn(annoAdd), sendBox = offsetIn(abSend), itemBox = offsetIn(annoItem);
      var onSub = { x: subBox.x + 70, y: subBox.y + 14 };
      var onDocs = { x: docsBox.x + 80, y: docsBox.y + 14 };
      var onField = { x: fieldBox.x + 120, y: fieldBox.y + fieldBox.h / 2 };
      var onBtn = { x: btnBox.x + 10, y: btnBox.y + 8 };
      var dragA = { x: siteBox.x + box.x + 2, y: siteBox.y + box.y + 2 }, dragB = { x: siteBox.x + box.x + box.w, y: siteBox.y + box.y + box.h };
      var onAdd = { x: addBox.x + 16, y: addBox.y + 8 }, onSendBtn = { x: sendBox.x + 40, y: sendBox.y + 12 }, onItem = { x: itemBox.x + 50, y: itemBox.y + 10 };
      var path = [[0, nearChip], [4.0, nearChip], [4.4, onChip], [8.05, onChip], [8.7, onDocs], [9.0, onDocs], [9.6, onBtn], [9.8, onBtn], [10.3, dragA], [10.4, dragA], [11.0, dragB], [12.0, dragB], [12.3, onAdd], [12.5, onAdd], [12.8, onSendBtn], [12.95, onSendBtn], [13.15, onItem], [13.35, onItem], [14.0, rest3], [16.6, rest3], [17.3, onSub], [17.8, onSub], [18.7, onField], [D, onField]];
      var p = nearChip;
      for (var i = 0; i < path.length - 1; i++) {
        if (t >= path[i][0] && t < path[i + 1][0]) {
          var f = ease((t - path[i][0]) / (path[i + 1][0] - path[i][0]));
          p = { x: path[i][1].x + (path[i + 1][1].x - path[i][1].x) * f, y: path[i][1].y + (path[i + 1][1].y - path[i][1].y) * f };
          break;
        }
      }
      cursor.style.transform = 'translate(' + p.x + 'px,' + p.y + 'px)';
      var clicks = [4.45, 8.75, 9.7, 12.35, 12.85, 13.2, 17.4, 18.85];
      cursor.classList.toggle('click', clicks.some(function (c) { return t >= c && t < c + 0.4; }));
      // The pointer shows only while it moves to something or clicks it: to Toasty's chip, from the
      // docs step to its last click, then from the move to the task row until the user types
      // "merge it" (macOS hides the pointer while you type). So it never sits idle in a still such
      // as the poster.
      cursor.style.opacity = t < 3.95 ? 0 : t < 4.6 ? seg(3.95, 4.1) : t < 4.9 ? 1 - seg(4.6, 4.9) : t < 8.0 ? 0 : t < 13.6 ? seg(8.0, 8.15)
        : t < 14.0 ? 1 - seg(13.6, 14.0) : t < 16.5 ? 0 : t < 19.1 ? seg(16.5, 16.7) : 1 - seg(19.1, 19.3);

      // loop fade
      fade.style.opacity = t > 23.2 ? (t - 23.2) / 0.8 : (t < 0.4 ? 1 - t / 0.4 : 0);

      // beat strip
      var idx = 0;
      beats.forEach(function (b, j) { if (t >= parseFloat(b.getAttribute('data-t'))) idx = j; });
      beats.forEach(function (b, j) {
        var s0 = parseFloat(b.getAttribute('data-t'));
        var s1 = j + 1 < beats.length ? parseFloat(beats[j + 1].getAttribute('data-t')) : D;
        b.classList.toggle('on', j === idx);
        b.querySelector('.bar i').style.width = (j < idx ? 100 : j === idx ? Math.min(100, (t - s0) / (s1 - s0) * 100) : 0) + '%';
      });
    }

    function frame(ts) {
      if (rendering) return;
      // Skip work while the video is scrolled out of view; resume where it left off.
      if (onScreen) {
        if (last !== null && playing) { t += Math.min(ts - last, 100) / 1000; if (t >= D) t = 0; }
        render();
      }
      stage.classList.toggle('paused', !playing || !onScreen);
      last = ts;
      requestAnimationFrame(frame);
    }
    var rendering = false;
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(function (entries) { onScreen = entries[0].isIntersecting; }).observe(wrap);
    }
    requestAnimationFrame(frame);

    var pp = $('pp'), ppIc = $('pp-ic');
    function setPlaying(v) {
      playing = v;
      pp.setAttribute('aria-label', v ? 'Pause' : 'Play');
      ppIc.innerHTML = v ? '<rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/>' : '<path d="M7 5v14l12-7z"/>';
    }
    setPlaying(playing);
    pp.addEventListener('click', function () { setPlaying(!playing); });
    beats.forEach(function (b) { b.addEventListener('click', function () { t = parseFloat(b.getAttribute('data-t')) + 0.01; render(); }); });

    // Frame-stepping API for scripts/website/render-hero-video.mjs. renderFrame(t) sets the
    // timeline and then drives every CSS transition and animation from that same clock, so a
    // headless browser can capture identical frames regardless of how long each capture takes.
    // Frames must be rendered in increasing t from a freshly loaded page. A still taken by
    // jumping straight to t has no history, so settle=true finishes the finite transitions
    // that start on that frame instead of showing their first instant.
    var animStart = new WeakMap();
    function syncAnimations(settle) {
      document.getAnimations().forEach(function (a) {
        var isNew = !animStart.has(a);
        if (isNew) { animStart.set(a, t); a.pause(); }
        var timing = a.effect && a.effect.getComputedTiming();
        if (isNew && settle && timing && isFinite(timing.endTime)) { a.finish(); return; }
        a.currentTime = Math.max(0, (t - animStart.get(a)) * 1000);
      });
    }
    window.toasttyHero = {
      duration: D,
      poster: POSTER,
      beats: beats.map(function (b) { return parseFloat(b.getAttribute('data-t')); }),
      startRendering: function () { rendering = true; setPlaying(false); fit(); },
      // A still renders twice: the pointer and the annotation overlays are placed from the layout,
      // which is final only once the transitions that this frame started have finished.
      renderFrame: function (x, settle) { t = x; render(); syncAnimations(!!settle); if (settle) { render(); syncAnimations(true); } }
    };

  } catch (e) {
    // The stage's static markup still shows the opening frame if the timeline fails.
    console.error('Toastty hero video failed to start', e);
  }
})();
