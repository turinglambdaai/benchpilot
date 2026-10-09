// Rivet Linux host — GTK4 window over one embedded Racket CS backend.
// Mirrors the SwiftUI host in a compact form: runtime status and targets,
// power control, DTC memory read, and the recent operation history. The
// backend boots off the UI thread; every completion dispatches back to the
// main loop before touching widgets.
#include <gtk/gtk.h>

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include "GeneratedBackend.hpp"

namespace {

struct AppState {
  GtkWindow* window{nullptr};
  GtkLabel* status{nullptr};
  GtkLabel* info{nullptr};
  GtkLabel* history{nullptr};
  GtkButton* power_on{nullptr};
  GtkButton* power_off{nullptr};
  GtkButton* dtc_read{nullptr};
  GtkButton* refresh{nullptr};

  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::unique_ptr<rivet_app::API> api;
  std::mutex startup_mutex;
  std::thread startup_thread;
  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  std::string startup_error;
  std::atomic<bool> shutting_down{false};
  std::string target_id;

  void set_status(std::string const& text) {
    gtk_label_set_text(status, text.c_str());
  }

  void set_buttons_sensitive(bool sensitive) {
    gtk_widget_set_sensitive(GTK_WIDGET(power_on), sensitive);
    gtk_widget_set_sensitive(GTK_WIDGET(power_off), sensitive);
    gtk_widget_set_sensitive(GTK_WIDGET(dtc_read), sensitive);
    gtk_widget_set_sensitive(GTK_WIDGET(refresh), sensitive);
  }
};

AppState g_state;

std::filesystem::path executable_path() {
  return std::filesystem::read_symlink("/proc/self/exe");
}

// Rivet keeps runtime/res beside the executable in development and packages.
struct RuntimeLayout {
  std::filesystem::path petite_boot;
  std::filesystem::path scheme_boot;
  std::filesystem::path racket_boot;
  std::filesystem::path core;
};

std::optional<RuntimeLayout> discover_runtime_layout() {
  std::filesystem::path const exe = executable_path();
  std::filesystem::path const roots[] = {exe.parent_path()};
  for (auto const& root : roots) {
    RuntimeLayout layout{
        root / "runtime" / "petite.boot",
        root / "runtime" / "scheme.boot",
        root / "runtime" / "racket.boot",
        root / "res" / "core.zo",
    };
    if (std::filesystem::exists(layout.petite_boot) &&
        std::filesystem::exists(layout.scheme_boot) &&
        std::filesystem::exists(layout.racket_boot) &&
        std::filesystem::exists(layout.core)) {
      return layout;
    }
  }
  return std::nullopt;
}

// One background job: `body` runs off the main loop, its `apply` closure
// runs on the main loop through g_idle_add.
struct UiJob {
  bool ok{false};
  std::string error;
  std::function<void()> apply;
};

int on_job_delivered(gpointer user_data) {
  std::unique_ptr<UiJob> job(static_cast<UiJob*>(user_data));
  if (job->ok && job->apply) {
    job->apply();
  } else if (!job->ok) {
    g_state.set_status("Error: " + job->error);
  }
  g_state.set_buttons_sensitive(g_state.api != nullptr);
  return G_SOURCE_REMOVE;
}

void run_job(std::function<void(UiJob&)> body) {
  auto* job = new UiJob;
  std::thread([job, body = std::move(body)]() mutable {
    try {
      body(*job);
      job->ok = true;
    } catch (std::exception const& error) {
      job->ok = false;
      job->error = error.what();
    } catch (...) {
      job->ok = false;
      job->error = "unknown backend failure";
    }
    g_idle_add(on_job_delivered, job);
  }).detach();
}

std::string describe_status(rivet_app::RuntimeStatus const& status) {
  std::string text = status.name;
  if (status.runtime_version.has_value()) {
    text += " · runtime " + *status.runtime_version;
  }
  text += "\n" + std::to_string(status.targets.size()) + " target(s):";
  for (auto const& target : status.targets) {
    text += "\n · " + target.name + " (" + target.id;
    if (target.mcu.has_value()) {
      text += ", " + *target.mcu;
    }
    text += ")";
  }
  return text;
}

void fetch_status() {
  rivet_app::API* api = g_state.api.get();
  run_job([api](UiJob& job) {
    rivet_app::RuntimeStatus const status = api->status().get();
    if (!status.targets.empty()) {
      g_state.target_id = status.targets.front().id;
    }
    job.apply = [status]() {
      gtk_label_set_text(g_state.info, describe_status(status).c_str());
    };
  });
}

void fetch_history() {
  rivet_app::API* api = g_state.api.get();
  run_job([api](UiJob& job) {
    auto const past = api->operation_history(5).get();
    std::string text = "Recent operations:";
    if (past.empty()) {
      text += " none yet";
    }
    for (auto const& entry : past) {
      text += "\n · " + entry.state + " " + entry.kind + " (" +
              std::to_string(entry.duration_ms) + " ms)";
    }
    job.apply = [text]() {
      gtk_label_set_text(g_state.history, text.c_str());
    };
  });
}

int on_backend_finished(gpointer) {
  if (g_state.startup_thread.joinable()) {
    g_state.startup_thread.join();
  }

  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::string error;
  {
    std::lock_guard lock(g_state.startup_mutex);
    backend = std::move(g_state.startup_backend);
    error = std::move(g_state.startup_error);
  }

  if (g_state.shutting_down.load(std::memory_order_acquire)) {
    if (backend != nullptr) {
      backend->stop();
    }
    return G_SOURCE_REMOVE;
  }

  if (!error.empty()) {
    g_state.set_status("Backend error: " + error);
    return G_SOURCE_REMOVE;
  }
  if (backend == nullptr) {
    g_state.set_status("Backend error: startup completed without a backend");
    return G_SOURCE_REMOVE;
  }

  g_state.backend = std::move(backend);
  g_state.api = std::make_unique<rivet_app::API>(*g_state.backend);

  g_state.set_status("Connected");
  g_state.set_buttons_sensitive(true);
  fetch_status();
  fetch_history();
  return G_SOURCE_REMOVE;
}

void start_backend() {
  auto layout = discover_runtime_layout();
  if (!layout.has_value()) {
    g_state.set_status(
        "Missing Rivet runtime layout (runtime/*.boot, res/core.zo) next to "
        "the executable. Build with raco rivet build/dev.");
    return;
  }

  rivet::linux_runtime::RacketRuntimeConfig config;
  config.executable_path = executable_path().string();
  config.petite_boot = layout->petite_boot.string();
  config.scheme_boot = layout->scheme_boot.string();
  config.racket_boot = layout->racket_boot.string();
  config.backend_bundle = layout->core.string();
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;

  // Booting the embedded runtime blocks on file I/O; only startup runs off
  // the main loop. Everything after completion dispatches back through
  // g_idle_add.
  g_state.startup_thread = std::thread([config = std::move(config)]() mutable {
    auto backend =
        std::make_unique<rivet::linux_runtime::Backend>(std::move(config));
    try {
      backend->start();
      {
        std::lock_guard lock(g_state.startup_mutex);
        g_state.startup_backend = std::move(backend);
      }
    } catch (std::exception const& e) {
      std::lock_guard lock(g_state.startup_mutex);
      g_state.startup_error = e.what();
    }
    g_idle_add(on_backend_finished, nullptr);
  });
}

void on_power_on_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr || g_state.target_id.empty()) {
    return;
  }
  g_state.set_buttons_sensitive(false);
  g_state.set_status("Powering on…");
  std::string const target = g_state.target_id;
  rivet_app::API* api = g_state.api.get();
  run_job([api, target](UiJob& job) {
    rivet_app::PowerOnResult const result =
        api->power_on(target, 12000, 2000).get();
    job.apply = [result]() {
      g_state.set_status(result.ok ? "Power on: " +
                                       std::to_string(result.voltage_millivolts / 1000) +
                                       " V settled"
                                   : "Power on failed: " +
                                       result.error.value_or("unknown error"));
    };
  });
}

