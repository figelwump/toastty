import assert from "node:assert/strict";
import test from "node:test";

import {
  destinationIsAvailable,
  describeDeviceListError,
  readinessProblems,
  selectPhysicalDevice,
  warmConnectTargets,
} from "../../scripts/lib/physical-device.mjs";

function iphone({
  identifier,
  udid,
  name,
  pairingState = "paired",
  developerModeStatus = "enabled",
  tunnelState = "connected",
  ddiServicesAvailable = true,
  potentialHostnames = [],
} = {}) {
  return {
    identifier,
    hardwareProperties: {
      reality: "physical",
      platform: "iOS",
      deviceType: "iPhone",
      udid,
    },
    deviceProperties: {
      name,
      osVersionNumber: "18.6",
      developerModeStatus,
      ddiServicesAvailable,
    },
    connectionProperties: {
      pairingState,
      tunnelState,
      potentialHostnames,
    },
  };
}

function list(devices) {
  return { result: { devices } };
}

test("selectPhysicalDevice ignores simulators and selects the only ready physical iPhone", () => {
  const ready = iphone({ identifier: "core-1", udid: "UDID-1", name: "Vishal iPhone" });
  const simulator = {
    ...iphone({ identifier: "sim-1", udid: "SIM-1", name: "Simulator" }),
    hardwareProperties: {
      reality: "virtual",
      platform: "iOS",
      deviceType: "iPhone",
      udid: "SIM-1",
    },
  };

  const report = selectPhysicalDevice(list([simulator, ready]));
  assert.equal(report.ok, true);
  assert.equal(report.selectedDevice.identifier, "core-1");
  assert.equal(report.selectedDevice.udid, "UDID-1");
});

test("selection requires an explicit discriminator when multiple phones are ready", () => {
  const first = iphone({
    identifier: "core-1",
    udid: "UDID-1",
    name: "Phone",
    potentialHostnames: ["phone-one.local"],
  });
  const second = iphone({ identifier: "core-2", udid: "UDID-2", name: "Phone" });

  const ambiguous = selectPhysicalDevice(list([first, second]));
  assert.equal(ambiguous.ok, false);
  assert.match(ambiguous.error, /Multiple ready iPhones/);

  const exact = selectPhysicalDevice(list([first, second]), "phone-one.local");
  assert.equal(exact.ok, true);
  assert.equal(exact.selectedDevice.identifier, "core-1");
});

test("an explicitly selected unready phone fails closed with actionable state", () => {
  const unready = iphone({
    identifier: "core-1",
    udid: "UDID-1",
    name: "Locked Phone",
    pairingState: "unpaired",
    developerModeStatus: "disabled",
    tunnelState: "disconnected",
    ddiServicesAvailable: false,
  });

  const report = selectPhysicalDevice(list([unready]), "UDID-1");
  assert.equal(report.ok, false);
  assert.match(report.error, /not ready/);
  assert.deepEqual(readinessProblems(unready), [
    "pairingState=unpaired",
    "developerModeStatus=disabled",
    "device services unavailable (tunnelState=disconnected, ddiServicesAvailable=false)",
  ]);
  assert.ok(report.candidateDevices[0].readinessHints.length >= 3);
});

test("warmConnectTargets only returns paired phones whose device services may recover", () => {
  const recoverable = iphone({
    identifier: "core-1",
    udid: "UDID-1",
    name: "Recoverable",
    tunnelState: "disconnected",
    ddiServicesAvailable: false,
  });
  const disabled = iphone({
    identifier: "core-2",
    udid: "UDID-2",
    name: "Disabled",
    developerModeStatus: "disabled",
    tunnelState: "disconnected",
    ddiServicesAvailable: false,
  });

  assert.deepEqual(warmConnectTargets(list([recoverable, disabled])), [
    { identifier: "core-1", name: "Recoverable" },
  ]);
  assert.deepEqual(warmConnectTargets(list([recoverable]), "different"), []);
});

test("failed or malformed devicectl payloads are reported without guessing", () => {
  const failed = {
    info: { outcome: "failed" },
    error: { userInfo: { NSLocalizedDescription: { string: "CoreDevice unavailable" } } },
  };
  assert.equal(describeDeviceListError(failed), "CoreDevice unavailable");
  assert.match(describeDeviceListError({}), /result\.devices/);
  assert.equal(selectPhysicalDevice(failed).ok, false);
});

test("destination validation ignores an ineligible-only UDID", () => {
  const output = `
    Available destinations for the "ToasttyMobileApp" scheme:
      { platform:iOS, arch:arm64, id:READY-UDID, name:Ready Phone }

    Ineligible destinations for the "ToasttyMobileApp" scheme:
      { platform:iOS, arch:arm64, id:INELIGIBLE-UDID, name:Locked Phone, error:Device is locked }
  `;
  assert.equal(destinationIsAvailable(output, "READY-UDID"), true);
  assert.equal(destinationIsAvailable(output, "INELIGIBLE-UDID"), false);
  assert.equal(destinationIsAvailable(output, "READY"), false);
});
