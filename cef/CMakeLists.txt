# Fotufilm Desktop: the web editor in the Chromium Embedded Framework, over a native compositor.
#
#   cmake -S cef -B build/cef-host -G Ninja -DCEF_ROOT="$(cef/fetch-cef.sh)"
#   cmake --build build/cef-host
#
# cef/build.sh does both and bundles the web build.
cmake_minimum_required(VERSION 3.21)
# The engine library, like the Mac app, targets macOS 14.
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS")
project(FotufilmDesktop LANGUAGES C CXX)
if(APPLE)
  enable_language(OBJC OBJCXX)
endif()

set(CEF_ROOT "" CACHE PATH "The unpacked CEF distribution (cef/fetch-cef.sh prints it)")
if(NOT EXISTS "${CEF_ROOT}/cmake/FindCEF.cmake")
  message(FATAL_ERROR "Set CEF_ROOT to the path cef/fetch-cef.sh prints.")
endif()
set(FOTUFILM_WEB_DIST "${CMAKE_CURRENT_SOURCE_DIR}/../web/dist" CACHE PATH
    "The built web editor bundled as fotufilm://app/")
set(FOTUFILM_ENGINE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../build/cef-engine" CACHE PATH
    "libfotufilm and its resources (cef/build-engine.sh); without it the editor keeps its browser engine")
set(FOTUFILM_PLUGINS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../build" CACHE PATH
    "Where tools/build-editor-plugins.sh leaves resolve/ and finalcut/; the engine installs them")

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CEF_ROOT}/cmake")
# Linux ships as an AppImage, which cannot carry Chromium's setuid sandbox helper. The editor only
# loads its own bundled pages (or a trusted development server), as on the Mac.
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  set(USE_SANDBOX OFF CACHE BOOL "Chromium's sandbox" FORCE)
endif()
find_package(CEF REQUIRED)
SET_CEF_TARGET_OUT_DIR()
# No path of the machine that built it goes into the app: source paths in assertions are written
# relative to the checkout and the CEF distribution, and links leave out debug maps and local
# symbols, as the Mac app's build does.
get_filename_component(_checkout "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
add_compile_options("-ffile-prefix-map=${_checkout}=Fotufilm" "-ffile-prefix-map=${CEF_ROOT}=CEF")
if(APPLE)
  add_link_options("LINKER:-S" "LINKER:-x")
endif()
add_subdirectory(${CEF_LIBCEF_DLL_WRAPPER_PATH} libcef_dll_wrapper)

file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/../version.env" _versions)
foreach(_line ${_versions})
  if(_line MATCHES "^MARKETING_VERSION=(.*)$")
    set(FOTUFILM_MARKETING_VERSION "${CMAKE_MATCH_1}")
  elseif(_line MATCHES "^CURRENT_PROJECT_VERSION=(.*)$")
    set(FOTUFILM_PROJECT_VERSION "${CMAKE_MATCH_1}")
  endif()
endforeach()

# The renderer installs bridge.js before any page script runs; it is compiled in, not fetched.
set(_bridge_js "${CMAKE_CURRENT_SOURCE_DIR}/src/renderer/bridge.js")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_bridge_js}")
file(READ "${_bridge_js}" FOTUFILM_BRIDGE_JS)
file(CONFIGURE
  OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/generated/renderer/bridge_script.h"
  CONTENT "#pragma once\n\n// Generated from src/renderer/bridge.js.\ninline constexpr char kBridgeScript[] = R\"FOTUFILM(@FOTUFILM_BRIDGE_JS@)FOTUFILM\";\n"
  @ONLY)

set(FOTUFILM_COMMON_SOURCES
  src/app/browser_app.cc
  src/app/scheme.cc
  src/renderer/renderer_bridge.cc
)
set(FOTUFILM_BROWSER_SOURCES
  src/app/client.cc
  src/app/host_capabilities.cc
  src/app/library_folders.cc
  src/app/library_methods.cc
  src/bridge/dispatcher.cc
  src/presentation/compositor_core.cc
  src/presentation/image_layer.cc
  src/presentation/pooled_presenter.cc
  src/presentation/presentation_methods.cc
)
set(FOTUFILM_ENGINE_LIBRARY "${FOTUFILM_ENGINE_DIR}/libfotufilm${CMAKE_SHARED_LIBRARY_SUFFIX}")
if(EXISTS "${FOTUFILM_ENGINE_LIBRARY}")
  set(FOTUFILM_WITH_ENGINE ON)
  list(APPEND FOTUFILM_BROWSER_SOURCES src/engine/engine_bridge.cc)