void on_power_off_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr || g_state.target_id.empty()) {
    return;
  }
  g_state.set_buttons_sensitive(false);
  g_state.set_status("Powering off…");
  std::string const target = g_state.target_id;
  rivet_app::API* api = g_state.api.get();
  run_job([api, target](UiJob& job) {
    rivet_app::ActionResult const result = api->power_off(target).get();
    job.apply = [result]() {
      g_state.set_status(result.ok ? "Power off."
                                   : "Power off failed: " +
                                       result.error.value_or("unknown error"));
    };
  });
}

void on_dtc_read_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr || g_state.target_id.empty()) {
    return;
  }
  g_state.set_buttons_sensitive(false);
  g_state.set_status("Reading DTCs…");
  std::string const target = g_state.target_id;
  rivet_app::API* api = g_state.api.get();
  run_job([api, target](UiJob& job) {
    rivet_app::DtcReadResult const result = api->dtc_read(target, std::nullopt).get();
    std::string text;
    if (!result.positive) {
      text = "DTC read: " + result.error.value_or("the ECU did not answer.");
    } else if (result.dtcs.empty()) {
      text = "DTC memory: no faults stored" +
             (result.available_mask.has_value()
                  ? " (availability " + *result.available_mask + ")"
                  : "");
    } else {
      text = "DTC memory:";
      for (auto const& entry : result.dtcs) {
        text += "\n · " + entry.dtc + " status " + entry.status;
      }
    }
    job.apply = [text]() {
      gtk_label_set_text(g_state.history, text.c_str());
    };
  });
}

