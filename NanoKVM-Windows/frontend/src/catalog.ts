export interface Control {
  label: string;
  action: string;
  kind: "button" | "text" | "toggle" | "password" | "select";
  destructive?: boolean;
  requiresConfirmation?: boolean;
}

export interface PageSection {
  title: string;
  description: string;
  controls: Control[];
}

export const sections: Record<Page, PageSection[]> = {
  Screen: [
    {
      title: "Keyboard and mouse",
      description: "Native video and HID must be active before keyboard or pointer capture starts.",
      controls: [
        { label: "Paste text", action: "hid-paste", kind: "button" },
        { label: "Ctrl+Alt+Del", action: "send-control-alt-delete", kind: "button" },
        { label: "Reconnect", action: "reconnect", kind: "button" },
      ],
    },
  ],
  Media: [
    {
      title: "Disk images",
      description: "Upload, mount as CD-ROM or disk, unmount and delete ISO/IMG images.",
      controls: [
        { label: "Upload image", action: "image-upload", kind: "button" },
        { label: "Mount", action: "image-mount", kind: "button" },
        { label: "Unmount", action: "image-unmount", kind: "button" },
        {
          label: "Delete image",
          action: "image-delete",
          kind: "button",
          destructive: true,
          requiresConfirmation: true,
        },
      ],
    },
  ],
  Wake: [
    {
      title: "Wake-on-LAN",
      description: "Save named MAC addresses and wake hosts on the KVM network.",
      controls: [
        { label: "MAC address", action: "wol-mac", kind: "text" },
        { label: "Name", action: "wol-name", kind: "text" },
        { label: "Save", action: "wol-save", kind: "button" },
        { label: "Wake now", action: "wol-wake", kind: "button" },
        {
          label: "Delete saved host",
          action: "wol-delete",
          kind: "button",
          destructive: true,
          requiresConfirmation: true,
        },
      ],
    },
  ],
  Network: [
    {
      title: "KVM network",
      description: "Hostname, mDNS, SSH, Wi-Fi and Tailscale. Network changes can disconnect the KVM.",
      controls: [
        { label: "Hostname", action: "hostname", kind: "text" },
        { label: "mDNS", action: "mdns", kind: "toggle" },
        { label: "SSH", action: "ssh", kind: "toggle", requiresConfirmation: true },
        { label: "Scan Wi-Fi", action: "wifi-scan", kind: "button" },
        { label: "Connect Wi-Fi", action: "wifi-connect", kind: "button", requiresConfirmation: true },
        { label: "Disconnect Wi-Fi", action: "wifi-disconnect", kind: "button", destructive: true, requiresConfirmation: true },
      ],
    },
    {
      title: "Tailscale",
      description: "Start, connect, stop, log out and configure exit node and subnet routes.",
      controls: [
        { label: "Install", action: "tailscale-install", kind: "button", requiresConfirmation: true },
        { label: "Login", action: "tailscale-login", kind: "button", requiresConfirmation: true },
        { label: "Start", action: "tailscale-start", kind: "button", requiresConfirmation: true },
        { label: "Connect", action: "tailscale-up", kind: "button", requiresConfirmation: true },
        { label: "Disconnect", action: "tailscale-down", kind: "button", requiresConfirmation: true },
        { label: "Stop", action: "tailscale-stop", kind: "button", requiresConfirmation: true },
        { label: "Exit node", action: "tailscale-exit-node", kind: "toggle" },
        { label: "Subnet route", action: "tailscale-subnet-route", kind: "toggle" },
        { label: "Log out", action: "tailscale-logout", kind: "button", destructive: true, requiresConfirmation: true },
      ],
    },
  ],
  Services: [
    {
      title: "AI services",
      description: "MCP endpoint and key, memory fabric and screen timelapse.",
      controls: [
        { label: "MCP server", action: "mcp-enable", kind: "toggle" },
        { label: "Copy MCP config", action: "mcp-copy-config", kind: "button" },
        { label: "Regenerate key", action: "mcp-regenerate", kind: "button", destructive: true, requiresConfirmation: true },
        { label: "Memory fabric", action: "memory-fabric", kind: "toggle" },
        { label: "Screen timelapse", action: "timelapse", kind: "toggle", requiresConfirmation: true },
      ],
    },
    {
      title: "Scripts",
      description: "Upload, run in foreground/background, inspect logs and delete scripts.",
      controls: [
        { label: "Upload script", action: "script-upload", kind: "button" },
        { label: "Run foreground", action: "script-foreground", kind: "button" },
        { label: "Run background", action: "script-background", kind: "button" },
        { label: "Delete script", action: "script-delete", kind: "button", destructive: true, requiresConfirmation: true },
      ],
    },
  ],
  Device: [
    {
      title: "Device",
      description: "Hardware and application information, USB mode, time and power settings.",
      controls: [
        { label: "Low power", action: "low-power", kind: "toggle" },
        { label: "Swap input", action: "swap", kind: "toggle" },
        { label: "Sync time", action: "time-sync", kind: "button" },
        { label: "Preview updates", action: "preview-updates", kind: "toggle" },
        { label: "Update", action: "firmware-update", kind: "button", destructive: true, requiresConfirmation: true },
        { label: "Reboot", action: "reboot", kind: "button", destructive: true, requiresConfirmation: true },
      ],
    },
  ],
  Advanced: [
    {
      title: "USB and virtual devices",
      description: "USB identity, network mode, virtual audio/disk devices and reported names.",
      controls: [
        { label: "USB ID", action: "usb-id", kind: "button" },
        { label: "USB network", action: "usb-network", kind: "button" },
        { label: "Refresh devices", action: "virtual-refresh", kind: "button" },
        { label: "Disable virtual disk", action: "virtual-disk-disable", kind: "button" },
        { label: "Virtual network", action: "virtual-network", kind: "toggle", requiresConfirmation: true },
        { label: "Virtual disk", action: "virtual-disk", kind: "toggle", requiresConfirmation: true },
        { label: "Virtual audio mode", action: "virtual-audio", kind: "button", requiresConfirmation: true },
        { label: "CD-ROM reported name", action: "usb-name-cdrom", kind: "button" },
        { label: "Disk reported name", action: "usb-name-disk", kind: "button" },
        { label: "Audio reported name", action: "usb-name-audio", kind: "button" },
      ],
    },
    {
      title: "Network and downloads",
      description: "Static IP, Wi-Fi preset and KVM-side image download controls.",
      controls: [
        { label: "Set static IP", action: "static-ip", kind: "button", requiresConfirmation: true },
        { label: "Save Wi-Fi preset", action: "wifi-preset", kind: "button", requiresConfirmation: true },
        { label: "Download image", action: "image-download", kind: "button" },
        { label: "Pause", action: "image-download-pause", kind: "button" },
        { label: "Resume", action: "image-download-resume", kind: "button" },
        { label: "Cancel", action: "image-download-cancel", kind: "button", destructive: true },
      ],
    },
    {
      title: "Security and automation",
      description: "Signature verification, credentials, 2FA status, finger robot and installed apps.",
      controls: [
        { label: "Verify signatures", action: "signature-verification", kind: "toggle", requiresConfirmation: true },
        { label: "New password", action: "password-change", kind: "password" },
        { label: "Finger press", action: "finger-press", kind: "button", requiresConfirmation: true },
        { label: "Finger release", action: "finger-release", kind: "button" },
      ],
    },
  ],
  Settings: [
    {
      title: "Video",
      description: "Codec, quality, rate-control, GOP and frame rate.",
      controls: [
        { label: "Codec", action: "stream-codec", kind: "text" },
        { label: "Quality", action: "stream-quality", kind: "text" },
        { label: "Rate control", action: "stream-rate-control", kind: "text" },
        { label: "GOP", action: "stream-gop", kind: "text" },
        { label: "Frame rate", action: "stream-fps", kind: "text" },
      ],
    },
    {
      title: "Display and input",
      description: "Choose an available EDID or generate one for the monitor holding this window. EDID changes interrupt HDMI briefly; first confirm that the NanoKVM has its own USB-C power.",
      controls: [
        { label: "HDMI capture", action: "hdmi-capture", kind: "toggle" },
        { label: "External USB-C power connected", action: "edid-power-confirmed", kind: "toggle" },
        { label: "EDID", action: "edid-picker", kind: "select" },
        { label: "Upload EDID", action: "edid-upload", kind: "button", requiresConfirmation: true },
        { label: "Delete selected custom EDID", action: "edid-delete", kind: "button", destructive: true, requiresConfirmation: true },
        { label: "Auto-match display on connect", action: "edid-auto-switch", kind: "toggle", requiresConfirmation: true },
        { label: "Match local display", action: "edid-match-display", kind: "button", requiresConfirmation: true },
        { label: "Pointer mode", action: "pointer-mode", kind: "text" },
        { label: "Pointer sensitivity", action: "pointer-sensitivity", kind: "text" },
        { label: "Reset HID", action: "hid-reset", kind: "button" },
        { label: "Mouse jiggler", action: "mouse-jiggler", kind: "toggle" },
      ],
    },
  ],
};
import type { Page } from "./types";
