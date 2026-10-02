import AppKit
import Carbon
import Testing
@testable import TapTapApp

@Test @MainActor func hiddenIconDoesNotOpenSettingsAtLogin() {
    let event = NSAppleEventDescriptor.appleEvent(
        withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
        targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
    )
    #expect(!AppDelegate.isBackgroundLaunch(event))
    event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
    #expect(AppDelegate.isBackgroundLaunch(event))
    #expect(!AppDelegate.isBackgroundLaunch(nil))
}
