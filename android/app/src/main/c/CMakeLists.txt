cmake_minimum_required(VERSION 3.12.0)
project(ilm_gui)

# find_package(SDL3 CONFIG REQUIRED)

# add_library(ilm_gui_lib STATIC IMPORTED)
# set_target_properties(ilm_gui_lib PROPERTIES IMPORTED_LOCATION ${CMAKE_SOURCE_DIR}/prebuilt/${ANDROID_ABI}/libilm-gui.a)

# find_library(log-lib log)

# add_library(ilm_gui SHARED main.c)
# target_link_libraries(ilm_gui
#   ${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${ANDROID_ABI}/libilm-gui.a
#   ${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${ANDROID_ABI}/libgraphviz.a
#   ${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${ANDROID_ABI}/libplutovg.a
#   ${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${ANDROID_ABI}/libsqlite.a
#   ${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${ANDROID_ABI}/libiroh_c_ffi.a
#   SDL3::SDL3
#   ${log-lib}
# )

# Built by `zig build lib` in ../zig-project (single ABI: arm64-v8a).
set(ZIG_OUT_LIB ${CMAKE_SOURCE_DIR}/../../../../../zig-out/lib)

add_library(ilm_gui_lib STATIC IMPORTED)
set_target_properties(ilm_gui_lib PROPERTIES IMPORTED_LOCATION ${ZIG_OUT_LIB}/libilm-gui.a)
add_library(sdl3_lib STATIC IMPORTED)
set_target_properties(sdl3_lib PROPERTIES IMPORTED_LOCATION ${ZIG_OUT_LIB}/libSDL3.a)

add_library(ilm_gui SHARED main.c)
target_include_directories(ilm_gui PRIVATE ${ZIG_OUT_LIB}/../include)
# whole-archive: SDL's JNI entry points (JNI_OnLoad, Java_org_libsdl_app_*) are only
# looked up at runtime by the JVM, so a plain static link would drop them.
target_link_libraries(ilm_gui PRIVATE
    ilm_gui_lib
    ${ZIG_OUT_LIB}/libgraphviz.a
    ${ZIG_OUT_LIB}/libplutovg.a
    ${ZIG_OUT_LIB}/libsqlite.a
    ${ZIG_OUT_LIB}/libcrsql_bundle.a
    ${ZIG_OUT_LIB}/libiroh_c_ffi.a
    -Wl,--whole-archive sdl3_lib -Wl,--no-whole-archive
    android log dl m EGL GLESv1_CM GLESv2 OpenSLES)
