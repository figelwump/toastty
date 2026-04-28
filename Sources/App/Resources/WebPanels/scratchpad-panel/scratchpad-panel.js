(()=>{var j="toasttyScratchpadPanel";function l(e){window.webkit?.messageHandlers?.[j]?.postMessage(e)}var s={bridgeReady(){l({type:"bridgeReady"})},consoleMessage(e,n,t="panel"){l({type:"consoleMessage",level:e,message:n,diagnosticSource:t})},javascriptError(e,n,t,r,i,m="panel"){l({type:"javascriptError",message:e,source:n,line:t,column:r,stack:i,diagnosticSource:m})},unhandledRejection(e,n,t="panel"){l({type:"unhandledRejection",reason:e,stack:n,diagnosticSource:t})},cspViolation(e,n,t,r,i,m,d,g="panel"){l({type:"cspViolation",violatedDirective:e,effectiveDirective:n,blockedURI:t,sourceFile:r,line:i,column:m,disposition:d,diagnosticSource:g})},renderReady(e,n){l({type:"renderReady",displayName:e,revision:n})}};var N=["default-src 'none'","script-src 'unsafe-inline'","script-src-elem 'unsafe-inline'","script-src-attr 'none'","style-src 'unsafe-inline'","img-src data: blob:","font-src data: blob:","media-src data: blob:","connect-src 'none'","frame-src 'none'","worker-src 'none'","object-src 'none'","base-uri 'none'","form-action 'none'"].join("; "),b="toastty:scratchpad-generated-diagnostic:v1";function R(){return`<meta http-equiv="Content-Security-Policy" content="${N.replaceAll('"',"&quot;")}">`}function L(e){return`<script>
(() => {
  if (window.__toasttyScratchpadGeneratedDiagnosticsInstalled) {
    return;
  }
  window.__toasttyScratchpadGeneratedDiagnosticsInstalled = true;
  const messageType = "${b}";
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
<\/script>`}function P(e){return e.replace(/^\s*<!doctype[^>]*>/i,"")}function v(e,n,t){let r=P(e),i=`<script>document.documentElement.dataset.toasttyTheme=${JSON.stringify(n)};<\/script>`,d=`${R()}<style>html,body{min-height:100%;}body{margin:0;}</style>${L(t)}${i}`;return/<head(?:\s[^>]*)?>/i.test(r)?r.replace(/<head(?:\s[^>]*)?>/i,g=>`${g}${d}`):/<html(?:\s[^>]*)?>/i.test(r)?r.replace(/<html(?:\s[^>]*)?>/i,g=>`${g}<head>${d}</head>`):`<!doctype html><html><head>${d}</head><body>${r}</body></html>`}var k=new Set,u=null,p=null,o=null,h=null,S=!1,w=2e3;function a(e,n=w){return e.length<=n?e:`${e.slice(0,n-1)}...`}function E(e,n=new WeakSet){if(e instanceof Error)return{message:e.message||e.name||"Error",stack:e.stack?a(e.stack):null};if(typeof e=="string")return{message:a(e),stack:null};if(typeof e=="number"||typeof e=="boolean"||typeof e=="bigint"||typeof e=="symbol")return{message:String(e),stack:null};if(e==null)return{message:String(e),stack:null};if(typeof e=="object"){if(n.has(e))return{message:"[Circular]",stack:null};n.add(e);let t="stack"in e&&typeof e.stack=="string"?a(e.stack):null;try{return{message:a(JSON.stringify(e)),stack:t}}catch{return{message:a(Object.prototype.toString.call(e)),stack:t}}}return{message:a(String(e)),stack:null}}function B(e){return e.length===0?"":e.map(n=>E(n).message).join(" ")}function C(){if(!window.__toasttyScratchpadDiagnosticsInstalled){window.__toasttyScratchpadDiagnosticsInstalled=!0;for(let e of["info","warn","error"]){let n=console[e].bind(console);console[e]=(...t)=>{n(...t),s.consoleMessage(e,B(t))}}window.addEventListener("error",e=>{s.javascriptError(e.message||"JavaScript error",e.filename||null,Number.isFinite(e.lineno)?e.lineno:null,Number.isFinite(e.colno)?e.colno:null,e.error instanceof Error&&e.error.stack?a(e.error.stack):null)}),window.addEventListener("unhandledrejection",e=>{let n=E(e.reason);s.unhandledRejection(n.message,n.stack)})}}function D(e){return typeof e=="object"&&e!==null}function c(e,n=w){return typeof e=="string"&&e.length>0?a(e,n):null}function f(e,n,t=w){return typeof e=="string"&&e.length>0?a(e,t):n}function y(e){if(typeof e!="number"||!Number.isFinite(e))return null;let n=Math.trunc(e);return n>=0&&n<=1e6?n:null}function $(e){switch(e){case"info":case"warn":case"error":return e;default:return null}}function I(e){switch(e.type){case"consoleMessage":{let n=$(e.level),t=c(e.message);if(!n||!t)return;s.consoleMessage(n,t,"generated-content");return}case"javascriptError":{s.javascriptError(f(e.message,"JavaScript error"),c(e.source),y(e.line),y(e.column),c(e.stack),"generated-content");return}case"unhandledRejection":{s.unhandledRejection(f(e.reason,"Unhandled promise rejection"),c(e.stack),"generated-content");return}case"cspViolation":{s.cspViolation(f(e.violatedDirective,"<unknown>",128),f(e.effectiveDirective,"<unknown>",128),c(e.blockedURI,512),c(e.sourceFile,512),y(e.line),y(e.column),c(e.disposition,32),"generated-content");return}}}function x(){window.addEventListener("message",e=>{if(!o||e.source!==o||!D(e.data)||e.data.type!==b||typeof e.data.sessionToken!="string"||e.data.sessionToken!==h)return;let n=e.data.event;D(n)&&I(n)})}function V(){return globalThis.crypto?.randomUUID?.()??`${Date.now()}-${Math.random()}`}function M(e){document.documentElement.dataset.theme=e?.theme??"dark"}function F(){for(let e of k)e(u)}function _(e){e.contractVersion!==1&&console.warn(`[ToasttyScratchpadPanel] Expected bootstrap contractVersion 1 but received ${e.contractVersion}.`),u=e,M(e),F()}function H(){if(p){if(!S)return!1;try{return p.focus({preventScroll:!0}),o?.focus(),!0}catch{return!1}}if(!u?.missingDocument)return!1;let e=document.querySelector(".scratchpad-empty");return e instanceof HTMLElement?(e.tabIndex=-1,e.focus({preventScroll:!0}),document.activeElement===e):!1}window.ToasttyScratchpadPanel={receiveBootstrap:_,focusActiveContent:H,getCurrentBootstrap(){return u},subscribe(e){return k.add(e),e(u),()=>{k.delete(e)}}};function W(e,n){p=null,o=null,h=null,S=!1,e.replaceChildren();let t=document.createElement("section");t.className="scratchpad-empty";let r=document.createElement("h1");r.textContent=n.displayName||"Scratchpad";let i=document.createElement("p");i.textContent=n.message||"This Scratchpad document is unavailable.",t.append(r,i),e.append(t),s.renderReady(n.displayName,n.revision)}function G(e,n){p=null,o=null,h=V(),S=!1,e.replaceChildren();let t=document.createElement("iframe");t.className="scratchpad-frame",t.title=n.displayName||"Scratchpad",t.tabIndex=-1,t.sandbox.add("allow-scripts"),t.referrerPolicy="no-referrer",t.srcdoc=v(n.contentHTML??"",n.theme,h),t.addEventListener("load",()=>{S=!0,o=t.contentWindow,s.renderReady(n.displayName,n.revision)},{once:!0}),p=t,o=t.contentWindow,e.append(t),o=t.contentWindow}function U(e,n){if(n){if(n.missingDocument){W(e,n);return}G(e,n)}}C();x();var T=document.getElementById("root");if(!(T instanceof HTMLElement))throw s.javascriptError("Missing Scratchpad panel root container","main.ts",null,null,null),new Error("Missing Scratchpad panel root container");M(u);window.ToasttyScratchpadPanel.subscribe(e=>U(T,e));s.bridgeReady();})();
