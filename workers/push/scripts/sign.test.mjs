import { generateKeyPairSync, verify } from "node:crypto";
import { test } from "node:test";
import assert from "node:assert/strict";
import { signingConfiguration } from "./sign.mjs";

for (const escapedNewlines of [false, true]) {
  test(`signs an APNs JWT from ${escapedNewlines ? "single-line escaped" : "multiline"} PEM with an ES256 signature and correct claims`, () => {
    const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    const pem = privateKey.export({ type: "pkcs8", format: "pem" });
    const source = {
      TOASTTY_APNS_PRIVATE_KEY: escapedNewlines ? pem.replaceAll("\n", "\\n") : pem,
      TOASTTY_APNS_KEY_ID: "TESTKEY123", TOASTTY_APNS_TEAM_ID: "TESTTEAM12",
      TOASTTY_APNS_DEVICE_TOKEN: "ab".repeat(32)
    };
    const result = signingConfiguration(source, 1_791_331_200_000);
    const [header, claims, signature] = result.APNS_PROVIDER_TOKEN.split(".");
    assert.deepEqual(JSON.parse(Buffer.from(header, "base64url").toString()), { alg: "ES256", kid: "TESTKEY123" });
    assert.deepEqual(JSON.parse(Buffer.from(claims, "base64url").toString()), { iss: "TESTTEAM12", iat: 1_791_331_200 });
    assert.equal(verify("sha256", Buffer.from(`${header}.${claims}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(signature, "base64url")), true);
    assert.equal(result.APNS_DEVICE_TOKEN, source.TOASTTY_APNS_DEVICE_TOKEN);
    assert.equal(JSON.stringify(result).includes("PRIVATE KEY"), false);
  });
}

test("fails before deployment for absent or invalid inputs without echoing them", () => {
  assert.throws(() => signingConfiguration({}), /Required vault key: TOASTTY_APNS_PRIVATE_KEY/);
  for (const invalid of ["private-invalid-value", "-----BEGIN PRIVATE KEY-----", "-----BEGIN PRIVATE KEY-----\\n"]) {
    assert.throws(() => signingConfiguration({ TOASTTY_APNS_PRIVATE_KEY: invalid,
      TOASTTY_APNS_KEY_ID: "TESTKEY123", TOASTTY_APNS_TEAM_ID: "TESTTEAM12", TOASTTY_APNS_DEVICE_TOKEN: "ab".repeat(32)
    }), /^Error: APNs private key must contain the PEM .p8 file contents\.$/);
  }
});
