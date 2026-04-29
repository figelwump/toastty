(()=>{var U="toasttyScratchpadPanel";function f(e){window.webkit?.messageHandlers?.[U]?.postMessage(e)}var a={bridgeReady(){f({type:"bridgeReady"})},consoleMessage(e,t,n="panel"){f({type:"consoleMessage",level:e,message:t,diagnosticSource:n})},javascriptError(e,t,n,r,s,p="panel"){f({type:"javascriptError",message:e,source:t,line:n,column:r,stack:s,diagnosticSource:p})},unhandledRejection(e,t,n="panel"){f({type:"unhandledRejection",reason:e,stack:t,diagnosticSource:n})},cspViolation(e,t,n,r,s,p,i,o="panel"){f({type:"cspViolation",violatedDirective:e,effectiveDirective:t,blockedURI:n,sourceFile:r,line:s,column:p,disposition:i,diagnosticSource:o})},renderReady(e,t){f({type:"renderReady",displayName:e,revision:t})}};var W=["default-src 'none'","script-src 'unsafe-inline'","script-src-elem 'unsafe-inline'","script-src-attr 'none'","style-src 'unsafe-inline'","img-src data: blob:","font-src data: blob:","media-src data: blob:","connect-src 'none'","frame-src 'none'","worker-src 'none'","object-src 'none'","base-uri 'none'","form-action 'none'"].join("; "),E="toastty:scratchpad-generated-diagnostic:v1";function G(){return`<meta http-equiv="Content-Security-Policy" content="${W.replaceAll('"',"&quot;")}">`}function O(e){return`<script>
(() => {
  if (window.__toasttyScratchpadGeneratedDiagnosticsInstalled) {
    return;
  }
  window.__toasttyScratchpadGeneratedDiagnosticsInstalled = true;
  const messageType = "${E}";
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
<\/script>`}function A(e){return e.replace(/^\s*<!doctype[^>]*>/i,"")}function R(e,t,n){let r=A(e),s=`<script>document.documentElement.dataset.toasttyTheme=${JSON.stringify(t)};<\/script>`,i=`${G()}<style>html,body{min-height:100%;}body{margin:0;}</style>${O(n)}${s}`;return/<head(?:\s[^>]*)?>/i.test(r)?r.replace(/<head(?:\s[^>]*)?>/i,o=>`${o}${i}`):/<html(?:\s[^>]*)?>/i.test(r)?r.replace(/<html(?:\s[^>]*)?>/i,o=>`${o}<head>${i}</head>`):`<!doctype html><html><head>${i}</head><body>${r}</body></html>`}var D=new Set,u=null,S=null,m=null,b=null,C=!1,T=2e3,$=`mkdir -p "$HOME/.codex/skills"
curl -L https://github.com/figelwump/toastty/archive/refs/heads/main.tar.gz \\
  | tar -xz -C "$HOME/.codex/skills" --strip-components=3 "toastty-main/.agents/skills/toastty-scratchpad"`;function l(e,t=T){return e.length<=t?e:`${e.slice(0,t-1)}...`}function H(e,t=new WeakSet){if(e instanceof Error)return{message:e.message||e.name||"Error",stack:e.stack?l(e.stack):null};if(typeof e=="string")return{message:l(e),stack:null};if(typeof e=="number"||typeof e=="boolean"||typeof e=="bigint"||typeof e=="symbol")return{message:String(e),stack:null};if(e==null)return{message:String(e),stack:null};if(typeof e=="object"){if(t.has(e))return{message:"[Circular]",stack:null};t.add(e);let n="stack"in e&&typeof e.stack=="string"?l(e.stack):null;try{return{message:l(JSON.stringify(e)),stack:n}}catch{return{message:l(Object.prototype.toString.call(e)),stack:n}}}return{message:l(String(e)),stack:null}}function J(e){return e.length===0?"":e.map(t=>H(t).message).join(" ")}function q(){if(!window.__toasttyScratchpadDiagnosticsInstalled){window.__toasttyScratchpadDiagnosticsInstalled=!0;for(let e of["info","warn","error"]){let t=console[e].bind(console);console[e]=(...n)=>{t(...n),a.consoleMessage(e,J(n))}}window.addEventListener("error",e=>{a.javascriptError(e.message||"JavaScript error",e.filename||null,Number.isFinite(e.lineno)?e.lineno:null,Number.isFinite(e.colno)?e.colno:null,e.error instanceof Error&&e.error.stack?l(e.error.stack):null)}),window.addEventListener("unhandledrejection",e=>{let t=H(e.reason);a.unhandledRejection(t.message,t.stack)})}}function I(e){return typeof e=="object"&&e!==null}function g(e,t=T){return typeof e=="string"&&e.length>0?l(e,t):null}function h(e,t,n=T){return typeof e=="string"&&e.length>0?l(e,n):t}function y(e){if(typeof e!="number"||!Number.isFinite(e))return null;let t=Math.trunc(e);return t>=0&&t<=1e6?t:null}function z(e){switch(e){case"info":case"warn":case"error":return e;default:return null}}function K(e){switch(e.type){case"consoleMessage":{let t=z(e.level),n=g(e.message);if(!t||!n)return;a.consoleMessage(t,n,"generated-content");return}case"javascriptError":{a.javascriptError(h(e.message,"JavaScript error"),g(e.source),y(e.line),y(e.column),g(e.stack),"generated-content");return}case"unhandledRejection":{a.unhandledRejection(h(e.reason,"Unhandled promise rejection"),g(e.stack),"generated-content");return}case"cspViolation":{a.cspViolation(h(e.violatedDirective,"<unknown>",128),h(e.effectiveDirective,"<unknown>",128),g(e.blockedURI,512),g(e.sourceFile,512),y(e.line),y(e.column),g(e.disposition,32),"generated-content");return}}}function Q(){window.addEventListener("message",e=>{if(!m||e.source!==m||!I(e.data)||e.data.type!==E||typeof e.data.sessionToken!="string"||e.data.sessionToken!==b)return;let t=e.data.event;I(t)&&K(t)})}function X(){return globalThis.crypto?.randomUUID?.()??`${Date.now()}-${Math.random()}`}function V(e){document.documentElement.dataset.theme=e?.theme??"dark"}function Y(){for(let e of D)e(u)}function x(){S=null,m=null,b=null,C=!1}function _(e){return!e.missingDocument&&e.sessionLinked!==!0&&(e.contentHTML??"").trim().length===0}function Z(e){e.contractVersion!==1&&console.warn(`[ToasttyScratchpadPanel] Expected bootstrap contractVersion 1 but received ${e.contractVersion}.`),u=e,V(e),Y()}function ee(){if(S){if(!C)return!1;try{return S.focus({preventScroll:!0}),m?.focus(),!0}catch{return!1}}if(!u||!u.missingDocument&&!_(u))return!1;let e=document.querySelector(".scratchpad-empty");return e instanceof HTMLElement?(e.tabIndex=-1,e.focus({preventScroll:!0}),document.activeElement===e):!1}window.ToasttyScratchpadPanel={receiveBootstrap:Z,focusActiveContent:ee,getCurrentBootstrap(){return u},subscribe(e){return D.add(e),e(u),()=>{D.delete(e)}}};function te(e,t){x(),e.replaceChildren();let n=document.createElement("section");n.className="scratchpad-empty";let r=document.createElement("h1");r.textContent=t.displayName||"Scratchpad";let s=document.createElement("p");s.textContent=t.message||"This Scratchpad document is unavailable.",n.append(r,s),e.append(n),a.renderReady(t.displayName,t.revision)}function ne(e,t){x(),e.replaceChildren();let n=document.createElement("section");n.className="scratchpad-empty scratchpad-empty--guide",n.tabIndex=-1;let r=document.createElement("div");r.className="scratchpad-guide-header";let s=document.createElement("h1");s.textContent="Scratchpad is ready";let p=document.createElement("p");p.textContent="Bind it to an active agent or install the skill to publish visual work from Toastty.",r.append(s,p);let i=document.createElement("div");i.className="scratchpad-guide-steps";let o=document.createElement("article");o.className="scratchpad-guide-step";let N=document.createElement("h2");N.textContent="Bind to an agent";let M=document.createElement("p");M.textContent="Use the Unbound menu in this panel header, then choose an active agent session in the current tab.",o.append(N,M);let k=document.createElement("article");k.className="scratchpad-guide-step scratchpad-guide-step--snippet";let v=document.createElement("div");v.className="scratchpad-snippet-header";let L=document.createElement("h2");L.textContent="Install the skill";let c=document.createElement("button");c.type="button",c.className="scratchpad-copy-button",c.textContent="Copy",v.append(L,c);let B=document.createElement("p");B.textContent="Paste this into a Codex-compatible agent terminal.";let d=document.createElement("textarea");d.className="scratchpad-snippet",d.readOnly=!0,d.spellcheck=!1,d.value=$,d.setAttribute("aria-label","Toastty Scratchpad skill install snippet"),c.addEventListener("click",async()=>{try{if(!navigator.clipboard)throw new Error("Clipboard unavailable");await navigator.clipboard.writeText($),c.textContent="Copied",setTimeout(()=>{c.textContent="Copy"},1600)}catch{d.focus(),d.select(),c.textContent="Selected",setTimeout(()=>{c.textContent="Copy"},1600)}}),k.append(v,B,d);let w=document.createElement("article");w.className="scratchpad-guide-step";let j=document.createElement("h2");j.textContent="Ask for a visual";let P=document.createElement("p");P.textContent="After the skill is installed, ask your agent to create diagrams, mock-ups, wireframes, architecture maps, or data visualizations in Scratchpad.",w.append(j,P),i.append(o,k,w),n.append(r,i),e.append(n),a.renderReady(t.displayName,t.revision)}function re(e,t){x(),b=X(),e.replaceChildren();let n=document.createElement("iframe");n.className="scratchpad-frame",n.title=t.displayName||"Scratchpad",n.tabIndex=-1,n.sandbox.add("allow-scripts"),n.referrerPolicy="no-referrer",n.srcdoc=R(t.contentHTML??"",t.theme,b),n.addEventListener("load",()=>{C=!0,m=n.contentWindow,a.renderReady(t.displayName,t.revision)},{once:!0}),S=n,m=n.contentWindow,e.append(n),m=n.contentWindow}function ae(e,t){if(t){if(t.missingDocument){te(e,t);return}if(_(t)){ne(e,t);return}re(e,t)}}q();Q();var F=document.getElementById("root");if(!(F instanceof HTMLElement))throw a.javascriptError("Missing Scratchpad panel root container","main.ts",null,null,null),new Error("Missing Scratchpad panel root container");V(u);window.ToasttyScratchpadPanel.subscribe(e=>ae(F,e));a.bridgeReady();})();
