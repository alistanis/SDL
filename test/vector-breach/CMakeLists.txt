cmake_minimum_required(VERSION 3.16)
project(VectorBreachFenceCheck C)
find_package(SDL3 CONFIG REQUIRED)
add_executable(testvectorbreachfences ../testvectorbreachfences.c)
target_compile_features(testvectorbreachfences PRIVATE c_std_11)
target_link_libraries(testvectorbreachfences PRIVATE SDL3::SDL3)
enable_testing()
add_test(NAME gpu_fences_debug COMMAND testvectorbreachfences)
add_test(NAME gpu_fences_release COMMAND testvectorbreachfences --no-debug)
set_tests_properties(gpu_fences_debug gpu_fences_release PROPERTIES
    SKIP_RETURN_CODE 77 TIMEOUT 130 RUN_SERIAL TRUE)

add_executable(testioproperties testioproperties.c)
target_compile_features(testioproperties PRIVATE c_std_11)
target_link_libraries(testioproperties PRIVATE SDL3::SDL3)
add_test(NAME io_properties_allocation_failure COMMAND testioproperties)
set_tests_properties(io_properties_allocation_failure PROPERTIES TIMEOUT 30)

if(APPLE AND CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    enable_language(OBJC)
    add_executable(testmetalwindowlifetime testmetalwindowlifetime.m)
    target_compile_options(testmetalwindowlifetime PRIVATE -fobjc-arc)
    target_link_libraries(testmetalwindowlifetime PRIVATE SDL3::SDL3
        "-framework Cocoa" "-framework QuartzCore")
    add_test(NAME gpu_metal_window_lifetime COMMAND testmetalwindowlifetime)
    set_tests_properties(gpu_metal_window_lifetime PROPERTIES
        SKIP_RETURN_CODE 77 TIMEOUT 30 RUN_SERIAL TRUE)
endif()
