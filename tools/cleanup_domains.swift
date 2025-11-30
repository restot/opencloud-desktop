#!/usr/bin/env swift
// cleanup_domains.swift - List and remove orphaned FileProvider domains
// Usage: swift cleanup_domains.swift [--remove-all | --remove <identifier>]

import FileProvider
import Foundation

func listDomains() {
    let semaphore = DispatchSemaphore(value: 0)
    
    NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
        if let error = error {
            print("Error getting domains: \(error.localizedDescription)")
            semaphore.signal()
            return
        }
        
        print("Found \(domains.count) FileProvider domain(s):\n")
        
        for domain in domains {
            print("  Identifier: \(domain.identifier.rawValue)")
            print("  Display Name: \(domain.displayName)")
            print("  Hidden: \(domain.isHidden)")
            print("")
        }
        
        semaphore.signal()
    }
    
    semaphore.wait()
}

func removeDomain(identifier: String) {
    let semaphore = DispatchSemaphore(value: 0)
    
    NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
        if let error = error {
            print("Error getting domains: \(error.localizedDescription)")
            semaphore.signal()
            return
        }
        
        guard let domain = domains.first(where: { $0.identifier.rawValue == identifier }) else {
            print("Domain '\(identifier)' not found")
            semaphore.signal()
            return
        }
        
        print("Removing domain: \(domain.displayName) (\(domain.identifier.rawValue))...")
        
        NSFileProviderManager.remove(domain) { removeError in
            if let removeError = removeError {
                print("Error removing domain: \(removeError.localizedDescription)")
            } else {
                print("Successfully removed domain")
            }
            semaphore.signal()
        }
    }
    
    semaphore.wait()
}

func removeAllDomains() {
    let semaphore = DispatchSemaphore(value: 0)
    
    NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
        if let error = error {
            print("Error getting domains: \(error.localizedDescription)")
            semaphore.signal()
            return
        }
        
        guard !domains.isEmpty else {
            print("No domains to remove")
            semaphore.signal()
            return
        }
        
        let group = DispatchGroup()
        
        for domain in domains {
            // Skip iCloud domains
            if domain.identifier.rawValue.contains("iCloud") || 
               domain.identifier.rawValue.starts(with: "com.apple") {
                print("Skipping system domain: \(domain.displayName)")
                continue
            }
            
            group.enter()
            print("Removing: \(domain.displayName) (\(domain.identifier.rawValue))...")
            
            NSFileProviderManager.remove(domain) { removeError in
                if let removeError = removeError {
                    print("  Error: \(removeError.localizedDescription)")
                } else {
                    print("  Removed successfully")
                }
                group.leave()
            }
        }
        
        group.wait()
        semaphore.signal()
    }
    
    semaphore.wait()
}

// Main
let args = CommandLine.arguments

if args.count == 1 {
    print("FileProvider Domain Cleanup Utility\n")
    listDomains()
    print("\nUsage:")
    print("  swift \(args[0]) --remove-all              Remove all non-system domains")
    print("  swift \(args[0]) --remove <identifier>     Remove specific domain")
} else if args.contains("--remove-all") {
    print("Removing all non-system FileProvider domains...\n")
    removeAllDomains()
    print("\nDone. Remaining domains:")
    listDomains()
} else if let removeIndex = args.firstIndex(of: "--remove"), removeIndex + 1 < args.count {
    let identifier = args[removeIndex + 1]
    removeDomain(identifier: identifier)
} else {
    print("Unknown arguments. Run without arguments for usage.")
}
