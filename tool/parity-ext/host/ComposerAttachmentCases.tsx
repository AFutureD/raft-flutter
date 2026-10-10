// raft-flutter parity EXTENSION cases: composer attachments (not official).
//
// Appended to the generated VisualTestingCases.tsx like host/ComputerCases.tsx
// (shares its imports and private helpers, e.g. primeVisualStores, fxChannels,
// fxMessages); identifiers are prefixed `parityExtCa`. Ids:
// components.composerattachments.<platform>.<kind>.<theme>.
//
// Mounts the REAL product `MessageInput` exactly like the official
// ComposerVisualCaseView (channel composer host, "As Task" toggle; the thread
// kind drops the toggle like ThreadPanel's composer) and then performs what a
// user does: the fixture files are put on the hidden file input (the same
// `change` event the picker fires) and, for the drag state, a file `dragenter`
// reaches the composer root. The upload endpoints are answered by the fixture
// routes (tool/parity-ext/fixtures/composer-attachments.json `routes` /
// `routeSets`): upload-capabilities (size ceiling), POST /attachments/upload
// (ready / hanging / failing). The element only gets `data-visual-case` once
// the expected state is on screen, so the capture waits for it.
import parityExtCaFixture from "virtual:parity-ext/composer-attachments";
import { useEffect as parityExtCaUseEffect, useState as parityExtCaUseState } from "react";

type ParityExtCaFileSpec = { kind: "image" | "file"; key: string; name?: string; padTo?: number };
type ParityExtCaKind = {
  files: ParityExtCaFileSpec[];
  draft?: string;
  routeSet?: string;
  progress?: number;
  drag?: boolean;
  hover?: boolean;
  thread?: boolean;
};

function parityExtCaProps() {
  const params = new URLSearchParams(window.location.search);
  const raw = params.get("case") ?? "";
  if (!raw.startsWith("components.composerattachments.") || params.get("extKind") !== "composerattachments") return null;
  const kind = (parityExtCaFixture.kinds as Record<string, ParityExtCaKind>)[params.get("kind") ?? ""];
  if (!kind) return null;
  return { raw, kind, width: Number(params.get("width") ?? 342) };
}

function parityExtCaBytes(spec: ParityExtCaFileSpec): { name: string; type: string; bytes: Uint8Array } {
  const fixture = parityExtCaFixture as unknown as {
    images: Record<string, string>;
    files: Record<string, { name: string; mime: string; text: string }>;
  };
  let bytes: Uint8Array;
  let name = spec.name ?? "";
  let type = "";
  if (spec.kind === "image") {
    const binary = atob(fixture.images[spec.key]);
    bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
    type = "image/png";
  } else {
    const file = fixture.files[spec.key];
    bytes = new TextEncoder().encode(file.text);
    name = file.name;
    type = file.mime;
  }
  if (spec.padTo && bytes.length < spec.padTo) {
    const padded = new Uint8Array(spec.padTo);
    padded.set(bytes);
    bytes = padded;
  }
  return { name, type, bytes };
}

function ParityExtCaView({ p }: { p: NonNullable<ReturnType<typeof parityExtCaProps>> }) {
  useMemo(() => {
    primeVisualStores({
      id: p.raw,
      visualCaseAttr: p.raw,
      draft: p.kind.draft ?? "",
      placeholder: p.kind.thread ? "Message thread" : fxMessages.composerPlaceholder,
    } as ComposerVisualCase);
  }, [p]);
  const [ready, setReady] = parityExtCaUseState(false);
  parityExtCaUseEffect(() => {
    let cancelled = false;
    (async () => {
      if (p.kind.progress !== undefined) {
        // The legacy upload reports progress through XHR upload events; the
        // hanging fixture route never answers, so deliver one progress event.
        const send = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.send = function (this: XMLHttpRequest, ...args: [Document | XMLHttpRequestBodyInit | null | undefined]) {
          const result = send.apply(this, args);
          window.setTimeout(() => {
            this.upload.dispatchEvent(new ProgressEvent("progress", {
              lengthComputable: true, loaded: p.kind.progress!, total: 100,
            }));
          }, 30);
          return result;
        } as typeof XMLHttpRequest.prototype.send;
      }
      const input = document.querySelector<HTMLInputElement>("[data-testid='composer-media-input']");
      if (!input) return;
      const transfer = new DataTransfer();
      for (const spec of p.kind.files) {
        const { name, type, bytes } = parityExtCaBytes(spec);
        transfer.items.add(new File([bytes as BlobPart], name, { type, lastModified: 1_700_000_000_000 }));
      }
      Object.defineProperty(input, "files", { value: transfer.files, configurable: true });
      input.dispatchEvent(new Event("change", { bubbles: true }));
      // Wait until the expected state is rendered, then let it settle.
      const expectCount = Math.min(p.kind.files.filter((f) => f.key !== "empty").length, 10);
      const deadline = Date.now() + 3000;
      while (!cancelled && Date.now() < deadline) {
        const chips = document.querySelectorAll("[data-slot='composer-attachment']").length;
        const failedRows = document.querySelectorAll("[role='alert']").length;
        const banner = document.querySelector("[data-slot='banner']");
        const images = Array.from(document.querySelectorAll<HTMLImageElement>("[data-slot='composer-attachment'] img"));
        const decoded = images.every((img) => img.complete && img.naturalWidth > 0);
        const done = p.kind.files.length === 0
          || (p.kind.routeSet === "composer-small-limit" || p.kind.files[0].key === "empty"
            ? Boolean(banner)
            : p.kind.routeSet === "composer-failed"
              ? failedRows >= p.kind.files.length
              : p.kind.files.length > 10 ? chips >= 10 && Boolean(banner) : chips >= expectCount);
        const overlayWanted = p.kind.routeSet === "composer-checking" || p.kind.routeSet === "composer-uploading";
        const overlays = document.querySelectorAll("[data-slot='composer-attachment-uploading-overlay']").length;
        const overlayOk = !overlayWanted || overlays >= expectCount;
        if (done && decoded && overlayOk) break;
        await new Promise((r) => window.setTimeout(r, 40));
      }
      if (p.kind.drag) {
        const root = document.querySelector("[data-slot='composer-root']") ?? document.querySelector("form");
        const drag = new DataTransfer();
        drag.items.add(new File(["x"], "drop.png", { type: "image/png" }));
        root?.dispatchEvent(new DragEvent("dragenter", { bubbles: true, cancelable: true, dataTransfer: drag }));
        await new Promise((r) => window.setTimeout(r, 80));
      }
      await new Promise((r) => window.setTimeout(r, 200));
      if (!cancelled) setReady(true);
    })();
    return () => { cancelled = true; };
  }, [p]);
  return (
    <main className="min-h-screen bg-white p-0 font-display text-black">
      <div
        data-visual-case={ready ? p.raw : undefined}
        data-visual-case-id={p.raw}
        style={{ width: p.width, boxSizing: "border-box" }}
      >
        <MessageInput
          channelId={VISUAL_CHANNEL_ID}
          channelName={fxChannels.design.name}
          showTaskButton={!p.kind.thread}
          placeholder={p.kind.thread ? "Message thread" : fxMessages.composerPlaceholder}
          onSendOverride={async () => undefined}
        />
      </div>
    </main>
  );
}

function parityExtComposerAttachmentsElement() {
  const p = parityExtCaProps();
  return p ? <ParityExtCaView p={p} /> : null;
}
