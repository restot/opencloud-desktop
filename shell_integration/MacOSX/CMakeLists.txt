if(APPLE)
set(OC_OEM_SHARE_ICNS "${CMAKE_BINARY_DIR}/src/gui/${APPLICATION_ICON_NAME}.icns")

if (CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(XCODE_CONFIG "Debug")
else()
    set(XCODE_CONFIG "Release")
endif()

# The bundle identifier and application group need to have compatible values with the client
# to be able to open a Mach port across the extension's sandbox boundary.
# Pass the info through the xcodebuild command line and make sure that the project uses
# those user-defined settings to build the plist.

# Build FinderSyncExt (Finder overlay icons and context menus)
add_custom_target( mac_overlayplugin ALL
    xcodebuild -project ${CMAKE_SOURCE_DIR}/shell_integration/MacOSX/OpenCloudFinderExtension/OpenCloudFinderExtension.xcodeproj
        -target FinderSyncExt -configuration "${XCODE_CONFIG}" "SYMROOT=${CMAKE_CURRENT_BINARY_DIR}"
        "OC_OEM_SHARE_ICNS=${OC_OEM_SHARE_ICNS}"
        "OC_APPLICATION_NAME=${APPLICATION_NAME}"
        "OC_APPLICATION_REV_DOMAIN=${APPLICATION_REV_DOMAIN}"
        "OC_SOCKETAPI_TEAM_IDENTIFIER_PREFIX=${SOCKETAPI_TEAM_IDENTIFIER_PREFIX}"
    COMMENT "Building FinderSyncExt (Finder overlay icons)"
    VERBATIM)
add_dependencies(mac_overlayplugin opencloud) # for the ${APPLICATION_ICON_NAME}.icns to be generated
add_custom_command(TARGET mac_overlayplugin POST_BUILD COMMAND ${CMAKE_COMMAND}
    ARGS -E copy_directory "${CMAKE_CURRENT_BINARY_DIR}/${XCODE_CONFIG}/FinderSyncExt.appex" "$<TARGET_FILE_DIR:opencloud>/../PlugIns/FinderSyncExt.appex")

# Build FileProviderExt (Virtual file system in Finder sidebar)
add_custom_target( mac_fileprovider ALL
    xcodebuild -project ${CMAKE_SOURCE_DIR}/shell_integration/MacOSX/OpenCloudFinderExtension/OpenCloudFinderExtension.xcodeproj
        -target FileProviderExt -configuration "${XCODE_CONFIG}" "SYMROOT=${CMAKE_CURRENT_BINARY_DIR}"
        "OC_APPLICATION_NAME=${APPLICATION_NAME}"
        "OC_APPLICATION_REV_DOMAIN=${APPLICATION_REV_DOMAIN}"
        "OC_SOCKETAPI_TEAM_IDENTIFIER_PREFIX=${SOCKETAPI_TEAM_IDENTIFIER_PREFIX}"
    COMMENT "Building FileProviderExt (Virtual file system)"
    VERBATIM)
add_dependencies(mac_fileprovider opencloud)
add_custom_command(TARGET mac_fileprovider POST_BUILD COMMAND ${CMAKE_COMMAND}
    ARGS -E copy_directory "${CMAKE_CURRENT_BINARY_DIR}/${XCODE_CONFIG}/FileProviderExt.appex" "$<TARGET_FILE_DIR:opencloud>/../PlugIns/FileProviderExt.appex")

endif()
