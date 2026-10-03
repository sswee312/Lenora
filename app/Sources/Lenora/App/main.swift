import AppKit

Log.bootstrap()
CredentialStore.useLoginKeychain()
BundledFonts.register()
Task { @MainActor in await BackendConnection.shared.reload() }

// Shorten the default tooltip delay from 2s to 0.01s.
UserDefaults.standard.set(10, forKey: "NSInitialToolTipDelay")

let app = NSApplication.shared
AppAppearanceStore.shared.apply()
let delegate = AppDelegate.shared
app.delegate = delegate
app.mainMenu = MainMenuBuilder.buildMenu()
app.run()
