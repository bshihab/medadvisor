import Foundation

extension URL {
    /// Exclude this file or directory from iCloud + iTunes/Finder device backups.
    ///
    /// The privacy promise ("audio and transcripts never leave the device")
    /// depends on this: iOS backs up everything under Documents/ to Apple by
    /// default. Raw audio, redacted-transcript feedback, and the (re-downloadable)
    /// model must never ride a backup off the device. Excluding a directory also
    /// excludes files later created inside it. Best-effort — never throws into a
    /// caller; the file must already exist when this is called.
    func excludeFromBackup() {
        var url = self
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
