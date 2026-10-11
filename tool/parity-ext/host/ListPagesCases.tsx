// raft-flutter parity EXTENSION cases (not part of the official case set):
// list-style pages that had no case: Search page states, Activity filters and
// context menu, Saved list / actions, Tasks filters / views / status menu,
// the desktop notification center and channel / section dialogs.
//
// tool/parity-ext-web.mjs appends this file to a generated copy of the pinned
// packages/web/visual-testing/VisualTestingCases.tsx (the Source checkout is never
// edited), so it shares that module's imports and private fixture helpers
// (primeDirectVisualStores, fxServer, ThreadsInbox, SavedPanel, TasksPanel,
// MessageSearchPage, useInboxStore, ...). Identifiers introduced here are
// prefixed `parityExtLp` / `ParityExtLp`. Ids: components.list-pages.<key>.<theme>
// (tool/parity-ext/build-list-pages.py). API reads are answered from
// tool/parity-ext/fixtures/listpages.json (`routes` + the case's `routeSet`), the
// same file the Flutter provider reads.
import parityExtLpFixture from "virtual:parity-ext/listpages";

type ParityExtLpProps = {
  raw: string;
  extCase: string;
  extKind: string;
  platform: "desktop" | "mobile";
  params: URLSearchParams;
};

function parityExtLpProps(): ParityExtLpProps | null {
  const params = new URLSearchParams(window.location.search);
  const raw = params.get("case") ?? "";
  if (!raw.startsWith("components.list-pages.")) return null;
  const extCase = params.get("extCase");
  const extKind = params.get("extKind");
  if (!extCase || !extKind) return null;
  return { raw, extCase, extKind, platform: params.get("platform") === "mobile" ? "mobile" : "desktop", params };
}

// Route-based panels read their state from the URL (search q / filters, tasks
// view / filters): put it in place before BrowserRouter mounts, like the
// official primeVisualRoutePath().
(function parityExtLpPrimeRoute() {
  if (typeof window === "undefined") return;
  const props = parityExtLpProps();
  if (!props) return;
  const route = props.params.get("route");
  if (!route) return;
  const next = new URLSearchParams(props.params.get("routeQuery") ?? "");
  for (const [key, value] of props.params.entries()) {
    if (key !== "route" && key !== "routeQuery") next.set(key, value);
  }
  window.history.replaceState(null, "", `/s/${fxServer.slug}${route}?${next.toString()}`);
  // Local-only search memory (history tags) the page reads on mount.
  const history = props.params.get("searchHistory");
  if (history) {
    window.localStorage.setItem(`raft:search-history:${fxServer.id}:${fxOwner.id}`, JSON.stringify(history.split("|")));
  } else {
    window.localStorage.removeItem(`raft:search-history:${fxServer.id}:${fxOwner.id}`);
  }
  window.localStorage.removeItem(`raft:search-state:${fxServer.id}:${fxOwner.id}`);
})();

function parityExtLpBox(props: ParityExtLpProps) {
  const width = Number(props.params.get("w") ?? 342);
  const height = Number(props.params.get("h") ?? 620);
  return { width, height };
}

function parityExtLpPrime(props: ParityExtLpProps) {
  primeDirectVisualStores(props.raw);
  const state = props.params.get("state") ?? "results";
  const panel = props.params.get("panel");
  const results = state === "results";
  const routes = { ...(parityExtLpFixture.routes as Record<string, unknown>), ...((parityExtLpFixture.routeSets as Record<string, Record<string, unknown>>)[props.params.get("routeSet") ?? ""] ?? {}) };
  const inbox = routes["GET /channels/inbox"] as typeof activityResultsFixture;
  const saved = routes["GET /channels/saved"] as typeof savedMessagesFixture;
  if (panel === "activity") {
    useInboxStore.setState({
      items: (results ? inbox.items : []) as never,
      filter: (props.params.get("filter") ?? "all") as never,
      loading: state === "loading",
      loadingMore: false,
      hasMore: false,
      totalCount: results ? inbox.totalCount : 0,
      totalUnreadCount: results ? inbox.totalUnreadCount : 0,
    });
  }
  if (panel === "saved") {
    useSavedStore.setState({
      saved: (results ? saved.saved : []) as never,
      savedIds: new Set(results ? saved.saved.map((s) => s.messageId) : []),
      loading: state === "loading",
      hasMore: results ? Boolean(saved.hasMore) : false,
      total: results ? saved.total : 0,
    });
  }
}

function ParityExtLpPanel({ props }: { props: ParityExtLpProps }) {
  const panel = props.params.get("panel");
  const { width, height } = parityExtLpBox(props);
  useMemo(() => parityExtLpPrime(props), [props]);
  const body = panel === "saved" ? <SavedPanel /> : panel === "activity" ? <ThreadsInbox /> : panel === "tasks" ? <TasksPanel /> : <MessageSearchPage />;
  return (
    <main className="min-h-screen bg-white p-0 font-display text-black">
      <div
        data-visual-case={props.raw}
        style={{ width, height, overflow: "hidden", display: "flex", flexDirection: "column", background: "white" }}
      >
        {body}
      </div>
    </main>
  );
}

function ParityExtLpView({ props }: { props: ParityExtLpProps }) {
  if (props.extKind === "panel") return <ParityExtLpPanel props={props} />;
  return null;
}

function parityExtListPagesElement() {
  const props = parityExtLpProps();
  return props ? <ParityExtLpView props={props} /> : null;
}
