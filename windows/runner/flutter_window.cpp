#include "flutter_window.h"

#include <optional>
#include <vector>

#include "desktop_multi_window/desktop_multi_window_plugin.h"
#include "flutter/generated_plugin_registrant.h"
#include "process_job.h"

namespace {

// Child windows (standalone player) run on separate engines, so each one
// needs its own process-job channel. The handlers must outlive the engines.
std::vector<std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>>
    g_child_process_job_channels;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  process_job_channel_ =
      RegisterProcessJobChannel(flutter_controller_->engine()->messenger());
  // Child windows (standalone player) own a separate Flutter engine: desktop
  // plugins must be registered per engine, otherwise fvp / window_manager /
  // video output are unavailable in the child window.
  DesktopMultiWindowSetWindowCreatedCallback([](void* controller) {
    auto* flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController*>(controller);
    auto* registry = flutter_view_controller->engine();
    RegisterPlugins(registry);
    g_child_process_job_channels.push_back(
        RegisterProcessJobChannel(registry->messenger()));
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // WM_CLOSE / WM_TIMER are handled before the Flutter dispatch below: with
  // window_manager's "prevent close" the plugin consumes WM_CLOSE (returns -1),
  // so a watchdog has to be armed first. Dart then stops the streaming JVM and
  // posts WM_QUIT; if that never happens the window is destroyed (and the app
  // exits) from here instead of leaving an unclosable window behind.
  constexpr UINT_PTR kCloseWatchdogId = 0x4B4Eu;  // 'KN'
  constexpr UINT kCloseWatchdogMs = 5000;
  if (message == WM_CLOSE) {
    if (close_watchdog_ == 0) {
      close_watchdog_ = ::SetTimer(hwnd, kCloseWatchdogId, kCloseWatchdogMs, nullptr);
    }
  } else if (message == WM_TIMER && wparam == kCloseWatchdogId) {
    close_watchdog_ = 0;
    ::KillTimer(hwnd, kCloseWatchdogId);
    ::DestroyWindow(hwnd);
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
