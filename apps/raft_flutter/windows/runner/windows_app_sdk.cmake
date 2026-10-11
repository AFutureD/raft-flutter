# Pinned Microsoft SDK; generated WinRT projections remain in the build tree.
include(FetchContent)
if(POLICY CMP0135)
  cmake_policy(SET CMP0135 NEW)
endif()
FetchContent_Declare(raft_windows_app_sdk
  URL https://api.nuget.org/v3-flatcontainer/microsoft.windowsappsdk/1.7.250310001/microsoft.windowsappsdk.1.7.250310001.nupkg
  URL_HASH SHA256=A4FDCB81CE3C0F78C0EE801B5DB433FA316E91BE2659F9491706AB91DFE8A985
)
FetchContent_MakeAvailable(raft_windows_app_sdk)
set(RAFT_SDK_PROJECTIONS "${CMAKE_CURRENT_BINARY_DIR}/app-sdk-projections")
set(RAFT_SDK_KIT_BIN "$ENV{ProgramFiles\(x86\)}/Windows Kits/10/bin/${CMAKE_VS_WINDOWS_TARGET_PLATFORM_VERSION}/x64")
find_program(RAFT_CPPWINRT cppwinrt.exe PATHS "${RAFT_SDK_KIT_BIN}" REQUIRED)
if(NOT EXISTS "${RAFT_SDK_PROJECTIONS}/winrt/Microsoft.Windows.AppNotifications.h" OR
   NOT EXISTS "${RAFT_SDK_PROJECTIONS}/winrt/Microsoft.Windows.AppLifecycle.h")
  execute_process(COMMAND "${RAFT_CPPWINRT}"
    -input "${raft_windows_app_sdk_SOURCE_DIR}/lib/uap10.0/Microsoft.Windows.AppNotifications.winmd"
    -input "${raft_windows_app_sdk_SOURCE_DIR}/lib/uap10.0/Microsoft.Windows.AppNotifications.Builder.winmd"
    -input "${raft_windows_app_sdk_SOURCE_DIR}/lib/uap10.0/Microsoft.Windows.AppLifecycle.winmd"
    -reference sdk -output "${RAFT_SDK_PROJECTIONS}"
    RESULT_VARIABLE RAFT_PROJECTION_RESULT)
  if(NOT RAFT_PROJECTION_RESULT EQUAL 0)
    message(FATAL_ERROR "Microsoft Windows App SDK projection generation failed")
  endif()
endif()
target_include_directories(${BINARY_NAME} PRIVATE
  "${RAFT_SDK_PROJECTIONS}" "${raft_windows_app_sdk_SOURCE_DIR}/include")
target_link_libraries(${BINARY_NAME} PRIVATE
  "${raft_windows_app_sdk_SOURCE_DIR}/lib/win10-x64/Microsoft.WindowsAppRuntime.Bootstrap.lib")
set(RAFT_WINDOWS_BOOTSTRAP_DLL
  "${raft_windows_app_sdk_SOURCE_DIR}/runtimes/win-x64/native/Microsoft.WindowsAppRuntime.Bootstrap.dll"
  PARENT_SCOPE)
