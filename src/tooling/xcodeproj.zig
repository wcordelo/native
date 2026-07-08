//! Deterministic Xcode project generation for the iOS host tier.
//!
//! `native package --target ios` emits a COMPLETE project the user never
//! edits: the toolkit-owned UIKit host sources, the app's embed static
//! library, the generated Info.plist and asset catalog, and this
//! project file tying them together so `xcodebuild archive` works with
//! zero edits. Object identifiers are fixed constants (not random
//! UUIDs), so two runs over the same app.zon produce byte-identical
//! projects and layout tests can pin the output.

const std = @import("std");

pub const ProjectModel = struct {
    /// Target, product, and scheme name (the app.zon `name`).
    name: []const u8,
    /// CFBundleIdentifier / PRODUCT_BUNDLE_IDENTIFIER (the app.zon `id`).
    bundle_id: []const u8,
    /// MARKETING_VERSION (the app.zon `version`).
    version: []const u8,
    /// The embed static library file name under Libraries/.
    lib_name: []const u8 = "libnative-sdk.a",
};

// Fixed object ids (24 hex chars, "NSDK" prefix): deterministic output.
const id_project = "4E53444B0000000000000001";
const id_main_group = "4E53444B0000000000000002";
const id_products_group = "4E53444B0000000000000003";
const id_host_group = "4E53444B0000000000000004";
const id_libraries_group = "4E53444B0000000000000005";
const id_target = "4E53444B0000000000000006";
const id_product_ref = "4E53444B0000000000000007";
const id_file_host_m = "4E53444B0000000000000008";
const id_file_header = "4E53444B0000000000000009";
const id_file_infoplist = "4E53444B000000000000000A";
const id_file_assets = "4E53444B000000000000000B";
const id_file_resources = "4E53444B000000000000000C";
const id_file_lib = "4E53444B000000000000000D";
const id_build_host_m = "4E53444B0000000000000010";
const id_build_assets = "4E53444B0000000000000011";
const id_build_resources = "4E53444B0000000000000012";
const id_build_lib = "4E53444B0000000000000013";
const id_phase_sources = "4E53444B0000000000000020";
const id_phase_frameworks = "4E53444B0000000000000021";
const id_phase_resources = "4E53444B0000000000000022";
const id_project_configs = "4E53444B0000000000000030";
const id_target_configs = "4E53444B0000000000000031";
const id_cfg_project_debug = "4E53444B0000000000000032";
const id_cfg_project_release = "4E53444B0000000000000033";
const id_cfg_target_debug = "4E53444B0000000000000034";
const id_cfg_target_release = "4E53444B0000000000000035";

