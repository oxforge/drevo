import Foundation
import DrevoCore

/// Why changing the default folder app failed, in words a person can act on.
///
/// macOS 26 refuses to make any app but Finder the folder opener: both
/// `NSWorkspace.setDefaultApplication(at:toOpen: .folder)` and the older
/// `LSSetDefaultRoleHandlerForContentType("public.folder", …)` return paramErr (-50).
struct FolderViewerProblem {
    let refusedByMacOS: Bool
    let title: String
    let detail: String

    init(_ error: Error) {
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        let status = ns.domain == NSOSStatusErrorDomain ? ns.code : (underlying?.domain == NSOSStatusErrorDomain ? underlying!.code : nil)
        if status == -50 {
            refusedByMacOS = true
            title = "macOS keeps folders in Finder."
            detail = """
            This version of macOS doesn’t let any other app become the app that opens folders \
            (Launch Services refuses the change). Ways to get folders into Drevo instead are listed \
            under “Open folders in Drevo” in this tab.
            """
        } else {
            refusedByMacOS = false
            title = "Couldn’t change the folder viewer."
            detail = "\(ns.localizedDescription) (\(underlying.map { "\($0.domain) \($0.code)" } ?? "\(ns.domain) \(ns.code)"))"
        }
    }
}

/// The global `NSFileViewer` default many apps use for "Show in Finder".
enum FileViewerSetting {
    static let key = "NSFileViewer" as CFString

    static var current: String? {
        CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
    }

    static var isDrevo: Bool { current == Bundle.main.bundleIdentifier }

    static func set(_ useDrevo: Bool) {
        let value: CFPropertyList? = useDrevo ? (Bundle.main.bundleIdentifier ?? Drevo.bundleIdentifier) as CFString : nil
        CFPreferencesSetValue(key, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}
