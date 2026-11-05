cmake_minimum_required(VERSION 3.25)
project(bundlr_native C)

# vcpkg's manifest and immutable baseline own the complete dependency graph.
if(NOT DEFINED VCPKG_TARGET_TRIPLET OR NOT DEFINED VCPKG_INSTALLED_DIR)
  message(FATAL_ERROR "Configure with the pinned vcpkg toolchain and a Bundlr triplet")
endif()
set(PREFIX "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}")
set(STAGE "${CMAKE_BINARY_DIR}/portable-libs" CACHE PATH "Native runtime output")
find_library(LLHTTP_ARCHIVE NAMES llhttp libllhttp PATHS "${PREFIX}/lib" NO_DEFAULT_PATH REQUIRED)

# llhttp's vcpkg port intentionally builds a static archive. Export its upstream
# objects as a shared library; no application C wrapper or runtime is introduced.
if(WIN32)
  set(LLHTTP_SHARED "${CMAKE_BINARY_DIR}/llhttp.dll")
  add_custom_command(OUTPUT "${LLHTTP_SHARED}"
    COMMAND "${CMAKE_LINKER}" /DLL /NOENTRY "/OUT:${LLHTTP_SHARED}"
      "/WHOLEARCHIVE:${LLHTTP_ARCHIVE}"
      /EXPORT:llhttp_init /EXPORT:llhttp_execute /EXPORT:llhttp_get_method
    DEPENDS "${LLHTTP_ARCHIVE}" VERBATIM)
elseif(APPLE)
  set(LLHTTP_SHARED "${CMAKE_BINARY_DIR}/libllhttp.dylib")
  add_custom_command(OUTPUT "${LLHTTP_SHARED}"
    COMMAND "${CMAKE_C_COMPILER}" -dynamiclib "-Wl,-force_load,${LLHTTP_ARCHIVE}"
      -o "${LLHTTP_SHARED}"
    DEPENDS "${LLHTTP_ARCHIVE}" VERBATIM)
else()
  set(LLHTTP_SHARED "${CMAKE_BINARY_DIR}/libllhttp.so")
  add_custom_command(OUTPUT "${LLHTTP_SHARED}"
    COMMAND "${CMAKE_C_COMPILER}" -shared -Wl,--whole-archive "${LLHTTP_ARCHIVE}"
      -Wl,--no-whole-archive -o "${LLHTTP_SHARED}"
    DEPENDS "${LLHTTP_ARCHIVE}" VERBATIM)
endif()
add_custom_target(portable ALL DEPENDS "${LLHTTP_SHARED}")
add_custom_command(TARGET portable POST_BUILD
  COMMAND "${CMAKE_COMMAND}" "-DPREFIX=${PREFIX}" "-DSTAGE=${STAGE}"
    "-DLLHTTP_SHARED=${LLHTTP_SHARED}" "-DPROJECT_ROOT=${CMAKE_CURRENT_SOURCE_DIR}/.."
    "-DTRIPLET=${VCPKG_TARGET_TRIPLET}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/stage.cmake" VERBATIM)
