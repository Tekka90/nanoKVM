import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { eventCodeToHid } from "./keyboard";
import { appendSample, sampleStats, summarize, type StatBaseline, type StatSample } from "./stats";
import { sections, type Control } from "./catalog";
import {
  pageFromHash,
  pages,
  type FeatureState,
  type LoginCommandResult,
  type Page,
  type PageSnapshot,
  type RealtimeStatus,
  type SavedDevice,
  type StreamStats,
  type UploadProgress,
} from "./types";
import "./style.css";

const app = (() => {
  const root = document.querySelector<HTMLDivElement>("#app");
  if (!root) throw new Error("Application root is missing");
  return root;
})();

const state = {
  connectedId: "",
  pointerMode: "absolute" as "absolute" | "relative",
  pointerSensitivity: Number(window.localStorage.getItem("pointer-sensitivity") ?? "1"),
  codec: "h265" as "h264" | "h265",
  pressedKeys: new Set<number>(),
  stickyModifiers: 0,
  pointerButtons: 0,
  listeners: [] as UnlistenFn[],
  statsBaseline: null as StatBaseline | null,
  statsHistory: [] as StatSample[],
};

function html(value: unknown): string {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function navigate(page: Page): void {
  window.location.hash = page.toLowerCase();
  void render(page);
}

function controlMarkup(control: Control): string {
  const classes = [
    control.destructive ? "destructive" : "",
    control.requiresConfirmation ? "confirm" : "",
  ]
    .filter(Boolean)
    .join(" ");
  const connected = state.connectedId ? "" : " disabled";
  if (control.kind === "text" || control.kind === "password") {
    const appliesOnChange = control.action === "wol-mac" || control.action === "wol-name"
      ? ""
      : ` data-action="${control.action}"`;
    const value =
      control.action === "pointer-sensitivity"
        ? ` value="${state.pointerSensitivity}"`
        : "";
    return `<label class="field"><span>${html(control.label)}</span><input type="${control.kind}" data-value-for="${control.action}"${appliesOnChange}${value} autocomplete="off"${connected} /></label>`;
  }
  if (control.kind === "toggle") {
    const checked =
      control.action === "edid-auto-switch" &&
      window.localStorage.getItem("edid-auto-switch") === "true"
        ? " checked"
        : "";
    return `<label class="toggle"><span>${html(control.label)}</span><input type="checkbox" data-action="${control.action}"${checked}${connected} /></label>`;
  }
  return `<button class="${classes}" data-action="${control.action}"${connected}>${html(control.label)}</button>`;
}

function pageBody(page: Page, features: FeatureState[]): string {
  if (page === "Screen") {
    return `
      <section class="screen">
        <div class="native-surface" tabindex="0" id="video-surface" aria-label="NanoKVM video and input surface">
          <span class="status-dot"></span>
          <h2>Native realtime surface</h2>
          <p id="screen-status">${
            state.connectedId
              ? "Connecting video and HID…"
              : "Connect a device to start video and HID."
          }</p>
          <p class="capability-note">${
            features.find((feature) => feature.name === "screen")?.detail ?? ""
          }</p>
          <dl id="stream-stats"></dl>
        </div>
        <div class="screen-actions">
          <button data-action="hid-paste" ${state.connectedId ? "" : "disabled"}>Paste</button>
          <button data-action="send-control-alt-delete" ${state.connectedId ? "" : "disabled"}>Ctrl+Alt+Del</button>
          <button data-action="reconnect" ${state.connectedId ? "" : "disabled"}>Reconnect</button>
        </div>
      </section>`;
  }
  return `<div class="page-grid">${(sections[page] ?? [])
    .map(
      (section) => `
      <section class="page-card">
        <h2>${html(section.title)}</h2>
        <p>${html(section.description)}</p>
        <div class="controls">${section.controls.map(controlMarkup).join("")}</div>
      </section>`,
    )
    .join("")}
    <section class="page-card page-state">
      <h2>Device state</h2>
      <pre id="page-state">${state.connectedId ? "Loading…" : "Connect a device to load state."}</pre>
    </section>
    <section class="page-card integration-status">
      <h2>Capabilities</h2>
      <dl>${features
        .map(
          (feature) =>
            `<div><dt>${html(feature.name)}</dt><dd>${feature.available ? "Available" : "Unavailable"}</dd><dd>${html(feature.detail)}</dd></div>`,
        )
        .join("")}</dl>
    </section></div>`;
}

async function render(page = pageFromHash(window.location.hash)): Promise<void> {
  let features: FeatureState[] = [];
  let devices: SavedDevice[] = [];
  let loadError = "";
  try {
    [features, devices] = await Promise.all([
      invoke<FeatureState[]>("app_features"),
      invoke<SavedDevice[]>("list_devices"),
    ]);
  } catch (error) {
    loadError = String(error);
  }
  if (state.connectedId && !devices.some((device) => device.id === state.connectedId)) {
    state.connectedId = "";
  }

  app.innerHTML = `
    <div class="shell">
      <aside class="rail">
        <div class="brand">NanoKVM</div>
        <nav>${pages
          .map(
            (candidate) =>
              `<button data-page="${candidate}" class="${candidate === page ? "active" : ""}">${candidate}</button>`,
          )
          .join("")}</nav>
        <div class="rail-actions">
          <button data-open-keys ${state.connectedId ? "" : "disabled"}>Keys</button>
          <button data-action="hid-paste" ${state.connectedId ? "" : "disabled"}>Paste</button>
          <button data-action="reconnect" ${state.connectedId ? "" : "disabled"}>Reconnect</button>
          <button id="fullscreen">Full Screen</button>
          <button id="discover">Discover</button>
        </div>
      </aside>
      <main>
        <header>
          <div class="header-context">
            <span>${page}</span>
            <select id="device-selector" aria-label="Device">
              <option value="">${devices.length ? "Choose a device" : "No saved device"}</option>
              ${devices
                .map(
                  (device) =>
                    `<option value="${device.id}" data-name="${html(device.name)}" data-address="${html(device.address)}" data-username="${html(device.username)}" ${device.id === state.connectedId ? "selected" : ""}>${html(device.name)}</option>`,
                )
                .join("")}
            </select>
            <button id="connect-device" ${devices.length ? "" : "disabled"}>${state.connectedId ? "Reconnect" : "Connect"}</button>
            <button id="edit-device" ${devices.length ? "" : "disabled"}>Edit</button>
            <button id="remove-device" class="destructive" ${devices.length ? "" : "disabled"}>Remove</button>
          </div>
          <button id="add-device">Add device</button>
        </header>
        <div id="global-error" class="global-error" role="alert">${html(loadError)}</div>
        <div id="action-result" class="global-result" role="status"></div>
        ${pageBody(page, features)}
      </main>
    </div>
    <dialog id="device-dialog">
      <form id="device-form" method="dialog">
        <h2>Add device</h2>
        <label>Name<input name="name" required autocomplete="off" /></label>
        <label>Address<input name="address" required placeholder="https://192.168.1.100" autocomplete="url" /></label>
        <label>Username<input name="username" required autocomplete="username" /></label>
        <label>Password<input name="password" type="password" autocomplete="current-password" /></label>
        <p class="form-error" role="alert"></p>
        <div class="dialog-actions">
          <button value="cancel" formnovalidate>Cancel</button>
          <button value="save">Save device</button>
        </div>
      </form>
    </dialog>
    <dialog id="keys-dialog">
      <form method="dialog">
        <h2>Send key</h2>
        <div class="sticky-modifiers">
          <button type="button" data-sticky-modifier="1">Ctrl</button>
          <button type="button" data-sticky-modifier="2">Shift</button>
          <button type="button" data-sticky-modifier="4">Alt</button>
          <button type="button" data-sticky-modifier="8">Win</button>
        </div>
        <div class="shortcut-grid">
          ${[
            ["Escape", 41],
            ["Tab", 43],
            ["F1", 58],
            ["F2", 59],
            ["F3", 60],
            ["F4", 61],
            ["F5", 62],
            ["F6", 63],
            ["F7", 64],
            ["F8", 65],
            ["F9", 66],
            ["F10", 67],
            ["F11", 68],
            ["F12", 69],
            ["Print Screen", 70],
            ["Scroll Lock", 71],
            ["Pause", 72],
          ]
            .map(([label, code]) => `<button type="button" data-special-key="${code}">${label}</button>`)
            .join("")}
        </div>
        <button>Close</button>
      </form>
    </dialog>`;

  bindNavigation();
  bindDeviceActions(page);
  bindSurfaceInput();
  await loadPageState(page);
}

function setError(message: unknown): void {
  const target = app.querySelector<HTMLElement>("#global-error");
  if (target) target.textContent = String(message);
}

function setResult(message: unknown): void {
  const target = app.querySelector<HTMLElement>("#action-result");
  if (target) target.textContent = String(message);
}

function selectedDeviceId(): string {
  return (
    state.connectedId ||
    app.querySelector<HTMLSelectElement>("#device-selector")?.value ||
    ""
  );
}

function bindNavigation(): void {
  app.querySelectorAll<HTMLButtonElement>("[data-page]").forEach((button) => {
    button.addEventListener("click", () => navigate(button.dataset.page as Page));
  });
  app
    .querySelector("#fullscreen")
    ?.addEventListener("click", () => document.documentElement.requestFullscreen());
  document.addEventListener("fullscreenchange", () => {
    document.body.classList.toggle("native-fullscreen", Boolean(document.fullscreenElement));
  });
  document.addEventListener("pointermove", (event) => {
    document.body.classList.toggle(
      "reveal-rail",
      Boolean(document.fullscreenElement) && event.clientX < 64,
    );
  });
  const dialog = app.querySelector<HTMLDialogElement>("#device-dialog");
  app.querySelector("#add-device")?.addEventListener("click", () => {
    app.querySelector<HTMLFormElement>("#device-form")?.reset();
    const form = app.querySelector<HTMLFormElement>("#device-form");
    if (form) delete form.dataset.id;
    dialog?.showModal();
  });
  app.querySelector("#edit-device")?.addEventListener("click", () => {
    const option = app.querySelector<HTMLSelectElement>("#device-selector")?.selectedOptions[0];
    const form = app.querySelector<HTMLFormElement>("#device-form");
    if (!option?.value || !form) {
      setError("Choose a device to edit.");
      return;
    }
    form.dataset.id = option.value;
    (form.elements.namedItem("name") as HTMLInputElement).value = option.dataset.name ?? "";
    (form.elements.namedItem("address") as HTMLInputElement).value = option.dataset.address ?? "";
    (form.elements.namedItem("username") as HTMLInputElement).value = option.dataset.username ?? "";
    (form.elements.namedItem("password") as HTMLInputElement).value = "";
    dialog?.showModal();
  });
  app.querySelector("#remove-device")?.addEventListener("click", async () => {
    const selector = app.querySelector<HTMLSelectElement>("#device-selector");
    if (!selector?.value) return setError("Choose a device to remove.");
    if (!window.confirm("Remove this saved device and its stored password?")) return;
    try {
      await invoke("remove_device", { id: selector.value });
      if (state.connectedId === selector.value) state.connectedId = "";
      await render();
    } catch (error) {
      setError(error);
    }
  });
  app.querySelector<HTMLDialogElement>("#keys-dialog");
  app.querySelector("[data-open-keys]")?.addEventListener("click", () => {
    app.querySelector<HTMLDialogElement>("#keys-dialog")?.showModal();
  });
  app.querySelectorAll<HTMLButtonElement>("[data-special-key]").forEach((button) => {
    button.addEventListener("click", () => {
      void tapKeys([Number(button.dataset.specialKey)], state.stickyModifiers);
    });
  });
  app.querySelectorAll<HTMLButtonElement>("[data-sticky-modifier]").forEach((button) => {
    button.addEventListener("click", () => {
      const mask = Number(button.dataset.stickyModifier);
      state.stickyModifiers ^= mask;
      button.classList.toggle("active", (state.stickyModifiers & mask) !== 0);
    });
  });
  app.querySelector("#discover")?.addEventListener("click", async () => {
    try {
      const found = await invoke<{ name: string; address: string }[]>("discover_devices");
      if (!found.length) {
        setError("No NanoKVM advertised by mDNS was found.");
        return;
      }
      const chosen = window.prompt(
        `Discovered devices:\\n${found
          .map((device, index) => `${index + 1}. ${device.name} — ${device.address}`)
          .join("\\n")}\\n\\nEnter a number to add.`,
      );
      const device = found[Number(chosen) - 1];
      if (device) {
        const address = app.querySelector<HTMLInputElement>('[name="address"]');
        const name = app.querySelector<HTMLInputElement>('[name="name"]');
        if (address) address.value = device.address;
        if (name) name.value = device.name;
        dialog?.showModal();
      }
    } catch (error) {
      setError(error);
    }
  });
}

function bindDeviceActions(page: Page): void {
  app.querySelector("#connect-device")?.addEventListener("click", connectSelected);
  app.querySelector<HTMLFormElement>("#device-form")?.addEventListener("submit", saveDevice);
  app.querySelectorAll<HTMLInputElement | HTMLButtonElement>("[data-action]").forEach((control) => {
    if (control instanceof HTMLInputElement && control.type === "checkbox") {
      control.addEventListener("change", () => {
        if (control.dataset.action) void runControl(control, page);
      });
    } else if (control instanceof HTMLInputElement) {
      control.addEventListener("change", () => {
        if (control.dataset.action) void runControl(control, page);
      });
    } else {
      control.addEventListener("click", () => {
        if (control.dataset.action) void runControl(control, page);
      });
    }
  });
}

async function connectSelected(): Promise<void> {
  const selector = app.querySelector<HTMLSelectElement>("#device-selector");
  const id = selector?.value;
  if (!id) {
    setError("Choose a device first.");
    selector?.focus();
    return;
  }
  try {
    if (state.connectedId) {
      await invoke("stop_realtime", { id: state.connectedId }).catch(() => undefined);
    }
    let result = await invoke<LoginCommandResult>("connect_device", { id });
    if (result.status === "requires_two_factor") {
      const code = window.prompt("Two-factor authentication code");
      if (!code) {
        setError("Connection cancelled: no two-factor code.");
        return;
      }
      result = await invoke<LoginCommandResult>("complete_two_factor", { id, code });
    }
    if (result.status !== "authenticated") throw new Error("Authentication did not complete.");
    state.connectedId = id;
    state.statsBaseline = null;
    state.statsHistory = [];
    await render();
    const codec = state.codec;
    await invoke("start_realtime", { id, codec });
    if (window.localStorage.getItem("edid-auto-switch") === "true") {
      try {
        const matched = await invoke<string>("match_local_edid", {
          id,
          refresh: 60,
          confirmed: true,
        });
        setResult(matched);
      } catch (error) {
        setError(`Automatic EDID match failed; the KVM remains connected: ${String(error)}`);
      }
    }
  } catch (error) {
    state.connectedId = "";
    setError(error);
  }
}

async function saveDevice(event: SubmitEvent): Promise<void> {
  event.preventDefault();
  const form = event.currentTarget as HTMLFormElement;
  const submitter = event.submitter as HTMLButtonElement | null;
  const dialog = app.querySelector<HTMLDialogElement>("#device-dialog");
  if (submitter?.value === "cancel") {
    dialog?.close();
    return;
  }
  const data = new FormData(form);
  try {
    const saved = await invoke<SavedDevice>("save_device", {
      id: form.dataset.id ?? null,
      name: String(data.get("name") ?? ""),
      address: String(data.get("address") ?? ""),
      username: String(data.get("username") ?? ""),
      password: String(data.get("password") ?? "") || null,
    });
    state.connectedId = "";
    dialog?.close();
    await render();
    const selector = app.querySelector<HTMLSelectElement>("#device-selector");
    if (selector) selector.value = saved.id;
  } catch (error) {
    const message = form.querySelector<HTMLElement>(".form-error");
    if (message) message.textContent = String(error);
  }
}

async function loadPageState(page: Page): Promise<void> {
  const target = app.querySelector<HTMLElement>("#page-state");
  if (!target || !state.connectedId) return;
  try {
    const snapshot = await invoke<PageSnapshot>("load_page_state", {
      id: state.connectedId,
      page,
    });
    target.textContent = JSON.stringify(snapshot, null, 2);
  } catch (error) {
    target.textContent = `State unavailable: ${String(error)}`;
  }
}

async function runControl(control: HTMLInputElement | HTMLButtonElement, page: Page): Promise<void> {
  const action = control.dataset.action ?? "";
  const id = selectedDeviceId();
  if (!id) return setError("Connect a device first.");
  try {
    if (action === "edid-auto-switch" && control instanceof HTMLInputElement) {
      const confirmed =
        !control.checked ||
        window.confirm(
          "Allow automatic EDID changes? This briefly interrupts video after each connection.",
        );
      if (!confirmed) {
        control.checked = false;
        return;
      }
      window.localStorage.setItem("edid-auto-switch", String(control.checked));
      setResult(`Automatic EDID matching ${control.checked ? "enabled" : "disabled"}.`);
      return;
    }
    if (action === "pointer-sensitivity" && control instanceof HTMLInputElement) {
      const sensitivity = Number(control.value);
      if (!Number.isFinite(sensitivity) || sensitivity <= 0 || sensitivity > 10) {
        setError("Pointer sensitivity must be greater than 0 and at most 10.");
        return;
      }
      state.pointerSensitivity = sensitivity;
      window.localStorage.setItem("pointer-sensitivity", String(sensitivity));
      setResult(`Pointer sensitivity set to ${sensitivity}.`);
      return;
    }
    if (action === "reconnect") {
      await connectSelected();
      return;
    }
    if (action === "hid-paste") {
      const content = window.prompt("Text to paste on the remote host");
      if (content === null) return;
      await invokeAction(id, action, { content }, false, null, null);
    } else if (action === "send-control-alt-delete") {
      await tapKeys([76], 5 | state.stickyModifiers);
    } else if (action === "image-upload" || action === "edid-upload" || action === "script-upload") {
      await pickAndUpload(action, id);
    } else if (action === "edid-match-display") {
      const confirmed = window.confirm(
        "Generate an EDID for this monitor and briefly interrupt the KVM video signal?",
      );
      if (!confirmed) return;
      const refresh = Number(window.prompt("Refresh rate in Hz", "60") ?? "0");
      const result = await invoke<string>("match_local_edid", {
        id,
        refresh: Number.isFinite(refresh) && refresh > 0 ? refresh : 60,
        confirmed,
      });
      setResult(result);
    } else if (control instanceof HTMLInputElement && control.type === "checkbox") {
      await invokeAction(id, action, { enabled: control.checked, mode: "relative" }, false, null, null);
    } else {
      const payload = payloadForAction(action);
      if (!payload) return;
      const confirmed = control.classList.contains("confirm")
        ? window.confirm(`Run “${action}”? This action may affect the KVM or disconnect it.`)
        : false;
      if (control.classList.contains("confirm") && !confirmed) return;
      const sensitive = await sensitiveCode(action);
      const result = await invokeAction(
        id,
        action,
        payload,
        confirmed,
        sensitive.code,
        sensitive.password,
      );
      if (action === "pointer-mode") {
        state.pointerMode = String(payload.value) === "relative" ? "relative" : "absolute";
      }
      if (action === "stream-codec") {
        state.codec = String(payload.value).toLowerCase().includes("h264") ? "h264" : "h265";
      }
      if (action === "mcp-copy-config") {
        await navigator.clipboard.writeText(JSON.stringify(result.value));
        setResult("MCP configuration copied to the clipboard.");
      } else {
        setError("");
        setResult(JSON.stringify(result.value, null, 2));
      }
    }
    await loadPageState(page);
  } catch (error) {
    setError(error);
  }
}

async function invokeAction(
  id: string,
  action: string,
  payload: Record<string, unknown>,
  confirmed: boolean,
  twoFactorCode: string | null,
  password: string | null,
): Promise<{ value: unknown }> {
  return invoke("device_action", {
    id,
    action,
    payload,
    confirmed,
    twoFactorCode,
    password,
  });
}

function promptValue(label: string): string | null {
  return window.prompt(label);
}

function payloadForAction(action: string): Record<string, unknown> | null {
  switch (action) {
    case "wol-save":
      return {
        mac: app.querySelector<HTMLInputElement>('[data-value-for="wol-mac"]')?.value ?? "",
        name: app.querySelector<HTMLInputElement>('[data-value-for="wol-name"]')?.value ?? "",
      };
    case "wol-wake":
      return { mac: promptValue("MAC address") };
    case "wol-delete":
      return { name: promptValue("Saved host name") };
    case "hostname":
      return {
        hostname: app.querySelector<HTMLInputElement>('[data-value-for="hostname"]')?.value,
      };
    case "stream-quality":
    case "stream-gop":
    case "stream-fps":
      return {
        value: Number(app.querySelector<HTMLInputElement>(`[data-value-for="${action}"]`)?.value),
      };
    case "stream-codec":
    case "stream-rate-control":
    case "pointer-mode":
      return {
        value: app.querySelector<HTMLInputElement>(`[data-value-for="${action}"]`)?.value,
      };
    case "wifi-connect":
      return { ssid: promptValue("Wi-Fi SSID"), password: promptValue("Wi-Fi password") };
    case "script-foreground":
    case "script-background":
    case "script-delete":
      return { name: promptValue("Script name") };
    case "static-ip":
      return {
        enabled: window.confirm("Enable static IP? Choose Cancel for DHCP."),
        ip: promptValue("Static IPv4 address"),
      };
    case "wifi-preset":
      return { ssid: promptValue("Preset SSID"), password: promptValue("Preset password") };
    case "image-download":
      return { url: promptValue("Image URL"), checksum: promptValue("Expected checksum (optional)") };
    case "password-change":
      return {
        username: promptValue("Username"),
        new_password: promptValue("New password"),
      };
    case "image-mount":
      return {
        file: promptValue("Remote image file name"),
        cdrom: window.confirm("Mount as CD-ROM? Cancel means disk."),
        read_only: window.confirm("Mount read-only?"),
      };
    case "image-unmount":
    case "image-delete":
      return action === "image-delete" ? { file: promptValue("Remote image file name") } : {};
    case "edid-match-display":
    case "edid-set":
    case "edid-delete":
      return { name: promptValue("EDID preset file name") };
    case "usb-id":
      return {
        enabled: true,
        vid: promptValue("Vendor ID"),
        pid: promptValue("Product ID"),
        bcdDevice: promptValue("BCD device"),
        serialnumber: promptValue("Serial number"),
        manufacturer: promptValue("Manufacturer"),
        product: promptValue("Product"),
      };
    case "usb-network":
      return {
        mode: promptValue("Mode"),
        ipv4: promptValue("IPv4 network"),
        forwarding: window.confirm("Enable IP forwarding?"),
      };
    case "usb-name-cdrom":
    case "usb-name-disk":
    case "usb-name-audio":
      return {
        enabled: window.confirm("Enable this custom reported name? Choose Cancel to restore default."),
        value: promptValue("Reported device name"),
      };
    case "virtual-audio":
      return { mode: promptValue("Audio mode: off, mic, or duplex") };
    case "mouse-jiggler":
      return { enabled: true, mode: "relative" };
    case "mcp-copy-config":
    case "mcp-regenerate":
    case "wifi-disconnect":
    case "tailscale-logout":
    case "tailscale-install":
    case "tailscale-login":
    case "tailscale-start":
    case "tailscale-up":
    case "tailscale-down":
    case "tailscale-stop":
    case "tailscale-restart":
    case "time-sync":
    case "firmware-update":
    case "reboot":
    case "virtual-refresh":
    case "virtual-disk-disable":
    case "image-download-pause":
    case "image-download-resume":
    case "image-download-cancel":
    case "finger-press":
    case "finger-release":
    case "hid-reset":
      return {};
    default:
      setError(`No parameter collector exists for action ${action}.`);
      return null;
  }
}

async function sensitiveCode(
  action: string,
): Promise<{ code: string | null; password: string | null }> {
  const sensitive = new Set([
    "ssh",
    "tailscale-exit-node",
    "tailscale-subnet-route",
    "tailscale-logout",
    "tailscale-install",
    "tailscale-login",
    "tailscale-start",
    "tailscale-up",
    "tailscale-down",
    "tailscale-stop",
    "tailscale-restart",
    "mcp-copy-config",
    "mcp-regenerate",
    "mcp-enable",
    "memory-fabric",
    "timelapse",
    "reboot",
    "image-delete",
    "signature-verification",
    "script-foreground",
    "script-background",
    "script-delete",
    "finger-press",
    "finger-release",
    "password-change",
  ]);
  if (!sensitive.has(action)) return { code: null, password: null };
  return {
    code: window.prompt("Two-factor code for this sensitive action"),
    password:
      action === "password-change"
        ? window.prompt("Current password")
        : null,
  };
}

async function pickAndUpload(action: string, id: string): Promise<void> {
  const input = document.createElement("input");
  input.type = "file";
  input.accept =
    action === "image-upload"
      ? ".iso,.img"
      : action === "edid-upload"
        ? ".bin,.dat,.edid"
        : "*/*";
  input.click();
  const file = await new Promise<File | null>((resolve) => {
    input.addEventListener("change", () => resolve(input.files?.[0] ?? null), { once: true });
  });
  if (!file) return;
  const kind =
    action === "image-upload" ? "image" : action === "edid-upload" ? "edid" : "script";
  if (kind === "edid") {
    const confirmed = window.confirm(
      "Changing EDID briefly interrupts the video signal. Continue?",
    );
    if (!confirmed) return;
  }
  await invoke("upload_file", {
    id,
    kind,
    fileName: file.name,
    contentType: file.type || null,
    bytes: Array.from(new Uint8Array(await file.arrayBuffer())),
  });
}

function bindSurfaceInput(): void {
  const surface = app.querySelector<HTMLElement>("#video-surface");
  if (!surface) return;
  surface.addEventListener("contextmenu", (event) => event.preventDefault());
  surface.addEventListener("pointerdown", (event) => {
    surface.focus();
    surface.setPointerCapture(event.pointerId);
    state.pointerButtons = 1 << event.button;
    void sendPointer(event, 0);
  });
  surface.addEventListener("pointermove", (event) => {
    if (!state.connectedId) return;
    void sendPointer(event, 0);
  });
  surface.addEventListener("pointerup", (event) => {
    state.pointerButtons = 0;
    void sendPointer(event, 0);
    surface.releasePointerCapture(event.pointerId);
  });
  surface.addEventListener("wheel", (event) => {
    event.preventDefault();
    void sendPointer(event, Math.round(-event.deltaY));
  }, { passive: false });
  surface.addEventListener("keydown", (event) => {
    event.preventDefault();
    const code = eventCodeToHid(event.code);
    if (code === null) {
      setError(`Keyboard key ${event.code} is not mapped to a HID usage.`);
      return;
    }
    if (state.pressedKeys.size < 6) state.pressedKeys.add(code);
    void sendKeys([...state.pressedKeys], modifierMask(event) | state.stickyModifiers);
  });
  surface.addEventListener("keyup", (event) => {
    event.preventDefault();
    const code = eventCodeToHid(event.code);
    if (code !== null) state.pressedKeys.delete(code);
    void sendKeys([...state.pressedKeys], modifierMask(event) | state.stickyModifiers);
  });
  window.addEventListener("blur", releaseInput);
}

async function sendPointer(
  event: PointerEvent | WheelEvent,
  wheel: number,
): Promise<void> {
  if (!state.connectedId) return;
  const surface = event.currentTarget as HTMLElement;
  const rect = surface.getBoundingClientRect();
  try {
    if (state.pointerMode === "absolute") {
      await invoke("send_hid_input", {
        id: state.connectedId,
        input: {
          kind: "absolute_pointer",
          buttons: state.pointerButtons,
          x: (event.clientX - rect.left) / Math.max(1, rect.width),
          y: (event.clientY - rect.top) / Math.max(1, rect.height),
          wheel,
        },
      });
    } else {
      const movement = event as PointerEvent;
      await invoke("send_hid_input", {
        id: state.connectedId,
        input: {
          kind: "relative_pointer",
          buttons: state.pointerButtons,
          dx: "movementX" in movement
            ? Math.round(movement.movementX * state.pointerSensitivity)
            : 0,
          dy: "movementY" in movement
            ? Math.round(movement.movementY * state.pointerSensitivity)
            : 0,
          wheel,
        },
      });
    }
  } catch (error) {
    setError(error);
  }
}

async function sendKeys(keys: number[], modifiers: number): Promise<void> {
  if (!state.connectedId) return;
  await invoke("send_hid_input", {
    id: state.connectedId,
    input: { kind: "keyboard", modifiers, keys: keys.slice(0, 6) },
  });
}

async function tapKeys(keys: number[], modifiers: number): Promise<void> {
  await sendKeys(keys, modifiers);
  await sendKeys([], 0);
}

async function releaseInput(): Promise<void> {
  state.pressedKeys.clear();
  state.pointerButtons = 0;
  if (!state.connectedId) return;
  try {
    await sendKeys([], 0);
    await invoke("send_hid_input", {
      id: state.connectedId,
      input: { kind: "release" },
    });
  } catch (error) {
    setError(error);
  }
}

function modifierMask(event: KeyboardEvent): number {
  return (
    (event.ctrlKey ? 1 : 0) |
    (event.shiftKey ? 2 : 0) |
    (event.altKey ? 4 : 0) |
    (event.metaKey ? 8 : 0)
  );
}

async function installEventListeners(): Promise<void> {
  for (const unlisten of state.listeners) unlisten();
  state.listeners = [
    await listen<RealtimeStatus>("realtime://status", ({ payload }) => {
      if (payload.deviceId !== state.connectedId) return;
      const target = app.querySelector<HTMLElement>("#screen-status");
      if (!target) return;
      target.textContent = payload.connected
        ? `${payload.channel.toUpperCase()} connected`
        : `${payload.channel.toUpperCase()} error: ${payload.error ?? "disconnected"} (attempt ${payload.attempts})`;
      if (!payload.connected && payload.error) setError(payload.error);
    }),
    await listen<StreamStats>("realtime://stats", ({ payload }) => {
      if (payload.deviceId !== state.connectedId) return;
      const target = app.querySelector<HTMLElement>("#stream-stats");
      if (!target) return;
      const measured = sampleStats(
        state.statsBaseline,
        payload,
        performance.now(),
      );
      state.statsBaseline = measured.baseline;
      state.statsHistory = appendSample(state.statsHistory, measured.sample);
      const summary = summarize(state.statsHistory);
      const dimensions =
        payload.width && payload.height
          ? `${payload.width}×${payload.height}`
          : "pending";
      target.innerHTML = `
        <div><dt>Codec</dt><dd>${payload.codec}</dd></div>
        <div><dt>Dimensions</dt><dd>${dimensions}</dd></div>
        <div><dt>Packets</dt><dd>${payload.packets}</dd></div>
        <div><dt>Bytes</dt><dd>${payload.bytes}</dd></div>
        <div><dt>Keyframes</dt><dd>${payload.keyframes}</dd></div>
        <div><dt>FPS</dt><dd>${measured.sample?.fps.toFixed(1) ?? "0.0"}</dd></div>
        <div><dt>Bitrate avg</dt><dd>${summary.averageKbps.toFixed(0)} kbps</dd></div>
        <div><dt>Bitrate peak</dt><dd>${summary.peakKbps.toFixed(0)} kbps</dd></div>
        <div class="stats-history">${state.statsHistory
          .map(
            (sample) =>
              `<i style="height:${Math.max(2, (sample.kbps / Math.max(1, summary.peakKbps)) * 44)}px"></i>`,
          )
          .join("")}</div>`;
    }),
    await listen<UploadProgress>("upload://progress", ({ payload }) => {
      const percent = Math.round((payload.bytesSent / Math.max(1, payload.totalBytes)) * 100);
      setResult(`Uploading: ${percent}% (${payload.chunkIndex + 1}/${payload.totalChunks})`);
    }),
  ];
}

window.addEventListener("hashchange", () => void render());
void installEventListeners();
void render();
