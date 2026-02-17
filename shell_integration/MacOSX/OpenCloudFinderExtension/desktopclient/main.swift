import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

NSLog("main.swift: Starting application with AppDelegate")
app.run()
