# Testing

Running and adding tests for OpenCloud Desktop.

## Running Tests

```bash
# From Craft
pwsh .github/workflows/.craft.ps1 -c --test opencloud/opencloud-desktop

# From build directory (if using plain CMake)
ctest                    # All tests
ctest -R testname        # Specific test
ctest -V                 # Verbose output
./bin/testsyncengine     # Run test binary directly
```

Test binaries are in `build/bin/` and follow the pattern `test<classname>`.

## Adding Tests

Tests use `opencloud_add_test()` defined in `test/opencloud_add_test.cmake`:

```cmake
opencloud_add_test(MyNewFeature)
```

This expects a source file `test/testmynewfeature.cpp` with a Qt Test class. The test automatically links against `OpenCloudGui`, `syncenginetestutils`, `testutilsloader`, and `Qt::Test`.

Tests are built with `QT_FORCE_ASSERTS` defined and run with `QT_QPA_PLATFORM=offscreen` on Linux/Windows.
