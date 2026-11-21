import Foundation

enum ToolFailure: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message): message
        }
    }
}

let fileManager = FileManager.default
let environment = ProcessInfo.processInfo.environment
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let rootURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let buildURL = rootURL.appendingPathComponent(".build", isDirectory: true)
let distURL = rootURL.appendingPathComponent("dist", isDirectory: true)

@discardableResult
func run(
    _ executable: String,
    _ arguments: [String],
    currentDirectory: URL? = nil,
    extraEnvironment: [String: String] = [:],
    captureOutput: Bool = false,
    suppressError: Bool = false
) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    process.environment = environment.merging(extraEnvironment) { _, new in new }

    let outputPipe = Pipe()
    if captureOutput {
        process.standardOutput = outputPipe
    } else {
        process.standardOutput = FileHandle.standardOutput
    }
    process.standardError = suppressError ? FileHandle.nullDevice : FileHandle.standardError

    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ToolFailure.message("命令执行失败（\(process.terminationStatus)）：\(executable) \(arguments.joined(separator: " "))")
    }

    guard captureOutput else { return "" }
    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func removeIfPresent(_ url: URL) throws {
    if fileManager.fileExists(atPath: url.path) {
        try fileManager.removeItem(at: url)
    }
}

func removeSigningAttributes(below root: URL) {
    var items = [root]
    if let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: [],
        errorHandler: { _, _ in true }
    ) {
        for case let item as URL in enumerator {
            items.append(item)
        }
    }

    for item in items {
        _ = try? run("/usr/bin/xattr", ["-d", "com.apple.provenance", item.path], suppressError: true)
    }
    _ = try? run("/usr/bin/xattr", ["-d", "com.apple.FinderInfo", root.path], suppressError: true)
    _ = try? run("/usr/bin/xattr", ["-d", "com.apple.fileprovider.fpfs#P", root.path], suppressError: true)
}

