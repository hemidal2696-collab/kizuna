# Kizuna for iOS/iPadOS - native core build
# SPDX-License-Identifier: AGPL-3.0-only
#
# Top-level CMake project used by scripts/build-core.sh. It builds chiaki-ng's
# chiaki-lib for iOS (arm64, iphoneos) and the Kizuna C shim (KizunaCore.c)
# as a static library, using the SAME compile definitions as chiaki-lib so the
# shim sees exactly the struct layouts the library was compiled with.
#
# Expected cache variables (set by build-core.sh):
#   KIZUNA_CHIAKI_DIR     path to the pinned chiaki-ng checkout (patched)
#   PYTHON_EXECUTABLE     python3 with protobuf/grpcio-tools (nanopb generator)

cmake_minimum_required(VERSION 3.20)
project(kizuna_core C CXX)

if(NOT IOS)
	message(WARNING "kizuna_core is meant to be configured with -DCMAKE_SYSTEM_NAME=iOS")
endif()

set(KIZUNA_CHIAKI_DIR "" CACHE PATH "Path to the chiaki-ng source tree")
if(NOT EXISTS "${KIZUNA_CHIAKI_DIR}/lib/CMakeLists.txt")
	message(FATAL_ERROR "KIZUNA_CHIAKI_DIR does not point to chiaki-ng: '${KIZUNA_CHIAKI_DIR}'")
endif()

include(FetchContent)

