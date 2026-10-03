cmake_minimum_required(VERSION 3.24)
project(GuitarCozy LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
add_compile_options(-Wall -Wextra -Wno-unused-parameter)

# ---------------------------------------------------------------- core (portable C++)
add_library(gccore STATIC
  src/core/tempo.cpp
  src/core/track.cpp
  src/core/chart_parser.cpp
  src/core/song_ini.cpp
  src/core/engine.cpp
  src/core/sng.cpp
  src/core/chart_scan.cpp
)
target_include_directories(gccore PUBLIC src)

# ---------------------------------------------------------------- tests
enable_testing()
add_executable(gctests
  tests/test_main.cpp
  tests/test_tempo.cpp
  tests/test_chart.cpp
  tests/test_engine.cpp
  tests/test_bot.cpp
  tests/test_sng.cpp
  tests/test_scan.cpp
  tests/test_stars.cpp
)
target_link_libraries(gctests PRIVATE gccore)
target_compile_definitions(gctests PRIVATE GC_ASSETS_DIR="${CMAKE_SOURCE_DIR}/assets")
add_test(NAME core COMMAND gctests)

# ---------------------------------------------------------------- app (macOS, Objective-C++ + Metal)
if(APPLE)
  enable_language(OBJCXX)
  set(CMAKE_OBJCXX_STANDARD 20)
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(AUDIOLIBS REQUIRED IMPORTED_TARGET vorbisfile ogg opus)

  add_library(gccore_midi STATIC src/core/midi_parser.cpp)
  target_include_directories(gccore_midi PUBLIC src)
  target_sources(gctests PRIVATE tests/test_midi.cpp)
  target_link_libraries(gctests PRIVATE gccore_midi)

  # Metal shader library
  set(METALLIB ${CMAKE_BINARY_DIR}/default.metallib)
  add_custom_command(
    OUTPUT ${METALLIB}
    COMMAND xcrun -sdk macosx metal -I ${CMAKE_SOURCE_DIR}/src/render -c ${CMAKE_SOURCE_DIR}/src/render/shaders.metal -o ${CMAKE_BINARY_DIR}/shaders.air
    COMMAND xcrun -sdk macosx metallib ${CMAKE_BINARY_DIR}/shaders.air -o ${METALLIB}
    DEPENDS src/render/shaders.metal src/render/shader_types.h
    COMMENT "Compiling Metal shaders")
  add_custom_target(shaders DEPENDS ${METALLIB})

  add_executable(GuitarCozy MACOSX_BUNDLE
    src/app/main.mm
    src/app/App.mm
    src/app/Settings.mm
    src/app/Library.mm
    src/app/screens/Chrome.mm
    src/app/screens/MainMenuScreen.mm
    src/app/screens/GameplayScreen.mm
    src/app/screens/SongSelectScreen.mm
    src/app/screens/ResultsScreen.mm
    src/app/screens/PracticeSetupScreen.mm
    src/app/screens/CareerScreen.mm
    src/app/screens/OptionsScreen.mm
    src/app/screens/WelcomeScreen.mm
    src/ui/Stage.mm
    src/platform/song_loader.cpp
    src/platform/gamepad.mm
    src/audio/sfx.mm
    src/audio/decoder.mm
    src/audio/mixer.mm
    src/render/renderer.mm
  )
  add_dependencies(GuitarCozy shaders)
  target_sources(GuitarCozy PRIVATE ${METALLIB})
  set_source_files_properties(${METALLIB} PROPERTIES MACOSX_PACKAGE_LOCATION Resources GENERATED TRUE)
  set(APP_ICON ${CMAKE_SOURCE_DIR}/assets/icon/GuitarCozy.icns)
  target_sources(GuitarCozy PRIVATE ${APP_ICON})
  set_source_files_properties(${APP_ICON} PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
  target_include_directories(GuitarCozy PRIVATE src src/platform src/app)
  target_link_libraries(GuitarCozy PRIVATE gccore gccore_midi PkgConfig::AUDIOLIBS sqlite3
    "-framework Cocoa" "-framework Metal" "-framework MetalKit" "-framework QuartzCore"
    "-framework AudioToolbox" "-framework AudioUnit" "-framework CoreAudio" "-framework ImageIO" "-framework CoreServices" "-framework CoreText" "-framework GameController" "-framework CoreHaptics" "-framework AVFoundation" "-framework CoreVideo" "-framework CoreMedia" "-framework IOKit")
  target_compile_options(GuitarCozy PRIVATE -fobjc-arc)
  set_target_properties(GuitarCozy PROPERTIES
    MACOSX_BUNDLE_BUNDLE_NAME "GuitarCozy"
    MACOSX_BUNDLE_ICON_FILE "GuitarCozy.icns"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.guitarcozy.native"
    MACOSX_BUNDLE_BUNDLE_VERSION "0.1.0"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "0.1.0")
  # bundle resources: shaders + demo song
  add_custom_command(TARGET GuitarCozy POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory $<TARGET_BUNDLE_CONTENT_DIR:GuitarCozy>/Resources/demo
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${CMAKE_SOURCE_DIR}/assets/demo $<TARGET_BUNDLE_CONTENT_DIR:GuitarCozy>/Resources/demo
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${CMAKE_SOURCE_DIR}/assets/fonts $<TARGET_BUNDLE_CONTENT_DIR:GuitarCozy>/Resources/fonts)
endif()
