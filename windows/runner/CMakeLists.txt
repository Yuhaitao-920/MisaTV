cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "process_job.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Bundle the VC++ runtime app-locally.
#
# MisaTV.exe and the Flutter/plugin DLLs are linked with /MD, so a machine
# without the Visual C++ Redistributable fails to start with "VCRUNTIME140_1.dll
# not found" (or MSVCP140.dll). Windows searches the executable directory before
# System32, so shipping the three runtime DLLs next to the exe is enough and
# avoids requiring an administrator-level vc_redist install.
#
# Source: the Visual Studio redist directory matching the compiler toolset.
# Do not take msvcp140.dll from a JRE/bin directory: its older 14.x build can
# crash when paired with objects produced by a newer compiler.
if (MSVC)
  set(_vc_probe "${CMAKE_CXX_COMPILER}")
  if (NOT _vc_probe OR NOT _vc_probe MATCHES "/bin/Host")
    set(_vc_probe "${CMAKE_LINKER}")
  endif()
  if (_vc_probe AND NOT _vc_probe MATCHES "NOTFOUND")
    file(TO_CMAKE_PATH "${_vc_probe}" _vc_probe)
    if (_vc_probe MATCHES "/bin/Host")
      string(REGEX REPLACE "/bin/Host.*$" "" _msvc_toolset_dir "${_vc_probe}")
      get_filename_component(_msvc_version "${_msvc_toolset_dir}" NAME)
      string(REGEX REPLACE "/Tools/MSVC/.*$" "" _vc_root "${_msvc_toolset_dir}")
      set(_vc_redist_root "${_vc_root}/Redist/MSVC")
      set(_vc_crt_dir "")
      if (EXISTS "${_vc_redist_root}/${_msvc_version}/x64")
        file(GLOB _vc_crt_candidates
          "${_vc_redist_root}/${_msvc_version}/x64/Microsoft.VC*.CRT")
      else()
        file(GLOB _vc_crt_candidates
          "${_vc_redist_root}/*/x64/Microsoft.VC*.CRT")
      endif()
      if (_vc_crt_candidates)
        list(SORT _vc_crt_candidates)
        list(REVERSE _vc_crt_candidates)
        list(GET _vc_crt_candidates 0 _vc_crt_dir)
      endif()
      # Fallback: the toolset's own bin directory carries matching runtime DLLs.
      if (NOT _vc_crt_dir AND EXISTS "${_msvc_toolset_dir}/bin/Hostx64/x64/msvcp140.dll")
        set(_vc_crt_dir "${_msvc_toolset_dir}/bin/Hostx64/x64")
      endif()
      if (_vc_crt_dir)
        set(_vc_copy_commands)
        foreach(_vc_dll msvcp140.dll vcruntime140.dll vcruntime140_1.dll)
          if (EXISTS "${_vc_crt_dir}/${_vc_dll}")
            list(APPEND _vc_copy_commands
              COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${_vc_crt_dir}/${_vc_dll}"
                "$<TARGET_FILE_DIR:${BINARY_NAME}>/${_vc_dll}")
          else()
            message(WARNING "VC++ runtime ${_vc_dll} missing: ${_vc_crt_dir}")
          endif()
        endforeach()
        if (_vc_copy_commands)
          # ALL so an incremental build also repairs a Release folder whose
          # runtime DLLs were removed; copy_if_different keeps it cheap.
          add_custom_target(bundle_vc_runtime ALL
            ${_vc_copy_commands}
            DEPENDS ${BINARY_NAME}
            COMMENT "Bundling VC++ runtime")
        endif()
      else()
        message(WARNING "VC++ redist not found; the app may require vc_redist")
      endif()
    endif()
  endif()
endif()

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
