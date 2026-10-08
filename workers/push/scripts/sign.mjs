import { createPrivateKey, sign } from "node:crypto";

export function signingConfiguration(source, now = Date.now()) {
  for (const name of ["TOASTTY_APNS_PRIVATE_KEY", "TOASTTY_APNS_KEY_ID", "TOASTTY_APNS_TEAM_ID", "TOASTTY_APNS_DEVICE_TOKEN"]) {
    if (!source[name]) throw new Error(`Required vault key: ${name}.`);
  }
  const keyID = source.TOASTTY_APNS_KEY_ID.trim();
  const teamID = source.TOASTTY_APNS_TEAM_ID.trim();
  const token = source.TOASTTY_APNS_DEVICE_TOKEN.trim();
  if (!/^[A-Z0-9]{10}$/.test(keyID) || !/^[A-Z0-9]{10}$/.test(teamID)) {
    throw new Error("APNs key ID and team ID must each contain 10 uppercase letters or digits.");
  }
  if (!/^(?:[a-f0-9]{2}){16,256}$/i.test(token)) throw new Error("APNs device token must be hexadecimal bytes.");
  let key;
  // Some vault input commands accept one line only. Allow escaped PEM newlines.
  try { key = createPrivateKey(source.TOASTTY_APNS_PRIVATE_KEY.replaceAll("\\n", "\n")); }
  catch { throw new Error("APNs private key must contain the PEM .p8 file contents."); }
  if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails?.namedCurve !== "prime256v1") {
    throw new Error("APNs private key must be an ES256 P-256 key.");
  }
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const unsigned = `${encode({ alg: "ES256", kid: keyID })}.${encode({ iss: teamID, iat: Math.floor(now / 1000) })}`;
  const signature = sign("sha256", Buffer.from(unsigned), { key, dsaEncoding: "ieee-p1363" }).toString("base64url");
  return { APNS_PROVIDER_TOKEN: `${unsigned}.${signature}`, APNS_DEVICE_TOKEN: token };
}
