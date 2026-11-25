import type { PageSnapshot } from "./types";

export interface EdidOption {
  id: string;
  label: string;
  custom: boolean;
}

export interface EdidState {
  current: string;
  options: EdidOption[];
  custom: string[];
}

export const builtinEdids: EdidOption[] = [
  { id: "nanokvm-go-3840x2160-50", label: "3840 × 2160 @ 50 Hz", custom: false },
  { id: "nanokvm-go-3840x2160-30", label: "3840 × 2160 @ 30 Hz", custom: false },
  { id: "nanokvm-go-3440x1440-60", label: "3440 × 1440 @ 60 Hz", custom: false },
  { id: "nanokvm-go-2560x1440-60", label: "2560 × 1440 @ 60 Hz", custom: false },
  { id: "nanokvm-go-1920x1080-60", label: "1920 × 1080 @ 60 Hz", custom: false },
];

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function stringArray(value: unknown): string[] {
  if (Array.isArray(value)) {
    return value.filter((item): item is string => typeof item === "string");
  }
  const record = asRecord(value);
  if (!record) return [];
  const list = record.edidList ?? record.edids ?? record.files;
  return Array.isArray(list)
    ? list.filter((item): item is string => typeof item === "string")
    : [];
}

export function edidLabel(name: string): string {
  const builtin = builtinEdids.find((option) => option.id === name);
  return builtin?.label ?? name.replace(/\.bin$/i, "").replaceAll("_", " ");
}

export function edidState(snapshot: PageSnapshot): EdidState {
  const currentRecord = asRecord(snapshot.values.edid);
  const current =
    typeof snapshot.values.edid === "string"
      ? snapshot.values.edid
      : typeof currentRecord?.edid === "string"
        ? currentRecord.edid
        : "";
  const custom = [...new Set(stringArray(snapshot.values.custom_edid))].sort();
  const options = [...builtinEdids, ...custom.map((id) => ({
    id,
    label: edidLabel(id),
    custom: true,
  }))];
  if (current && !options.some((option) => option.id === current)) {
    options.push({ id: current, label: edidLabel(current), custom: false });
  }
  return { current, options, custom };
}

export function edidPowerKey(deviceId: string): string {
  return `edid-power-confirmed:${deviceId}`;
}

export function edidAutoKey(deviceId: string): string {
  return `edid-auto-switch:${deviceId}`;
}