func developerDirectory(sdkVersion: String) throws -> (developer: URL, sdk: URL, swift: URL) {
    var candidates: [URL] = []
    if let configured = environment["DEVELOPER_DIR"], !configured.isEmpty {
        candidates.append(URL(fileURLWithPath: configured))
    }
    candidates.append(URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
    candidates.append(URL(fileURLWithPath: "/Applications/Xcode-beta.app/Contents/Developer"))

    if let selected = try? run("/usr/bin/xcode-select", ["-p"], captureOutput: true), !selected.isEmpty {
        candidates.append(URL(fileURLWithPath: selected))
    }

    // Also scan mounted volumes so packaging keeps working when the only
    // Xcode with this SDK lives on an external disk.
    if let volumes = try? fileManager.contentsOfDirectory(atPath: "/Volumes") {
        candidates += volumes.sorted().flatMap { volume in
            [
                URL(fileURLWithPath: "/Volumes/\(volume)/Applications/Xcode.app/Contents/Developer"),
                URL(fileURLWithPath: "/Volumes/\(volume)/Applications/Xcode-beta.app/Contents/Developer")
            ]
        }
    }

    for developer in candidates {
        let sdkRoot = developer
            .appendingPathComponent("Platforms/MacOSX.platform/Developer/SDKs", isDirectory: true)
        let names = ["MacOSX\(sdkVersion).0.sdk", "MacOSX\(sdkVersion).sdk"]
        guard let sdk = names
            .map({ sdkRoot.appendingPathComponent($0, isDirectory: true) })
            .first(where: { fileManager.fileExists(atPath: $0.path) })
        else { continue }

        let swift = developer.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin/swift")
        guard fileManager.isExecutableFile(atPath: swift.path) else { continue }
        return (developer, sdk, swift)
    }

    throw ToolFailure.message("找不到包含 macOS \(sdkVersion) SDK 的 Xcode")
}

/// Builds the EC25-patched lpac directly from the vendored C sources.
/// Only the stdio APDU bridge and curl HTTP backend are included because the
/// app supplies APDUs through its native USB transport.
func buildBundledLPAC(
    sdk: URL,
    extraEnvironment: [String: String]
) throws -> URL {
    let sourceURL = rootURL.appendingPathComponent("ThirdParty/lpac", isDirectory: true)
    let outputDirectory = buildURL.appendingPathComponent("bundled-lpac", isDirectory: true)
    let includeDirectory = outputDirectory.appendingPathComponent("include", isDirectory: true)
    let outputURL = outputDirectory.appendingPathComponent("lpac")

    guard fileManager.fileExists(atPath: sourceURL.appendingPathComponent("src/main.c").path) else {
        throw ToolFailure.message("缺少内置 lpac 源码：\(sourceURL.path)")
    }

    try removeIfPresent(outputDirectory)
    try fileManager.createDirectory(at: includeDirectory, withIntermediateDirectories: true)

    let describedVersion = try? run(
        "/usr/bin/git",
        ["-C", sourceURL.path, "describe", "--always", "--tags", "--dirty", "--match", "v*"],
        captureOutput: true,
        suppressError: true
    )
    let version = describedVersion?.isEmpty == false ? describedVersion! : "v2.3.0-ec25"
    let versionHeader = """
    #ifndef LPAC_VERSION_H_
    #define LPAC_VERSION_H_
    #define LPAC_VERSION "\(version.replacingOccurrences(of: "\"", with: ""))"
    #endif
    """
    try versionHeader.write(
        to: includeDirectory.appendingPathComponent("version.h"),
        atomically: true,
        encoding: .utf8
    )

    func cSources(below directory: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "c" else { return nil }
            return url
        }
    }

    var sources = ["cjson", "euicc", "utils", "src"]
        .flatMap { cSources(below: sourceURL.appendingPathComponent($0, isDirectory: true)) }
    sources += [
        sourceURL.appendingPathComponent("driver/driver.c"),
        sourceURL.appendingPathComponent("driver/apdu/stdio.c"),
        sourceURL.appendingPathComponent("driver/http/stdio.c"),
        sourceURL.appendingPathComponent("driver/http/curl.c")
    ]
    sources.sort { $0.path < $1.path }

    let architecture = try run("/usr/bin/uname", ["-m"], captureOutput: true)
    var arguments = [
        "clang",
        "-arch", architecture,
        "-isysroot", sdk.path,
        "-mmacosx-version-min=26.0",
        "-std=c99", "-O2",
        "-DLPAC_WITH_HTTP_CURL",
        "-I", includeDirectory.path,
        "-I", sourceURL.path,
        "-I", sourceURL.appendingPathComponent("utils").path,
        "-I", sourceURL.appendingPathComponent("driver").path,
        "-I", sourceURL.appendingPathComponent("src").path
    ]
    arguments += sources.map(\.path)
    arguments += ["-lcurl", "-o", outputURL.path]

    try run(
        "/usr/bin/xcrun",
        arguments,
        currentDirectory: sourceURL,
        extraEnvironment: extraEnvironment
    )
    guard fileManager.isExecutableFile(atPath: outputURL.path) else {
        throw ToolFailure.message("内置 lpac 构建产物不存在：\(outputURL.path)")
    }
    return outputURL
}

private struct BundleVersions: Decodable {
    let CFBundleShortVersionString: String
    let CFBundleVersion: String

