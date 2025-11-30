/*
 * Copyright (C) by Daniel Molkentin <danimo@owncloud.com>
 * Copyright (C) by Erik Verbruggen <erik@verbruggen.consulting>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
 * for more details.
 */

/*
 * Changes for Unix socket support based on Nextcloud Desktop Client:
 * https://github.com/nextcloud/desktop/blob/master/src/gui/socketapi/socketapi_mac.mm
 */

#include "application.h"
#include "guiutility.h"
#include "macOS/fileprovider.h"

#include "libsync/theme.h"

#include <QProcess>

#import <Cocoa/Cocoa.h>
#import <Foundation/NSBundle.h>

namespace OCC {

void Utility::startShellIntegration()
{
    QString bundlePath = QUrl::fromNSURL([NSBundle mainBundle].bundleURL).path();

    auto _system = [](const QString &cmd, const QStringList &args) {
        QProcess process;
        process.setProcessChannelMode(QProcess::MergedChannels);
        process.start(cmd, args);
        if (!process.waitForFinished()) {
            qCWarning(lcGuiUtility) << "Failed to load shell extension:" << cmd
                                    << args.join(QLatin1Char(' ')) << process.errorString();
        } else {
            qCInfo(lcGuiUtility) << (process.exitCode() != 0 ? "Failed to load" : "Loaded")
                                 << "shell extension:" << cmd << args.join(QLatin1Char(' '))
                                 << process.readAll();
        }
    };

    // Register FinderSyncExt (overlay icons and context menus)
    _system(QStringLiteral("pluginkit"), { QStringLiteral("-a"), QStringLiteral("%1Contents/PlugIns/FinderSyncExt.appex/").arg(bundlePath) });
    _system(QStringLiteral("pluginkit"),
        {QStringLiteral("-e"), QStringLiteral("use"), QStringLiteral("-i"), Theme::instance()->orgDomainName() + QStringLiteral(".FinderSyncExt")});

    // Register FileProviderExt (virtual file system in Finder sidebar)
    _system(QStringLiteral("pluginkit"), { QStringLiteral("-a"), QStringLiteral("%1Contents/PlugIns/FileProviderExt.appex/").arg(bundlePath) });
    _system(QStringLiteral("pluginkit"),
        {QStringLiteral("-e"), QStringLiteral("use"), QStringLiteral("-i"), Theme::instance()->orgDomainName() + QStringLiteral(".FileProviderExt")});

    // Initialize FileProvider integration (domain manager + XPC)
    // This will register domains for all existing accounts
    Mac::FileProvider::instance();
}

QString Utility::socketApiSocketPath()
{
    // Unix socket path in App Group container for FinderSyncExt communication
    // Based on Nextcloud's approach: https://github.com/nextcloud/desktop
    //
    // The socket must be in a location accessible to both the main app and the FinderSyncExt.
    // On macOS, this is the App Group container: ~/Library/Group Containers/<TEAM>.<bundle-id>/
    //
    // For developer builds: App Group ID is just the domain (e.g., "eu.opencloud.desktop")
    // For signed builds: App Group ID includes team prefix (e.g., "9B5WD74GWJ.eu.opencloud.desktop")
    //
    // SOCKETAPI_TEAM_IDENTIFIER_PREFIX is defined at build time:
    //   - Empty string "" for ad-hoc/dev builds
    //   - "TEAMID." for signed builds

    // Get the reverse domain from Theme (e.g., "eu.opencloud.desktopclient")
    QString revDomain = Theme::instance()->orgDomainName();

    // Build app group ID: prefix + domain
    // Note: For signed apps, prefix includes trailing dot ("TEAMID.")
    QString teamPrefix = QStringLiteral(SOCKETAPI_TEAM_IDENTIFIER_PREFIX);
    QString appGroupIdStr = teamPrefix + revDomain;
    NSString *appGroupId = appGroupIdStr.toNSString();

    qCDebug(lcGuiUtility) << "Looking for App Group container:" << appGroupIdStr;

    NSURL *container = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:appGroupId];
    if (container) {
        NSURL *socketPath = [container URLByAppendingPathComponent:@".socket" isDirectory:NO];
        qCInfo(lcGuiUtility) << "Using App Group socket path:" << QString::fromNSString(socketPath.path);
        return QString::fromNSString(socketPath.path);
    }

    // Fallback for development without App Groups configured
    // Use Application Support directory
    qCWarning(lcGuiUtility) << "Could not get App Group container for" << appGroupIdStr
                            << "- falling back to Application Support";

    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    if (paths.count > 0) {
        NSString *appSupport = [paths firstObject];
        NSString *socketDir = [appSupport stringByAppendingPathComponent:@"OpenCloud"];
        [[NSFileManager defaultManager] createDirectoryAtPath:socketDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString *socketPath = [socketDir stringByAppendingPathComponent:@".socket"];
        qCInfo(lcGuiUtility) << "Using fallback socket path:" << QString::fromNSString(socketPath);
        return QString::fromNSString(socketPath);
    }

    qCCritical(lcGuiUtility) << "Could not determine socket path!";
    return QString();
}

bool Utility::isInstalledByStore()
{
    return false;
}

bool Utility::isFinderSyncExtensionEnabled()
{
    // Check if our FinderSync extension is enabled by querying pluginkit
    // The extension is enabled if pluginkit -m returns our bundle ID
    QString bundleId = Theme::instance()->orgDomainName() + QStringLiteral(".FinderSyncExt");

    QProcess process;
    process.start(QStringLiteral("pluginkit"), {QStringLiteral("-m"), QStringLiteral("-i"), bundleId});
    if (!process.waitForFinished(5000)) {
        qCWarning(lcGuiUtility) << "pluginkit query timed out";
        return false;
    }

    QString output = QString::fromUtf8(process.readAllStandardOutput()).trimmed();
    // If extension is registered and enabled, output contains the bundle ID
    // If not, output is "(no matches)" or empty
    bool enabled = !output.isEmpty() && !output.contains(QStringLiteral("no matches"));
    qCDebug(lcGuiUtility) << "Finder Sync extension" << bundleId << "enabled:" << enabled;
    return enabled;
}

void Utility::showFinderSyncExtensionManagementInterface()
{
    // Open System Settings/Preferences to the Extensions pane
    // On macOS 13+ (Ventura): System Settings > Privacy & Security > Extensions > Added Extensions
    // On macOS 12 and earlier: System Preferences > Extensions > Finder Extensions

    if (@available(macOS 13.0, *)) {
        // macOS Ventura and later - open Privacy & Security > Extensions
        // The URL scheme for System Settings
        NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.ExtensionsPreferences"];
        [[NSWorkspace sharedWorkspace] openURL:url];
    } else {
        // macOS Monterey and earlier - open System Preferences Extensions pane
        NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preferences.extensions"];
        [[NSWorkspace sharedWorkspace] openURL:url];
    }

    qCInfo(lcGuiUtility) << "Opened System Settings Extensions pane";
}

} // namespace OCC
