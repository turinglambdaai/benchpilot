#pragma once

#include "pch.h"
#include "MainWindow.g.h"

namespace winrt::RivetHost::implementation {

struct MainWindow : MainWindowT<MainWindow> {
  MainWindow();

  void Increment_Click(winrt::Windows::Foundation::IInspectable const& sender,
                       Microsoft::UI::Xaml::RoutedEventArgs const& args);

 private:
  winrt::fire_and_forget InitializeBackendAsync();
  void IncrementAsync();
  void SetReadyUi();
  void SetErrorUi(std::string const& message);

  std::shared_ptr<rivet::windows::Backend> backend_;
  std::atomic<std::int64_t> count_{0};
};

}  // namespace winrt::RivetHost::implementation

namespace winrt::RivetHost::factory_implementation {

struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};

}  // namespace winrt::RivetHost::factory_implementation
