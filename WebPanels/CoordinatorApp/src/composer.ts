export interface ComposerAddress {
  kind: "task" | "project";
  id: string;
  token: string;
  title: string;
  version: number | null;
}

export type AddressPick = Pick<ComposerAddress, "id" | "kind" | "token">;
export function pickedAddress(address: ComposerAddress): AddressPick {
  return { id: address.id, kind: address.kind, token: address.token };
}

export function addressMatches(text: string, choices: ComposerAddress[]): ComposerAddress[] {
  const match = /^@([^\s]*)$/.exec(text);
  if (!match) return [];
  const query = match[1].toLocaleLowerCase();
  return choices.filter((c) => c.token.toLocaleLowerCase().includes(query) || c.title.toLocaleLowerCase().includes(query)).slice(0, 12);
}

export function addressFor(text: string, choices: ComposerAddress[], pick: AddressPick | null): { address: ComposerAddress; text: string } | null {
  const match = /^@([^\s]+)\s+([\s\S]+)$/.exec(text);
  if (!match || !match[2].trim()) return null;
  const matches = choices.filter((c) => c.token === match[1]);
  if (pick?.token === match[1]) {
    const current = matches.find((c) => c.id === pick.id && c.kind === pick.kind);
    return current ? { address: current, text: match[2].trim() } : null;
  }
  return matches.length === 1 ? { address: matches[0], text: match[2].trim() } : null;
}
