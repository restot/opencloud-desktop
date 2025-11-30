/*
 * Copyright (C) by OpenCloud GmbH
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

#pragma once

namespace OCC {

/**
 * @brief Manages FileProvider domain registration on macOS
 *
 * The FileProvider extension provides a virtual file system that appears
 * in Finder's sidebar under Locations. This class handles registering
 * and removing the domain with the system.
 */
class FileProviderDomainManager
{
public:
    /**
     * Register the FileProvider domain with the system.
     * This should be called once at application startup.
     */
    static void registerDomain();

    /**
     * Remove the FileProvider domain from the system.
     * This can be called on application quit if desired.
     */
    static void removeDomain();
};

} // namespace OCC