    init(contentsOf url: URL) throws {
        self = try PropertyListDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

@discardableResult
func packageApp() throws -> URL {
    let sdkVersion = environment["MACOS_SDK_VERSION"] ?? "27"
    let toolchain = try developerDirectory(sdkVersion: sdkVersion)
    let appName = environment["APP_NAME"] ?? "EC25 Toolbox"
    let displayName = environment["BUNDLE_DISPLAY_NAME"] ?? appName
    let bundleIdentifier = environment["BUNDLE_IDENTIFIER"] ?? "ing.fuyaoskyrocket.ec25toolbox"
    let sourceVersions = try BundleVersions(
        contentsOf: rootURL.appendingPathComponent("Resources/EC25Toolbox-Info.plist")
    )
    let appVersion = environment["APP_VERSION"] ?? sourceVersions.CFBundleShortVersionString
    let appURL = distURL.appendingPathComponent("\(appName).app", isDirectory: true)
    let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
    let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
    let privilegedHelpersURL = contentsURL.appendingPathComponent(
        "Library/PrivilegedHelperTools", isDirectory: true
    )
    let launchDaemonsURL = contentsURL.appendingPathComponent(
        "Library/LaunchDaemons", isDirectory: true
    )
    let appBinaryURL = macOSURL.appendingPathComponent("EC25Toolbox")
    let helperBinaryURL = privilegedHelpersURL.appendingPathComponent("EC25IKEHelper")
    // SMAppService daemons live in Contents/Library/LaunchDaemons together
    // with their property list; BundleProgram in the plist points here.
    let systemHelperBinaryURL = launchDaemonsURL.appendingPathComponent("EC25SystemHelper")
    let systemHelperPlistSourceURL = rootURL.appendingPathComponent(
        "Sources/EC25SystemHelper/ing.fuyaoskyrocket.ec25toolbox.system-helper.plist"
    )

    var buildArguments = [
        "build", "--disable-sandbox", "-c", "release",
        "-debug-info-format", "none",
        "--scratch-path", buildURL.path,
        "--sdk", toolchain.sdk.path,
        "-Xlinker", "-platform_version",
        "-Xlinker", "macos",
        "-Xlinker", "26.0",
        "-Xlinker", sdkVersion.contains(".") ? sdkVersion : "\(sdkVersion).0"
    ]
    let pluginCandidates = [
        toolchain.developer.appendingPathComponent("Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"),
        URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"),
        URL(fileURLWithPath: "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins")
    ]
    if let plugins = pluginCandidates.first(where: {
        fileManager.fileExists(atPath: $0.appendingPathComponent("libSwiftUIMacros.dylib").path)
    }) {
        buildArguments += ["-Xswiftc", "-plugin-path", "-Xswiftc", plugins.path]
    }

    let toolEnvironment = [
        "DEVELOPER_DIR": toolchain.developer.path,
        "SDKROOT": toolchain.sdk.path,
        "CLANG_MODULE_CACHE_PATH": buildURL.appendingPathComponent("module-cache", isDirectory: true).path
    ]

    print("==> [1/4] 从内置源码构建 lpac")
    let builtLPACURL = try buildBundledLPAC(sdk: toolchain.sdk, extraEnvironment: toolEnvironment)

    print("==> [2/4] 构建原生 SwiftUI 应用（release）")
    print("    Xcode: \(toolchain.developer.path)")
    print("    SDK: \(toolchain.sdk.path)")
    try run(toolchain.swift.path, buildArguments, currentDirectory: rootURL, extraEnvironment: toolEnvironment)

    let builtBinaryURL = buildURL.appendingPathComponent("release/EC25Toolbox")
    let builtHelperURL = buildURL.appendingPathComponent("release/EC25IKEHelper")
    let builtSystemHelperURL = buildURL.appendingPathComponent("release/EC25SystemHelper")
    guard fileManager.isExecutableFile(atPath: builtBinaryURL.path) else {
        throw ToolFailure.message("构建产物不存在：\(builtBinaryURL.path)")
    }
    guard fileManager.isExecutableFile(atPath: builtHelperURL.path) else {
        throw ToolFailure.message("IKE Helper 构建产物不存在：\(builtHelperURL.path)")
    }
    guard fileManager.isExecutableFile(atPath: builtSystemHelperURL.path) else {
        throw ToolFailure.message("System Helper 构建产物不存在：\(builtSystemHelperURL.path)")
    }
    guard fileManager.fileExists(atPath: systemHelperPlistSourceURL.path) else {
        throw ToolFailure.message("System Helper LaunchDaemon plist 不存在：\(systemHelperPlistSourceURL.path)")
    }
    let builtResourceBundleURL = buildURL.appendingPathComponent(
        "release/EC25Toolbox_EC25Toolbox.bundle",
        isDirectory: true
    )
    guard fileManager.fileExists(atPath: builtResourceBundleURL.path) else {
        throw ToolFailure.message("资源 bundle 不存在：\(builtResourceBundleURL.path)")
    }

    print("==> [3/4] 组装 .app bundle")
    try removeIfPresent(appURL)
    try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: privilegedHelpersURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: launchDaemonsURL, withIntermediateDirectories: true)
    try fileManager.copyItem(at: builtBinaryURL, to: appBinaryURL)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appBinaryURL.path)
    try fileManager.copyItem(at: builtHelperURL, to: helperBinaryURL)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperBinaryURL.path)
    try fileManager.copyItem(at: builtSystemHelperURL, to: systemHelperBinaryURL)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: systemHelperBinaryURL.path)
    try fileManager.copyItem(
        at: systemHelperPlistSourceURL,
        to: launchDaemonsURL.appendingPathComponent(systemHelperPlistSourceURL.lastPathComponent)
    )
    try fileManager.copyItem(
        at: builtResourceBundleURL,
        to: resourcesURL.appendingPathComponent("EC25Toolbox_EC25Toolbox.bundle", isDirectory: true)
    )
    let bundledLPACURL = resourcesURL.appendingPathComponent("lpac")
    try fileManager.copyItem(at: builtLPACURL, to: bundledLPACURL)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledLPACURL.path)
    let lpacLicensesURL = rootURL.appendingPathComponent("ThirdParty/lpac/LICENSES", isDirectory: true)
    if fileManager.fileExists(atPath: lpacLicensesURL.path) {
        try fileManager.copyItem(
            at: lpacLicensesURL,
            to: resourcesURL.appendingPathComponent("lpac-LICENSES", isDirectory: true)
        )
    }
    // Localized About-panel credits, matching the package_swiftui.sh layout.
    for locale in ["en", "zh-Hans"] {
        let creditsURL = rootURL.appendingPathComponent("Resources/\(locale).lproj/Credits.html")
        guard fileManager.fileExists(atPath: creditsURL.path) else {
            throw ToolFailure.message("关于面板 Credits 不存在：\(creditsURL.path)")
        }
        let localeURL = resourcesURL.appendingPathComponent("\(locale).lproj", isDirectory: true)
        try fileManager.createDirectory(at: localeURL, withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: creditsURL,
            to: localeURL.appendingPathComponent("Credits.html")
        )
    }

    let sourceIconURL = rootURL.appendingPathComponent("Resources/EC25Toolbox.icon", isDirectory: true)
    guard fileManager.fileExists(atPath: sourceIconURL.path) else {
        throw ToolFailure.message("应用图标不存在：\(sourceIconURL.path)")
    }
    let iconInfoURL = buildURL.appendingPathComponent("EC25Toolbox-IconInfo.plist")
    try removeIfPresent(iconInfoURL)
    try run(
        "/usr/bin/xcrun",
        [
            "actool", sourceIconURL.path,
            "--compile", resourcesURL.path,
            "--platform", "macosx",
            "--minimum-deployment-target", "26.0",
            "--app-icon", "EC25Toolbox",
            "--output-partial-info-plist", iconInfoURL.path,
            "--warnings", "--notices", "--errors"
        ],
        currentDirectory: rootURL,
        extraEnvironment: toolEnvironment
    )

    let plist: [String: Any] = [
        "CFBundleDevelopmentRegion": "zh_CN",
        "CFBundleDisplayName": displayName,
        "CFBundleExecutable": "EC25Toolbox",
        "CFBundleIconFile": "EC25Toolbox",
        "CFBundleIconName": "EC25Toolbox",
        "CFBundleIdentifier": bundleIdentifier,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": displayName,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": appVersion,
        "CFBundleVersion": environment["BUILD_NUMBER"] ?? sourceVersions.CFBundleVersion,
        "LSMinimumSystemVersion": "26.0",
        "LSUIElement": true,
        "NSHighResolutionCapable": true,
        "NSSupportsAutomaticGraphicsSwitching": true,
        // Standard About-panel copyright; localized copies ship through the
        // per-locale Credits.html and InfoPlist.strings below.
        "NSHumanReadableCopyright": "Copyright © 2026 扶摇 skyrocketing. Released under the GNU AGPL v3."
    ]
    let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"), options: .atomic)
    let helperLabel = "ing.fuyaoskyrocket.ec25toolbox.ike-helper"
    let helperPlist: [String: Any] = [
        "Label": helperLabel,
        "ProgramArguments": ["/Library/PrivilegedHelperTools/\(helperLabel)"],
        "MachServices": [helperLabel: true],
        "ProcessType": "Interactive",
        "RunAtLoad": false,
        "ThrottleInterval": 3
    ]
    let helperPlistData = try PropertyListSerialization.data(
        fromPropertyList: helperPlist, format: .xml, options: 0
    )
    try helperPlistData.write(
        to: launchDaemonsURL.appendingPathComponent("\(helperLabel).plist"),
        options: .atomic
    )
    try Data("APPL????".utf8).write(to: contentsURL.appendingPathComponent("PkgInfo"), options: .atomic)

    print("==> [4/4] ad-hoc 签名")
    let systemHelperLabel = "ing.fuyaoskyrocket.ec25toolbox.system-helper"
    _ = try? run("/usr/bin/xattr", ["-cr", appURL.path], suppressError: true)
    removeSigningAttributes(below: appURL)
    try run("/usr/bin/codesign", ["--force", "--sign", "-", bundledLPACURL.path])
    try run(
        "/usr/bin/codesign",
        ["--force", "--identifier", helperLabel, "--sign", "-", helperBinaryURL.path]
    )
    try run(
        "/usr/bin/codesign",
        ["--force", "--identifier", systemHelperLabel, "--sign", "-", systemHelperBinaryURL.path]
    )
    try run("/usr/bin/codesign", ["--force", "--sign", "-", appBinaryURL.path])
    try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", appURL.path])
    try run("/usr/bin/codesign", ["--verify", "--strict", helperBinaryURL.path])
    try run("/usr/bin/codesign", ["--verify", "--strict", systemHelperBinaryURL.path])
    print("    特权 helper 包结构（静态验收）：")
    print("      - \(helperBinaryURL.path.replacingOccurrences(of: appURL.path + "/", with: ""))（旧 IKE helper，迁移回滚用，后续版本移除）")
    print("      - \(systemHelperBinaryURL.path.replacingOccurrences(of: appURL.path + "/", with: "")) + \(systemHelperPlistSourceURL.lastPathComponent)（SMAppService daemon）")
    print("    本包为 ad hoc 本地签名：helper 的注册、批准、升级和卸载必须在正式签名分发包上验收。")
    print("\n完成：\(appURL.path)")
    return appURL
}

