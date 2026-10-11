// raft-flutter parity EXTENSION cases: work package 6 (task and settings
// leftovers). Ids: components.wp6.<surface>.<state>.<theme>.
//
// Appended by tool/parity-ext-web.mjs to a generated copy of the pinned
// VisualTestingCases.tsx (shares its imports and fixture helpers; identifiers
// here are prefixed `parityExtWp6`). Data: tool/parity-ext/fixtures/wp6.json
// (every route lives in a `routeSets` entry so no other family is affected);
// the Flutter provider reads the same file (cases/ext_wp6.dart).
//
//   tasks.create-dialog*  -> task/CreateTaskDialog (the card; Modal on the viewport)
//   tasks.filter*         -> task/TaskFilterSegmentedControl
//   tasks.empty-lanes*    -> the real MainLayout on /s/<slug>/tasks with empty lanes
import ParityExtWp6CreateTaskDialog from "../src/components/task/CreateTaskDialog";
import { TaskFilterSegmentedControl as ParityExtWp6TaskFilter } from "../src/components/task/TaskFilterSegmentedControl";
import parityExtWp6Fixture from "virtual:parity-ext/wp6";
import parityExtWp6TaskDetailFixture from "virtual:parity-ext/taskdetail";

type ParityExtWp6Props = {
  caseId: string;
  surface: string;
  state: string;
  mobile: boolean;
  routeSet: string;
};

function parityExtWp6Props(): ParityExtWp6Props | null {
  const raw = parityExtRawCaseId();
  if (!raw.startsWith("components.wp6.")) return null;
  const params = new URLSearchParams(window.location.search);
  const surface = params.get("surface");
  if (!surface || params.get("extKind") !== "wp6") return null;
  return {
    caseId: raw,
    surface,
    state: params.get("state") ?? "",
    mobile: params.get("platform") === "mobile",
    routeSet: params.get("routeSet") ?? "",
  };
}

// Route-based surfaces need the browser URL in place BEFORE BrowserRouter
// mounts (see primeVisualRoutePath in the official host).
(function parityExtWp6PrimeRoute() {
  if (typeof window === "undefined") return;
  const props = parityExtWp6Props();
  if (!props) return;
  let path: string | null = null;
  if (props.surface === "tasks-board") path = `/s/${fxServer.slug}/tasks`;
  if (props.surface === "settings") {
    path = parityExtSettingsRoutePath(new URLSearchParams(window.location.search).get("tab") ?? "account");
  }
  if (path && window.location.pathname !== path) {
    window.history.replaceState(null, "", `${path}${window.location.search}`);
  }
})();

function parityExtWp6PrimeBoard(props: ParityExtWp6Props) {
  primeNavigationVisualStores();
  const board = (parityExtWp6Fixture.boards as Record<string, unknown[]>)[props.state] as unknown as Task[];
  useChannelStore.setState({
    channels: parityExtWp6TaskDetailFixture.channels as never,
    dmChannels: [],
    loading: false,
  });
  useMessageStore.setState({ currentChannelId: parityExtWp6TaskDetailFixture.channels[0].id, currentUserId: fxOwner.id });
  const lane = { nextCursor: null, loading: false, loaded: true };
  useTaskStore.setState({
    serverTasks: board,
    serverLoading: false,
    serverTasksLoaded: true,
    serverTaskPages: { todo: lane, in_progress: lane, in_review: lane, done: lane, closed: lane },
    tasks: [],
    loading: false,
    currentChannelId: null,
    tasksByChannelId: {},
    loadedByChannelId: {},
    loadingByChannelId: {},
  } as never);
}

function ParityExtWp6BoardView({ props }: { props: ParityExtWp6Props }) {
  useMemo(() => parityExtWp6PrimeBoard(props), [props]);
  return (
    <main className="min-h-screen bg-white p-0 font-display text-black">
      <div
        data-visual-case={props.caseId}
        style={{ width: props.mobile ? 390 : 1280, height: props.mobile ? 844 : 800, overflow: "hidden", display: "flex", flexDirection: "column" }}
      >
        <Routes>
          <Route path="/s/:serverSlug/*" element={<MainLayout />} />
        </Routes>
      </div>
    </main>
  );
}

function ParityExtWp6TasksView({ props }: { props: ParityExtWp6Props }) {
  const mobile = props.mobile;
  if (props.surface === "tasks-create") {
    return (
      <main className="min-h-screen bg-white p-0 font-display text-black">
        <div
          data-visual-case={props.caseId}
          style={{ width: mobile ? 390 : 1280, height: mobile ? 844 : 800, overflow: "hidden", position: "relative" }}
        >
          <ParityExtWp6CreateTaskDialog channelId="channel-design" onClose={() => undefined} />
        </div>
      </main>
    );
  }
  if (props.surface === "tasks-filter") {
    const counts = parityExtWp6Fixture.filterCounts as never;
    return (
      <main className="min-h-screen bg-white p-0 font-display text-black">
        <div
          data-visual-case={props.caseId}
          className="bg-layer-canvas-muted theme-brutal:bg-white"
          style={{ width: mobile ? 390 : 1280, height: 200, padding: 16, overflow: "hidden" }}
        >
          <ParityExtWp6TaskFilter value={(props.state === "selected" ? "in_progress" : "all") as never} counts={counts} onValueChange={() => undefined} />
        </div>
      </main>
    );
  }
  return <ParityExtWp6BoardView props={props} />;
}

// ---------------------------------------------------------------- settings
// The settings surfaces reuse SettingsCases' real shell (rail + panel in the
// 1216px frame, or the bare SettingsPanel at 390 on mobile): this wrapper only
// maps the case props onto ParityExtSettingsProps. `prefs` names a store patch
// applied after the stores are primed (the Flutter builder applies the same
// patch to the signed-in user).
const PARITY_EXT_WP6_USER_PREFS: Record<string, Record<string, unknown>> = {
  "translation-off": { preferredTranslationMode: "off" },
  "translation-manual": { preferredTranslationDisplay: "bilingual" },
};

function parityExtWp6AfterSettingsPrime() {
  const prefs = new URLSearchParams(window.location.search).get("prefs");
  const patch = prefs ? PARITY_EXT_WP6_USER_PREFS[prefs] : undefined;
  if (patch) {
    useAuthStore.setState((state) => ({ user: state.user ? { ...state.user, ...patch } : state.user } as never));
  }
}

function parityExtWp6SettingsProps(props: ParityExtWp6Props): ParityExtSettingsProps {
  const params = new URLSearchParams(window.location.search);
  return {
    caseId: props.caseId,
    tab: params.get("tab") ?? "account",
    role: (params.get("role") ?? "owner") as ParityExtSettingsProps["role"],
    flags: new Set((params.get("flags") ?? "").split(",").filter(Boolean)),
    routeSet: props.routeSet,
    mobile: props.mobile,
  };
}

function parityExtWp6Element() {
  const props = parityExtWp6Props();
  if (!props) return null;
  if (props.surface.startsWith("tasks-")) return <ParityExtWp6TasksView props={props} />;
  if (props.surface === "settings") return <ParityExtSettingsCaseView props={parityExtWp6SettingsProps(props)} />;
  return null;
}
