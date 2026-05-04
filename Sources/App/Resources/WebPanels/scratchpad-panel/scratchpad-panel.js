(()=>{var J="toasttyScratchpadPanel";function h(e){window.webkit?.messageHandlers?.[J]?.postMessage(e)}var r={bridgeReady(){h({type:"bridgeReady"})},consoleMessage(e,t,n="panel"){h({type:"consoleMessage",level:e,message:t,diagnosticSource:n})},javascriptError(e,t,n,a,s,p="panel"){h({type:"javascriptError",message:e,source:t,line:n,column:a,stack:s,diagnosticSource:p})},unhandledRejection(e,t,n="panel"){h({type:"unhandledRejection",reason:e,stack:t,diagnosticSource:n})},cspViolation(e,t,n,a,s,p,l,o="panel"){h({type:"cspViolation",violatedDirective:e,effectiveDirective:t,blockedURI:n,sourceFile:a,line:s,column:p,disposition:l,diagnosticSource:o})},renderReady(e,t){h({type:"renderReady",displayName:e,revision:t})}};var q=["default-src 'none'","script-src 'unsafe-inline'","script-src-elem 'unsafe-inline'","script-src-attr 'none'","style-src 'unsafe-inline'","img-src data: blob:","font-src data: blob:","media-src data: blob:","connect-src 'none'","frame-src 'none'","worker-src 'none'","object-src 'none'","base-uri 'none'","form-action 'none'"].join("; "),D="toastty:scratchpad-generated-diagnostic:v1";function z(){return`<meta http-equiv="Content-Security-Policy" content="${q.replaceAll('"',"&quot;")}">`}function K(e){return`<script>
(() => {
  if (window.__toasttyScratchpadGeneratedDiagnosticsInstalled) {
    return;
  }
  window.__toasttyScratchpadGeneratedDiagnosticsInstalled = true;
  const messageType = "${D}";
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
<\/script>`}function Y(e){return e.replace(/^\s*<!doctype[^>]*>/i,"")}function _(e,t,n){let a=Y(e),s=`<script>document.documentElement.dataset.toasttyTheme=${JSON.stringify(t)};<\/script>`,l=`${z()}<style>html,body{min-height:100%;}body{margin:0;}</style>${K(n)}${s}`;return/<head(?:\s[^>]*)?>/i.test(a)?a.replace(/<head(?:\s[^>]*)?>/i,o=>`${o}${l}`):/<html(?:\s[^>]*)?>/i.test(a)?a.replace(/<html(?:\s[^>]*)?>/i,o=>`${o}<head>${l}</head>`):`<!doctype html><html><head>${l}</head><body>${a}</body></html>`}var x=new Set,u=null,S=null,m=null,b=null,T=!1,N=2e3,F=`Download the Toastty Scratchpad skill from
https://github.com/figelwump/toastty/tree/main/.agents/skills/toastty-scratchpad

Install it globally. Check which of these directories already exist
and copy the toastty-scratchpad folder into the matching ones:

  \u2022 ~/.claude/skills        (Claude Code)
  \u2022 ~/.codex/skills         (Codex)
  \u2022 ~/.agents/skills        (generic / Codex)

If none of these exist for the agent I'm currently using, create the
appropriate one and install there.`;function c(e,t=N){return e.length<=t?e:`${e.slice(0,t-1)}...`}function W(e,t=new WeakSet){if(e instanceof Error)return{message:e.message||e.name||"Error",stack:e.stack?c(e.stack):null};if(typeof e=="string")return{message:c(e),stack:null};if(typeof e=="number"||typeof e=="boolean"||typeof e=="bigint"||typeof e=="symbol")return{message:String(e),stack:null};if(e==null)return{message:String(e),stack:null};if(typeof e=="object"){if(t.has(e))return{message:"[Circular]",stack:null};t.add(e);let n="stack"in e&&typeof e.stack=="string"?c(e.stack):null;try{return{message:c(JSON.stringify(e)),stack:n}}catch{return{message:c(Object.prototype.toString.call(e)),stack:n}}}return{message:c(String(e)),stack:null}}function Q(e){return e.length===0?"":e.map(t=>W(t).message).join(" ")}function X(){if(!window.__toasttyScratchpadDiagnosticsInstalled){window.__toasttyScratchpadDiagnosticsInstalled=!0;for(let e of["info","warn","error"]){let t=console[e].bind(console);console[e]=(...n)=>{t(...n),r.consoleMessage(e,Q(n))}}window.addEventListener("error",e=>{r.javascriptError(e.message||"JavaScript error",e.filename||null,Number.isFinite(e.lineno)?e.lineno:null,Number.isFinite(e.colno)?e.colno:null,e.error instanceof Error&&e.error.stack?c(e.error.stack):null)}),window.addEventListener("unhandledrejection",e=>{let t=W(e.reason);r.unhandledRejection(t.message,t.stack)})}}function U(e){return typeof e=="object"&&e!==null}function g(e,t=N){return typeof e=="string"&&e.length>0?c(e,t):null}function f(e,t,n=N){return typeof e=="string"&&e.length>0?c(e,n):t}function y(e){if(typeof e!="number"||!Number.isFinite(e))return null;let t=Math.trunc(e);return t>=0&&t<=1e6?t:null}function Z(e){switch(e){case"info":case"warn":case"error":return e;default:return null}}function ee(e){switch(e.type){case"consoleMessage":{let t=Z(e.level),n=g(e.message);if(!t||!n)return;r.consoleMessage(t,n,"generated-content");return}case"javascriptError":{r.javascriptError(f(e.message,"JavaScript error"),g(e.source),y(e.line),y(e.column),g(e.stack),"generated-content");return}case"unhandledRejection":{r.unhandledRejection(f(e.reason,"Unhandled promise rejection"),g(e.stack),"generated-content");return}case"cspViolation":{r.cspViolation(f(e.violatedDirective,"<unknown>",128),f(e.effectiveDirective,"<unknown>",128),g(e.blockedURI,512),g(e.sourceFile,512),y(e.line),y(e.column),g(e.disposition,32),"generated-content");return}}}function te(){window.addEventListener("message",e=>{if(!m||e.source!==m||!U(e.data)||e.data.type!==D||typeof e.data.sessionToken!="string"||e.data.sessionToken!==b)return;let t=e.data.event;U(t)&&ee(t)})}function ne(){return globalThis.crypto?.randomUUID?.()??`${Date.now()}-${Math.random()}`}function G(e){document.documentElement.dataset.theme=e?.theme??"dark"}function ae(){for(let e of x)e(u)}function M(){S=null,m=null,b=null,T=!1}function O(e){return!e.missingDocument&&e.sessionLinked!==!0&&(e.contentHTML??"").trim().length===0}function re(e){e.contractVersion!==1&&console.warn(`[ToasttyScratchpadPanel] Expected bootstrap contractVersion 1 but received ${e.contractVersion}.`),u=e,G(e),ae()}function se(){if(S){if(!T)return!1;try{return S.focus({preventScroll:!0}),m?.focus(),!0}catch{return!1}}if(!u||!u.missingDocument&&!O(u))return!1;let e=document.querySelector(".scratchpad-empty");return e instanceof HTMLElement?(e.tabIndex=-1,e.focus({preventScroll:!0}),document.activeElement===e):!1}window.ToasttyScratchpadPanel={receiveBootstrap:re,focusActiveContent:se,getCurrentBootstrap(){return u},subscribe(e){return x.add(e),e(u),()=>{x.delete(e)}}};function oe(e,t){M(),e.replaceChildren();let n=document.createElement("section");n.className="scratchpad-empty";let a=document.createElement("h1");a.textContent=t.displayName||"Scratchpad";let s=document.createElement("p");s.textContent=t.message||"This Scratchpad document is unavailable.",n.append(a,s),e.append(n),r.renderReady(t.displayName,t.revision)}function ie(e,t){M(),e.replaceChildren();let n=document.createElement("section");n.className="scratchpad-empty scratchpad-empty--guide",n.tabIndex=-1;let a=document.createElement("div");a.className="scratchpad-guide-header";let s=document.createElement("h1");s.textContent="Scratchpad is ready";let p=document.createElement("p");p.textContent="You\u2019re on the manual path: you created an empty Scratchpad, so you\u2019ll need to bind it to an agent and install the Scratchpad skill before the agent can publish to it.";let l=document.createElement("p");l.textContent="The shorter path is to install the skill once and skip this screen entirely \u2014 agents create and bind their own Scratchpads on demand. See \u201CSkip this next time\u201D below.",a.append(s,p,l);let o=document.createElement("ol");o.className="scratchpad-guide-steps";let k=document.createElement("li");k.className="scratchpad-guide-step";let L=document.createElement("h2");L.textContent="Bind this Scratchpad to an agent";let j=document.createElement("p");j.textContent="Click the \u201CUnbound\u201D chip in this panel\u2019s header and pick an agent session running in the current tab. Only Toastty-managed sessions show up.",k.append(L,j);let w=document.createElement("li");w.className="scratchpad-guide-step scratchpad-guide-step--snippet";let v=document.createElement("div");v.className="scratchpad-snippet-header";let R=document.createElement("h2");R.textContent="Install the Scratchpad skill";let i=document.createElement("button");i.type="button",i.className="scratchpad-copy-button",i.textContent="Copy",v.append(R,i);let B=document.createElement("p");B.textContent="Paste this into your agent\u2019s chat (Claude Code, Codex, or any compatible agent). It tells the agent to download the skill and install it globally for whichever runtime you\u2019re using.";let d=document.createElement("textarea");d.className="scratchpad-snippet",d.readOnly=!0,d.spellcheck=!1,d.value=F,d.setAttribute("aria-label","Toastty Scratchpad skill install snippet"),i.addEventListener("click",async()=>{try{if(!navigator.clipboard)throw new Error("Clipboard unavailable");await navigator.clipboard.writeText(F),i.textContent="Copied",setTimeout(()=>{i.textContent="Copy"},1600)}catch{d.focus(),d.select(),i.textContent="Selected",setTimeout(()=>{i.textContent="Copy"},1600)}}),w.append(v,B,d);let E=document.createElement("li");E.className="scratchpad-guide-step";let P=document.createElement("h2");P.textContent="Ask the agent for a visual";let I=document.createElement("p");I.textContent="Ask for a diagram, mock-up, wireframe, architecture map, or data viz, or invoke the skill explicitly. The result will publish into this Scratchpad.",E.append(P,I),o.append(k,w,E);let C=document.createElement("aside");C.className="scratchpad-guide-footer";let $=document.createElement("h2");$.textContent="Skip this next time";let H=document.createElement("p");H.textContent="Once the skill is installed for an agent, you don\u2019t need New Scratchpad at all \u2014 just ask the agent for a visual and it\u2019ll create and bind a fresh Scratchpad on the fly.";let V=document.createElement("p");V.textContent="Rebinding is still useful, though: you might want one agent to create a Scratchpad and another to read it. Use the binding chip to switch which agent has access. Only one agent session can read or write a Scratchpad at a time.",C.append($,H,V),n.append(a,o,C),e.append(n),r.renderReady(t.displayName,t.revision)}function ce(e,t){M(),b=ne(),e.replaceChildren();let n=document.createElement("iframe");n.className="scratchpad-frame",n.title=t.displayName||"Scratchpad",n.tabIndex=-1,n.sandbox.add("allow-scripts"),n.referrerPolicy="no-referrer",n.srcdoc=_(t.contentHTML??"",t.theme,b),n.addEventListener("load",()=>{T=!0,m=n.contentWindow,r.renderReady(t.displayName,t.revision)},{once:!0}),S=n,m=n.contentWindow,e.append(n),m=n.contentWindow}function le(e,t){if(t){if(t.missingDocument){oe(e,t);return}if(O(t)){ie(e,t);return}ce(e,t)}}X();te();var A=document.getElementById("root");if(!(A instanceof HTMLElement))throw r.javascriptError("Missing Scratchpad panel root container","main.ts",null,null,null),new Error("Missing Scratchpad panel root container");G(u);window.ToasttyScratchpadPanel.subscribe(e=>le(A,e));r.bridgeReady();})();
