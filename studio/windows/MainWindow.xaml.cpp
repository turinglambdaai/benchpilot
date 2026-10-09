#include "pch.h"
#include "MainWindow.xaml.h"
#if __has_include("MainWindow.g.cpp")
#include "MainWindow.g.cpp"
#endif
#include "GeneratedBackend.hpp"

#include <stdexcept>

namespace winrt::RivetHost::implementation {
namespace {

std::filesystem::path executable_path() {
  std::wstring buffer(32768, L'\0');
  auto const length = ::GetModuleFileNameW(nullptr, buffer.data(),
                                          static_cast<DWORD>(buffer.size()));
  if (length == 0 || length == buffer.size()) {
    throw std::runtime_error("GetModuleFileNameW failed");
  }
  buffer.resize(length);
  return std::filesystem::path(buffer);
}

std::string utf8(std::filesystem::path const& path) {
  auto const wide = path.wstring();
  if (wide.empty()) {
    return {};
  }
  auto const size = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                          wide.data(),
                                          static_cast<int>(wide.size()),
                                          nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  std::string result(static_cast<std::size_t>(size), '\0');
  if (::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                            wide.data(), static_cast<int>(wide.size()),
                            result.data(), size, nullptr, nullptr) != size) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  return result;
}

std::wstring wide(std::string const& text) {
  return std::wstring(winrt::to_hstring(text).c_str());
}

rivet::windows::RacketRuntimeConfig runtime_config() {
  auto const exe = executable_path();
  auto const root = exe.parent_path();
  auto const runtime = root / L"runtime";

  rivet::windows::RacketRuntimeConfig config;
  config.executable_path = utf8(exe);
  config.petite_boot = utf8(runtime / L"petite.boot");
  config.scheme_boot = utf8(runtime / L"scheme.boot");
  config.racket_boot = utf8(runtime / L"racket.boot");
  config.backend_bundle = utf8(root / L"res" / L"core.zo");
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;
  config.dll_dir = runtime.wstring();
  return config;
}

}  // namespace

MainWindow::MainWindow() {
  InitializeComponent();
  Title(L"BenchPilot Studio");
  InitializeBackendAsync();
}

// One background job: `body` runs off the UI thread and touches widgets only
// through the dispatcher lambdas it enqueues itself.
void MainWindow::RunJob(std::function<void()> body) {
  auto const weak = get_weak();
  std::thread([weak, body = std::move(body)]() mutable {
    try {
      body();
    } catch (std::exception const& e) {
      auto const message = std::string(e.what());
      if (auto window = weak.get()) {
        window->DispatcherQueue().TryEnqueue([weak, message] {
          if (auto current = weak.get()) {
            current->SetErrorUi(message);
            current->SetButtonsEnabled(true);
          }
        });
      }
    }
  }).detach();
}

void MainWindow::FetchStatus() {
  auto const weak = get_weak();
  auto backend = backend_;
  RunJob([weak, backend]() mutable {
    rivet_app::API api(*backend);
    rivet_app::RuntimeStatus const status = api.status().get();
    std::wstring text = wide(status.name);
    if (status.runtime_version.has_value()) {
      text += L" · runtime " + wide(*status.runtime_version);
    }
    text += L"\n" + std::to_wstring(status.targets.size()) + L" target(s):";
    std::wstring first_target;
    for (auto const& target : status.targets) {
      if (first_target.empty()) {
        first_target = wide(target.id);
      }
      text += L"\n · " + wide(target.name) + L" (" + wide(target.id) + L")";
    }
    if (auto window = weak.get()) {
      window->DispatcherQueue().TryEnqueue([weak, text, first_target] {
        if (auto current = weak.get()) {
          current->target_id_ = first_target;
          current->InfoText().Text(text);
        }
      });
    }
  });
}

void MainWindow::FetchHistory() {
  auto const weak = get_weak();
  auto backend = backend_;
  RunJob([weak, backend]() mutable {
    rivet_app::API api(*backend);
    auto const past = api.operation_history(5).get();
    std::wstring text = L"Recent operations:";
    if (past.empty()) {
      text += L" none yet";
    }
    for (auto const& entry : past) {
      text += L"\n · " + wide(entry.state) + L" " + wide(entry.kind) + L" (" +
              std::to_wstring(entry.duration_ms) + L" ms)";
    }
    if (auto window = weak.get()) {
      window->DispatcherQueue().TryEnqueue([weak, text] {
        if (auto current = weak.get()) {
          current->HistoryText().Text(text);
        }
      });
    }
  });
}

winrt::fire_and_forget MainWindow::InitializeBackendAsync() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = std::make_shared<rivet::windows::Backend>(runtime_config());

  try {
    // Booting the embedded runtime can block on file I/O, so only startup is
    // moved off the UI thread.
    co_await winrt::resume_background();
    backend->start();

    dispatcher.TryEnqueue([weak, backend = std::move(backend)]() mutable {
      if (auto window = weak.get()) {
        window->backend_ = std::move(backend);
        window->SetReadyUi();
        window->FetchStatus();
        window->FetchHistory();
      } else {
        // Never destroy the last Backend reference on its own reader thread.
        std::thread([backend = std::move(backend)]() mutable {
          backend->stop();
        }).detach();
      }
    });
  } catch (std::exception const& e) {
    auto message = std::string(e.what());
    dispatcher.TryEnqueue([weak, message = std::move(message)] {
      if (auto window = weak.get()) {
        window->SetErrorUi(message);
      }
    });
  }
}