# --------------------------------------------------------------------------
# Opus (built from source) + include bridge.
# chiaki's opusdecoder.c includes <opus/opus.h>, while an Opus source tree has
# the headers directly in include/. We copy them into <build>/opus-bridge/opus
# and pre-seed the variables chiaki's FindOpus.cmake looks for, so its
# find_path()/find_library() calls are satisfied without searching the host.
# --------------------------------------------------------------------------
set(OPUS_BUILD_SHARED_LIBRARY OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
FetchContent_Declare(opus
	URL https://github.com/xiph/opus/archive/refs/tags/v1.5.2.tar.gz
	URL_HASH SHA256=9480e329e989f70d69886ded470c7f8cfe6c0667cc4196d4837ac9e668fb7404
	DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(opus)

set(KZ_OPUS_BRIDGE "${CMAKE_BINARY_DIR}/opus-bridge")
file(MAKE_DIRECTORY "${KZ_OPUS_BRIDGE}/opus")
file(GLOB KZ_OPUS_HEADERS "${opus_SOURCE_DIR}/include/*.h")
file(COPY ${KZ_OPUS_HEADERS} DESTINATION "${KZ_OPUS_BRIDGE}/opus")
set(Opus_INCLUDE_DIRS "${KZ_OPUS_BRIDGE}" CACHE PATH "Opus include bridge" FORCE)
set(Opus_LIBRARIES opus CACHE STRING "Opus target" FORCE)

# --------------------------------------------------------------------------
# chiaki-ng options for a library-only iOS build.
# chiaki's root CMakeLists uses cmake_minimum_required(3.10) (CMP0077 OLD), so
# option() only honours CACHE entries: everything is set as cache + FORCE.
# --------------------------------------------------------------------------
macro(kz_force var type value)
	set(${var} ${value} CACHE ${type} "" FORCE)
endmacro()

kz_force(CHIAKI_ENABLE_TESTS BOOL OFF)
kz_force(CHIAKI_ENABLE_CLI BOOL OFF)
kz_force(CHIAKI_ENABLE_GUI BOOL OFF)
kz_force(CHIAKI_ENABLE_ANDROID BOOL OFF)
kz_force(CHIAKI_ENABLE_BOREALIS BOOL OFF)
kz_force(CHIAKI_ENABLE_SETSU STRING OFF)
kz_force(CHIAKI_ENABLE_STEAMDECK_NATIVE STRING OFF)
kz_force(CHIAKI_ENABLE_STEAM_SHORTCUT BOOL OFF)
kz_force(CHIAKI_ENABLE_FFMPEG_DECODER STRING OFF)
kz_force(CHIAKI_ENABLE_PI_DECODER STRING OFF)
kz_force(CHIAKI_ENABLE_SPEEX STRING OFF)
kz_force(CHIAKI_ENABLE_RUDP STRING ON)
kz_force(CHIAKI_LIB_ENABLE_OPUS BOOL ON)
kz_force(CHIAKI_LIB_ENABLE_MBEDTLS BOOL ON)
kz_force(CHIAKI_LIB_MBEDTLS_EXTERNAL_PROJECT BOOL ON)
kz_force(CHIAKI_LIB_OPENSSL_EXTERNAL_PROJECT BOOL OFF)
kz_force(CHIAKI_LIB_JSONC_EXTERNAL_PROJECT BOOL ON)
kz_force(CHIAKI_LIB_MINIUPNPC_EXTERNAL_PROJECT BOOL ON)
kz_force(CHIAKI_USE_SYSTEM_CURL STRING OFF)
kz_force(CHIAKI_USE_SYSTEM_NANOPB STRING OFF)
kz_force(CHIAKI_USE_SYSTEM_JERASURE STRING OFF)

# mbedTLS 2.28 (fetched by chiaki): library only, warnings are not errors with
# a modern clang.
kz_force(ENABLE_PROGRAMS BOOL OFF)
kz_force(ENABLE_TESTING BOOL OFF)
kz_force(MBEDTLS_FATAL_WARNINGS BOOL OFF)
kz_force(GEN_FILES BOOL OFF)
kz_force(USE_SHARED_MBEDTLS_LIBRARY BOOL OFF)
kz_force(USE_STATIC_MBEDTLS_LIBRARY BOOL ON)

# libcurl 8.11 (chiaki submodule) with Secure Transport and WebSockets, no
# optional host dependencies (PKG_CONFIG_LIBDIR=/nonexistent is also exported).
kz_force(CURL_USE_SECTRANSP BOOL ON)
kz_force(CURL_USE_OPENSSL BOOL OFF)
kz_force(CURL_USE_MBEDTLS BOOL OFF)
kz_force(CURL_USE_LIBPSL BOOL OFF)
kz_force(CURL_USE_LIBSSH2 BOOL OFF)
kz_force(CURL_USE_LIBSSH BOOL OFF)
kz_force(CURL_USE_GSSAPI BOOL OFF)
kz_force(CURL_USE_PKGCONFIG BOOL OFF)
kz_force(CURL_ZLIB STRING OFF)
kz_force(CURL_BROTLI STRING OFF)
kz_force(CURL_ZSTD STRING OFF)
kz_force(USE_LIBIDN2 BOOL OFF)
kz_force(USE_APPLE_IDN BOOL OFF)
kz_force(USE_NGHTTP2 BOOL OFF)
kz_force(USE_NGTCP2 BOOL OFF)
kz_force(USE_QUICHE BOOL OFF)
kz_force(USE_MSH3 BOOL OFF)
kz_force(ENABLE_ARES BOOL OFF)
kz_force(CURL_DISABLE_LDAP BOOL ON)
kz_force(CURL_DISABLE_LDAPS BOOL ON)
kz_force(ENABLE_CURL_MANUAL BOOL OFF)
kz_force(BUILD_LIBCURL_DOCS BOOL OFF)
kz_force(BUILD_MISC_DOCS BOOL OFF)
kz_force(CURL_CA_BUNDLE STRING none)
kz_force(CURL_CA_PATH STRING none)

# json-c / miniupnpc FetchContent builds
kz_force(BUILD_SHARED_LIBS BOOL OFF)
kz_force(BUILD_TESTING BOOL OFF)

add_subdirectory("${KIZUNA_CHIAKI_DIR}" chiaki-ng)

# --------------------------------------------------------------------------
# The shim
# --------------------------------------------------------------------------
add_library(kizuna_core STATIC KizunaCore.c KizunaCore.h)
set_target_properties(kizuna_core PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON)
target_include_directories(kizuna_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(kizuna_core PRIVATE chiaki-lib)

# Same defines as chiaki-lib: directory-level add_definitions() from chiaki's
# root/lib CMakeLists (CHIAKI_LIB_ENABLE_MBEDTLS changes ChiakiECDH and thus
# ChiakiSession's layout) plus any target-level ones.
get_directory_property(KZ_CHIAKI_DIR_DEFS DIRECTORY "${KIZUNA_CHIAKI_DIR}/lib" COMPILE_DEFINITIONS)
get_target_property(KZ_CHIAKI_TGT_DEFS chiaki-lib COMPILE_DEFINITIONS)
if(KZ_CHIAKI_DIR_DEFS)
	target_compile_definitions(kizuna_core PRIVATE ${KZ_CHIAKI_DIR_DEFS})
endif()
if(KZ_CHIAKI_TGT_DEFS)
	target_compile_definitions(kizuna_core PRIVATE ${KZ_CHIAKI_TGT_DEFS})
endif()
# Belt and braces: the shim must never be compiled with the OpenSSL layout.
target_compile_definitions(kizuna_core PRIVATE CHIAKI_LIB_ENABLE_MBEDTLS)

# ecdh.h includes mbedtls headers when CHIAKI_LIB_ENABLE_MBEDTLS is defined.
if(TARGET mbedcrypto)
	target_link_libraries(kizuna_core PRIVATE mbedcrypto)
endif()

target_compile_options(kizuna_core PRIVATE -Wall -Wno-unused-function)
message(STATUS "Kizuna shim defines: ${KZ_CHIAKI_DIR_DEFS}")
