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
  Title(L"Rivet — Racket + WinUI 3");
  InitializeBackendAsync();
}

winrt::fire_and_forget MainWindow::InitializeBackendAsync() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = std::make_shared<rivet::windows::Backend>(runtime_config());

  try {
    // Booting the embedded runtime can block on file I/O, so only startup is
    // moved off the UI thread. RPC/State traffic below is completion-driven.
    co_await winrt::resume_background();
    backend->start();

    dispatcher.TryEnqueue([weak, backend = std::move(backend)]() mutable {
      if (auto window = weak.get()) {
        window->backend_ = std::move(backend);
        try {
          rivet_app::API api(*window->backend_);
          auto const callbackDispatcher = window->DispatcherQueue();
          auto const callbackWeak = window->get_weak();
          (void)api.get_counter_async(
              [callbackDispatcher, callbackWeak](rivet_app::Result<std::int64_t> result) {
                try {
                  auto const initial = result.get();
                  callbackDispatcher.TryEnqueue([callbackWeak, initial] {
                    if (auto current = callbackWeak.get()) {
                      current->count_.store(initial, std::memory_order_relaxed);
                      std::wstring text = L"Count: ";
                      text += std::to_wstring(initial);
                      current->CountText().Text(winrt::hstring(text));
                      current->SetReadyUi();
                    }
                  });
                } catch (std::exception const& e) {
                  auto message = std::string(e.what());
                  callbackDispatcher.TryEnqueue(
                      [callbackWeak, message = std::move(message)] {
                        if (auto current = callbackWeak.get()) {
                          current->SetErrorUi(message);
                        }
                      });
                }
              });
        } catch (std::exception const& e) {
          window->SetErrorUi(e.what());
        }
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

void MainWindow::Increment_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  IncrementAsync();
}

void MainWindow::IncrementAsync() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  if (backend == nullptr || !backend->running()) {
    SetErrorUi("Racket backend is not running");
    return;
  }

  auto const next = count_.load(std::memory_order_relaxed) + 1;
  IncrementButton().IsEnabled(false);

  try {
    rivet_app::API api(*backend);
    (void)api.set_counter_async(
        next,
        [dispatcher, weak](rivet_app::Result<std::int64_t> result) {
          try {
            auto const stored = result.get();
            dispatcher.TryEnqueue([weak, stored] {
              if (auto window = weak.get()) {
                window->count_.store(stored, std::memory_order_relaxed);
                std::wstring text = L"Count: ";
                text += std::to_wstring(stored);
                window->CountText().Text(winrt::hstring(text));
                window->IncrementButton().IsEnabled(true);
              }
            });
          } catch (std::exception const& e) {
            auto message = std::string(e.what());
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) {
                window->SetErrorUi(message);
                window->IncrementButton().IsEnabled(true);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    SetErrorUi(e.what());
    IncrementButton().IsEnabled(true);
  }
}

void MainWindow::SetReadyUi() {
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Success);
  StatusBar().Message(L"Embedded Racket CS is ready");
  IncrementButton().IsEnabled(true);
}

void MainWindow::SetErrorUi(std::string const& message) {
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Error);
  StatusBar().Message(winrt::to_hstring(message));
}

}  // namespace winrt::RivetHost::implementation
