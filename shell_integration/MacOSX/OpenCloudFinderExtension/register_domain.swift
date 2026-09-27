#!/usr/bin/env swift
// Simple script to register a FileProvider domain for testing
// Run with: swift register_domain.swift

import Foundation
import FileProvider

let domainIdentifier = NSFileProviderDomainIdentifier("OpenCloud")
let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: "OpenCloud")

print("Registering FileProvider domain: \(domain.displayName)")

let semaphore = DispatchSemaphore(value: 0)

NSFileProviderManager.add(domain) { error in
    if let error = error {
        print("Error adding domain: \(error.localizedDescription)")
    } else {
        print("✅ Domain added successfully!")
        print("Check Finder sidebar under 'Locations' for 'OpenCloud'")
    }
    semaphore.signal()
}

semaphore.wait()

// List all domains
NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
    if let error = error {
        print("Error listing domains: \(error.localizedDescription)")
    } else {
        print("\nRegistered domains:")
        for d in domains {
            print("  - \(d.displayName) (\(d.identifier.rawValue))")
        }
    }
    semaphore.signal()
}

semaphore.wait()
