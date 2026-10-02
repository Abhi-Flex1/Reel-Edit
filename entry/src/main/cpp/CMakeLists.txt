cmake_minimum_required(VERSION 3.5.0)
project(reeledit)

set(CMAKE_C_STANDARD 11)

add_library(reeledit SHARED
  reel_export.c
  reel_napi.c
)

target_include_directories(reeledit PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(reeledit
  PRIVATE
  libace_napi.z.so
  libnative_media_core.so
  libnative_media_codecbase.so
  libnative_media_avmuxer.so
  libnative_media_venc.so
  libnative_media_aenc.so
  libnative_media_acodec.so
  libhilog_ndk.z.so
)
