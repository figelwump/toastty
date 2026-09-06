(()=>{var A="toasttyScratchpadPanel";function m(e){window.webkit?.messageHandlers?.[A]?.postMessage(e)}var s={contentSize(e,t,n){m({type:"contentSize",width:e,height:t,revision:n})},bridgeReady(){m({type:"bridgeReady"})},consoleMessage(e,t,n="panel"){m({type:"consoleMessage",level:e,message:t,diagnosticSource:n})},javascriptError(e,t,n,a,r,d="panel"){m({type:"javascriptError",message:e,source:t,line:n,column:a,stack:r,diagnosticSource:d})},unhandledRejection(e,t,n="panel"){m({type:"unhandledRejection",reason:e,stack:t,diagnosticSource:n})},cspViolation(e,t,n,a,r,d,f,i="panel"){m({type:"cspViolation",violatedDirective:e,effectiveDirective:t,blockedURI:n,sourceFile:a,line:r,column:d,disposition:f,diagnosticSource:i})},renderReady(e,t){m({type:"renderReady",displayName:e,revision:t})}};var J=["default-src 'none'","script-src 'unsafe-inline'","script-src-elem 'unsafe-inline'","script-src-attr 'none'","style-src 'unsafe-inline'","img-src data: blob:","font-src https: data: blob:","media-src data: blob:","connect-src 'none'","frame-src 'none'","worker-src 'none'","object-src 'none'","base-uri 'none'","form-action 'none'"].join("; "),x="toastty:scratchpad-generated-diagnostic:v1";function q(){return`<meta http-equiv="Content-Security-Policy" content="${J.replaceAll('"',"&quot;")}">`}function K(e,t){return`<script>
(() => {
  if (window.__toasttyScratchpadGeneratedDiagnosticsInstalled) {
    return;
  }
  window.__toasttyScratchpadGeneratedDiagnosticsInstalled = true;
  const messageType = "${x}";
  const sessionToken = ${JSON.stringify(e)};
  const diagnosticStringLimit = 2000;
  const truncate = (value, limit = diagnosticStringLimit) => {
    const stringValue = String(value);
    return stringValue.length <= limit
      ? stringValue
      : stringValue.slice(0, limit - 1) + "...";
  };
  const describe = (value, seen = new WeakSet()) => {
    if (value instanceof Error) {
      return {
        message: truncate(value.message || value.name || "Error"),
        stack: value.stack ? truncate(value.stack) : null
      };
    }
    if (typeof value === "string") {
      return { message: truncate(value), stack: null };
    }
    if (
      typeof value === "number" ||
      typeof value === "boolean" ||
      typeof value === "bigint" ||
      typeof value === "symbol" ||
      value == null
    ) {
      return { message: truncate(value), stack: null };
    }
    if (typeof value === "object") {
      if (seen.has(value)) {
        return { message: "[Circular]", stack: null };
      }
      seen.add(value);
      const stack = typeof value.stack === "string" ? truncate(value.stack) : null;
      try {
        return { message: truncate(JSON.stringify(value)), stack };
      } catch {
        return { message: truncate(Object.prototype.toString.call(value)), stack };
      }
    }
    return { message: truncate(value), stack: null };
  };
  const postDiagnostic = (event) => {
    try {
      window.parent?.postMessage({ type: messageType, sessionToken, event }, "*");
    } catch {
    }
  };
  if (${JSON.stringify(t)}) {
    let scheduled = false;
    let previous = "";
    const measure = () => {
      if (scheduled) return;
      scheduled = true;
      requestAnimationFrame(() => {
        scheduled = false;
        const width = Math.max(1024, document.documentElement.scrollWidth, document.body?.scrollWidth || 0);
        const height = Math.max(900, document.documentElement.scrollHeight, document.body?.scrollHeight || 0);
        const key = width + ":" + height;
        if (key === previous || width > 16384 || height > 16384) return;
        previous = key;
        postDiagnostic({ type: "contentSize", width, height });
      });
    };
    window.addEventListener("load", () => {
      const observer = new ResizeObserver(measure);
      observer.observe(document.documentElement);
      if (document.body) observer.observe(document.body);
      measure();
    }, { once: true });
  }
  for (const level of ["info", "warn", "error"]) {
    const original = console[level]?.bind(console);
    if (!original) {
      continue;
    }
    console[level] = (...args) => {
      original(...args);
      postDiagnostic({
        type: "consoleMessage",
        level,
        message: args.map((value) => describe(value).message).join(" ")
      });
    };
  }
  window.addEventListener("error", (event) => {
    const diagnostic = describe(event.error || event.message || "JavaScript error");
    postDiagnostic({
      type: "javascriptError",
      message: event.message || diagnostic.message,
      source: event.filename || null,
      line: Number.isFinite(event.lineno) ? event.lineno : null,
      column: Number.isFinite(event.colno) ? event.colno : null,
      stack: diagnostic.stack
    });
  });
  window.addEventListener("unhandledrejection", (event) => {
    const diagnostic = describe(event.reason);
    postDiagnostic({
      type: "unhandledRejection",
      reason: diagnostic.message,
      stack: diagnostic.stack
    });
  });
  window.addEventListener("securitypolicyviolation", (event) => {
    postDiagnostic({
      type: "cspViolation",
      violatedDirective: truncate(event.violatedDirective || "", 128),
      effectiveDirective: truncate(event.effectiveDirective || "", 128),
      blockedURI: event.blockedURI ? truncate(event.blockedURI, 512) : null,
      sourceFile: event.sourceFile ? truncate(event.sourceFile, 512) : null,
      line: Number.isFinite(event.lineNumber) ? event.lineNumber : null,
      column: Number.isFinite(event.columnNumber) ? event.columnNumber : null,
      disposition: event.disposition ? truncate(event.disposition, 32) : null
    });
  });
})();
<\/script>`}function Y(e){return e.replace(/^\s*<!doctype[^>]*>/i,"")}function H(e,t,n,a=!1){let r=Y(e),d=`<script>document.documentElement.dataset.toasttyTheme=${JSON.stringify(t)};<\/script>`,i=`${q()}<style>html,body{min-height:100%;}body{margin:0;}</style>${K(n,a)}${d}`;return/<head(?:\s[^>]*)?>/i.test(r)?r.replace(/<head(?:\s[^>]*)?>/i,p=>`${p}${i}`):/<html(?:\s[^>]*)?>/i.test(r)?r.replace(/<html(?:\s[^>]*)?>/i,p=>`${p}<head>${i}</head>`):`<!doctype html><html><head>${i}</head><body>${r}</body></html>`}var D=new Set,o=null,S=null,h=null,k=null,T=!1,N=2e3,_=`Download the Toastty Scratchpad skill from
https://github.com/figelwump/toastty/tree/main/.agents/skills/toastty-scratchpad

Install it globally. Check which of these directories already exist
and copy the toastty-scratchpad folder into the matching ones:

  \u2022 ~/.claude/skills        (Claude Code)
  \u2022 ~/.codex/skills         (Codex)
  \u2022 ~/.agents/skills        (generic / Codex)

If none of these exist for the agent I'm currently using, create the
appropriate one and install there.`;function l(e,t=N){return e.length<=t?e:`${e.slice(0,t-1)}...`}function O(e,t=new WeakSet){if(e instanceof Error)return{message:e.message||e.name||"Error",stack:e.stack?l(e.stack):null};if(typeof e=="string")return{message:l(e),stack:null};if(typeof e=="number"||typeof e=="boolean"||typeof e=="bigint"||typeof e=="symbol")return{message:String(e),stack:null};if(e==null)return{message:String(e),stack:null};if(typeof e=="object"){if(t.has(e))return{message:"[Circular]",stack:null};t.add(e);let n="stack"in e&&typeof e.stack=="string"?l(e.stack):null;try{return{message:l(JSON.stringify(e)),stack:n}}catch{return{message:l(Object.prototype.toString.call(e)),stack:n}}}return{message:l(String(e)),stack:null}}function Q(e){return e.length===0?"":e.map(t=>O(t).message).join(" ")}function X(){if(!window.__toasttyScratchpadDiagnosticsInstalled){window.__toasttyScratchpadDiagnosticsInstalled=!0;for(let e of["info","warn","error"]){let t=console[e].bind(console);console[e]=(...n)=>{t(...n),s.consoleMessage(e,Q(n))}}window.addEventListener("error",e=>{s.javascriptError(e.message||"JavaScript error",e.filename||null,Number.isFinite(e.lineno)?e.lineno:null,Number.isFinite(e.colno)?e.colno:null,e.error instanceof Error&&e.error.stack?l(e.error.stack):null)}),window.addEventListener("unhandledrejection",e=>{let t=O(e.reason);s.unhandledRejection(t.message,t.stack)})}}function W(e){return typeof e=="object"&&e!==null}function g(e,t=N){return typeof e=="string"&&e.length>0?l(e,t):null}function y(e,t,n=N){return typeof e=="string"&&e.length>0?l(e,n):t}function b(e){if(typeof e!="number"||!Number.isFinite(e))return null;let t=Math.trunc(e);return t>=0&&t<=1e6?t:null}function Z(e){switch(e){case"info":case"warn":case"error":return e;default:return null}}function ee(e){switch(e.type){case"consoleMessage":{let t=Z(e.level),n=g(e.message);if(!t||!n)return;s.consoleMessage(t,n,"generated-content");return}case"javascriptError":{s.javascriptError(y(e.message,"JavaScript error"),g(e.source),b(e.line),b(e.column),g(e.stack),"generated-content");return}case"unhandledRejection":{s.unhandledRejection(y(e.reason,"Unhandled promise rejection"),g(e.stack),"generated-content");return}case"cspViolation":{s.cspViolation(y(e.violatedDirective,"<unknown>",128),y(e.effectiveDirective,"<unknown>",128),g(e.blockedURI,512),g(e.sourceFile,512),b(e.line),b(e.column),g(e.disposition,32),"generated-content");return}}}function te(){window.addEventListener("message",e=>{if(!h||e.source!==h||!W(e.data)||e.data.type!==x||typeof e.data.sessionToken!="string"||e.data.sessionToken!==k)return;let t=e.data.event;if(W(t)){if(t.type==="contentSize"){if(!o?.mobileViewport)return;let{width:n,height:a}=t;if(typeof n!="number"||typeof a!="number"||!Number.isFinite(n)||!Number.isFinite(a)||n<320||a<320||n>16384||a>16384)return;s.contentSize(n,a,o.revision);return}ee(t)}})}function ne(){return globalThis.crypto?.randomUUID?.()??`${Date.now()}-${Math.random()}`}function U(e){document.documentElement.dataset.theme=e?.theme??"dark"}function ae(){for(let e of D)e(o)}function M(){S=null,h=null,k=null,T=!1}function G(e){return!e.missingDocument&&e.sessionLinked!==!0&&(e.contentHTML??"").trim().length===0}function re(e){e.contractVersion!==1&&console.warn(`[ToasttyScratchpadPanel] Expected bootstrap contractVersion 1 but received ${e.contractVersion}.`),o=e,U(e),ae()}function se(){if(S){if(!T)return!1;try{return S.focus({preventScroll:!0}),h?.focus(),!0}catch{return!1}}if(!o||!o.missingDocument&&!G(o))return!1;let e=document.querySelector(".scratchpad-empty");return e instanceof HTMLElement?(e.tabIndex=-1,e.focus({preventScroll:!0}),document.activeElement===e):!1}window.ToasttyScratchpadPanel={receiveBootstrap:re,focusActiveContent:se,getCurrentBootstrap(){return o},subscribe(e){return D.add(e),e(o),()=>{D.delete(e)}}};function oe(e,t){M(),e.replaceChildren();let n=document.createElement("section");n.className="scratchpad-empty";let a=document.createElement("h1");a.textContent=t.displayName||"Scratchpad";let r=document.createElement("p");r.textContent=t.message||"This Scratchpad document is unavailable.",n.append(a,r),e.append(n),s.renderReady(t.displayName,t.revision)}function ie(e,t){M(),e.replaceChildren();let n=document.createElement("section");n.className="scratchpad-empty scratchpad-empty--guide",n.tabIndex=-1;let a=document.createElement("div");a.className="scratchpad-guide-header";let r=document.createElement("h1");r.textContent="Scratchpad is ready";let d=document.createElement("p");d.textContent="You\u2019re on the manual path: you created an empty Scratchpad, so you\u2019ll need to bind it to an agent and install the Scratchpad skill before the agent can publish to it.";let f=document.createElement("p");f.textContent="The shorter path is to install the skill once and skip this screen entirely \u2014 agents create and bind their own Scratchpads on demand. See \u201CSkip this next time\u201D below.",a.append(r,d,f);let i=document.createElement("ol");i.className="scratchpad-guide-steps";let p=document.createElement("li");p.className="scratchpad-guide-step";let L=document.createElement("h2");L.textContent="Bind this Scratchpad to an agent";let R=document.createElement("p");R.textContent="Click the \u201CUnbound\u201D chip in this panel\u2019s header and pick an agent session running in the current tab. Only Toastty-managed sessions show up.",p.append(L,R);let w=document.createElement("li");w.className="scratchpad-guide-step scratchpad-guide-step--snippet";let v=document.createElement("div");v.className="scratchpad-snippet-header";let j=document.createElement("h2");j.textContent="Install the Scratchpad skill";let c=document.createElement("button");c.type="button",c.className="scratchpad-copy-button",c.textContent="Copy",v.append(j,c);let B=document.createElement("p");B.textContent="Paste this into your agent\u2019s chat (Claude Code, Codex, or any compatible agent). It tells the agent to download the skill and install it globally for whichever runtime you\u2019re using.";let u=document.createElement("textarea");u.className="scratchpad-snippet",u.readOnly=!0,u.spellcheck=!1,u.value=_,u.setAttribute("aria-label","Toastty Scratchpad skill install snippet"),c.addEventListener("click",async()=>{try{if(!navigator.clipboard)throw new Error("Clipboard unavailable");await navigator.clipboard.writeText(_),c.textContent="Copied",setTimeout(()=>{c.textContent="Copy"},1600)}catch{u.focus(),u.select(),c.textContent="Selected",setTimeout(()=>{c.textContent="Copy"},1600)}}),w.append(v,B,u);let E=document.createElement("li");E.className="scratchpad-guide-step";let P=document.createElement("h2");P.textContent="Ask the agent for a visual";let I=document.createElement("p");I.textContent="Ask for a diagram, mock-up, wireframe, architecture map, or data viz, or invoke the skill explicitly. The result will publish into this Scratchpad.",E.append(P,I),i.append(p,w,E);let C=document.createElement("aside");C.className="scratchpad-guide-footer";let $=document.createElement("h2");$.textContent="Skip this next time";let V=document.createElement("p");V.textContent="Once the skill is installed for an agent, you don\u2019t need New Scratchpad at all \u2014 just ask the agent for a visual and it\u2019ll create and bind a fresh Scratchpad on the fly.";let F=document.createElement("p");F.textContent="Rebinding is still useful, though: you might want one agent to create a Scratchpad and another to read it. Use the binding chip to switch which agent has access. Only one agent session can read or write a Scratchpad at a time.",C.append($,V,F),n.append(a,i,C),e.append(n),s.renderReady(t.displayName,t.revision)}function ce(e,t){M(),k=ne(),e.replaceChildren();let n=document.createElement("iframe");n.className="scratchpad-frame",n.title=t.displayName||"Scratchpad",n.tabIndex=-1,n.sandbox.add("allow-scripts"),n.referrerPolicy="no-referrer",n.srcdoc=H(t.contentHTML??"",t.theme,k,t.mobileViewport===!0),n.addEventListener("load",()=>{T=!0,h=n.contentWindow,s.renderReady(t.displayName,t.revision)},{once:!0}),S=n,h=n.contentWindow,e.append(n),h=n.contentWindow}function le(e,t){if(t){if(t.missingDocument){oe(e,t);return}if(G(t)){ie(e,t);return}ce(e,t)}}X();te();var z=document.getElementById("root");if(!(z instanceof HTMLElement))throw s.javascriptError("Missing Scratchpad panel root container","main.ts",null,null,null),new Error("Missing Scratchpad panel root container");U(o);window.ToasttyScratchpadPanel.subscribe(e=>le(z,e));s.bridgeReady();})();
