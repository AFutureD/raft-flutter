#include "vsync_driver.h"

#include <gtk/gtk.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include "flutter_embedder.h"

// The embedder API table lives inside the FlEngine instance (fl_engine.cc:
// `FlutterEngineProcTable embedder_api`) and fl_engine_start() calls
// `embedder_api.Initialize(...)` through it. FlEngine is private, so the table
// is located by its struct_size and checked slot by slot; Initialize is then
// wrapped to add the vsync callback the GTK embedder omits.

namespace {

constexpr gint64 kDefaultIntervalUs = 16667;
constexpr gint64 kMinIntervalUs = 4000;
constexpr gint64 kMaxIntervalUs = 40000;
constexpr guint kMinWatchdogMs = 34;

struct State {
  GtkWidget* view = nullptr;
  FlutterEngineProcTable* table = nullptr;
  FlutterEngineInitializeFnPtr initialize = nullptr;
  std::atomic<FlutterEngine> engine{nullptr};
  GMutex lock;
  GArray* batons = nullptr;  // intptr_t, guarded by lock
  bool scheduled = false;    // guarded by lock
  guint tick_id = 0;         // main thread only
  guint watchdog_id = 0;     // main thread only
  bool stats = false;
  gint64 stats_start_us = 0;
  guint stats_frames = 0;
  gint64 requested_us = 0;     // guarded by lock
  gint64 delivered_us = 0;
  gint64 wait_total_us = 0;    // request -> release
  gint64 gap_total_us = 0;     // release -> next request
};

State state;

gint64 monitor_interval_us(GtkWidget* view) {
  GdkWindow* window = gtk_widget_get_window(view);
  if (window == nullptr) return kDefaultIntervalUs;
  GdkMonitor* monitor =
      gdk_display_get_monitor_at_window(gdk_window_get_display(window), window);
  int millihertz = monitor != nullptr ? gdk_monitor_get_refresh_rate(monitor) : 0;
  if (millihertz <= 0) return kDefaultIntervalUs;
  return CLAMP(1000000000LL / millihertz, kMinIntervalUs, kMaxIntervalUs);
}

gint64 interval_us(GtkWidget* view, GdkFrameClock* clock) {
  gint64 interval = monitor_interval_us(view);
  // The monitor's mode is authoritative; the frame clock's own estimate is
  // only a default (16.667 ms) until it has measured presentations.
  if (interval == kDefaultIntervalUs && clock != nullptr) {
    gint64 presentation = 0, measured = 0;
    gdk_frame_clock_get_refresh_info(clock, gdk_frame_clock_get_frame_time(clock),
                                     &measured, &presentation);
    if (measured > 0) interval = CLAMP(measured, kMinIntervalUs, kMaxIntervalUs);
  }
  return interval;
}

// GDK 3 on Wayland/X11 paces its frame clock with the previous frame's
// GdkFrameTimings::refresh_interval and falls back to 16.667 ms when that is
// zero. A GL-rendered window commits through eglSwapBuffers, never requests a
// wl_surface frame callback and so never gets a measured interval: the clock
// (and with it every repaint) is capped at 60 Hz on any monitor. Fill the
// interval in from the monitor's mode on each cycle. GdkFrameTimings is
// private, so its layout is verified against the public getters first.
constexpr size_t kTimingsCounterOffset = 8;
constexpr size_t kTimingsFrameTimeOffset = 24;
constexpr size_t kTimingsPresentationOffset = 48;
constexpr size_t kTimingsRefreshIntervalOffset = 56;
constexpr size_t kTimingsPredictedOffset = 64;
int timings_layout = 0;  // 0 unchecked, 1 verified, -1 unknown

template <typename T>
T* timings_field(GdkFrameTimings* timings, size_t offset) {
  return reinterpret_cast<T*>(reinterpret_cast<uint8_t*>(timings) + offset);
}

bool verify_timings_layout(GdkFrameTimings* t) {
  return *timings_field<gint64>(t, kTimingsCounterOffset) == gdk_frame_timings_get_frame_counter(t) &&
         *timings_field<gint64>(t, kTimingsFrameTimeOffset) == gdk_frame_timings_get_frame_time(t) &&
         *timings_field<gint64>(t, kTimingsPresentationOffset) == gdk_frame_timings_get_presentation_time(t) &&
         *timings_field<gint64>(t, kTimingsRefreshIntervalOffset) == gdk_frame_timings_get_refresh_interval(t) &&
         *timings_field<gint64>(t, kTimingsPredictedOffset) ==
             gdk_frame_timings_get_predicted_presentation_time(t) &&
         gdk_frame_timings_get_frame_time(t) != 0;
}

void on_before_paint(GdkFrameClock* clock, gpointer) {
  if (timings_layout < 0 || state.view == nullptr) return;
  GdkFrameTimings* timings = gdk_frame_clock_get_current_timings(clock);
  if (timings == nullptr) return;
  if (timings_layout == 0) {
    timings_layout = verify_timings_layout(timings) ? 1 : -1;
    if (timings_layout < 0) {
      g_message("raft.vsync: frame timings layout not recognised; repaint stays on GDK's pacing");
      return;
    }
  }
  gint64* interval = timings_field<gint64>(timings, kTimingsRefreshIntervalOffset);
  if (*interval == 0) *interval = monitor_interval_us(state.view);
}

void on_view_realize(GtkWidget* view, gpointer) {
  GdkFrameClock* clock = gtk_widget_get_frame_clock(view);
  if (clock != nullptr) g_signal_connect(clock, "before-paint", G_CALLBACK(on_before_paint), nullptr);
}

void clear_sources() {
  if (state.tick_id != 0) {
    gtk_widget_remove_tick_callback(state.view, state.tick_id);
    state.tick_id = 0;
  }
  if (state.watchdog_id != 0) {
    g_source_remove(state.watchdog_id);
    state.watchdog_id = 0;
  }
}

// Hand every waiting baton back to the engine. Main thread only (the thread
// that ran the engine: FlutterEngineOnVsync must be called there).
void deliver(GdkFrameClock* clock) {
  clear_sources();
  g_mutex_lock(&state.lock);
  g_autoptr(GArray) taken = state.batons;
  state.batons = g_array_new(FALSE, FALSE, sizeof(intptr_t));
  state.scheduled = false;
  if (state.stats) {
    state.delivered_us = g_get_monotonic_time();
    state.wait_total_us += state.delivered_us - state.requested_us;
  }
  g_mutex_unlock(&state.lock);

  FlutterEngine engine = state.engine.load();
  if (engine == nullptr) return;
  uint64_t start = state.table->GetCurrentTime();
  gint64 interval = state.view != nullptr ? interval_us(state.view, clock) : kDefaultIntervalUs;
  uint64_t target = start + static_cast<uint64_t>(interval) * 1000;
  for (guint i = 0; i < taken->len; i++) {
    state.table->OnVsync(engine, g_array_index(taken, intptr_t, i), start, target);
  }
  if (state.stats) {
    state.stats_frames++;
    gint64 now = g_get_monotonic_time();
    if (state.stats_start_us == 0) state.stats_start_us = now;
    if (now - state.stats_start_us >= G_USEC_PER_SEC) {
      g_printerr("raft.vsync: %u frames in %.0f ms, interval %.2f ms, wait for tick %.2f ms, engine gap %.2f ms\n",
                 state.stats_frames, (now - state.stats_start_us) / 1000.0,
                 interval / 1000.0, state.wait_total_us / 1000.0 / state.stats_frames,
                 state.gap_total_us / 1000.0 / state.stats_frames);
      state.wait_total_us = state.gap_total_us = 0;
      state.stats_start_us = now;
      state.stats_frames = 0;
    }
  }
}

gboolean on_tick(GtkWidget*, GdkFrameClock* clock, gpointer) {
  state.tick_id = 0;  // returning REMOVE drops it
  deliver(clock);
  return G_SOURCE_REMOVE;
}

// No frame-clock tick (window hidden, minimised or not yet mapped, as during
// the first frame that shows it): fall back to a timer like the engine's own.
gboolean on_watchdog(gpointer) {
  state.watchdog_id = 0;
  deliver(state.view != nullptr ? gtk_widget_get_frame_clock(state.view) : nullptr);
  return G_SOURCE_REMOVE;
}

gboolean schedule_on_main(gpointer) {
  if (state.view == nullptr) return G_SOURCE_REMOVE;
  GdkFrameClock* clock = gtk_widget_get_frame_clock(state.view);
  guint wait_ms = kDefaultIntervalUs / 1000;
  if (clock != nullptr && gtk_widget_get_mapped(state.view)) {
    state.tick_id = gtk_widget_add_tick_callback(state.view, on_tick, nullptr, nullptr);
    wait_ms = MAX(kMinWatchdogMs, static_cast<guint>(interval_us(state.view, clock) * 3 / 1000));
  }
  state.watchdog_id = g_timeout_add(wait_ms, on_watchdog, nullptr);
  return G_SOURCE_REMOVE;
}

// Engine-managed thread.
void on_engine_vsync(void*, intptr_t baton) {
  g_mutex_lock(&state.lock);
  if (state.stats) {
    gint64 now = g_get_monotonic_time();
    if (state.delivered_us != 0 && !state.scheduled) state.gap_total_us += now - state.delivered_us;
    state.requested_us = now;
  }
  g_array_append_val(state.batons, baton);
  bool first = !state.scheduled;
  state.scheduled = true;
  g_mutex_unlock(&state.lock);
  if (first) g_main_context_invoke_full(nullptr, G_PRIORITY_HIGH, schedule_on_main, nullptr, nullptr);
}

FlutterEngineResult initialize_with_vsync(size_t version, const FlutterRendererConfig* config,
                                          const FlutterProjectArgs* args, void* user_data,
                                          FlutterEngine* engine_out) {
  FlutterProjectArgs patched;
  const FlutterProjectArgs* use = args;
  if (args != nullptr && args->struct_size == sizeof(FlutterProjectArgs) &&
      args->vsync_callback == nullptr) {
    std::memcpy(&patched, args, sizeof(patched));
    patched.vsync_callback = on_engine_vsync;
    use = &patched;
  }
  FlutterEngineResult result = state.initialize(version, config, use, user_data, engine_out);
  if (result == kSuccess && use == &patched && engine_out != nullptr) {
    state.engine.store(*engine_out);
  }
  return result;
}

void on_view_destroy(GtkWidget*, gpointer) {
  clear_sources();
  state.view = nullptr;
}

FlutterEngineProcTable* find_table(GObject* engine) {
  GTypeQuery query;
  g_type_query(G_OBJECT_TYPE(engine), &query);
  auto* bytes = reinterpret_cast<uint8_t*>(engine);
  FlutterEngineProcTable* found = nullptr;
  for (size_t offset = sizeof(GObject); offset + sizeof(FlutterEngineProcTable) <= query.instance_size;
       offset += sizeof(void*)) {
    auto* candidate = reinterpret_cast<FlutterEngineProcTable*>(bytes + offset);
    if (candidate->struct_size != sizeof(FlutterEngineProcTable)) continue;
    auto** slots = reinterpret_cast<void**>(candidate);
    bool complete = true;
    for (size_t i = 1; i < sizeof(FlutterEngineProcTable) / sizeof(void*); i++) {
      if (slots[i] == nullptr) complete = false;
    }
    if (!complete) continue;
    if (found != nullptr) return nullptr;  // ambiguous
    found = candidate;
  }
  return found;
}

}  // namespace

void raft_vsync_install(FlView* view) {
  if (g_strcmp0(g_getenv("RAFT_LINUX_VSYNC"), "0") == 0) return;
  if (state.table != nullptr) return;
  FlEngine* engine = fl_view_get_engine(view);
  FlutterEngineProcTable* table = engine != nullptr ? find_table(G_OBJECT(engine)) : nullptr;
  if (table == nullptr) {
    g_message("raft.vsync: engine layout not recognised; keeping the engine's own 60 Hz timer");
    return;
  }
  g_mutex_init(&state.lock);
  state.batons = g_array_new(FALSE, FALSE, sizeof(intptr_t));
  state.view = GTK_WIDGET(view);
  state.table = table;
  state.initialize = table->Initialize;
  state.stats = g_strcmp0(g_getenv("RAFT_LINUX_VSYNC_STATS"), "1") == 0;
  table->Initialize = initialize_with_vsync;
  g_signal_connect(view, "destroy", G_CALLBACK(on_view_destroy), nullptr);
  g_signal_connect_after(view, "realize", G_CALLBACK(on_view_realize), nullptr);
}
