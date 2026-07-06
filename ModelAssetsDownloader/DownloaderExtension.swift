import BackgroundAssets

/// Background Assets downloader extension for the Apple-hosted model asset pack.
///
/// iOS 26 provides a fully-featured system implementation for managed,
/// Apple-hosted asset packs — `BAManagedDownloaderExtension` supplies default
/// implementations for every requirement, so this empty conformance is all that's
/// needed to opt in (this is what Xcode's "Background Download" template
/// generates). The system handles downloads, background updates, and resume.
///
/// VERIFY ON DEVICE: exact protocol name / whether an explicit `init()` is
/// required can shift between betas; if the build complains, match whatever the
/// current Background Download template emits.
@main
struct ModelAssetsDownloader: BAManagedDownloaderExtension {
    init() {}
}
