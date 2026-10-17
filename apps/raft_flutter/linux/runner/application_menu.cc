#include "application_menu.h"

namespace {
struct MenuState {
  FlMethodChannel* channel;
  GSimpleAction* action;
  GMenu* entries;
};

void menu_state_free(gpointer data) {
  auto* state = static_cast<MenuState*>(data);
  g_simple_action_set_enabled(state->action, FALSE);
  g_signal_handlers_disconnect_by_data(state->action, state);
  fl_method_channel_set_method_call_handler(state->channel, nullptr, nullptr,
                                            nullptr);
  g_clear_object(&state->channel);
  g_clear_object(&state->action);
  g_clear_object(&state->entries);
  g_free(state);
}
}  // namespace

void raft_application_menu_install(GtkApplication* application,
                                   GtkWindow* window,
                                   GtkWidget* header_bar,
                                   FlView* view) {
  auto* state = g_new0(MenuState, 1);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  state->channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "app.raft/linux-menu", FL_METHOD_CODEC(codec));
  state->action = g_simple_action_new("check-for-updates", nullptr);
  // The Dart handler enables this after its root navigator is available.
  g_simple_action_set_enabled(state->action, FALSE);
  g_signal_connect(state->action, "activate", G_CALLBACK(+[](
      GSimpleAction*, GVariant*, gpointer data) {
    auto* state = static_cast<MenuState*>(data);
    fl_method_channel_invoke_method(state->channel, "checkForUpdates", nullptr,
                                    nullptr, nullptr, nullptr);
  }), state);
  g_action_map_add_action(G_ACTION_MAP(application), G_ACTION(state->action));
  state->entries = g_menu_new();
  g_menu_append(state->entries, "Check for updates…", "app.check-for-updates");

  // A native header menu on GNOME/Wayland; the conventional application menu
  // when the window manager owns the title bar. Both share the same action.
  g_autoptr(GMenu) menubar = g_menu_new();
  g_menu_append_submenu(menubar, "Raft", G_MENU_MODEL(state->entries));
  gtk_application_set_menubar(application, G_MENU_MODEL(menubar));
  gtk_application_window_set_show_menubar(GTK_APPLICATION_WINDOW(window),
                                         header_bar == nullptr);
  if (header_bar != nullptr) {
    GtkWidget* button = gtk_menu_button_new();
    GtkWidget* icon = gtk_image_new_from_icon_name(
        "open-menu-symbolic", GTK_ICON_SIZE_BUTTON);
    gtk_button_set_image(GTK_BUTTON(button), icon);
    gtk_widget_set_tooltip_text(button, "Raft");
    atk_object_set_name(gtk_widget_get_accessible(button), "Raft");
    gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(button),
                                   G_MENU_MODEL(state->entries));
    gtk_header_bar_pack_end(GTK_HEADER_BAR(header_bar), button);
    gtk_widget_show_all(button);
  }

  fl_method_channel_set_method_call_handler(state->channel,
      [](FlMethodChannel*, FlMethodCall* call, gpointer data) {
        auto* state = static_cast<MenuState*>(data);
        if (g_strcmp0(fl_method_call_get_name(call), "setState") != 0) {
          fl_method_call_respond_not_implemented(call, nullptr);
          return;
        }
        FlValue* args = fl_method_call_get_args(call);
        if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
          fl_method_call_respond_error(call, "bad-arguments",
                                      "Expected menu state", nullptr, nullptr);
          return;
        }
        FlValue* ready = fl_value_lookup_string(args, "ready");
        g_simple_action_set_enabled(state->action,
            ready != nullptr && fl_value_get_type(ready) == FL_VALUE_TYPE_BOOL &&
            fl_value_get_bool(ready));
        FlValue* label = fl_value_lookup_string(args, "label");
        if (label != nullptr && fl_value_get_type(label) == FL_VALUE_TYPE_STRING &&
            fl_value_get_string(label)[0] != '\0') {
          g_menu_remove_all(state->entries);
          g_menu_append(state->entries, fl_value_get_string(label),
                         "app.check-for-updates");
        }
        fl_method_call_respond_success(call, nullptr, nullptr);
      }, state, nullptr);
  g_object_set_data_full(G_OBJECT(window), "raft-application-menu", state,
                         menu_state_free);
}
