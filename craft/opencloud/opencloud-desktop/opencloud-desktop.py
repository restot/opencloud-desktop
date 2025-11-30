import os
import re
import subprocess
from pathlib import Path

import info
import utils
from Blueprints.CraftPackageObject import CraftPackageObject
from Packager.AppxPackager import AppxPackager
from Packager.NullsoftInstallerPackager import NullsoftInstallerPackager


class subinfo(info.infoclass):
    def registerOptions(self):
        self.options.dynamic.registerOption("buildNumber", "")
        self.options.dynamic.registerOption("enableCrashReporter", False)
        self.options.dynamic.registerOption("enableAppImageUpdater", False)
        self.options.dynamic.registerOption("enableAutoUpdater", False)
        self.options.dynamic.registerOption("forceAsserts", False)
        self.options.dynamic.registerOption("buildBeta", False)

    def setTargets(self):
        self.svnTargets["main"] = "https://github.com/opencloud-eu/desktop.git|main"
        self.defaultTarget = "main"

        self.description = "OpenCloud Desktop"
        self.displayName =  "OpenCloud Beta" if self.options.dynamic.buildBeta else "OpenCloud"
        self.webpage = "https://github.com/opencloud-eu/desktop"

    def setDependencies(self):
        self.buildDependencies["craft/craft-blueprints-opencloud"] = None
        self.buildDependencies["dev-utils/cmake"] = None
        self.buildDependencies["kde/frameworks/extra-cmake-modules"] = None

        self.runtimeDependencies["opencloud/libre-graph-api-cpp-qt-client"] = None
        self.runtimeDependencies["libs/zlib"] = None
        self.runtimeDependencies["libs/sqlite"] = None
        if CraftCore.compiler.isWindows:
            self.buildDependencies["libs/nlohmann-json"] = None
            self.runtimeDependencies["dev-utils/snoretoast"] = None

        self.runtimeDependencies["libs/qt/qtbase"] = None
        self.runtimeDependencies["libs/qt/qttranslations"] = None
        self.runtimeDependencies["libs/qt/qtsvg"] = None
        self.runtimeDependencies["libs/qt/qtimageformats"] = None
        self.runtimeDependencies["libs/qt/qtdeclarative"] = None
        if CraftCore.compiler.isLinux:
            self.runtimeDependencies["libs/qt/qtwayland"] = None

        self.runtimeDependencies["qt-libs/qtkeychain"] = None
        self.runtimeDependencies["libs/kdsingleapplication"] = None

        if self.options.dynamic.enableAutoUpdater:
            self.runtimeDependencies["libs/sparkle"] = None
            if self.options.dynamic.enableAppImageUpdater:
                self.runtimeDependencies["libs/libappimageupdate"] = None

        if self.options.dynamic.enableCrashReporter:
            self.runtimeDependencies["opencloud/libcrashreporter-qt"] = None
            self.buildDependencies["dev-utils/breakpad"] = None
            self.buildDependencies["dev-utils/symsorter"] = None


from Package.CMakePackageBase import *