void on_refresh_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) {
    return;
  }
  g_state.set_buttons_sensitive(false);
  fetch_status();
  fetch_history();
}

void on_activate(GtkApplication* app, gpointer) {
  if (g_state.window != nullptr) {
    gtk_window_present(g_state.window);
    return;
  }

  auto* window = gtk_application_window_new(app);
  gtk_window_set_title(GTK_WINDOW(window), "BenchPilot Studio");
  gtk_window_set_default_size(GTK_WINDOW(window), 560, 480);

  auto* root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
  gtk_widget_set_margin_top(root, 24);
  gtk_widget_set_margin_bottom(root, 24);
  gtk_widget_set_margin_start(root, 24);
  gtk_widget_set_margin_end(root, 24);
  gtk_widget_set_valign(root, GTK_ALIGN_FILL);
  gtk_widget_set_halign(root, GTK_ALIGN_FILL);

  auto* title = gtk_label_new("BenchPilot Studio");
  gtk_widget_add_css_class(title, "title-1");
  gtk_widget_set_halign(title, GTK_ALIGN_START);
  auto* status = gtk_label_new("Starting embedded Racket CS…");
  gtk_widget_add_css_class(status, "dim-label");
  gtk_widget_set_halign(status, GTK_ALIGN_START);
  auto* info = gtk_label_new("");
  gtk_widget_set_halign(info, GTK_ALIGN_START);

  auto* controls = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  auto* power_on = gtk_button_new_with_label("Power on");
  auto* power_off = gtk_button_new_with_label("Power off");
  auto* dtc_read = gtk_button_new_with_label("Read DTCs");
  auto* refresh = gtk_button_new_with_label("Refresh");
  gtk_widget_set_sensitive(power_on, FALSE);
  gtk_widget_set_sensitive(power_off, FALSE);
  gtk_widget_set_sensitive(dtc_read, FALSE);
  gtk_widget_set_sensitive(refresh, FALSE);
  gtk_box_append(GTK_BOX(controls), power_on);
  gtk_box_append(GTK_BOX(controls), power_off);
  gtk_box_append(GTK_BOX(controls), dtc_read);
  gtk_box_append(GTK_BOX(controls), refresh);

  auto* history = gtk_label_new("Recent operations:");
  gtk_widget_set_halign(history, GTK_ALIGN_START);

  gtk_box_append(GTK_BOX(root), title);
  gtk_box_append(GTK_BOX(root), status);
  gtk_box_append(GTK_BOX(root), info);
  gtk_box_append(GTK_BOX(root), controls);
  gtk_box_append(GTK_BOX(root), history);
  gtk_window_set_child(GTK_WINDOW(window), root);

  g_state.status = GTK_LABEL(status);
  g_state.info = GTK_LABEL(info);
  g_state.history = GTK_LABEL(history);
  g_state.power_on = GTK_BUTTON(power_on);
  g_state.power_off = GTK_BUTTON(power_off);
  g_state.dtc_read = GTK_BUTTON(dtc_read);
  g_state.refresh = GTK_BUTTON(refresh);
  g_state.window = GTK_WINDOW(window);
  g_signal_connect(power_on, "clicked",
                   G_CALLBACK(on_power_on_clicked), nullptr);
  g_signal_connect(power_off, "clicked",
                   G_CALLBACK(on_power_off_clicked), nullptr);
  g_signal_connect(dtc_read, "clicked",
                   G_CALLBACK(on_dtc_read_clicked), nullptr);
  g_signal_connect(refresh, "clicked",
                   G_CALLBACK(on_refresh_clicked), nullptr);

  gtk_window_present(GTK_WINDOW(window));
  start_backend();
}

void on_shutdown(GApplication*, gpointer) {
  g_state.shutting_down.store(true, std::memory_order_release);
  if (g_state.startup_thread.joinable()) {
    g_state.startup_thread.join();
  }

  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  {
    std::lock_guard lock(g_state.startup_mutex);
    startup_backend = std::move(g_state.startup_backend);
  }
  if (startup_backend != nullptr) {
    startup_backend->stop();
  }
  if (g_state.backend != nullptr) {
    g_state.backend->stop();
  }
}

}  // namespace

int main(int argc, char** argv) {
  auto* app = gtk_application_new("site.jrtx.benchpilot-studio",
                                  G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);
  g_signal_connect(app, "shutdown", G_CALLBACK(on_shutdown), nullptr);
  int const status = g_application_run(G_APPLICATION(app), argc, argv);
  g_object_unref(app);
  return status;
}
