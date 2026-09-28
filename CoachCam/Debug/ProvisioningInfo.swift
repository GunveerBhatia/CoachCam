import Foundation

/// Reads the signing profile that iloader/SideStore put inside the app, so the app
/// can tell you when its 7-day signature runs out.
enum ProvisioningInfo {
    /// When the current signature expires, or nil if the profile can't be read.
    static let expirationDate: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              // The file is a signed wrapper around a plain XML plist; cut the plist out.
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)),
              start.lowerBound < end.upperBound
        else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        return plist?["ExpirationDate"] as? Date
    }()

    /// A short description such as "Signature expires in 5 days (Oct 3)".
    static var summary: String {
        guard let date = expirationDate else { return "Signature expiry unknown" }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        let when = date.formatted(date: .abbreviated, time: .shortened)
        if date < Date() { return "Signature expired (\(when))" }
        return "Signature expires in \(days) day\(days == 1 ? "" : "s") (\(when))"
    }
}

/// Version and build number from Info.plist.
enum AppVersion {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    static var full: String { "Version \(version) · Build \(build)" }
}
