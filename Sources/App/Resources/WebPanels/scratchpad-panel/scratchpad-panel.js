(()=>{var K="toasttyScratchpadPanel";function g(e){window.webkit?.messageHandlers?.[K]?.postMessage(e)}var o={contentSize(e,t,n){g({type:"contentSize",width:e,height:t,revision:n})},bridgeReady(){g({type:"bridgeReady"})},consoleMessage(e,t,n="panel"){g({type:"consoleMessage",level:e,message:t,diagnosticSource:n})},javascriptError(e,t,n,r,a,u="panel"){g({type:"javascriptError",message:e,source:t,line:n,column:r,stack:a,diagnosticSource:u})},unhandledRejection(e,t,n="panel"){g({type:"unhandledRejection",reason:e,stack:t,diagnosticSource:n})},cspViolation(e,t,n,r,a,u,y,s="panel"){g({type:"cspViolation",violatedDirective:e,effectiveDirective:t,blockedURI:n,sourceFile:r,line:a,column:u,disposition:y,diagnosticSource:s})},renderReady(e,t,n=null){g({type:"renderReady",displayName:e,revision:t,annotationRenderID:n})}};var Y=["default-src 'none'","script-src 'unsafe-inline'","script-src-elem 'unsafe-inline'","script-src-attr 'none'","style-src 'unsafe-inline'","img-src data: blob:","font-src https: data: blob:","media-src data: blob:","connect-src 'none'","frame-src 'none'","worker-src 'none'","object-src 'none'","base-uri 'none'","form-action 'none'"].join("; "),N="toastty:scratchpad-generated-diagnostic:v1",R="toastty:scratchpad-annotation-viewport-request:v1";function X(){return`<meta http-equiv="Content-Security-Policy" content="${Y.replaceAll('"',"&quot;")}">`}function Q(e,t){return`<script>
(() => {
  if (window.__toasttyScratchpadGeneratedDiagnosticsInstalled) {
    return;
  }
  window.__toasttyScratchpadGeneratedDiagnosticsInstalled = true;
  const messageType = "${N}";
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
  window.addEventListener("message", (event) => {
    const data = event.data;
    if (event.source !== window.parent || !data ||
        data.type !== "${R}" ||
        data.sessionToken !== sessionToken || typeof data.requestID !== "string") return;
    postDiagnostic({ type: "annotationViewport", requestID: data.requestID, x: window.scrollX, y: window.scrollY });
  });
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
<\/script>`}function Z(e){return e.replace(/^\s*<!doctype[^>]*>/i,"")}function _(e,t,n,r=!1){let a=Z(e),u=`<script>document.documentElement.dataset.toasttyTheme=${JSON.stringify(t)};<\/script>`,s=`${X()}<style>html,body{min-height:100%;}body{margin:0;}</style>${Q(n,r)}${u}`;return/<head(?:\s[^>]*)?>/i.test(a)?a.replace(/<head(?:\s[^>]*)?>/i,m=>`${m}${s}`):/<html(?:\s[^>]*)?>/i.test(a)?a.replace(/<html(?:\s[^>]*)?>/i,m=>`${m}<head>${s}</head>`):`<!doctype html><html><head>${s}</head><body>${a}</body></html>`}var M=new Set,i=null,b=null,d=null,f=null,E=!1,ee=0,k=new Map,I=2e3,W=`Download the Toastty Scratchpad skill from
https://github.com/figelwump/toastty/tree/main/.agents/skills/toastty-scratchpad

Install it globally. Check which of these directories already exist
and copy the toastty-scratchpad folder into the matching ones:

  \u2022 ~/.claude/skills        (Claude Code)
  \u2022 ~/.codex/skills         (Codex)
  \u2022 ~/.agents/skills        (generic / Codex)

If none of these exist for the agent I'm currently using, create the
appropriate one and install there.`;function l(e,t=I){return e.length<=t?e:`${e.slice(0,t-1)}...`}function U(e,t=new WeakSet){if(e instanceof Error)return{message:e.message||e.name||"Error",stack:e.stack?l(e.stack):null};if(typeof e=="string")return{message:l(e),stack:null};if(typeof e=="number"||typeof e=="boolean"||typeof e=="bigint"||typeof e=="symbol")return{message:String(e),stack:null};if(e==null)return{message:String(e),stack:null};if(typeof e=="object"){if(t.has(e))return{message:"[Circular]",stack:null};t.add(e);let n="stack"in e&&typeof e.stack=="string"?l(e.stack):null;try{return{message:l(JSON.stringify(e)),stack:n}}catch{return{message:l(Object.prototype.toString.call(e)),stack:n}}}return{message:l(String(e)),stack:null}}function te(e){return e.length===0?"":e.map(t=>U(t).message).join(" ")}function ne(){if(!window.__toasttyScratchpadDiagnosticsInstalled){window.__toasttyScratchpadDiagnosticsInstalled=!0;for(let e of["info","warn","error"]){let t=console[e].bind(console);console[e]=(...n)=>{t(...n),o.consoleMessage(e,te(n))}}window.addEventListener("error",e=>{o.javascriptError(e.message||"JavaScript error",e.filename||null,Number.isFinite(e.lineno)?e.lineno:null,Number.isFinite(e.colno)?e.colno:null,e.error instanceof Error&&e.error.stack?l(e.error.stack):null)}),window.addEventListener("unhandledrejection",e=>{let t=U(e.reason);o.unhandledRejection(t.message,t.stack)})}}function O(e){return typeof e=="object"&&e!==null}function h(e,t=I){return typeof e=="string"&&e.length>0?l(e,t):null}function w(e,t,n=I){return typeof e=="string"&&e.length>0?l(e,n):t}function S(e){if(typeof e!="number"||!Number.isFinite(e))return null;let t=Math.trunc(e);return t>=0&&t<=1e6?t:null}function re(e){switch(e){case"info":case"warn":case"error":return e;default:return null}}function ae(e){switch(e.type){case"consoleMessage":{let t=re(e.level),n=h(e.message);if(!t||!n)return;o.consoleMessage(t,n,"generated-content");return}case"javascriptError":{o.javascriptError(w(e.message,"JavaScript error"),h(e.source),S(e.line),S(e.column),h(e.stack),"generated-content");return}case"unhandledRejection":{o.unhandledRejection(w(e.reason,"Unhandled promise rejection"),h(e.stack),"generated-content");return}case"cspViolation":{o.cspViolation(w(e.violatedDirective,"<unknown>",128),w(e.effectiveDirective,"<unknown>",128),h(e.blockedURI,512),h(e.sourceFile,512),S(e.line),S(e.column),h(e.disposition,32),"generated-content");return}}}function oe(){window.addEventListener("message",e=>{if(!d||e.source!==d||!O(e.data)||e.data.type!==N||typeof e.data.sessionToken!="string"||e.data.sessionToken!==f)return;let t=e.data.event;if(O(t)){if(t.type==="annotationViewport"){let{requestID:n,x:r,y:a}=t;if(typeof n!="string"||typeof r!="number"||typeof a!="number"||!Number.isFinite(r)||!Number.isFinite(a))return;v(n,{x:r,y:a});return}if(t.type==="contentSize"){if(!i?.mobileViewport)return;let{width:n,height:r}=t;if(typeof n!="number"||typeof r!="number"||!Number.isFinite(n)||!Number.isFinite(r)||n<320||r<320||n>16384||r>16384)return;o.contentSize(n,r,i.revision);return}ae(t)}})}function ie(){return globalThis.crypto?.randomUUID?.()??`${Date.now()}-${Math.random()}`}function G(e){document.documentElement.dataset.theme=e?.theme??"dark"}function se(){for(let e of M)e(i)}function L(){for(let e of k.keys())v(e,null);b=null,d=null,f=null,E=!1}function v(e,t){let n=k.get(e);n&&(k.delete(e),clearTimeout(n.timeout),n.resolve(t))}function ce(){if(!E||!d||!f)return Promise.resolve(null);let e=d,t=f,n=String(++ee);return new Promise(r=>{let a=setTimeout(()=>v(n,null),500);k.set(n,{resolve:r,timeout:a});try{e.postMessage({type:R,sessionToken:t,requestID:n},"*")}catch{v(n,null)}})}function z(e){return!e.missingDocument&&e.sessionLinked!==!0&&(e.contentHTML??"").trim().length===0}function le(e){e.contractVersion!==1&&console.warn(`[ToasttyScratchpadPanel] Expected bootstrap contractVersion 1 but received ${e.contractVersion}.`),i=e,G(e),se()}function de(){if(b){if(!E)return!1;try{return b.focus({preventScroll:!0}),d?.focus(),!0}catch{return!1}}if(!i||!i.missingDocument&&!z(i))return!1;let e=document.querySelector(".scratchpad-empty");return e instanceof HTMLElement?(e.tabIndex=-1,e.focus({preventScroll:!0}),document.activeElement===e):!1}window.ToasttyScratchpadPanel={receiveBootstrap:le,focusActiveContent:de,getAnnotationViewport:ce,getCurrentBootstrap(){return i},subscribe(e){return M.add(e),e(i),()=>{M.delete(e)}}};function ue(e,t){L(),e.replaceChildren();let n=document.createElement("section");n.className="scratchpad-empty";let r=document.createElement("h1");r.textContent=t.displayName||"Scratchpad";let a=document.createElement("p");a.textContent=t.message||"This Scratchpad document is unavailable.",n.append(r,a),e.append(n),o.renderReady(t.displayName,t.revision,t.annotationRenderID??null)}function pe(e,t){L(),e.replaceChildren();let n=document.createElement("section");n.className="scratchpad-empty scratchpad-empty--guide",n.tabIndex=-1;let r=document.createElement("div");r.className="scratchpad-guide-header";let a=document.createElement("h1");a.textContent="Scratchpad is ready";let u=document.createElement("p");u.textContent="You\u2019re on the manual path: you created an empty Scratchpad, so you\u2019ll need to bind it to an agent and install the Scratchpad skill before the agent can publish to it.";let y=document.createElement("p");y.textContent="The shorter path is to install the skill once and skip this screen entirely \u2014 agents create and bind their own Scratchpads on demand. See \u201CSkip this next time\u201D below.",r.append(a,u,y);let s=document.createElement("ol");s.className="scratchpad-guide-steps";let m=document.createElement("li");m.className="scratchpad-guide-step";let V=document.createElement("h2");V.textContent="Bind this Scratchpad to an agent";let P=document.createElement("p");P.textContent="Click the \u201CUnbound\u201D chip in this panel\u2019s header and pick an agent session running in the current tab. Only Toastty-managed sessions show up.",m.append(V,P);let D=document.createElement("li");D.className="scratchpad-guide-step scratchpad-guide-step--snippet";let x=document.createElement("div");x.className="scratchpad-snippet-header";let j=document.createElement("h2");j.textContent="Install the Scratchpad skill";let c=document.createElement("button");c.type="button",c.className="scratchpad-copy-button",c.textContent="Copy",x.append(j,c);let B=document.createElement("p");B.textContent="Paste this into your agent\u2019s chat (Claude Code, Codex, or any compatible agent). It tells the agent to download the skill and install it globally for whichever runtime you\u2019re using.";let p=document.createElement("textarea");p.className="scratchpad-snippet",p.readOnly=!0,p.spellcheck=!1,p.value=W,p.setAttribute("aria-label","Toastty Scratchpad skill install snippet"),c.addEventListener("click",async()=>{try{if(!navigator.clipboard)throw new Error("Clipboard unavailable");await navigator.clipboard.writeText(W),c.textContent="Copied",setTimeout(()=>{c.textContent="Copy"},1600)}catch{p.focus(),p.select(),c.textContent="Selected",setTimeout(()=>{c.textContent="Copy"},1600)}}),D.append(x,B,p);let T=document.createElement("li");T.className="scratchpad-guide-step";let A=document.createElement("h2");A.textContent="Ask the agent for a visual";let $=document.createElement("p");$.textContent="Ask for a diagram, mock-up, wireframe, architecture map, or data viz, or invoke the skill explicitly. The result will publish into this Scratchpad.",T.append(A,$),s.append(m,D,T);let C=document.createElement("aside");C.className="scratchpad-guide-footer";let F=document.createElement("h2");F.textContent="Skip this next time";let H=document.createElement("p");H.textContent="Once the skill is installed for an agent, you don\u2019t need New Scratchpad at all \u2014 just ask the agent for a visual and it\u2019ll create and bind a fresh Scratchpad on the fly.";let q=document.createElement("p");q.textContent="Rebinding is still useful, though: you might want one agent to create a Scratchpad and another to read it. Use the binding chip to switch which agent has access. Only one agent session can read or write a Scratchpad at a time.",C.append(F,H,q),n.append(r,s,C),e.append(n),o.renderReady(t.displayName,t.revision,t.annotationRenderID??null)}function me(e,t){L(),f=ie(),e.replaceChildren();let n=document.createElement("iframe");n.className="scratchpad-frame",n.title=t.displayName||"Scratchpad",n.tabIndex=-1,n.sandbox.add("allow-scripts"),n.referrerPolicy="no-referrer",n.srcdoc=_(t.contentHTML??"",t.theme,f,t.mobileViewport===!0),n.addEventListener("load",()=>{b===n&&(E=!0,d=n.contentWindow,o.renderReady(t.displayName,t.revision,t.annotationRenderID??null))},{once:!0}),b=n,d=n.contentWindow,e.append(n),d=n.contentWindow}function ge(e,t){if(t){if(t.missingDocument){ue(e,t);return}if(z(t)){pe(e,t);return}me(e,t)}}ne();oe();var J=document.getElementById("root");if(!(J instanceof HTMLElement))throw o.javascriptError("Missing Scratchpad panel root container","main.ts",null,null,null),new Error("Missing Scratchpad panel root container");G(i);window.ToasttyScratchpadPanel.subscribe(e=>ge(J,e));o.bridgeReady();})();
