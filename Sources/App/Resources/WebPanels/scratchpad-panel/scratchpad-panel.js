(()=>{var j="toasttyScratchpadPanel";function c(e){window.webkit?.messageHandlers?.[j]?.postMessage(e)}var s={bridgeReady(){c({type:"bridgeReady"})},consoleMessage(e,n,t="panel"){c({type:"consoleMessage",level:e,message:n,diagnosticSource:t})},javascriptError(e,n,t,r,i,p="panel"){c({type:"javascriptError",message:e,source:n,line:t,column:r,stack:i,diagnosticSource:p})},unhandledRejection(e,n,t="panel"){c({type:"unhandledRejection",reason:e,stack:n,diagnosticSource:t})},cspViolation(e,n,t,r,i,p,u,d="panel"){c({type:"cspViolation",violatedDirective:e,effectiveDirective:n,blockedURI:t,sourceFile:r,line:i,column:p,disposition:u,diagnosticSource:d})},renderReady(e,n){c({type:"renderReady",displayName:e,revision:n})}};var M=["default-src 'none'","script-src 'unsafe-inline'","script-src-elem 'unsafe-inline'","script-src-attr 'none'","style-src 'unsafe-inline'","img-src data: blob:","font-src data: blob:","media-src data: blob:","connect-src 'none'","frame-src 'none'","worker-src 'none'","object-src 'none'","base-uri 'none'","form-action 'none'"].join("; "),h="toastty:scratchpad-generated-diagnostic:v1";function N(){return`<meta http-equiv="Content-Security-Policy" content="${M.replaceAll('"',"&quot;")}">`}function T(e){return`<script>
(() => {
  if (window.__toasttyScratchpadGeneratedDiagnosticsInstalled) {
    return;
  }
  window.__toasttyScratchpadGeneratedDiagnosticsInstalled = true;
  const messageType = "${h}";
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
<\/script>`}function R(e){return e.replace(/^\s*<!doctype[^>]*>/i,"")}function k(e,n,t){let r=R(e),i=`<script>document.documentElement.dataset.toasttyTheme=${JSON.stringify(n)};<\/script>`,u=`${N()}<style>html,body{min-height:100%;}body{margin:0;}</style>${T(t)}${i}`;return/<head(?:\s[^>]*)?>/i.test(r)?r.replace(/<head(?:\s[^>]*)?>/i,d=>`${d}${u}`):/<html(?:\s[^>]*)?>/i.test(r)?r.replace(/<html(?:\s[^>]*)?>/i,d=>`${d}<head>${u}</head>`):`<!doctype html><html><head>${u}</head><body>${r}</body></html>`}var S=new Set,g=null,l=null,y=null,b=2e3;function a(e,n=b){return e.length<=n?e:`${e.slice(0,n-1)}...`}function v(e,n=new WeakSet){if(e instanceof Error)return{message:e.message||e.name||"Error",stack:e.stack?a(e.stack):null};if(typeof e=="string")return{message:a(e),stack:null};if(typeof e=="number"||typeof e=="boolean"||typeof e=="bigint"||typeof e=="symbol")return{message:String(e),stack:null};if(e==null)return{message:String(e),stack:null};if(typeof e=="object"){if(n.has(e))return{message:"[Circular]",stack:null};n.add(e);let t="stack"in e&&typeof e.stack=="string"?a(e.stack):null;try{return{message:a(JSON.stringify(e)),stack:t}}catch{return{message:a(Object.prototype.toString.call(e)),stack:t}}}return{message:a(String(e)),stack:null}}function P(e){return e.length===0?"":e.map(n=>v(n).message).join(" ")}function B(){if(!window.__toasttyScratchpadDiagnosticsInstalled){window.__toasttyScratchpadDiagnosticsInstalled=!0;for(let e of["info","warn","error"]){let n=console[e].bind(console);console[e]=(...t)=>{n(...t),s.consoleMessage(e,P(t))}}window.addEventListener("error",e=>{s.javascriptError(e.message||"JavaScript error",e.filename||null,Number.isFinite(e.lineno)?e.lineno:null,Number.isFinite(e.colno)?e.colno:null,e.error instanceof Error&&e.error.stack?a(e.error.stack):null)}),window.addEventListener("unhandledrejection",e=>{let n=v(e.reason);s.unhandledRejection(n.message,n.stack)})}}function w(e){return typeof e=="object"&&e!==null}function o(e,n=b){return typeof e=="string"&&e.length>0?a(e,n):null}function m(e,n,t=b){return typeof e=="string"&&e.length>0?a(e,t):n}function f(e){if(typeof e!="number"||!Number.isFinite(e))return null;let n=Math.trunc(e);return n>=0&&n<=1e6?n:null}function L(e){switch(e){case"info":case"warn":case"error":return e;default:return null}}function $(e){switch(e.type){case"consoleMessage":{let n=L(e.level),t=o(e.message);if(!n||!t)return;s.consoleMessage(n,t,"generated-content");return}case"javascriptError":{s.javascriptError(m(e.message,"JavaScript error"),o(e.source),f(e.line),f(e.column),o(e.stack),"generated-content");return}case"unhandledRejection":{s.unhandledRejection(m(e.reason,"Unhandled promise rejection"),o(e.stack),"generated-content");return}case"cspViolation":{s.cspViolation(m(e.violatedDirective,"<unknown>",128),m(e.effectiveDirective,"<unknown>",128),o(e.blockedURI,512),o(e.sourceFile,512),f(e.line),f(e.column),o(e.disposition,32),"generated-content");return}}}function C(){window.addEventListener("message",e=>{if(!l||e.source!==l||!w(e.data)||e.data.type!==h||typeof e.data.sessionToken!="string"||e.data.sessionToken!==y)return;let n=e.data.event;w(n)&&$(n)})}function V(){return globalThis.crypto?.randomUUID?.()??`${Date.now()}-${Math.random()}`}function D(e){document.documentElement.dataset.theme=e?.theme??"dark"}function x(){for(let e of S)e(g)}function I(e){e.contractVersion!==1&&console.warn(`[ToasttyScratchpadPanel] Expected bootstrap contractVersion 1 but received ${e.contractVersion}.`),g=e,D(e),x()}window.ToasttyScratchpadPanel={receiveBootstrap:I,getCurrentBootstrap(){return g},subscribe(e){return S.add(e),e(g),()=>{S.delete(e)}}};function _(e,n){l=null,y=null,e.replaceChildren();let t=document.createElement("section");t.className="scratchpad-empty";let r=document.createElement("h1");r.textContent=n.displayName||"Scratchpad";let i=document.createElement("p");i.textContent=n.message||"This Scratchpad document is unavailable.",t.append(r,i),e.append(t),s.renderReady(n.displayName,n.revision)}function F(e,n){l=null,y=V(),e.replaceChildren();let t=document.createElement("iframe");t.className="scratchpad-frame",t.title=n.displayName||"Scratchpad",t.sandbox.add("allow-scripts"),t.referrerPolicy="no-referrer",t.srcdoc=k(n.contentHTML??"",n.theme,y),t.addEventListener("load",()=>{s.renderReady(n.displayName,n.revision)},{once:!0}),l=t.contentWindow,e.append(t),l=t.contentWindow}function H(e,n){if(n){if(n.missingDocument){_(e,n);return}F(e,n)}}B();C();var E=document.getElementById("root");if(!(E instanceof HTMLElement))throw s.javascriptError("Missing Scratchpad panel root container","main.ts",null,null,null),new Error("Missing Scratchpad panel root container");D(g);window.ToasttyScratchpadPanel.subscribe(e=>H(E,e));s.bridgeReady();})();
