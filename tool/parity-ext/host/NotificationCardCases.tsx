// raft-flutter parity EXTENSION cases: Settings -> Notifications on Raft
// Desktop (DesktopNativeNotificationsCard). Appended to the generated
// VisualTestingCases.tsx like host/ComputerCases.tsx (shares its imports and
// private helpers); identifiers are prefixed `parityExtNotif`.
//
// DesktopNativeNotificationsCard is private to SettingsPanel.tsx, and the
// Source checkout is never edited, so the REAL SettingsPanel (tab
// "notifications", exactly the official settings.notifications.page mount) is
// rendered with the one capability the product itself keys on:
// `resolveNotificationChannel()` picks the desktop-native card when
// `window.raftDesktop.isDesktop === true` (the Electron preload marker), and
// the card reports "Unavailable" when the renderer has no `Notification` API.
// Ids: components.notifications.desktop.<available|unavailable>.<theme>.
// The capture is the card's SectionHeader + card block.

function parityExtNotifProps() {
  const params = new URLSearchParams(window.location.search);
  const raw = params.get("case") ?? "";
  if (!raw.startsWith("components.notifications.desktop.")) return null;
  return { raw, available: params.get("available") !== "false" };
}

function ParityExtNotifView({ p }: { p: NonNullable<ReturnType<typeof parityExtNotifProps>> }) {
  useMemo(() => {
    const caseConfig = SETTINGS_CASES["components.settings.notifications.page"];
    primeSettingsVisualStores(caseConfig);
    // Runtime markers read synchronously by resolveNotificationChannel() and
    // isDesktopNativeNotificationsAvailable() during the first render.
    (window as unknown as { raftDesktop?: unknown }).raftDesktop = { isDesktop: true };
    if (!p.available) (window as unknown as { Notification?: unknown }).Notification = undefined;
  }, [p.raw, p.available]);
  // Same 640px settings column in both providers; height follows the content.
  return (
    <main className="min-h-screen bg-white p-0 font-display text-black">
      <div data-visual-case={p.raw} style={{ width: 640, height: 600, overflow: "hidden" }}>
        <SettingsPanel tab="notifications" />
      </div>
    </main>
  );
}

function parityExtNotifElement() {
  const p = parityExtNotifProps();
  return p ? <ParityExtNotifView p={p} /> : null;
}