void MainWindow::PowerOn_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  auto const weak = get_weak();
  auto backend = backend_;
  if (backend == nullptr || !backend->running() || target_id_.empty()) {
    SetErrorUi("Racket backend is not running");
    return;
  }
  SetButtonsEnabled(false);
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Informational);
  StatusBar().Message(L"Powering on…");
  auto const target = target_id_;
  RunJob([weak, backend, target]() mutable {
    rivet_app::API api(*backend);
    rivet_app::PowerOnResult const result =
        api.power_on(winrt::to_string(target), 12000, 2000).get();
    auto const line =
        result.ok ? L"Power on: 12 V settled"
                  : L"Power on failed: " + wide(result.error.value_or("unknown error"));
    auto const ok = result.ok;
    if (auto window = weak.get()) {
      window->DispatcherQueue().TryEnqueue([weak, line, ok] {
        if (auto current = weak.get()) {
          current->StatusBar().Severity(
              ok ? Microsoft::UI::Xaml::Controls::InfoBarSeverity::Success
                 : Microsoft::UI::Xaml::Controls::InfoBarSeverity::Error);
          current->StatusBar().Message(line);
          current->SetButtonsEnabled(true);
        }
      });
    }
  });
}

void MainWindow::PowerOff_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  auto const weak = get_weak();
  auto backend = backend_;
  if (backend == nullptr || !backend->running() || target_id_.empty()) {
    SetErrorUi("Racket backend is not running");
    return;
  }
  SetButtonsEnabled(false);
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Informational);
  StatusBar().Message(L"Powering off…");
  auto const target = target_id_;
  RunJob([weak, backend, target]() mutable {
    rivet_app::API api(*backend);
    rivet_app::ActionResult const result =
        api.power_off(winrt::to_string(target)).get();
    auto const line = result.ok ? L"Power off."
                                : L"Power off failed: " +
                                      wide(result.error.value_or("unknown error"));
    if (auto window = weak.get()) {
      window->DispatcherQueue().TryEnqueue([weak, line, ok = result.ok] {
        if (auto current = weak.get()) {
          current->StatusBar().Severity(
              ok ? Microsoft::UI::Xaml::Controls::InfoBarSeverity::Success
                 : Microsoft::UI::Xaml::Controls::InfoBarSeverity::Error);
          current->StatusBar().Message(line);
          current->SetButtonsEnabled(true);
        }
      });
    }
  });
}

void MainWindow::DtcRead_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  auto const weak = get_weak();
  auto backend = backend_;
  if (backend == nullptr || !backend->running() || target_id_.empty()) {
    SetErrorUi("Racket backend is not running");
    return;
  }
  SetButtonsEnabled(false);
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Informational);
  StatusBar().Message(L"Reading DTCs…");
  auto const target = target_id_;
  RunJob([weak, backend, target]() mutable {
    rivet_app::API api(*backend);
    rivet_app::DtcReadResult const result =
        api.dtc_read(winrt::to_string(target), std::nullopt).get();
    std::wstring text;
    if (!result.positive) {
      text = L"DTC read: " + wide(result.error.value_or("the ECU did not answer."));
    } else if (result.dtcs.empty()) {
      text = L"DTC memory: no faults stored";
    } else {
      text = L"DTC memory:";
      for (auto const& entry : result.dtcs) {
        text += L"\n · " + wide(entry.dtc) + L" status " + wide(entry.status);
      }
    }
    if (auto window = weak.get()) {
      window->DispatcherQueue().TryEnqueue([weak, text] {
        if (auto current = weak.get()) {
          current->DetailText().Text(text);
          current->SetButtonsEnabled(true);
        }
      });
    }
  });
}

void MainWindow::Refresh_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (backend_ == nullptr || !backend_->running()) {
    SetErrorUi("Racket backend is not running");
    return;
  }
  SetButtonsEnabled(false);
  FetchStatus();
  FetchHistory();
}

void MainWindow::SetReadyUi() {
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Success);
  StatusBar().Message(L"Connected");
  SetButtonsEnabled(true);
}

void MainWindow::SetErrorUi(std::string const& message) {
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Error);
  StatusBar().Message(winrt::to_hstring(message));
}

void MainWindow::SetButtonsEnabled(bool enabled) {
  auto const has_target = !target_id_.empty();
  PowerOnButton().IsEnabled(enabled && has_target);
  PowerOffButton().IsEnabled(enabled && has_target);
  DtcReadButton().IsEnabled(enabled && has_target);
  RefreshButton().IsEnabled(enabled);
}

}  // namespace winrt::RivetHost::implementation
