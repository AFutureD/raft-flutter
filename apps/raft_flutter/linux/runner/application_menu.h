#ifndef RUNNER_APPLICATION_MENU_H_
#define RUNNER_APPLICATION_MENU_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

void raft_application_menu_install(GtkApplication* application,
                                   GtkWindow* window,
                                   GtkWidget* header_bar,
                                   FlView* view);

#endif  // RUNNER_APPLICATION_MENU_H_