/// project.pbxproj for the host-tier app: one application target
/// compiling Host/uikit_host.m, linking Libraries/<lib> (system
/// frameworks arrive through Clang module autolinking), and copying the
/// asset catalog plus the bundled Assets folder into the bundle. The
/// folder is deliberately NOT named Resources: a bundle-root Resources
/// directory makes CFBundle read the .app as a deep (macOS-layout)
/// bundle and `xcodebuild archive` then fails to stamp the archive
/// ("Archive Missing Bundle Identifier").
pub fn pbxprojAlloc(allocator: std.mem.Allocator, model: ProjectModel) ![]u8 {
    const name = try quotedAlloc(allocator, model.name);
    defer allocator.free(name);
    const bundle_id = try quotedAlloc(allocator, model.bundle_id);
    defer allocator.free(bundle_id);
    const version = try quotedAlloc(allocator, model.version);
    defer allocator.free(version);
    const lib_name = try quotedAlloc(allocator, model.lib_name);
    defer allocator.free(lib_name);
    const product_name_value = try std.fmt.allocPrint(allocator, "{s}.app", .{model.name});
    defer allocator.free(product_name_value);
    const product_name = try quotedAlloc(allocator, product_name_value);
    defer allocator.free(product_name);

    return std.fmt.allocPrint(allocator,
        \\// !$*UTF8*$!
        \\{{
        \\    archiveVersion = 1;
        \\    classes = {{
        \\    }};
        \\    objectVersion = 56;
        \\    objects = {{
        \\
        \\/* Begin PBXBuildFile section */
        \\        {[build_host_m]s} /* uikit_host.m in Sources */ = {{isa = PBXBuildFile; fileRef = {[file_host_m]s} /* uikit_host.m */; }};
        \\        {[build_assets]s} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {[file_assets]s} /* Assets.xcassets */; }};
        \\        {[build_resources]s} /* Assets in Resources */ = {{isa = PBXBuildFile; fileRef = {[file_resources]s} /* Assets */; }};
        \\        {[build_lib]s} /* {[lib_comment]s} in Frameworks */ = {{isa = PBXBuildFile; fileRef = {[file_lib]s} /* {[lib_comment]s} */; }};
        \\/* End PBXBuildFile section */
        \\
        \\/* Begin PBXFileReference section */
        \\        {[product_ref]s} /* app product */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {[product_name]s}; sourceTree = BUILT_PRODUCTS_DIR; }};
        \\        {[file_host_m]s} /* uikit_host.m */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = "uikit_host.m"; sourceTree = "<group>"; }};
        \\        {[file_header]s} /* native_sdk_app.h */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = "native_sdk_app.h"; sourceTree = "<group>"; }};
        \\        {[file_infoplist]s} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Info.plist"; sourceTree = "<group>"; }};
        \\        {[file_assets]s} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = "Assets.xcassets"; sourceTree = "<group>"; }};
        \\        {[file_resources]s} /* Assets */ = {{isa = PBXFileReference; lastKnownFileType = folder; path = "Assets"; sourceTree = "<group>"; }};
        \\        {[file_lib]s} /* {[lib_comment]s} */ = {{isa = PBXFileReference; lastKnownFileType = archive.ar; path = {[lib_name]s}; sourceTree = "<group>"; }};
        \\/* End PBXFileReference section */
        \\
        \\/* Begin PBXFrameworksBuildPhase section */
        \\        {[phase_frameworks]s} /* Frameworks */ = {{
        \\            isa = PBXFrameworksBuildPhase;
        \\            buildActionMask = 2147483647;
        \\            files = (
        \\                {[build_lib]s} /* {[lib_comment]s} in Frameworks */,
        \\            );
        \\            runOnlyForDeploymentPostprocessing = 0;
        \\        }};
        \\/* End PBXFrameworksBuildPhase section */
        \\
        \\/* Begin PBXGroup section */
        \\        {[main_group]s} = {{
        \\            isa = PBXGroup;
        \\            children = (
        \\                {[host_group]s} /* Host */,
        \\                {[libraries_group]s} /* Libraries */,
        \\                {[file_assets]s} /* Assets.xcassets */,
        \\                {[file_resources]s} /* Assets */,
        \\                {[products_group]s} /* Products */,
        \\            );
        \\            sourceTree = "<group>";
        \\        }};
        \\        {[host_group]s} /* Host */ = {{
        \\            isa = PBXGroup;
        \\            children = (
        \\                {[file_host_m]s} /* uikit_host.m */,
        \\                {[file_header]s} /* native_sdk_app.h */,
        \\                {[file_infoplist]s} /* Info.plist */,
        \\            );
        \\            path = Host;
        \\            sourceTree = "<group>";
        \\        }};
        \\        {[libraries_group]s} /* Libraries */ = {{
        \\            isa = PBXGroup;
        \\            children = (
        \\                {[file_lib]s} /* {[lib_comment]s} */,
        \\            );
        \\            path = Libraries;
        \\            sourceTree = "<group>";
        \\        }};
        \\        {[products_group]s} /* Products */ = {{
        \\            isa = PBXGroup;
        \\            children = (
        \\                {[product_ref]s} /* app product */,
        \\            );
        \\            name = Products;
        \\            sourceTree = "<group>";
        \\        }};
        \\/* End PBXGroup section */
        \\
        \\/* Begin PBXNativeTarget section */
        \\        {[target]s} /* app target */ = {{
        \\            isa = PBXNativeTarget;
        \\            buildConfigurationList = {[target_configs]s};
        \\            buildPhases = (
        \\                {[phase_sources]s} /* Sources */,
        \\                {[phase_frameworks]s} /* Frameworks */,
        \\                {[phase_resources]s} /* Resources */,
        \\            );
        \\            buildRules = (
        \\            );
        \\            dependencies = (
        \\            );
        \\            name = {[name]s};
        \\            productName = {[name]s};
        \\            productReference = {[product_ref]s} /* app product */;
        \\            productType = "com.apple.product-type.application";
        \\        }};
        \\/* End PBXNativeTarget section */
        \\
        \\/* Begin PBXProject section */
        \\        {[project]s} /* Project object */ = {{
        \\            isa = PBXProject;
        \\            attributes = {{
        \\                BuildIndependentTargetsInParallel = 1;
        \\                LastUpgradeCheck = 1500;
        \\            }};
        \\            buildConfigurationList = {[project_configs]s};
        \\            compatibilityVersion = "Xcode 14.0";
        \\            developmentRegion = en;
        \\            hasScannedForEncodings = 0;
        \\            knownRegions = (
        \\                en,
        \\                Base,
        \\            );
        \\            mainGroup = {[main_group]s};
        \\            productRefGroup = {[products_group]s} /* Products */;
        \\            projectDirPath = "";
        \\            projectRoot = "";
        \\            targets = (
        \\                {[target]s} /* app target */,
        \\            );
        \\        }};
        \\/* End PBXProject section */
        \\
        \\/* Begin PBXResourcesBuildPhase section */
        \\        {[phase_resources]s} /* Resources */ = {{
        \\            isa = PBXResourcesBuildPhase;
        \\            buildActionMask = 2147483647;
        \\            files = (
        \\                {[build_assets]s} /* Assets.xcassets in Resources */,
        \\                {[build_resources]s} /* Assets in Resources */,
        \\            );
        \\            runOnlyForDeploymentPostprocessing = 0;
        \\        }};
        \\/* End PBXResourcesBuildPhase section */
        \\
        \\/* Begin PBXSourcesBuildPhase section */
        \\        {[phase_sources]s} /* Sources */ = {{
        \\            isa = PBXSourcesBuildPhase;
        \\            buildActionMask = 2147483647;
        \\            files = (
        \\                {[build_host_m]s} /* uikit_host.m in Sources */,
        \\            );
        \\            runOnlyForDeploymentPostprocessing = 0;
        \\        }};
        \\/* End PBXSourcesBuildPhase section */
        \\
        \\/* Begin XCBuildConfiguration section */
        \\        {[cfg_project_debug]s} /* Debug */ = {{
        \\            isa = XCBuildConfiguration;
        \\            buildSettings = {{
        \\                ALWAYS_SEARCH_USER_PATHS = NO;
        \\                CLANG_ENABLE_MODULES = YES;
        \\                CLANG_ENABLE_OBJC_ARC = YES;
        \\                DEBUG_INFORMATION_FORMAT = dwarf;
        \\                ENABLE_TESTABILITY = YES;
        \\                GCC_OPTIMIZATION_LEVEL = 0;
        \\                IPHONEOS_DEPLOYMENT_TARGET = 15.0;
        \\                ONLY_ACTIVE_ARCH = YES;
        \\                SDKROOT = iphoneos;
        \\            }};
        \\            name = Debug;
        \\        }};
        \\        {[cfg_project_release]s} /* Release */ = {{
        \\            isa = XCBuildConfiguration;
        \\            buildSettings = {{
        \\                ALWAYS_SEARCH_USER_PATHS = NO;
        \\                CLANG_ENABLE_MODULES = YES;
        \\                CLANG_ENABLE_OBJC_ARC = YES;
        \\                DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
        \\                IPHONEOS_DEPLOYMENT_TARGET = 15.0;
        \\                SDKROOT = iphoneos;
        \\                VALIDATE_PRODUCT = YES;
        \\            }};
        \\            name = Release;
        \\        }};
        \\        {[cfg_target_debug]s} /* Debug */ = {{
        \\            isa = XCBuildConfiguration;
        \\            buildSettings = {{
        \\                ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
        \\                CODE_SIGN_STYLE = Automatic;
        \\                CURRENT_PROJECT_VERSION = 1;
        \\                GENERATE_INFOPLIST_FILE = NO;
        \\                INFOPLIST_FILE = "Host/Info.plist";
        \\                LIBRARY_SEARCH_PATHS = (
        \\                    "$(inherited)",
        \\                    "$(PROJECT_DIR)/Libraries",
        \\                );
        \\                MARKETING_VERSION = {[version]s};
        \\                PRODUCT_BUNDLE_IDENTIFIER = {[bundle_id]s};
        \\                PRODUCT_NAME = {[name]s};
        \\                TARGETED_DEVICE_FAMILY = "1,2";
        \\            }};
        \\            name = Debug;
        \\        }};
        \\        {[cfg_target_release]s} /* Release */ = {{
        \\            isa = XCBuildConfiguration;
        \\            buildSettings = {{
        \\                ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
        \\                CODE_SIGN_STYLE = Automatic;
        \\                CURRENT_PROJECT_VERSION = 1;
        \\                GENERATE_INFOPLIST_FILE = NO;
        \\                INFOPLIST_FILE = "Host/Info.plist";
        \\                LIBRARY_SEARCH_PATHS = (
        \\                    "$(inherited)",
        \\                    "$(PROJECT_DIR)/Libraries",
        \\                );
        \\                MARKETING_VERSION = {[version]s};
        \\                PRODUCT_BUNDLE_IDENTIFIER = {[bundle_id]s};
        \\                PRODUCT_NAME = {[name]s};
        \\                TARGETED_DEVICE_FAMILY = "1,2";
        \\            }};
        \\            name = Release;
        \\        }};
        \\/* End XCBuildConfiguration section */
        \\
        \\/* Begin XCConfigurationList section */
        \\        {[project_configs]s} /* Build configuration list for PBXProject */ = {{
        \\            isa = XCConfigurationList;
        \\            buildConfigurations = (
        \\                {[cfg_project_debug]s} /* Debug */,
        \\                {[cfg_project_release]s} /* Release */,
        \\            );
        \\            defaultConfigurationIsVisible = 0;
        \\            defaultConfigurationName = Release;
        \\        }};
        \\        {[target_configs]s} /* Build configuration list for PBXNativeTarget */ = {{
        \\            isa = XCConfigurationList;
        \\            buildConfigurations = (
        \\                {[cfg_target_debug]s} /* Debug */,
        \\                {[cfg_target_release]s} /* Release */,
        \\            );
        \\            defaultConfigurationIsVisible = 0;
        \\            defaultConfigurationName = Release;
        \\        }};
        \\/* End XCConfigurationList section */
        \\    }};
        \\    rootObject = {[project]s} /* Project object */;
        \\}}
        \\
    , .{
        .name = name,
        .bundle_id = bundle_id,
        .version = version,
        .lib_name = lib_name,
        .lib_comment = model.lib_name,
        .product_name = product_name,
        .project = id_project,
        .main_group = id_main_group,
        .products_group = id_products_group,
        .host_group = id_host_group,
        .libraries_group = id_libraries_group,
        .target = id_target,
        .product_ref = id_product_ref,
        .file_host_m = id_file_host_m,
        .file_header = id_file_header,
        .file_infoplist = id_file_infoplist,
        .file_assets = id_file_assets,
        .file_resources = id_file_resources,
        .file_lib = id_file_lib,
        .build_host_m = id_build_host_m,
        .build_assets = id_build_assets,
        .build_resources = id_build_resources,
        .build_lib = id_build_lib,
        .phase_sources = id_phase_sources,
        .phase_frameworks = id_phase_frameworks,
        .phase_resources = id_phase_resources,
        .project_configs = id_project_configs,
        .target_configs = id_target_configs,
        .cfg_project_debug = id_cfg_project_debug,
        .cfg_project_release = id_cfg_project_release,
        .cfg_target_debug = id_cfg_target_debug,
        .cfg_target_release = id_cfg_target_release,
    });
}

