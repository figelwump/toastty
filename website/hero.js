/* Toastty hero video: an HTML recreation of the app driven by one timeline (t, in seconds). */
(function () {
  try {
    var D = 23;
    var stage = document.getElementById('stage');
    var wrap = document.getElementById('wrap');
    var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    // POSTER is the still used for reduced motion, the README, and the social card: the subspace
    // has just turned green with its PR chip, and the docs fix is visible in the right panel.
    var POSTER = 15.0;
    var t = reduce ? POSTER : 0, playing = !reduce, last = null, onScreen = true;

    // On narrow screens the window is shown through a portrait crop (VW design px wide)
    // that pans between the sidebar side and the right-panel side as the story moves.
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

    var timed = Array.prototype.slice.call(stage.querySelectorAll('[data-at],[data-until]'));
    var typedEl = document.getElementById('typed');
    var ANNO = 'Still shows the v1 payload. Update for v2.';
    var annoBtn = document.getElementById('anno-btn'), annoBar = document.getElementById('anno-bar'), abCount = document.getElementById('ab-count'), abSend = document.getElementById('ab-send');
    var abClear = annoBar.querySelector('.ab-clear'), annoMenu = document.getElementById('anno-menu'), annoItem = document.getElementById('anno-item'), annoRect = document.getElementById('anno-rect');
    var annoPop = document.getElementById('anno-pop'), annoTyped = document.getElementById('anno-typed'), annoAdd = document.getElementById('anno-add'), annoToast = document.getElementById('anno-toast');
    var cam = document.getElementById('cam');
    var site = document.getElementById('site'), para = document.getElementById('para'), codeBlock = document.getElementById('code-block');
    var wasV2 = false;
    var viewEls = { lumen: document.getElementById('view-lumen'), child: document.getElementById('view-child'), docs: document.getElementById('view-docs') };
    var cardDocs = document.getElementById('card-docs'), rowDocs = document.getElementById('row-docs');
    var docsS = document.getElementById('docs-s'), docsIc = document.getElementById('docs-ic');
    var docsPill = document.getElementById('docs-pill'), docsPillT = document.getElementById('docs-pill-t'), docsSpin = document.getElementById('docs-spin');
    var PROMPT = 'hand this off to a worktree and verify it visually';
    var pill = document.getElementById('pill'), pillT = document.getElementById('pill-t'), pillSpin = document.getElementById('pill-spin');
    var planS = document.getElementById('plan-s'), planIc = document.getElementById('plan-ic'), planFork = document.getElementById('plan-fork');
    var rowPlan = document.getElementById('row-plan');
    var rowSub = document.getElementById('row-sub'), subS = document.getElementById('sub-s'), subIc = document.getElementById('sub-ic');
    var subPr = document.getElementById('sub-pr'), subEl = document.getElementById('sub-el');
    var card = document.getElementById('card-lumen');
    var wtitle = document.getElementById('wtitle'), phead = document.getElementById('phead');
    var tabs = Array.prototype.slice.call(document.querySelectorAll('.rtab'));
    var views = {};
    Array.prototype.forEach.call(document.querySelectorAll('.rv'), function (v) { views[v.getAttribute('data-view')] = v; });
    var cb = document.getElementById('cb');
    var cursor = document.getElementById('cursor');
    var fade = document.getElementById('fade');
    var beats = Array.prototype.slice.call(document.querySelectorAll('.beat'));

    // Replacing innerHTML every frame restarts the spinner animation; only write on change.
    function setIcon(el, html) { if (el.__icon !== html) { el.innerHTML = html; el.__icon = html; } }
    function pick(list) { var v = list[0][1]; for (var i = 0; i < list.length; i++) if (t >= list[i][0]) v = list[i][1]; return v; }
    function offsetIn(el) {
      var x = 0, y = 0, n = el;
      while (n && n !== stage) { x += n.offsetLeft; y += n.offsetTop; n = n.offsetParent; }
      return { x: x, y: y, w: el.offsetWidth, h: el.offsetHeight };
    }
    function ease(p) { return p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2; }

    var PLAN_S = [[0, 'Waiting for your input'], [3.3, 'Creating worktree…'], [6.0, 'Handed off to checkout-redesign']];
    var SUB_S = [[0, 'Reading handoff…'], [6.0, 'Editing SummaryCard.tsx'], [7.0, 'Running npm test…'], [9.5, 'Capturing screenshots…'], [11.0, 'Writing verification report…'], [14.2, 'Opening PR…'], [15.0, 'Ready for review']];
    var DOCS_S = [[0, 'Ready for prompt'], [13.3, 'Reading annotation 1…'], [13.7, 'Editing webhooks.md'], [14.4, 'Updated the preview']];

    function render() {
      timed.forEach(function (el) {
        var a = parseFloat(el.getAttribute('data-at') || '-1');
        var u = parseFloat(el.getAttribute('data-until') || '999');
        el.classList.toggle('show', t >= a && t < u);
      });

      // typing in the parent prompt
      var k = Math.max(0, Math.min(1, (t - 0.8) / 2.2));
      typedEl.textContent = t < 3.2 ? PROMPT.slice(0, Math.round(k * PROMPT.length)) : '';

      // parent session row
      var planWorking = t >= 3.3 && t < 6.0;
      rowPlan.classList.toggle('working', planWorking);
      planS.textContent = pick(PLAN_S);
      setIcon(planIc, planWorking ? '<span class="spin"></span>' : '');
      planFork.style.display = t >= 6.0 ? '' : 'none';

      // which workspace is on screen; the subspace isn't opened until it's ready
      var ws = t < 8.9 ? 'lumen' : t < 17.75 ? 'docs' : 'child';
      Object.keys(viewEls).forEach(function (key) { viewEls[key].classList.toggle('show', key === ws); });

      // subspace row: working, then ready (green) until you open it
      var done = t >= 15.0;
      var readyUnread = done && ws !== 'child';
      rowSub.classList.toggle('working', !done);
      rowSub.classList.toggle('ready', readyUnread);
      subS.textContent = pick(SUB_S);
      // subspace marks are square: filled green while ready and unread, hollow once opened
      setIcon(subIc, !done ? '<span class="spin"></span>' : readyUnread ? '<span class="mk sq ready"></span>' : '<span class="mk sq quiet"></span>');
      subPr.classList.toggle('show', done);
      var secs = Math.round(Math.max(0, Math.min(t, 15.0) - 4.8) * 25 + 4);
      subEl.textContent = Math.floor(secs / 60) + 'm ' + ('0' + (secs % 60)).slice(-2) + 's';
      subEl.style.display = done ? 'none' : '';

      // docs-site: annotate the preview and send it to the agent
      var docsWorking = t >= 13.3 && t < 14.4;
      rowDocs.classList.toggle('working', docsWorking);
      docsS.textContent = pick(DOCS_S);
      setIcon(docsIc, docsWorking ? '<span class="spin"></span>' : '');
      docsPillT.textContent = (docsWorking ? 1 : 0) + '/1';
      docsSpin.style.display = docsWorking ? '' : 'none';
      docsPill.classList.toggle('quiet', !docsWorking);

      var annoMode = t >= 9.8 && t < 13.3;
      annoBtn.classList.toggle('on', annoMode);
      annoBar.classList.toggle('show', annoMode);
      var added = t >= 12.4;
      abCount.classList.toggle('show', added);
      abClear.classList.toggle('show', added);
      abSend.classList.toggle('on', added);
      // para's offsetParent is .site, which also holds the annotation overlays
      var box = { x: para.offsetLeft - 6, y: para.offsetTop - 5, w: para.offsetWidth + 12, h: codeBlock.offsetTop + codeBlock.offsetHeight - para.offsetTop + 10 };
      var drag = Math.max(0, Math.min(1, (t - 10.4) / 0.6));
      annoRect.classList.toggle('show', t >= 10.4 && t < 13.3);
      annoRect.style.left = box.x + 'px';
      annoRect.style.top = box.y + 'px';
      annoRect.style.width = Math.max(4, box.w * drag) + 'px';
      annoRect.style.height = Math.max(4, box.h * drag) + 'px';
      annoPop.classList.toggle('show', t >= 11.1 && t < 12.4);
      annoPop.style.left = Math.max(8, Math.min(box.x + box.w - 200, site.offsetWidth - 272)) + 'px';
      annoPop.style.top = (box.y + box.h + 8) + 'px';
      var ka = Math.max(0, Math.min(1, (t - 11.2) / 0.8));
      annoTyped.textContent = ANNO.slice(0, Math.round(ka * ANNO.length));
      annoAdd.classList.toggle('press', t >= 12.3 && t < 12.45);
      var sendBox0 = { x: annoBar.offsetLeft + abSend.offsetLeft, y: annoBar.offsetTop + annoBar.offsetHeight + 4 };
      annoMenu.style.left = (sendBox0.x - annoBar.offsetWidth / 2) + 'px';
      annoMenu.style.top = sendBox0.y + 'px';
      annoMenu.classList.toggle('show', t >= 12.9 && t < 13.25);
      annoItem.classList.toggle('hi', t >= 13.1);
      annoToast.classList.toggle('show', t >= 13.3 && t < 14.5);
      var v2 = t >= 14.4;
      site.classList.toggle('v2', v2);
      if (v2 && !wasV2) { para.classList.remove('flash'); void para.offsetWidth; para.classList.add('flash'); }
      wasV2 = v2;

      // workspace progress pill
      var running = (planWorking ? 1 : 0) + (t >= 4.8 && !done ? 1 : 0);
      pillT.textContent = running + '/' + (t >= 4.8 ? 3 : 2);
      pillSpin.style.display = running ? '' : 'none';
      pill.classList.toggle('quiet', !running);

      // selection
      card.classList.toggle('sel', ws === 'lumen');
      card.classList.toggle('parent-hl', ws === 'child');
      rowSub.classList.toggle('sel', ws === 'child');
      cardDocs.classList.toggle('sel', ws === 'docs');
      rowDocs.classList.toggle('sel', ws === 'docs');
      wtitle.innerHTML = ws === 'child' ? '<b>checkout-redesign</b><span>subspace of lumen</span>'
        : ws === 'docs' ? '<b>docs-site</b><span>' + (docsWorking ? '1 running' : 'idle') + '</span>'
        : '<b>lumen</b><span>' + (running ? running + ' running' : 'idle') + '</span>';
      phead.textContent = ws === 'child' ? 'Claude Code · lumen-checkout-redesign' : ws === 'docs' ? 'Codex · docs-site' : 'Claude Code · lumen';

      // right panel tabs belong to a workspace; the latest visible one is active
      var active = null;
      tabs.forEach(function (tb) {
        var a = parseFloat(tb.getAttribute('data-at') || '0');
        var vis = tb.getAttribute('data-ws').split(' ').indexOf(ws) >= 0 && t >= a;
        tb.classList.toggle('show', vis);
        if (vis) active = tb.getAttribute('data-tab');
      });
      tabs.forEach(function (tb) { tb.classList.toggle('on', tb.getAttribute('data-tab') === active); });
      Object.keys(views).forEach(function (key) { views[key].classList.toggle('on', key === active); });
      cb.classList.toggle('done', t >= 12.0);

      // camera: zoom into the sidebar when the subspace appears and when it turns ready
      function seg(a, b) { return ease(Math.max(0, Math.min(1, (t - a) / (b - a)))); }
      var zoomAmt = Math.max(seg(3.5, 4.2) - seg(7.4, 8.0), seg(15.0, 15.5) - seg(19.6, 20.2));
      var focus = offsetIn(card), Z = 1 + 1.05 * zoomAmt;
      // anchor on the card's top so the view doesn't drift as the subspace row grows in
      var fx = focus.x + focus.w / 2, fy = focus.y + 190;
      var tx = Math.min(0, Math.max(VW - 1200 * Z, 330 - fx * Z)), ty = Math.min(0, Math.max(740 - 740 * Z, 370 - fy * Z));
      if (VW < 1200 && zoomAmt < 0.001) {
        // phone crop: for the docs preview and the PR, zoom the 450px right panel to fill the crop
        var right = Math.max(seg(9.0, 9.6) - seg(14.4, 14.9), seg(20.2, 20.8));
        Z = 1 + (VW / 450 - 1) * right;
        tx = -(1200 * Z - VW) * right;
        ty = -40 * Z * right;
      }
      cam.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + Z + ')';

      // cursor path
      var rest1 = { x: 820, y: 560 }, rest3 = { x: 640, y: 600 };
      var subBox = offsetIn(rowSub), prBox = offsetIn(subPr), docsBox = offsetIn(rowDocs);
      var btnBox = offsetIn(annoBtn), siteBox = offsetIn(site), addBox = offsetIn(annoAdd), sendBox = offsetIn(abSend), itemBox = offsetIn(annoItem);
      var onSub = { x: subBox.x + 70, y: subBox.y + 14 };
      var onDocs = { x: docsBox.x + 80, y: docsBox.y + 14 };
      var onPr = { x: prBox.x + 20, y: prBox.y + 9 };
      var onBtn = { x: btnBox.x + 10, y: btnBox.y + 8 };
      var dragA = { x: siteBox.x + box.x + 2, y: siteBox.y + box.y + 2 }, dragB = { x: siteBox.x + box.x + box.w, y: siteBox.y + box.y + box.h };
      var restZ = { x: 470, y: subBox.y + 95 };
      var onAdd = { x: addBox.x + 16, y: addBox.y + 8 }, onSendBtn = { x: sendBox.x + 40, y: sendBox.y + 12 }, onItem = { x: itemBox.x + 50, y: itemBox.y + 10 };
      var path = [[0, rest1], [8.0, rest1], [8.7, onDocs], [9.0, onDocs], [9.6, onBtn], [9.8, onBtn], [10.3, dragA], [10.4, dragA], [11.0, dragB], [12.0, dragB], [12.3, onAdd], [12.5, onAdd], [12.8, onSendBtn], [12.95, onSendBtn], [13.15, onItem], [13.35, onItem], [14.0, rest3], [14.3, rest3], [14.9, restZ], [16.9, restZ], [17.5, onSub], [18.1, onSub], [18.6, restZ], [18.8, restZ], [19.3, onPr], [20.3, onPr], [21.0, rest1], [D, rest1]];
      var p = rest1;
      for (var i = 0; i < path.length - 1; i++) {
        if (t >= path[i][0] && t < path[i + 1][0]) {
          var f = ease((t - path[i][0]) / (path[i + 1][0] - path[i][0]));
          p = { x: path[i][1].x + (path[i + 1][1].x - path[i][1].x) * f, y: path[i][1].y + (path[i + 1][1].y - path[i][1].y) * f };
          break;
        }
      }
      cursor.style.transform = 'translate(' + p.x + 'px,' + p.y + 'px)';
      var clicks = [8.75, 9.7, 12.35, 12.85, 13.2, 17.6, 19.4];
      cursor.classList.toggle('click', clicks.some(function (c) { return t >= c && t < c + 0.4; }));
      cursor.style.opacity = t < 7.9 ? 0 : 1;

      // loop fade
      fade.style.opacity = t > 22.2 ? (t - 22.2) / 0.8 : (t < 0.4 ? 1 - t / 0.4 : 0);

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

    var pp = document.getElementById('pp'), ppIc = document.getElementById('pp-ic');
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
      renderFrame: function (x, settle) { t = x; render(); syncAnimations(!!settle); }
    };

  } catch (e) {
    // The stage's static markup still shows the opening frame if the timeline fails.
    console.error('Toastty hero video failed to start', e);
  }
})();
