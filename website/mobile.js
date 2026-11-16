/* Toastty Mobile video: an HTML recreation of the iPhone client driven by one timeline (t, in seconds). */
(function () {
  try {
    var D = 21;
    var wrap = document.getElementById('mwrap');
    var stage = document.getElementById('mstage');
    if (!wrap || !stage) return;
    var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    // POSTER is the still used for reduced motion, the README, and the mobile social card: Home on
    // Needs you, with a session that needs approval, two tasks ready for review and the tab bar.
    var POSTER = 1.2;
    var t = reduce ? POSTER : 0, playing = !reduce, last = null, onScreen = true, rendering = false;

    var W = 440, H = 900, SW = 390;
    function fit() {
      var s = wrap.clientWidth / W;
      stage.style.transform = 'scale(' + s + ')';
      wrap.style.height = (H * s) + 'px';
    }
    window.addEventListener('resize', fit);
    fit();

    function $(id) { return document.getElementById(id); }
    var scr = $('scr');
    var timed = Array.prototype.slice.call(stage.querySelectorAll('[data-at],[data-until]'));
    var home = $('s-home'), conv = $('s-conv'), coord = $('s-coord');
    var homeDim = $('home-dim');
    var lumenNeeds = $('lumen-needs'), lumenY = $('lumen-y'), segY = $('seg-y');
    var rowMigrate = $('row-migrate'), migrateIc = $('migrate-ic'), migrateBadge = $('migrate-badge'), migrateS = $('migrate-s'), migrateAge = $('migrate-age');
    var cstatIc = $('cstat-ic'), cstatT = $('cstat-t'), cstat = cstatT.parentNode;
    var qcard = $('qcard'), qstate = $('qstate'), opt1 = $('opt1'), qstatus = $('qstatus'), qsubmit = $('qsubmit');
    var strip2Spin = $('strip2-spin'), strip2Chev = $('strip2-chev'), strip2T = $('strip2-t');
    var comp = $('comp'), cph = $('cph'), csend = $('csend'), cstop = $('cstop'), wrow = $('wrow'), wrowT = $('wrow-t'), backb = $('backb');
    var ccomp = $('ccomp'), cfield2 = $('cfield2'), cph2 = $('cph2'), ctyped2 = $('ctyped2'), csend3 = $('csend3'), cstop3 = $('cstop3'), ckbd = $('ckbd');
    var cwrow = $('cwrow'), cwrowT = $('cwrow-t');
    var tabbar = $('tabbar'), tabHome = $('tab-home'), tabCoord = $('tab-coord');
    var touch = $('touch'), fade = $('mfade');
    var beats = Array.prototype.slice.call(document.querySelectorAll('#mbeats .beat'));
    var REQUEST = 'Add a CSV export to the orders page, like the mockup in lumen.';
    var MERGE_IT = 'merge it';

    function setIcon(el, html) { if (el.__icon !== html) { el.innerHTML = html; el.__icon = html; } }
    function setText(el, s) { if (el.__text !== s) { el.textContent = s; el.__text = s; } }
    function ease(p) { return p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2; }
    function seg(a, b) { return ease(Math.max(0, Math.min(1, (t - a) / (b - a)))); }
    function inside(a, b) { return t >= a && t < b; }
    function pick(list) { var v = list[0][1]; for (var i = 0; i < list.length; i++) if (t >= list[i][0]) v = list[i][1]; return v; }
    function offsetIn(el) {
      var x = 0, y = 0, n = el;
      while (n && n !== scr) { x += n.offsetLeft; y += n.offsetTop; n = n.offsetParent; }
      return { x: x, y: y, w: el.offsetWidth, h: el.offsetHeight };
    }
    function center(el) { var b = offsetIn(el); return { x: b.x + b.w / 2, y: b.y + b.h / 2 }; }
    function mmss(secs) { secs = Math.max(0, Math.round(secs)); return Math.floor(secs / 60) + 'm ' + ('0' + (secs % 60)).slice(-2) + 's'; }
    function typedAt(text, a, b) { return text.slice(0, Math.round(Math.max(0, Math.min(1, (t - a) / (b - a))) * text.length)); }

    // Timeline
    var T = {
      tapRow: 2.5, push: [2.75, 3.1],
      tapOpt: 4.3, tapSubmit: 5.4, sending: [5.45, 6.0], sent: [6.0, 6.8], resolved: 6.8,
      strip2: [[7.2, 'working · 1 tool call'], [7.9, 'working · 2 tool calls'], [8.6, 'working · 3 tool calls']],
      // Back to Home, where the tab bar is, then the Coordinator tab: ask for a task, then answer
      // Toasty's review note with "merge it".
      tapBack: 7.85, pop: [7.95, 8.3],
      tapTab: 8.55, tab: [8.6, 8.8],
      tapField: 9.15, kbd: [9.25, 9.55], type: [9.6, 11.0], tapSend: 11.3, kbdOut: [11.4, 11.7],
      tapField2: 15.2, kbd2: [15.3, 15.6], type2: [15.7, 16.1], tapSend2: 16.4, kbdOut2: [16.5, 16.8],
      fadeOut: 20.2
    };
    // Toasty works between a message and its answer.
    var COORD_TURNS = [[11.45, 12.5], [13.6, 14.0], [16.55, 17.5]];
    var TAPS = [
      [T.tapRow, function () { return center(rowMigrate); }],
      [T.tapOpt, function () { var b = offsetIn(opt1); return { x: b.x + 9, y: b.y + 13 }; }],
      [T.tapSubmit, function () { return center(qsubmit); }],
      [T.tapBack, function () { return center(backb); }],
      [T.tapTab, function () { return center(tabCoord); }],
      [T.tapField, function () { var b = offsetIn(cfield2); return { x: b.x + 120, y: b.y + b.h / 2 }; }],
      [T.tapSend, function () { return center(csend3); }],
      [T.tapField2, function () { var b = offsetIn(cfield2); return { x: b.x + 120, y: b.y + b.h / 2 }; }],
      [T.tapSend2, function () { return center(csend3); }]
    ];
    var MIGRATE_S = [[0, 'Needs approval: run migration'], [T.resolved, 'Backfilling orders in batches…']];

    function render() {
      timed.forEach(function (el) {
        var a = parseFloat(el.getAttribute('data-at') || '-1');
        var u = parseFloat(el.getAttribute('data-until') || '999');
        el.classList.toggle('show', t >= a && t < u);
      });

      // Screen transitions: iOS push slides the conversation in from the right and nudges Home left;
      // Back reverses it. The Coordinator tab replaces Home without a slide.
      var cx = seg(T.push[0], T.push[1]) - seg(T.pop[0], T.pop[1]);
      conv.style.visibility = cx > 0.001 ? 'visible' : 'hidden';
      conv.style.transform = 'translateX(' + (SW * (1 - cx)) + 'px)';
      home.style.transform = 'translateX(' + (-0.3 * SW * cx) + 'px)';
      homeDim.style.opacity = 0.4 * cx;
      var tb = seg(T.tab[0], T.tab[1]);
      coord.style.visibility = tb > 0.001 ? 'visible' : 'hidden';
      coord.style.opacity = tb;
      var onCoord = t >= T.tab[0];
      tabHome.classList.toggle('on', !onCoord);
      tabCoord.classList.toggle('on', onCoord);

      // Home: the migration session needs approval until the question is answered. Once its agent
      // works again it leaves the Needs you list, which Home shows.
      var mstate = t < T.resolved ? 'approval' : 'working';
      var listed = mstate === 'approval';
      rowMigrate.style.display = listed ? '' : 'none';
      lumenNeeds.style.display = listed ? '' : 'none';
      lumenY.style.display = listed ? '' : 'none';
      setText(segY, listed ? '2' : '1');
      rowMigrate.className = 'mrow ' + mstate;
      migrateBadge.style.display = mstate === 'approval' ? '' : 'none';
      setIcon(migrateIc, mstate === 'approval' ? '<i class="mk dot appr"></i>' : '<span class="spin"></span>');
      setText(migrateS, pick(MIGRATE_S));
      setText(migrateAge, mstate === 'working' ? mmss((t - T.resolved) * 9 + 3) : '1m');

      // Conversation header status
      cstat.className = 'cstat ' + mstate;
      setIcon(cstatIc, mstate === 'working' ? '<span class="spin"></span>' : '');
      cstatIc.className = mstate === 'working' ? 'spin' : '';
      setText(cstatT, mstate === 'approval' ? 'needs approval' : mstate);

      // Question card
      var sel = t >= T.tapOpt + 0.05;
      opt1.classList.toggle('sel', sel);
      qsubmit.classList.toggle('on', sel && t < T.sending[0]);
      qsubmit.classList.toggle('press', inside(T.tapSubmit, T.tapSubmit + 0.18));
      var qs = t < T.tapOpt + 0.05 ? 'Answer every question to continue' : t < T.sending[0] ? '' : t < T.sent[0] ? 'Sending answer…' : 'Answer sent · waiting for Claude';
      setText(qstatus, qs);
      qstatus.classList.toggle('sent', t >= T.sent[0]);
      qcard.classList.toggle('done', t >= T.resolved);
      setText(qstate, t >= T.resolved ? 'resolved' : 'pending');

      // Work strip after the answer
      setText(strip2T, pick(T.strip2));
      strip2Spin.style.display = '';
      strip2Chev.style.display = 'none';

      // Working row at the transcript tail; the turn time runs at the same pace as the Home row.
      var working = mstate === 'working';
      wrow.classList.toggle('show', working);
      if (working) {
        var secs = Math.round((t - T.resolved) * 9 + 3);
        setText(wrowT, 'working · ' + (secs < 60 ? secs + 's' : mmss(secs)));
      }

      // Conversation composer: locked while the question is pending, then Stop while the agent works.
      setText(cph, mstate === 'approval' ? 'Pending request — input paused' : 'Message Claude Code…');
      cstop.classList.toggle('show', working);
      csend.classList.toggle('hide', working);

      // Coordinator composer: type the request, then "merge it"; Stop shows while Toasty works.
      var coordWorking = COORD_TURNS.some(function (r) { return inside(r[0], r[1]); });
      cwrow.classList.toggle('show', coordWorking);
      if (coordWorking) {
        var turn = COORD_TURNS.filter(function (r) { return inside(r[0], r[1]); })[0];
        setText(cwrowT, 'working · ' + Math.max(1, Math.round((t - turn[0]) * 4)) + 's');
      }
      var typed = inside(T.type[0], T.tapSend + 0.1) ? typedAt(REQUEST, T.type[0], T.type[1])
        : inside(T.type2[0], T.tapSend2 + 0.1) ? typedAt(MERGE_IT, T.type2[0], T.type2[1]) : '';
      setText(ctyped2, typed);
      setText(cph2, typed ? '' : 'Message Claude…');
      var focused = inside(T.tapField, T.tapSend + 0.1) || inside(T.tapField2, T.tapSend2 + 0.1);
      cfield2.classList.toggle('focus', focused);
      csend3.classList.toggle('on', typed.length > 0);
      csend3.classList.toggle('press', inside(T.tapSend, T.tapSend + 0.18) || inside(T.tapSend2, T.tapSend2 + 0.18));
      csend3.classList.toggle('hide', coordWorking);
      cstop3.classList.toggle('show', coordWorking);
      var k = Math.max(seg(T.kbd[0], T.kbd[1]) - seg(T.kbdOut[0], T.kbdOut[1]), seg(T.kbd2[0], T.kbd2[1]) - seg(T.kbdOut2[0], T.kbdOut2[1]));
      ckbd.style.height = (248 * k) + 'px';
      // A session screen hides the tab bar (ToasttyConversationScreen.swift); the coordinator's chat
      // keeps it, and its composer clears it until the keyboard, which covers it, takes over.
      comp.style.paddingBottom = '42px';
      ccomp.style.paddingBottom = (12 + 96 * (1 - k)) + 'px';
      tabbar.style.opacity = (1 - cx) * (1 - k);

      // Touch indicator
      touch.style.opacity = 0;
      for (var i = 0; i < TAPS.length; i++) {
        var dt = t - TAPS[i][0];
        if (dt >= 0 && dt < 0.45) {
          // A target can hide mid-pulse (Send folds away); keep the pulse where it was last seen.
          var p = TAPS[i][1]();
          if (p.x || p.y) TAPS[i].last = p; else p = TAPS[i].last || p;
          touch.style.transform = 'translate(' + p.x + 'px,' + p.y + 'px) scale(' + (0.55 + dt) + ')';
          touch.style.opacity = Math.max(0, 1 - dt / 0.45);
        }
      }

      // loop fade
      fade.style.opacity = t > T.fadeOut ? (t - T.fadeOut) / 0.8 : (t < 0.4 ? 1 - t / 0.4 : 0);

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
      if (onScreen) {
        if (last !== null && playing) { t += Math.min(ts - last, 100) / 1000; if (t >= D) t = 0; }
        render();
      }
      stage.classList.toggle('paused', !playing || !onScreen);
      last = ts;
      requestAnimationFrame(frame);
    }
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(function (entries) { onScreen = entries[0].isIntersecting; }).observe(wrap);
    }
    requestAnimationFrame(frame);

    var pp = $('mpp'), ppIc = $('mpp-ic');
    function setPlaying(v) {
      playing = v;
      pp.setAttribute('aria-label', v ? 'Pause' : 'Play');
      ppIc.innerHTML = v ? '<rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/>' : '<path d="M7 5v14l12-7z"/>';
    }
    setPlaying(playing);
    pp.addEventListener('click', function () { setPlaying(!playing); });
    // A step button seeks to a settled frame inside its step (data-seek), not to the transition that starts it.
    beats.forEach(function (b) { b.addEventListener('click', function () { t = parseFloat(b.getAttribute('data-seek') || b.getAttribute('data-t')) + 0.01; render(); }); });

    // Frame-stepping API for scripts/website/render-hero-video.mjs --target mobile; see hero.js.
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
    window.toasttyMobile = {
      duration: D,
      poster: POSTER,
      beats: beats.map(function (b) { return parseFloat(b.getAttribute('data-t')); }),
      startRendering: function () {
        rendering = true; setPlaying(false);
        // Render at design size: the column is widened so the stage scale is exactly 1.
        var col = wrap.parentNode; col.style.maxWidth = 'none'; col.style.width = W + 'px'; col.style.marginTop = '0';
        fit();
      },
      renderFrame: function (x, settle) { t = x; render(); syncAnimations(!!settle); }
    };
  } catch (e) {
    console.error('Toastty mobile video failed to start', e);
  }
})();