func releaseArtifacts(skipBuild: Bool) throws {
    let appURL: URL
    if skipBuild {
        appURL = distURL.appendingPathComponent("EC25 Toolbox.app", isDirectory: true)
    } else {
        appURL = try packageApp()
    }
    guard fileManager.fileExists(atPath: appURL.path) else {
        throw ToolFailure.message("应用 bundle 不存在：\(appURL.path)")
    }

    let packagedVersions = try BundleVersions(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
    let version = environment["VERSION"] ?? packagedVersions.CFBundleShortVersionString

    print("==> 验证签名")
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])

    let architecture = try run("/usr/bin/uname", ["-m"], captureOutput: true)
    let baseName = "EC25-Toolbox-\(version)-\(architecture)"
    let dmgURL = distURL.appendingPathComponent("\(baseName).dmg")
    let zipURL = distURL.appendingPathComponent("\(baseName).zip")
    try removeIfPresent(dmgURL)
    try removeIfPresent(zipURL)

    let workURL = fileManager.temporaryDirectory
        .appendingPathComponent("EC25Release-\(UUID().uuidString)", isDirectory: true)
    let stageURL = workURL.appendingPathComponent("dmg", isDirectory: true)
    defer { try? removeIfPresent(workURL) }
    try fileManager.createDirectory(at: stageURL, withIntermediateDirectories: true)
    let stagedAppURL = stageURL.appendingPathComponent(appURL.lastPathComponent)
    try run(
        "/usr/bin/ditto",
        ["--norsrc", "--noextattr", "--noqtn", "--noacl", appURL.path, stagedAppURL.path]
    )
    try fileManager.createSymbolicLink(
        at: stageURL.appendingPathComponent("Applications"),
        withDestinationURL: URL(fileURLWithPath: "/Applications", isDirectory: true)
    )

    print("==> 生成 DMG")
    try run(
        "/usr/bin/hdiutil",
        ["create", "-volname", "EC25 Toolbox", "-srcfolder", stageURL.path, "-ov", "-format", "UDZO", dmgURL.path]
    )

    print("==> 生成 ZIP")
    try run(
        "/usr/bin/ditto",
        [
            "-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl",
            "--keepParent", appURL.lastPathComponent, zipURL.lastPathComponent
        ],
        currentDirectory: distURL
    )

    print("==> 生成校验和")
    let sums = try run(
        "/usr/bin/shasum",
        ["-a", "256", dmgURL.lastPathComponent, zipURL.lastPathComponent],
        currentDirectory: distURL,
        captureOutput: true
    )
    try (sums + "\n").write(
        to: distURL.appendingPathComponent("SHA256SUMS.txt"),
        atomically: true,
        encoding: .utf8
    )
    print(sums)
    print("\n产物：\n  \(dmgURL.path)\n  \(zipURL.path)")
}

func usage() {
    print("""
    用法：swift Tools/ec25.swift <command> [options]

      package                     构建 .app，并同步生成 DMG、ZIP 和 SHA256SUMS.txt
      release [--no-build]        生成 DMG、ZIP 和 SHA256SUMS.txt
    """)
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        usage()
        exit(2)
    }

    switch command {
    case "package":
        guard arguments.count == 1 else { throw ToolFailure.message("package 不支持额外参数") }
        try releaseArtifacts(skipBuild: false)
    case "release":
        try releaseArtifacts(skipBuild: arguments.contains("--no-build"))
    case "help", "--help", "-h":
        usage()
    default:
        usage()
        throw ToolFailure.message("未知命令：\(command)")
    }
} catch {
    FileHandle.standardError.write(Data("错误：\(error.localizedDescription)\n".utf8))
    exit(1)
}