else()
  message(WARNING "No engine at ${FOTUFILM_ENGINE_LIBRARY}; run cef/build-engine.sh "
                  "(cef/build-engine-linux.sh on Linux). "
                  "The editor will use its browser engine.")
endif()

function(fotufilm_target target)
  SET_EXECUTABLE_TARGET_PROPERTIES(${target})
  add_dependencies(${target} libcef_dll_wrapper)
  target_link_libraries(${target} libcef_dll_wrapper ${CEF_STANDARD_LIBS})
  target_include_directories(${target} PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${CMAKE_CURRENT_BINARY_DIR}/generated")
endfunction()

if(OS_MAC)
  set(FOTUFILM_APP_NAME "Fotufilm")
  set(FOTUFILM_HELPER_NAME "Fotufilm Helper")
  # The Mac app's identity. An official build (cef/build.sh with FOTUFILM_SOURCE_BUILD=0) replaces the
  # Mac app in place and reads its release feed; a source build is an app of its own, with no feed.
  set(FOTUFILM_BUNDLE_ID "com.muastudio.fotufilm.source" CACHE STRING "The app's bundle identifier")
  set(FOTUFILM_UPDATE_FEED "" CACHE STRING "The release feed Check for Updates reads")
  set(FOTUFILM_RELEASE_LIST "" CACHE STRING "The release list pre-release updates are read from")
  set(_mac_sources
    src/platform/mac/compositor.mm
    src/platform/mac/export_files.mm
    src/platform/mac/host_window.mm
    src/platform/mac/image_presenter.mm
    src/platform/mac/main_menu.mm
    src/platform/mac/main.mm)
  # CEF's flags cover C++ sources only; Objective-C++ needs the same standard, and no RTTI, so
  # its classes can derive from the portable ones compiled as C++.
  set_source_files_properties(${_mac_sources} PROPERTIES
    COMPILE_OPTIONS "-fobjc-arc;-std=c++20;-fno-rtti")

  add_executable(fotufilm_desktop MACOSX_BUNDLE
    ${FOTUFILM_COMMON_SOURCES} ${FOTUFILM_BROWSER_SOURCES} ${_mac_sources})
  fotufilm_target(fotufilm_desktop)
  target_link_libraries(fotufilm_desktop
    "-framework Metal" "-framework QuartzCore" "-framework IOSurface"
    "-framework UniformTypeIdentifiers" "-framework ImageIO")
  if(FOTUFILM_WITH_ENGINE)
    target_compile_definitions(fotufilm_desktop PRIVATE FOTUFILM_WITH_ENGINE=1)
    target_include_directories(fotufilm_desktop PRIVATE
      "${CMAKE_CURRENT_SOURCE_DIR}/../Sources/CFotufilmHost/include")
    target_link_libraries(fotufilm_desktop "${FOTUFILM_ENGINE_LIBRARY}")
    # Only the bundle's own Frameworks: CMake would otherwise add the build folder the library
    # was linked from.
    set_target_properties(fotufilm_desktop PROPERTIES
      BUILD_WITH_INSTALL_RPATH ON INSTALL_RPATH "@executable_path/../Frameworks")
  endif()
  set(EXECUTABLE_NAME "${FOTUFILM_APP_NAME}")
  set(PRODUCT_NAME "${FOTUFILM_APP_NAME}")
  configure_file(mac/Info.plist.in "${CMAKE_CURRENT_BINARY_DIR}/Info.plist")
  set_target_properties(fotufilm_desktop PROPERTIES
    OUTPUT_NAME "${FOTUFILM_APP_NAME}"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist")
  set(_app "${CEF_TARGET_OUT_DIR}/${FOTUFILM_APP_NAME}.app")

  add_custom_command(TARGET fotufilm_desktop POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CEF_BINARY_DIR}/Chromium Embedded Framework.framework"
            "${_app}/Contents/Frameworks/Chromium Embedded Framework.framework"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CMAKE_CURRENT_SOURCE_DIR}/resources/diagnostics"
            "${_app}/Contents/Resources/diagnostics"
    VERBATIM)
  # The web build and the engine change without the host relinking, so they are copied into the
  # bundle on every build rather than after a link.
  set(_bundle_commands)
  if(FOTUFILM_WITH_ENGINE)
    # The engine reads its films, camera profiles and priors from the main bundle.
    list(APPEND _bundle_commands
      COMMAND ${CMAKE_COMMAND} -E copy "${FOTUFILM_ENGINE_LIBRARY}"
              "${_app}/Contents/Frameworks/libfotufilm.dylib"
      COMMAND ${CMAKE_COMMAND} -E copy_directory "${FOTUFILM_ENGINE_DIR}/Resources"
              "${_app}/Contents/Resources"
      COMMAND ${CMAKE_COMMAND} -E rm -f "${_app}/Contents/Resources/fotufilm-bench")
  endif()
  # The Resolve and Final Cut plug-ins, where tools/build-editor-plugins.sh built them, go where
  # the Mac app keeps its own: the engine installs them from the bundle's resources. ditto keeps the
  # signatures of the nested bundles intact; a plug-in no longer built is taken out.
  foreach(_plugin "resolve/Fotufilm.ofx.bundle" "finalcut/Fotufilm for Final Cut Pro.app")
    get_filename_component(_plugin_name "${_plugin}" NAME)
    list(APPEND _bundle_commands
      COMMAND ${CMAKE_COMMAND} -E rm -rf "${_app}/Contents/Resources/${_plugin_name}")
    if(FOTUFILM_WITH_ENGINE AND EXISTS "${FOTUFILM_PLUGINS_DIR}/${_plugin}")
      list(APPEND _bundle_commands
        COMMAND ditto "${FOTUFILM_PLUGINS_DIR}/${_plugin}"
                "${_app}/Contents/Resources/${_plugin_name}")
    endif()
  endforeach()
  # The app's icon, compiled from its Icon Composer layers.
  list(APPEND _bundle_commands
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/mac/compile-icon.sh"
            "${CMAKE_CURRENT_SOURCE_DIR}/mac/AppIcon.icon" "${_app}/Contents/Resources"
            "${CMAKE_CURRENT_BINARY_DIR}/icon-partial.plist")
  if(EXISTS "${FOTUFILM_WEB_DIST}/index.html")
    list(APPEND _bundle_commands
      COMMAND ${CMAKE_COMMAND} -E rm -rf "${_app}/Contents/Resources/web"
      COMMAND ${CMAKE_COMMAND} -E copy_directory "${FOTUFILM_WEB_DIST}"
              "${_app}/Contents/Resources/web")
  else()
    message(WARNING "No web build at ${FOTUFILM_WEB_DIST}; run npm run build in web/.")
  endif()
  if(_bundle_commands)
    add_custom_target(fotufilm_bundle ALL ${_bundle_commands} VERBATIM)
    add_dependencies(fotufilm_bundle fotufilm_desktop)
  endif()

  # Chromium launches each process type from its own helper bundle.
  foreach(_suffixes ${CEF_HELPER_APP_SUFFIXES})
    string(REPLACE ":" ";" _suffixes ${_suffixes})
    list(GET _suffixes 0 _name_suffix)
    list(GET _suffixes 1 _target_suffix)
    list(GET _suffixes 2 _plist_suffix)
    set(_helper "fotufilm_desktop_helper${_target_suffix}")
    set(_helper_name "${FOTUFILM_HELPER_NAME}${_name_suffix}")
    set(EXECUTABLE_NAME "${_helper_name}")
    set(PRODUCT_NAME "${_helper_name}")
    set(BUNDLE_ID_SUFFIX "${_plist_suffix}")
    configure_file(mac/helper-Info.plist.in
                   "${CMAKE_CURRENT_BINARY_DIR}/helper-Info${_target_suffix}.plist")
    add_executable(${_helper} MACOSX_BUNDLE
      ${FOTUFILM_COMMON_SOURCES} src/platform/mac/helper.cc)
    fotufilm_target(${_helper})
    set_target_properties(${_helper} PROPERTIES
      OUTPUT_NAME "${_helper_name}"
      MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/helper-Info${_target_suffix}.plist")
    add_dependencies(fotufilm_desktop ${_helper})
    add_custom_command(TARGET fotufilm_desktop POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_directory
              "${CEF_TARGET_OUT_DIR}/${_helper_name}.app"
              "${_app}/Contents/Frameworks/${_helper_name}.app"
      VERBATIM)
  endforeach()
elseif(OS_LINUX)
  # One executable for every CEF process, in an ordinary window Chromium paints
  # (app/windowed_host.h); CEF's libraries and data, the web build and the engine sit beside it.
  add_executable(fotufilm_desktop
    ${FOTUFILM_COMMON_SOURCES} ${FOTUFILM_BROWSER_SOURCES}
    src/app/file_panels.cc
    src/app/windowed_host.cc
    src/platform/linux/main.cc
    src/platform/linux/system_open.cc)
  fotufilm_target(fotufilm_desktop)
  # The Mac loads CEF's framework at run time; Linux links libcef.so beside the executable.
  ADD_LOGICAL_TARGET("libcef_lib" "${CEF_LIB_DEBUG}" "${CEF_LIB_RELEASE}")
  target_link_libraries(fotufilm_desktop libcef_lib)
  set_target_properties(fotufilm_desktop PROPERTIES
    OUTPUT_NAME fotufilm BUILD_WITH_INSTALL_RPATH ON INSTALL_RPATH "$ORIGIN")
  if(FOTUFILM_WITH_ENGINE)
    target_compile_definitions(fotufilm_desktop PRIVATE FOTUFILM_WITH_ENGINE=1)
    target_include_directories(fotufilm_desktop PRIVATE
      "${CMAKE_CURRENT_SOURCE_DIR}/../Sources/CFotufilmHost/include")
    target_link_libraries(fotufilm_desktop "${FOTUFILM_ENGINE_LIBRARY}")
  endif()
  COPY_FILES(fotufilm_desktop "${CEF_BINARY_FILES}" "${CEF_BINARY_DIR}" "${CEF_TARGET_OUT_DIR}")
  COPY_FILES(fotufilm_desktop "${CEF_RESOURCE_FILES}" "${CEF_RESOURCE_DIR}" "${CEF_TARGET_OUT_DIR}")

  set(_out "${CEF_TARGET_OUT_DIR}")
  set(_bundle_commands
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CMAKE_CURRENT_SOURCE_DIR}/resources/diagnostics" "${_out}/diagnostics")
  if(FOTUFILM_WITH_ENGINE)
    list(APPEND _bundle_commands
      COMMAND ${CMAKE_COMMAND} -E copy "${FOTUFILM_ENGINE_LIBRARY}" "${_out}/"
      COMMAND ${CMAKE_COMMAND} -E rm -rf "${_out}/resources"
      COMMAND ${CMAKE_COMMAND} -E copy_directory "${FOTUFILM_ENGINE_DIR}/Resources"
              "${_out}/resources")
  endif()
  if(EXISTS "${FOTUFILM_WEB_DIST}/index.html")
    list(APPEND _bundle_commands
      COMMAND ${CMAKE_COMMAND} -E rm -rf "${_out}/web"
      COMMAND ${CMAKE_COMMAND} -E copy_directory "${FOTUFILM_WEB_DIST}" "${_out}/web"
      COMMAND ${CMAKE_COMMAND} -E copy "${FOTUFILM_WEB_DIST}/app-icon.png" "${_out}/fotufilm.png")
  else()
    message(WARNING "No web build at ${FOTUFILM_WEB_DIST}; run npm run build in web/.")
  endif()
  add_custom_target(fotufilm_bundle ALL ${_bundle_commands} VERBATIM)
  add_dependencies(fotufilm_bundle fotufilm_desktop)
else()
  message(FATAL_ERROR "Fotufilm Desktop builds on macOS and Linux so far; Windows follows cef/README.md.")
endif()

PRINT_CEF_CONFIG()
