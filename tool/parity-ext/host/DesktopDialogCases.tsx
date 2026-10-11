// raft-flutter parity EXTENSION cases: official dialog cases re-rendered at desktop width (not official).
//
// Appended by tool/parity-ext-web.mjs to a generated copy of the pinned
// VisualTestingCases.tsx, so it shares that file's imports and helpers
// (CreateChannelDialog, CreateAgentDialog, primeCreateChannelStores,
// primeCreateAgentStores, CREATE_AGENT_CASES, VISUAL_MACHINE_ID). Identifiers
// here are prefixed `parityExtDd`. Ids: components.dialogs.desktop.<key>.<theme>.
//
// The official phone cases wrap the dialog in a 390x844 box; here the same
// product dialog is mounted over a full 1280x800 viewport (the Modal portal is
// `fixed inset-0`, so only the viewport differs). `props.official` names the
// official case whose seeded stores / prefill the dialog reuses.
function parityExtDdProps() {
  const params = new URLSearchParams(window.location.search);
  const raw = params.get("case") ?? "";
  if (!raw.startsWith("components.dialogs.") || params.get("extKind") !== "dialogs") return null;
  return { raw, official: params.get("official") ?? "" };
}

function ParityExtDdChannelView({ raw }: { raw: string }) {
  useMemo(() => primeCreateChannelStores(), []);
  return (
    <main className="min-h-screen bg-white p-0 font-display text-black">
      <div data-visual-case={raw} style={{ width: "100vw", height: "100vh", overflow: "hidden" }}>
        {/* Same prefill as the official variant prefilled-members. */}
        <CreateChannelDialog
          prefilledName="android-artifacts"
          prefilledDescription="Build reports, screenshots, release blockers"
          prefilledVisibility="public"
          prefilledAgentIds={["agent-cindy"]}
          prefilledHumanIds={["visual-human-designer"]}
          onClose={() => undefined}
        />
      </div>
    </main>
  );
}

function ParityExtDdAgentView({ raw, caseConfig }: { raw: string; caseConfig: CreateAgentVisualCase }) {
  useMemo(() => primeCreateAgentStores(caseConfig), [caseConfig]);
  return (
    <main className="min-h-screen bg-white p-0 font-display text-black">
      <div data-visual-case={raw} data-visual-runtime={caseConfig.runtime} style={{ width: "100vw", height: "100vh" }}>
        <CreateAgentDialog
          defaultMachineId={VISUAL_MACHINE_ID}
          prefilledName={caseConfig.empty ? "" : (caseConfig.prefilledName ?? "Product-QA-Bot")}
          prefilledDescription={caseConfig.empty ? "" : "Watches release screenshots and reports visual regressions before merge."}
          onClose={() => undefined}
        />
      </div>
    </main>
  );
}

function parityExtDesktopDialogElement() {
  const props = parityExtDdProps();
  if (!props) return null;
  if (props.official === "components.home.create-channel.dialog") return <ParityExtDdChannelView raw={props.raw} />;
  const caseConfig = CREATE_AGENT_CASES[props.official];
  return caseConfig ? <ParityExtDdAgentView raw={props.raw} caseConfig={caseConfig} /> : null;
}