/// A shared scheme so `xcodebuild -scheme <name>` (and archive) works
/// headlessly on a freshly generated project — Xcode only auto-creates
/// schemes interactively.
pub fn schemeAlloc(allocator: std.mem.Allocator, model: ProjectModel) ![]u8 {
    const name = try xmlEscapeAlloc(allocator, model.name);
    defer allocator.free(name);
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Scheme LastUpgradeVersion = "1500" version = "1.7">
        \\   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
        \\      <BuildActionEntries>
        \\         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
        \\            <BuildableReference
        \\               BuildableIdentifier = "primary"
        \\               BlueprintIdentifier = "{[target]s}"
        \\               BuildableName = "{[name]s}.app"
        \\               BlueprintName = "{[name]s}"
        \\               ReferencedContainer = "container:{[name]s}.xcodeproj">
        \\            </BuildableReference>
        \\         </BuildActionEntry>
        \\      </BuildActionEntries>
        \\   </BuildAction>
        \\   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
        \\      <BuildableProductRunnable runnableDebuggingMode = "0">
        \\         <BuildableReference
        \\            BuildableIdentifier = "primary"
        \\            BlueprintIdentifier = "{[target]s}"
        \\            BuildableName = "{[name]s}.app"
        \\            BlueprintName = "{[name]s}"
        \\            ReferencedContainer = "container:{[name]s}.xcodeproj">
        \\         </BuildableReference>
        \\      </BuildableProductRunnable>
        \\   </LaunchAction>
        \\   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
        \\   </ArchiveAction>
        \\</Scheme>
        \\
    , .{ .target = id_target, .name = name });
}

