export type SecretScanRule = {
  id: string;
  label: string;
  pattern: string;
  caseInsensitive?: boolean;
};

export type SecretScanFinding = {
  ruleID: string;
  label: string;
  matchCount: number;
};

export const secretScanRules: SecretScanRule[] = [
  {
    id: "private-key",
    label: "private key block",
    pattern: String.raw`-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----`
  },
  {
    id: "github-pat",
    label: "GitHub personal access token",
    pattern: String.raw`github_pat_[A-Za-z0-9_]{20,}`
  },
  {
    id: "github-token",
    label: "GitHub token",
    pattern: String.raw`gh[pousr]_[A-Za-z0-9_]{20,}`
  },
  {
    id: "openai-token",
    label: "OpenAI-style API token",
    pattern: String.raw`(?:^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_][A-Za-z0-9_-]{19,}`
  },
  {
    id: "aws-access-key",
    label: "AWS access key ID",
    pattern: String.raw`AKIA[0-9A-Z]{16}`
  },
  {
    id: "stripe-token",
    label: "Stripe API token",
    pattern: String.raw`[rs]k_(?:live|test)_[A-Za-z0-9]{16,}`
  },
  {
    id: "bearer-token",
    label: "Bearer token",
    pattern: String.raw`\bBearer\s+[A-Za-z0-9._~+/=-]{24,}`,
    caseInsensitive: true
  },
  {
    id: "url-userinfo",
    label: "URL credentials",
    pattern: String.raw`https?://[^/\s:@]+(?::[^/\s@]+)?@`,
    caseInsensitive: true
  }
];

export function scanForSecrets(text: string, rules: SecretScanRule[] = secretScanRules): SecretScanFinding[] {
  const findings: SecretScanFinding[] = [];
  for (const rule of rules) {
    const expression = new RegExp(rule.pattern, rule.caseInsensitive ? "gi" : "g");
    const matches = text.match(expression);
    if (matches && matches.length > 0) {
      findings.push({
        ruleID: rule.id,
        label: rule.label,
        matchCount: matches.length
      });
    }
  }
  return findings;
}
