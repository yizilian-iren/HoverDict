import Foundation
import CoreServices

/// One of macOS's built-in dictionaries (the ones enabled in Dictionary.app → Settings),
/// opened directly so lookups don't depend on the user's dictionary order.
///
/// `DCSCopyRecordsForSearchString` and friends are private; they are resolved with
/// `dlsym`, so if a future macOS drops them `init` just fails and the caller falls back
/// (Japanese take-word off, English back to ECDICT) instead of crashing.
final class SystemDictionary {

    private typealias CreateFn = @convention(c) (CFURL) -> Unmanaged<DCSDictionary>?
    private typealias CopyRecordsFn = @convention(c) (DCSDictionary, CFString, UnsafeRawPointer?, UnsafeRawPointer?) -> Unmanaged<CFArray>?
    private typealias CopyRecordDataFn = @convention(c) (CFTypeRef, CFIndex) -> Unmanaged<CFString>?

    /// For the public DictionaryServices calls (`DCSGetTermRangeInString`).
    let dictionary: DCSDictionary
    private let copyRecords: CopyRecordsFn
    private let copyRecordData: CopyRecordDataFn

    /// `bundleName` is the dictionary's file name, e.g. "Simplified Chinese - English.dictionary".
    init?(bundleName: String) {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        guard let createSym = dlsym(rtldDefault, "DCSDictionaryCreate"),
              let recordsSym = dlsym(rtldDefault, "DCSCopyRecordsForSearchString"),
              let dataSym = dlsym(rtldDefault, "DCSRecordCopyData") else {
            NSLog("HoverDict: DictionaryServices private API unavailable — \(bundleName) disabled.")
            return nil
        }
        guard let url = Self.locate(bundleName) else {
            NSLog("HoverDict: \(bundleName) not installed — enable it in Dictionary.app → Settings.")
            return nil
        }
        let create = unsafeBitCast(createSym, to: CreateFn.self)
        guard let dict = create(url as CFURL)?.takeRetainedValue() else {
            NSLog("HoverDict: failed to open \(url.path)")
            return nil
        }
        dictionary = dict
        copyRecords = unsafeBitCast(recordsSym, to: CopyRecordsFn.self)
        copyRecordData = unsafeBitCast(dataSym, to: CopyRecordDataFn.self)
    }

    /// The XHTML of every entry matching `term` (inflected forms included: the
    /// dictionary's own index maps "running" to both "run" and "running"), in
    /// dictionary order. Not thread-safe; callers serialize.
    func entriesHTML(for term: String) -> [String] {
        guard let records = copyRecords(dictionary, term as CFString, nil, nil)?
            .takeRetainedValue() as? [AnyObject] else { return [] }
        return records.compactMap { copyRecordData($0, 0)?.takeRetainedValue() as String? }
    }

    /// Dictionaries downloaded from Dictionary.app live as MobileAssets; the asset folder
    /// name is a hash and the parent's suffix varies across macOS versions, so search.
    private static func locate(_ name: String) -> URL? {
        let fm = FileManager.default
        let assetsRoot = URL(fileURLWithPath: "/System/Library/AssetsV2")
        let assetTypes = (try? fm.contentsOfDirectory(atPath: assetsRoot.path)) ?? []
        for type in assetTypes where type.hasPrefix("com_apple_MobileAsset_DictionaryServices_dictionary") {
            let typeDir = assetsRoot.appendingPathComponent(type)
            for asset in (try? fm.contentsOfDirectory(atPath: typeDir.path)) ?? [] {
                let candidate = typeDir.appendingPathComponent(asset)
                    .appendingPathComponent("AssetData")
                    .appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        for dir in ["/Library/Dictionaries", NSHomeDirectory() + "/Library/Dictionaries"] {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
