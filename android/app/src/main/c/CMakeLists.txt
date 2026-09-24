cmake_minimum_required(VERSION 3.12.0)
project(ilm_gui)

find_package(SDL3 CONFIG REQUIRED)

add_library(ilm_gui_lib STATIC IMPORTED)
set_target_properties(ilm_gui_lib PROPERTIES IMPORTED_LOCATION ${CMAKE_SOURCE_DIR}/prebuilt/${ANDROID_ABI}/libilm-gui.a)

find_library(log-lib log)

add_library(ilm_gui SHARED main.c)
# target_link_libraries(ilm_gui PRIVATE ilm_gui_lib SDL3::SDL3)
target_link_libraries(ilm_gui
  ${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${ANDROID_ABI}/libilm-gui.a
  ${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${ANDROID_ABI}/libgraphviz.a
  ${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${ANDROID_ABI}/libplutovg.a
  ${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${ANDROID_ABI}/libsqlite.a
  ${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${ANDROID_ABI}/libiroh_c_ffi.a
  SDL3::SDL3
  ${log-lib}
)
