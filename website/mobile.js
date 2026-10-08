/* Toastty Mobile video: an HTML recreation of the iPhone client driven by one timeline (t, in seconds). */
(function () {
  try {
    var D = 21;
    var wrap = document.getElementById('mwrap');
    var stage = document.getElementById('mstage');
    if (!wrap || !stage) return;
    var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    // POSTER is the still used for reduced motion, the README, and the mobile social card: Home,
    // with the checkout-redesign subspace just turned green with its PR chip.
    var POSTER = 16.0;
    var t = reduce ? POSTER : 0, playing = !reduce, last = null, onScreen = true, rendering = false;

    var W = 440, H = 900, SW = 390, SH = 844;
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
    var home = $('s-home'), conv = $('s-conv'), sub = $('s-sub'), sheet = $('sheet');
    var homeDim = $('home-dim'), subDim = $('sub-dim');
    var rowMigrate = $('row-migrate'), migrateIc = $('migrate-ic'), migrateBadge = $('migrate-badge'), migrateS = $('migrate-s'), migrateAge = $('migrate-age');
    var rowCheckout = $('row-checkout'), checkoutIc = $('checkout-ic'), checkoutS = $('checkout-s'), checkoutAge = $('checkout-age'), checkoutPr = $('checkout-pr'), tally = $('tally');
    var cstatIc = $('cstat-ic'), cstatT = $('cstat-t'), cstat = cstatT.parentNode;
    var qcard = $('qcard'), qstate = $('qstate'), opt1 = $('opt1'), qstatus = $('qstatus'), qsubmit = $('qsubmit');
    var strip2Spin = $('strip2-spin'), strip2Chev = $('strip2-chev'), strip2T = $('strip2-t');
    var comp = conv.querySelector('.comp'), cfield = $('cfield'), cph = $('cph'), ctyped = $('ctyped'), csend = $('csend'), cstatus = $('cstatus'), kbd = $('kbd');
    var backb = $('backb'), subPr = $('msub-pr'), touch = $('touch'), fade = $('mfade');
    var beats = Array.prototype.slice.call(document.querySelectorAll('#mbeats .beat'));
    var REPLY = 'Open a PR once CI is green';

    function setIcon(el, html) { if (el.__icon !== html) { el.innerHTML = html; el.__icon = html; } }
    function setText(el, s) { if (el.__text !== s) { el.textContent = s; el.__text = s; } }
    function ease(p) { return p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2; }
    function seg(a, b) { return ease(Math.max(0, Math.min(1, (t - a) / (b - a)))); }
    function pick(list) { var v = list[0][1]; for (var i = 0; i < list.length; i++) if (t >= list[i][0]) v = list[i][1]; return v; }
    function offsetIn(el) {
      var x = 0, y = 0, n = el;
      while (n && n !== scr) { x += n.offsetLeft; y += n.offsetTop; n = n.offsetParent; }
      return { x: x, y: y, w: el.offsetWidth, h: el.offsetHeight };
    }
    function center(el) { var b = offsetIn(el); return { x: b.x + b.w / 2, y: b.y + b.h / 2 }; }
    function mmss(secs) { secs = Math.max(0, Math.round(secs)); return Math.floor(secs / 60) + 'm ' + ('0' + (secs % 60)).slice(-2) + 's'; }

    // Timeline
    var T = {
      tapRow: 2.5, push: [2.75, 3.1],
      tapOpt: 4.3, tapSubmit: 5.4, sending: [5.45, 6.0], sent: [6.0, 6.8], resolved: 6.8,
      strip2: [[7.2, 'working · 1 tool call'], [7.9, 'working · 2 tool calls'], [8.6, 'working · 3 tool calls'], [10.0, 'worked · 5 tool calls']],
      ready: 10.0, tapField: 10.9, kbd: [11.0, 11.3], type: [11.4, 12.7], tapSend: 13.3, sentMsg: 13.45, kbdOut: [13.55, 13.85], working2: 13.9,
      tapBack: 14.3, pop: [14.4, 14.75],
      checkoutReady: 15.8, tapCheckout: 16.4, pushSub: [16.55, 16.9], tapPr: 17.8, sheetUp: [17.95, 18.3],
      fadeOut: 20.2
    };
    var TAPS = [
      [T.tapRow, function () { return center(rowMigrate); }],
      [T.tapOpt, function () { var b = offsetIn(opt1); return { x: b.x + 9, y: b.y + 13 }; }],
      [T.tapSubmit, function () { return center(qsubmit); }],
      [T.tapField, function () { var b = offsetIn(cfield); return { x: b.x + 120, y: b.y + b.h / 2 }; }],
      [T.tapSend, function () { return center(csend); }],
      [T.tapBack, function () { return center(backb); }],
      [T.tapCheckout, function () { var b = offsetIn(rowCheckout); return { x: b.x + 110, y: b.y + b.h / 2 }; }],
      [T.tapPr, function () { return center(subPr); }]
    ];
    var MIGRATE_S = [[0, 'Needs approval: run migration'], [T.resolved, 'Backfilling orders in batches…'], [T.ready, 'Backfill done. Want me to open a PR?'], [T.working2, 'Opening a pull request…']];
    var CHECKOUT_S = [[0, 'Capturing screenshots…'], [11.0, 'Writing verification report…'], [14.6, 'Opening PR…'], [T.checkoutReady, 'Ready for review']];

    function render() {
      timed.forEach(function (el) {
        var a = parseFloat(el.getAttribute('data-at') || '-1');
        var u = parseFloat(el.getAttribute('data-until') || '999');
        el.classList.toggle('show', t >= a && t < u);
      });

      // Screen transitions: iOS push slides the new screen in from the right and nudges the old one left.
      var cx = seg(T.push[0], T.push[1]) - seg(T.pop[0], T.pop[1]);
      var sx = seg(T.pushSub[0], T.pushSub[1]);
      conv.style.visibility = cx > 0.001 ? 'visible' : 'hidden';
      conv.style.transform = 'translateX(' + (SW * (1 - cx)) + 'px)';
      sub.style.visibility = sx > 0.001 ? 'visible' : 'hidden';
      var sp = seg(T.sheetUp[0], T.sheetUp[1]);
      sub.style.transform = 'translateX(' + (SW * (1 - sx)) + 'px) translateY(' + (12 * sp) + 'px) scale(' + (1 - 0.07 * sp) + ')';
      sub.style.borderRadius = (20 * sp) + 'px';
      var hx = Math.max(cx, sx);
      home.style.transform = 'translateX(' + (-0.3 * SW * hx) + 'px)';
      homeDim.style.opacity = 0.4 * hx;
      subDim.style.opacity = 0.45 * sp;
      sheet.style.transform = 'translateY(' + (SH * (1 - sp)) + 'px)';

      // Home: the migration session moves through approval, working, ready, and working again.
      var mstate = t < T.resolved ? 'approval' : t < T.ready ? 'working' : t < T.sentMsg ? 'ready' : 'working';
      rowMigrate.className = 'mrow ' + mstate;
      migrateBadge.style.display = mstate === 'approval' ? '' : 'none';
      setIcon(migrateIc, mstate === 'approval' ? '<i class="mk dot appr"></i>' : mstate === 'ready' ? '<i class="mk dot ready"></i>' : '<span class="spin"></span>');
      setText(migrateS, pick(MIGRATE_S));
      setText(migrateAge, mstate === 'working' ? mmss((t - (t < T.ready ? T.resolved : T.working2)) * 9 + 3) : t < T.resolved ? '1m' : 'now');

      // The subspace works, then turns ready with its PR chip.
      var cready = t >= T.checkoutReady;
      rowCheckout.className = 'mrow subr ' + (cready ? 'ready' : 'working');
      setIcon(checkoutIc, cready ? '<i class="mk sq ready"></i>' : '<span class="spin"></span>');
      setText(checkoutS, pick(CHECKOUT_S));
      setText(checkoutAge, cready ? '' : mmss(401 + t * 12));
      checkoutAge.style.display = cready ? 'none' : '';
      checkoutPr.classList.toggle('show', cready);
      tally.classList.toggle('show', cready);

      // Conversation header status
      var hstate = t < T.resolved ? 'approval' : t < T.ready ? 'working' : t < T.sentMsg ? 'ready' : 'working';
      cstat.className = 'cstat ' + hstate;
      setIcon(cstatIc, hstate === 'working' ? '<span class="spin"></span>' : '');
      cstatIc.className = hstate === 'working' ? 'spin' : '';
      setText(cstatT, hstate === 'approval' ? 'needs approval' : hstate);

      // Question card
      var sel = t >= T.tapOpt + 0.05;
      opt1.classList.toggle('sel', sel);
      qsubmit.classList.toggle('on', sel && t < T.sending[0]);
      qsubmit.classList.toggle('press', t >= T.tapSubmit && t < T.tapSubmit + 0.18);
      var qs = t < T.tapOpt + 0.05 ? 'Answer every question to continue' : t < T.sending[0] ? '' : t < T.sent[0] ? 'Sending answer…' : 'Answer sent · waiting for Claude';
      setText(qstatus, qs);
      qstatus.classList.toggle('sent', t >= T.sent[0]);
      qcard.classList.toggle('done', t >= T.resolved);
      setText(qstate, t >= T.resolved ? 'resolved' : 'pending');

      // Work strip after the answer
      var s2 = pick(T.strip2);
      setText(strip2T, s2);
      var s2live = t < T.ready;
      strip2Spin.style.display = s2live ? '' : 'none';
      strip2Chev.style.display = s2live ? 'none' : '';

      // Composer: locked while the question is pending or the agent works, then the reply is typed and sent.
      var typed = t < T.type[0] ? '' : t < T.sentMsg ? REPLY.slice(0, Math.round(Math.max(0, Math.min(1, (t - T.type[0]) / (T.type[1] - T.type[0]))) * REPLY.length)) : '';
      setText(ctyped, typed);
      var focused = t >= T.tapField && t < T.sentMsg + 0.1;
      cfield.classList.toggle('focus', focused);
      var cph_s = hstate === 'approval' ? 'Pending request — input paused' : hstate === 'working' ? 'Agent working…' : 'Message Claude Code…';
      setText(cph, typed ? '' : cph_s);
      csend.classList.toggle('on', typed.length > 0);
      csend.classList.toggle('press', t >= T.tapSend && t < T.tapSend + 0.18);
      cstatus.classList.toggle('show', hstate === 'working');
      var k = seg(T.kbd[0], T.kbd[1]) - seg(T.kbdOut[0], T.kbdOut[1]);
      kbd.style.height = (248 * k) + 'px';
      // The composer clears the home indicator until the keyboard, which has its own bottom inset, takes over.
      comp.style.paddingBottom = (12 + 30 * (1 - k)) + 'px';

      // Touch indicator
      touch.style.opacity = 0;
      for (var i = 0; i < TAPS.length; i++) {
        var dt = t - TAPS[i][0];
        if (dt >= 0 && dt < 0.45) {
          var p = TAPS[i][1]();
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
