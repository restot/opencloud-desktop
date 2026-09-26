include(opencloud_add_test.cmake)

add_subdirectory(manual/icon_viewer)
add_subdirectory(testutils)

opencloud_add_test(JHash)

opencloud_add_test(OwncloudPropagator)
opencloud_add_test(OwnSql)
opencloud_add_test(SyncJournalDB)
opencloud_add_test(SyncFileItem)
opencloud_add_test(ConcatUrl)
opencloud_add_test(XmlParse)
opencloud_add_test(ChecksumValidator)
opencloud_add_test(ConnectionValidator)


# TODO: we need keychain access for this test
if (NOT APPLE OR NOT DEFINED ENV{GITHUB_ACTION})
    opencloud_add_test(CredentialManager)
endif()

opencloud_add_test(ExcludedFiles)

opencloud_add_test(Utility)

opencloud_add_test(SyncEngine)

opencloud_add_test(SyncMove)
add_dependencies(testsyncmove test_helper)
opencloud_add_test(SyncDelete)
opencloud_add_test(SyncConflict)
opencloud_add_test(SyncFileStatusTracker)
opencloud_add_test(Download)
opencloud_add_test(Blacklist)
opencloud_add_test(LocalDiscovery)
opencloud_add_test(RemoteDiscovery)
opencloud_add_test(Permissions)
opencloud_add_test(DatabaseError)
opencloud_add_test(LockedFiles)

opencloud_add_test(FolderWatcher)

if( UNIX AND NOT APPLE )
    opencloud_add_test(InotifyWatcher)
endif(UNIX AND NOT APPLE)


opencloud_add_test(LongPath)

opencloud_add_test(FolderMan)
opencloud_add_test(SyncProviderSelection)

if(APPLE)
    opencloud_add_test(MacSocketApi)
    target_sources(testmacsocketapi PRIVATE
        ../src/gui/socketapi/socketapisocket_mac.mm
        ../src/gui/socketapi/socketapisocket_mac.h)
    foreach(suite database webdav sockets)
        add_test(NAME testfileprovider_${suite}
            COMMAND bash "${PROJECT_SOURCE_DIR}/tools/test-fileprovider-${suite}.sh")
        set_tests_properties(testfileprovider_${suite} PROPERTIES TIMEOUT 120)
    endforeach()
endif()

opencloud_add_test(OAuth)

configure_file(test_journal.db "${PROJECT_BINARY_DIR}/bin/test_journal.db" COPYONLY)


opencloud_add_test(JobQueue)

add_subdirectory(modeltests)