class Package(CMakePackageBase):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.subinfo.options.fetch.checkoutSubmodules = True
        # TODO: fix msi generation which expects the existance of a /translation dir
        self.subinfo.options.package.moveTranslationsToBin = False

        if self.subinfo.options.dynamic.enableCrashReporter:
            self.subinfo.options.configure.args += ["-DWITH_CRASHREPORTER=ON"]
        if self.subinfo.options.dynamic.enableAutoUpdater:
            self.subinfo.options.configure.args += ["-DWITH_AUTO_UPDATER=ON"]
        if self.subinfo.options.dynamic.enableAppImageUpdater:
            self.subinfo.options.configure.args += ["-DWITH_APPIMAGEUPDATER=ON"]
        if self.subinfo.options.dynamic.forceAsserts:
            self.subinfo.options.configure.args += ["-DFORCE_ASSERTS=ON"]
        if self.subinfo.options.dynamic.buildNumber:
            self.subinfo.options.configure.args += [f"-DMIRALL_VERSION_BUILD={self.subinfo.options.dynamic.buildNumber}"]
        self.subinfo.options.configure.args += [f"-DBETA_CHANNEL_BUILD={self.subinfo.options.dynamic.buildBeta.asOnOff}"]

    def install(self):
        if not super().install():
            return False

        # macOS: Force-copy fresh extensions to ensure stale cache is invalidated
        # The Xcode-built extensions may not be properly updated by CMake's file(INSTALL)
        if CraftCore.compiler.isMacOS:
            appName = "OpenCloud Beta" if self.subinfo.options.dynamic.buildBeta else "OpenCloud"
            appBundle = CraftCore.standardDirs.craftRoot() / "Applications" / "KDE" / f"{appName}.app"
            pluginsDir = appBundle / "Contents" / "PlugIns"
            extensionsBuildDir = self.buildDir() / "shell_integration" / "MacOSX" / "Release"

            for ext in ["FinderSyncExt.appex", "FileProviderExt.appex"]:
                src = extensionsBuildDir / ext
                dest = pluginsDir / ext
                if src.exists():
                    CraftCore.log.info(f"Force-copying {ext} to {dest}")
                    if dest.exists():
                        utils.rmtree(dest)
                    if not utils.copyDir(src, dest):
                        CraftCore.log.warning(f"Failed to copy {ext}")
                        return False
                    # Touch the appex to invalidate Launch Services cache
                    os.utime(dest, None)

            # Touch the app bundle to invalidate Launch Services cache
            if appBundle.exists():
                os.utime(appBundle, None)
                # Re-register with Launch Services
                lsregister = Path("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
                if lsregister.exists():
                    utils.system([str(lsregister), "-f", str(appBundle)], logCommand=False)

        return True


    @property
    def applicationExecutable(self):
        return "opencloud_beta" if self.subinfo.options.dynamic.buildBeta else "opencloud"

    def buildNumber(self):
        if self.subinfo.options.dynamic.buildNumber:
            return self.subinfo.options.dynamic.buildNumber
        return super().buildNumber()

    def dumpSymbols(self) -> bool:
        dest = self.archiveDebugDir() / "symbols"
        utils.cleanDirectory(dest)
        allowError = None
        if CraftCore.compiler.isWindows:
            skipDumpPattern = r"icu\d\d\.dll|asprintf-0\.dll"
            if CraftCore.compiler.isWindows:
                for package in ["libs/runtime", "libs/d3dcompiler", "libs/gettext"]:
                    dbPackage = CraftCore.installdb.getInstalledPackages(CraftPackageObject.get(package))
                    if dbPackage:
                        files = dbPackage[0].getFiles()
                        skipDumpPattern += "|" + "|".join([re.escape(Path(x[0]).name) for x in files])
            allowError = re.compile(skipDumpPattern)
        else:
            # libs/qt6/qtbase installs .o files...
            # executing command: /drone/src/linux-64-gcc/dev-utils/bin/symsorter --compress --compress --output /drone/src/linux-64-gcc/build/opencloud/opencloud-client/archive-dbg/symbols /drone/src/linux-64-gcc/qml/Qt/test/controls/objects-RelWithDebInfo/QuickControlsTestUtilsPrivate_resources_1/.rcc/qrc_qmake_Qt_test_controls.cpp.o /drone/src/linux-64-gcc/qml/Qt/test/controls/objects-RelWithDebInfo/QuickControlsTestUtilsPrivate_resources_1/.rcc/qrc_qmake_Qt_test_controls.cpp.o.debug
            #
            # Sorting debug information files
            #
            # qrc_qmake_Qt_test_controls.cpp.o (rel, x86_64) -> /drone/src/linux-64-gcc/build/opencloud/opencloud-client/archive-dbg/symbols/00/0000e90000000000000000009f79900/executable
            #
            # error: failed to process file qrc_qmake_Qt_test_controls.cpp.o.debug
            #
            #   caused by failed to generate debug identifier
            allowError = re.compile(r".*\.o")

        for binaryFile in utils.filterDirectoryContent(
            self.archiveDir(), whitelist=lambda x, root: utils.isBinary(os.path.join(root, x)), blacklist=lambda x, root: True
        ):
            binaryFile = Path(binaryFile)
            # Assume all files are installed and the symbols are located next to the binary
            # TODO:
            installedBinary = CraftCore.standardDirs.craftRoot() / binaryFile.relative_to(self.archiveDir())
            if not installedBinary.exists():
                CraftCore.log.warning(f"{installedBinary} does not exist")
                return False

            if CraftCore.compiler.isWindows:
                symbolFile = Path(f"{installedBinary}.pdb")
                if not symbolFile.exists():
                    pdb = utils.getPDBForBinary(installedBinary)
                    if pdb:
                        symbolFile = installedBinary.parent / utils.getPDBForBinary(installedBinary).name
            elif CraftCore.compiler.isMacOS:
                debugInfoPath = installedBinary
                bundleDir = list(filter(lambda x: x.name.endswith(".framework") or x.name.endswith(".app"), debugInfoPath.parents))
                if bundleDir:
                    debugInfoPath = bundleDir[-1]
                debugInfoPath = Path(f"{debugInfoPath}.dSYM/Contents/Resources/DWARF/") / installedBinary.name
                if debugInfoPath.exists():
                    symbolFile = debugInfoPath
            elif CraftCore.compiler.isUnix:
                symbolFile = Path(f"{installedBinary}.debug")

            if not symbolFile.exists():
                if allowError and allowError.match(binaryFile.name):
                    # ignore errors in files matching allowError
                    continue
                CraftCore.log.warning(f"{symbolFile} does not exist")
                return False
            if not utils.system(["symsorter", "--compress", "--compress", "--output", dest, installedBinary, symbolFile]):
                if allowError and allowError.match(binaryFile.name):
                    # ignore errors in files matching allowError
                    CraftCore.log.warning(f"Ignoring error for {binaryFile.name}")
                    continue
                return False
        return True

    def openCloudVersion(self, withSuffix: bool = True) -> str:
        versionFile = self.sourceDir() / "VERSION.cmake"
        if not versionFile.exists():
            CraftCore.log.warning(f"Failed to find {versionFile}")
            return None

        print_var_script = os.path.join(self.blueprintDir(), "print-var.cmake")

        def get_var(name) -> str:
            command = ["cmake", f"-DTARGET_SCRIPT={os.path.basename(versionFile)}", f"-DTARGET_VAR={name}"]

            if self.subinfo.options.dynamic.buildNumber:
                command.append(f"-DMIRALL_VERSION_BUILD={self.subinfo.options.dynamic.buildNumber}")

            if not withSuffix:
                command += ["-DMIRALL_VERSION_SUFFIX="]

            command += ["-P", print_var_script]
            value = subprocess.check_output(
                command,
                cwd=os.path.dirname(versionFile),
                # make sure this call returns str instead of bytes
                universal_newlines=True,
            )
            value = value.strip()
            assert value, f"{name} empty"
            return value

        version_str = get_var("MIRALL_VERSION_STRING")

        print(f"*** version string fetched with CMake: {version_str} ***")

        return version_str

    def createPackage(self):
        self.blacklist_file.append(os.path.join(self.blueprintDir(), "blacklist.txt"))
        self.defines["appname"] = "OpenCloud" if not self.subinfo.options.dynamic.buildBeta else "OpenCloud Beta"
        self.defines["desktopFile"] = self.applicationExecutable
        self.defines["appimage_native_package_name"] = f'{self.applicationExecutable.lower().replace("_", "-")}-desktop'
        self.defines["apppath"] = "Applications/KDE/" + self.defines["appname"] + ".app"
        self.defines["company"] = "OpenCloud GmbH"

        exePath = Path(f"{self.applicationExecutable}{CraftCore.compiler.executableSuffix}")
        if isinstance(self, (NullsoftInstallerPackager, AppxPackager)):
            exePath = Path(f"bin/{exePath}")
        self.defines["shortcuts"] = [
            {
                "name": self.subinfo.displayName,
                "target": str(exePath),
                "description": self.subinfo.description,
                "appId": "eu.opencloud.desktopclient",
            }
        ]
        self.defines["icon"] = self.buildDir() / "src/gui/opencloud.ico"
        self.defines["pkgproj"] = self.buildDir() / "admin/osx/macosx.pkgproj"
        if CraftPackageObject.get("dev-utils/linuxdeploy-plugin-native-packages").isInstalled:
            self.defines["appimage_extra_output"] = ["native_packages"]
        ver = self.openCloudVersion()
        if ver:
            if isinstance(self, (AppxPackager)):
                # The Microsoft Store requires a version number in the format of X.Y.0.0
                # so we skip the suffix
                self.defines["version"] = self.openCloudVersion(False)
                self.defines["icon_png_44"] = self.sourceDir() / "src/resources/theme/colored/44-opencloud-icon-ms.png"
                self.defines["icon_png"] = self.sourceDir() / "src/resources/theme/colored/150-opencloud-icon-ms.png"
                # this one would also require us to set a 310x150 icon
                # self.defines["icon_png_310x310"] = self.sourceDir() / "src/resources/theme/colored/310-opencloud-icon-ms.png"
                cmdPath = exePath.parent / f"{exePath.stem}cmd.exe"
                self.defines["alias_executable"] = str(cmdPath)
                self.defines["alias"] = cmdPath.name
                # autostart
                self.defines["startup_task"] = str(exePath)

                self.defines["additional_xmlns"] = """xmlns:desktop3="http://schemas.microsoft.com/appx/manifest/desktop/windows10/3"\n"""
                self.defines["extensions"] = """<desktop3:Extension Category="windows.cloudFiles"><desktop3:CloudFiles></desktop3:CloudFiles></desktop3:Extension>"""
            else:
                self.defines["version"] = ver

        self.addExecutableFilter(r"(bin|libexec)/(?!(" + self.applicationExecutable + r"|snoretoast)).*")
        self.ignoredPackages += ["binary/mysql"]
        if not CraftCore.compiler.isLinux:
            self.ignoredPackages += ["libs/dbus"]
        return super().createPackage()

    def preArchiveMove(self):
        if self.subinfo.options.dynamic.enableCrashReporter:
            if not self.dumpSymbols():
                return False
        return super().preArchive()
