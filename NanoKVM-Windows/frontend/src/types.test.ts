import { describe, expect, it } from "vitest";
import { pageFromHash } from "./types";
import { sections } from "./catalog";
import { eventCodeToHid } from "./keyboard";
import { appendSample, sampleStats, summarize } from "./stats";
import { builtinEdids, edidAutoKey, edidLabel, edidPowerKey, edidState } from "./edid";

describe("pageFromHash", () => {
  it("matches known pages case-insensitively", () => {
    expect(pageFromHash("#NeTwOrK")).toBe("Network");
  });

  it("falls back to Screen for malformed navigation", () => {
    expect(pageFromHash("#unknown")).toBe("Screen");
  });

  it("keeps every Apple page in the parity UI", () => {
    expect(Object.keys(sections)).toEqual(
      expect.arrayContaining([
        "Screen",
        "Media",
        "Wake",
        "Network",
        "Services",
        "Device",
        "Advanced",
        "Settings",
      ]),
    );
  });

  it("marks risky controls as confirmation-required", () => {
    const network = sections.Network.flatMap((section) => section.controls);
    expect(network.find((control) => control.action === "wifi-disconnect")?.requiresConfirmation).toBe(true);
    expect(network.find((control) => control.action === "reboot")).toBeUndefined();
  });

  it("presents built-in and uploaded EDIDs without asking for a file name", () => {
    const settings = sections.Settings.flatMap((section) => section.controls);
    expect(settings.find((control) => control.action === "edid-picker")?.kind).toBe("select");
    expect(settings.find((control) => control.action === "edid-power-confirmed")?.kind).toBe("toggle");
    expect(settings.find((control) => control.action === "edid-set")).toBeUndefined();
  });

  it("parses the current EDID and custom upload list from API state", () => {
    const builtIn = builtinEdids[0]!;
    const state = edidState({
      values: {
        edid: { edid: builtIn.id },
        custom_edid: { edidList: ["Desk_Screen.bin", "Desk_Screen.bin"] },
      },
      errors: {},
    });
    expect(state.current).toBe(builtIn.id);
    expect(state.custom).toEqual(["Desk_Screen.bin"]);
    expect(state.options).toContainEqual({
      id: "Desk_Screen.bin",
      label: "Desk Screen",
      custom: true,
    });
  });

  it("keeps an unknown current EDID visible and scopes power confirmation per device", () => {
    const state = edidState({
      values: { edid: { edid: "factory-special.bin" }, custom_edid: {} },
      errors: {},
    });
    expect(state.options.at(-1)?.id).toBe("factory-special.bin");
    expect(edidLabel("factory-special.bin")).toBe("factory-special");
    expect(edidPowerKey("device-a")).toBe("edid-power-confirmed:device-a");
    expect(edidPowerKey("device-a")).not.toBe(edidPowerKey("device-b"));
    expect(edidAutoKey("device-a")).not.toBe(edidAutoKey("device-b"));
  });

  it("maps physical keyboard and shortcut keys to USB HID usages", () => {
    expect(eventCodeToHid("KeyA")).toBe(4);
    expect(eventCodeToHid("Digit0")).toBe(39);
    expect(eventCodeToHid("F12")).toBe(69);
    expect(eventCodeToHid("Delete")).toBe(76);
    expect(eventCodeToHid("AudioVolumeUp")).toBeNull();
  });

  it("calculates bounded bitrate and FPS history", () => {
    const first = sampleStats(null, { packets: 10, bytes: 1_000 }, 1_000);
    expect(first.sample).toBeNull();
    const second = sampleStats(
      first.baseline,
      { packets: 40, bytes: 11_000 },
      2_000,
    );
    expect(second.sample).toEqual({ kbps: 80, fps: 30 });
    const history = appendSample([], second.sample);
    expect(summarize(history)).toEqual({ averageKbps: 80, peakKbps: 80 });
    expect(appendSample(history, second.sample, 1)).toHaveLength(1);
  });
});