/// pbxproj string literal: always quoted, with backslash and quote
/// escaping (names with spaces or punctuation stay valid).
fn quotedAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

fn xmlEscapeAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, ch),
        }
    }
    return out.toOwnedSlice(allocator);
}

test "pbxproj carries the app identity and host wiring" {
    const text = try pbxprojAlloc(std.testing.allocator, .{
        .name = "calculator",
        .bundle_id = "dev.native-sdk.calculator",
        .version = "0.1.0",
    });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "PRODUCT_BUNDLE_IDENTIFIER = \"dev.native-sdk.calculator\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "PRODUCT_NAME = \"calculator\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "MARKETING_VERSION = \"0.1.0\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "path = \"uikit_host.m\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "path = \"libnative-sdk.a\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "INFOPLIST_FILE = \"Host/Info.plist\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "SDKROOT = iphoneos;") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "com.apple.product-type.application") != null);
    // Deterministic identifiers: the fixed target id appears verbatim.
    try std.testing.expect(std.mem.indexOf(u8, text, id_target) != null);
}

test "scheme references the fixed target for headless archive" {
    const text = try schemeAlloc(std.testing.allocator, .{
        .name = "calculator",
        .bundle_id = "dev.native-sdk.calculator",
        .version = "0.1.0",
    });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "BlueprintIdentifier = \"" ++ id_target ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "BuildableName = \"calculator.app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "container:calculator.xcodeproj") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<ArchiveAction") != null);
}

test "pbxproj quotes hostile names" {
    const text = try pbxprojAlloc(std.testing.allocator, .{
        .name = "My \"App\"",
        .bundle_id = "dev.example",
        .version = "1.0",
    });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "PRODUCT_NAME = \"My \\\"App\\\"\";") != null);
}
