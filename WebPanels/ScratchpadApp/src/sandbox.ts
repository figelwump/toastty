export const generatedContentCSP = [
  "default-src 'none'",
  "script-src 'unsafe-inline'",
  "style-src 'unsafe-inline'",
  "img-src data: blob:",
  "font-src data: blob:",
  "media-src data: blob:",
  "connect-src 'none'",
  "frame-src 'none'",
  "worker-src 'none'",
  "base-uri 'none'",
  "form-action 'none'"
].join("; ");

function cspMetaTag() {
  return `<meta http-equiv="Content-Security-Policy" content="${generatedContentCSP.replaceAll(
    '"',
    "&quot;"
  )}">`;
}

function stripLeadingDoctype(html: string): string {
  return html.replace(/^\s*<!doctype[^>]*>/i, "");
}

export function sandboxedSrcdoc(rawHTML: string, theme: "light" | "dark"): string {
  const html = stripLeadingDoctype(rawHTML);
  const themeScript = `<script>document.documentElement.dataset.toasttyTheme=${JSON.stringify(theme)};<\/script>`;
  const guardStyle = `<style>html,body{min-height:100%;}body{margin:0;}</style>`;
  const headPrefix = `${cspMetaTag()}${guardStyle}${themeScript}`;

  if (/<head(?:\s[^>]*)?>/i.test(html)) {
    return html.replace(/<head(?:\s[^>]*)?>/i, (match) => `${match}${headPrefix}`);
  }

  if (/<html(?:\s[^>]*)?>/i.test(html)) {
    return html.replace(/<html(?:\s[^>]*)?>/i, (match) => `${match}<head>${headPrefix}</head>`);
  }

  return `<!doctype html><html><head>${headPrefix}</head><body>${html}</body></html>`;
}
