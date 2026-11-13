// Exports one code-signing identity (certificate + private key) from the keychain as
// PKCS#12, for scripts/ci-signing-secret.sh. `security export` can only export every
// identity in a keychain at once; this picks the one whose certificate has the given name.
//
// Usage: P12_PASSWORD=… export-identity "<certificate name>" <out.p12>
// macOS asks for the login password to let it read the private key.
import Foundation
import Security

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let password = ProcessInfo.processInfo.environment["P12_PASSWORD"], !password.isEmpty
else { fail("usage: P12_PASSWORD=… export-identity <certificate name> <out.p12>") }
let name = arguments[1]
let output = URL(fileURLWithPath: arguments[2])

let query: [CFString: Any] = [
    kSecClass: kSecClassIdentity,
    kSecMatchLimit: kSecMatchLimitAll,
    kSecReturnRef: true,
]
var found: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &found)
guard status == errSecSuccess || status == errSecItemNotFound else {
    fail("Can't read the keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")")
}
let identities = (found as? [SecIdentity]) ?? []
let matches = identities.filter { identity in
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
          let certificate else { return false }
    return SecCertificateCopySubjectSummary(certificate) as String? == name
}
guard matches.count == 1 else {
    fail("Expected one identity named “\(name)” in the keychain, found \(matches.count).")
}

let passphrase = password as CFString
var exported: CFData?
let exportStatus = withExtendedLifetime(passphrase) { () -> OSStatus in
    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    parameters.passphrase = Unmanaged.passUnretained(passphrase)
    return SecItemExport(matches[0], .formatPKCS12, [], &parameters, &exported)
}
guard exportStatus == errSecSuccess, let data = exported as Data? else {
    fail("Export failed: \(SecCopyErrorMessageString(exportStatus, nil) as String? ?? "\(exportStatus)")")
}
do {
    try data.write(to: output, options: .withoutOverwriting)
} catch {
    fail("Can't write \(output.path): \(error.localizedDescription)")
}
