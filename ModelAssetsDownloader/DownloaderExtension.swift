import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// Background Assets downloader extension for the Apple-hosted model asset pack.
///
/// iOS 26's `StoreDownloaderExtension` (this is what Xcode's "Background
/// Download" template generates for Apple-hosted managed asset packs) supplies a
/// fully-featured system implementation — downloads, background updates, and
/// resume are all handled by the OS. `shouldDownload` is the only optional hook;
/// returning true accepts every pack (we only have one, the Qwen model).
@main
struct ModelAssetsDownloader: StoreDownloaderExtension {
    func shouldDownload(_ assetPack: AssetPack) -> Bool {
        true
    }
}
