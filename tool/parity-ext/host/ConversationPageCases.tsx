// raft-flutter parity EXTENSION cases: conversation pages that had no case
// (inventory rows 3.03, 3.06-3.08, 3.11-3.14, 3.16, 3.18, 3.26-3.31, 3.34, 3.37-3.39; not official).
//
// Appended by tool/parity-ext-web.mjs to a generated copy of the pinned
// VisualTestingCases.tsx (shares its imports and fixture helpers; identifiers
// here are prefixed `parityExtCv`). Ids: components.conversation.<scene>.<platform>.<state>.<theme>.
//
// Each case mounts the REAL product surface and clips a window of it:
//   view=window -> message/ChatPanel (or ThreadPanel presentation="side") in the
//                  desktop main column (1280 - rail - 240 sidebar), the 400px side
//                  thread column or the 390 mobile page, like host/ThreadCases.tsx
//   view=row    -> message/MessageItem on a panel-coloured box (hover cards, menus,
//                  reactions, quotes, action cards, translation)
// Data: tool/parity-ext/fixtures/conversation.json (`routes` + `routeSets` are
// answered by the provider spec for React and by the fake client for Flutter).
import ParityExtCvThreadPanel from "../src/components/message/ThreadPanel";
import parityExtCvFixture from "virtual:parity-ext/conversation";
import type { CSSProperties as ParityExtCvCSSProperties } from "react";

type ParityExtCvProps = {
  caseId: string;
  extCase: string;
  view: "window" | "row";
  platform: "desktop" | "mobile";
  surface: "chat" | "thread";
  channel: string;
  winY: number;
  winH: number;
  serverRole: string;
  row: string;
  boxWidth: number | null;
  boxHeight: number | null;
};

function parityExtCvProps(): ParityExtCvProps | null {
  const params = new URLSearchParams(window.location.search);
  const raw = params.get("case") ?? "";
  if (!raw.startsWith("components.conversation.") || params.get("extKind") !== "conversation") return null;
  const num = (key: string) => {
    const value = params.get(key);
    return value ? Number(value) : null;
  };
  return {
    caseId: raw,
    extCase: params.get("extCase") ?? "",
    view: params.get("view") === "row" ? "row" : "window",
    platform: params.get("platform") === "mobile" ? "mobile" : "desktop",
    surface: params.get("surface") === "thread" ? "thread" : "chat",
    channel: params.get("channel") ?? "",
    winY: Number(params.get("winY") ?? 0),
    winH: Number(params.get("winH") ?? 120),
    serverRole: params.get("serverRole") ?? "owner",
    row: params.get("row") ?? "",
    boxWidth: num("boxWidth"),
    boxHeight: num("boxHeight"),
  };
}

function parityExtCvTheme(): string {
  return new URLSearchParams(window.location.search).get("parityTheme") ?? "brutal-light";
}

function parityExtCvPrimeStores(p: ParityExtCvProps) {
  primeDirectVisualStores(p.caseId);
  useChannelStore.setState({
    channels: parityExtCvFixture.channels as never,
    dmChannels: parityExtCvFixture.dms as never,
    loading: false,
  });
  useMessageStore.setState({ currentChannelId: p.channel || null, currentUserId: fxOwner.id });
  if (p.serverRole !== "owner") {
    useServerStore.setState((s) => ({ current: s.current ? { ...s.current, role: p.serverRole as never } : s.current }));
  }
}

function ParityExtCvWindowView({ p }: { p: ParityExtCvProps }) {
  useMemo(() => parityExtCvPrimeStores(p), [p]);
  const brutal = parityExtCvTheme() === "brutal-light";
  // AppShell root sets the header height the PanelHeader recipe reads.
  const shellVars = { ["--shell-header-height" as string]: brutal ? "62px" : "56px" } as ParityExtCvCSSProperties;
  const mobile = p.platform === "mobile";
  const viewportHeight = window.innerHeight;
  const width = mobile ? 390 : p.surface === "thread" ? 400 : 1280 - (brutal ? 64 : 56) - 240;
  const channel = useChannelStore((s) => [...s.channels, ...s.dmChannels].find((c) => c.id === p.channel) ?? null);
  const t = parityExtCvFixture.thread;
  const top = p.winY < 0 ? viewportHeight + p.winY : p.winY;
  return (
    <main className="min-h-screen bg-white p-0 font-display text-black">
      <div data-visual-case={p.caseId} style={{ ...shellVars, width, height: p.winH, overflow: "hidden", position: "relative" }}>
        <div
          // The transform also makes the column the containing block of the
          // mobile page's `fixed` header, so a window cannot leak it.
          className={p.surface === "thread"
            ? `${mobile ? "thread-side-column " : ""}flex flex-col bg-layer-card theme-brutal:bg-white`
            : "flex flex-col"}
          style={{ width, height: viewportHeight, position: "absolute", left: 0, top: 0, transform: `translateY(${-top}px)` }}
        >
          {p.surface === "thread" ? (
            <ParityExtCvThreadPanel
              presentation="side"
              threadIdentity={{ parentMessageId: t.parentMessageId, parentChannelId: t.parentChannelId, threadChannelId: t.threadChannelId }}
              onClose={() => undefined}
            />
          ) : (
            <ChatPanel channel={channel} />
          )}
        </div>
      </div>
    </main>
  );
}

function parityExtConversationElement() {
  const p = parityExtCvProps();
  if (!p) return null;
  return <ParityExtCvWindowView p={p} />;
}
