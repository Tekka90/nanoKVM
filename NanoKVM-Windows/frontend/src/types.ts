export const pages = [
  "Screen",
  "Media",
  "Wake",
  "Network",
  "Services",
  "Device",
  "Advanced",
  "Settings",
] as const;

export type Page = (typeof pages)[number];

export interface FeatureState {
  name: string;
  available: boolean;
  detail: string;
}

export interface SavedDevice {
  id: string;
  name: string;
  address: string;
  username: string;
}

export type LoginStatus = "authenticated" | "requires_two_factor";

export interface LoginCommandResult {
  status: LoginStatus;
}

export interface PageSnapshot {
  values: Record<string, unknown>;
  errors: Record<string, string>;
}

export interface RealtimeStatus {
  deviceId: string;
  channel: "video" | "hid";
  connected: boolean;
  attempts: number;
  error: string | null;
}

export interface StreamStats {
  deviceId: string;
  codec: "h264" | "h265";
  packets: number;
  bytes: number;
  keyframes: number;
  timestampMicros: number;
  width: number | null;
  height: number | null;
}

export interface UploadProgress {
  uploadId: string;
  chunkIndex: number;
  totalChunks: number;
  bytesSent: number;
  totalBytes: number;
}

export function pageFromHash(hash: string): Page {
  const decoded = decodeURIComponent(hash.replace(/^#/, ""));
  return pages.find((page) => page.toLowerCase() === decoded.toLowerCase()) ?? "Screen";
}
