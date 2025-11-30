import Cocoa
import FileProvider
import os.log

let logger = Logger(subsystem: "eu.opencloud.desktopclient", category: "FileProvider")

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    
    override init() {
        super.init()
        NSLog("AppDelegate init called")
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("desktopclient launched - registering FileProvider domain...")
        NSLog("desktopclient launched - registering FileProvider domain...")
        registerFileProviderDomain()
    }
    
    func registerFileProviderDomain() {
        let domainIdentifier = NSFileProviderDomainIdentifier("OpenCloud")
        let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: "OpenCloud")
        
        // First remove any existing domain with same identifier to ensure clean state
        NSFileProviderManager.remove(domain) { _ in
            // Now add the domain
            NSFileProviderManager.add(domain) { error in
                if let error = error {
                    logger.error("❌ Error adding FileProvider domain: \(error.localizedDescription)")
                    NSLog("❌ Error adding FileProvider domain: %@", error.localizedDescription)
                } else {
                    logger.info("✅ FileProvider domain 'OpenCloud' registered successfully!")
                    NSLog("✅ FileProvider domain 'OpenCloud' registered successfully!")
                    NSLog("   Check Finder sidebar under 'Locations')")
                }
                
                // List all registered domains
                self.listDomains()
            }
        }
    }
    
    func listDomains() {
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
            if let error = error {
                print("Error listing domains: \(error.localizedDescription)")
                return
            }
            
            print("\nRegistered FileProvider domains:")
            for domain in domains {
                print("  - \(domain.displayName) (id: \(domain.identifier.rawValue))")
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Optionally remove domain on quit (for testing)
        // let domainIdentifier = NSFileProviderDomainIdentifier("OpenCloud")
        // let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: "OpenCloud")
        // NSFileProviderManager.remove(domain) { _ in }
    }
}
