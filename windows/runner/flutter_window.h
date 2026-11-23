#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Watchdog armed on WM_CLOSE. Dart owns the close path (window_manager keeps the
  // close message from destroying the window until the app cleaned up its child
  // processes); this timer force-closes the window if Dart never finishes.
  UINT_PTR close_watchdog_ = 0;

  // Keeps the "misatv/process_job" method-channel handler registered for the
  // lifetime of this engine.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      process_job_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
