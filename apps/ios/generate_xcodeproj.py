#!/usr/bin/env python3
"""Deterministically generates apps/ios/OpenUUMobile.xcodeproj."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path

IOS_DIR = Path(__file__).resolve().parent
PROJ_DIR = IOS_DIR / "OpenUUMobile.xcodeproj"
SOURCES_DIR = IOS_DIR / "Sources"


def uid(key: str) -> str:
    return hashlib.md5(f"openuu-ios::{key}".encode("utf-8")).hexdigest()[:24].upper()


def discover_swift_sources() -> list[str]:
    if not SOURCES_DIR.exists():
        return []
    files: list[str] = []
    for p in sorted(SOURCES_DIR.rglob("*.swift")):
        files.append(p.relative_to(IOS_DIR).as_posix())
    return files


def generate() -> None:
    swift_files = discover_swift_sources()
    if not swift_files:
        raise RuntimeError(f"No Swift source files found under {SOURCES_DIR}")

    proj_uuid = uid("PBXProject")
    main_group_uuid = uid("Group::Main")
    sources_group_uuid = uid("Group::Sources")
    resources_group_uuid = uid("Group::Resources")
    frameworks_group_uuid = uid("Group::Frameworks")
    products_group_uuid = uid("Group::Products")

    target_uuid = uid("Target::OpenUUMobile")
    app_product_uuid = uid("FileRef::OpenUUMobile.app")
    info_plist_uuid = uid("FileRef::Info.plist")

    assets_ref_uuid = uid("FileRef::Assets.xcassets")
    assets_build_uuid = uid("BuildFile::Assets.xcassets")

    xcfw_ref_uuid = uid("FileRef::OpenUUCore.xcframework")
    xcfw_build_uuid = uid("BuildFile::OpenUUCore.xcframework")

    system_frameworks = [
        "AVFoundation.framework",
        "AudioToolbox.framework",
        "CoreMedia.framework",
        "VideoToolbox.framework",
        "Security.framework",
        "SystemConfiguration.framework",
    ]
    sys_fw_entries = [
        (name, uid(f"FileRef::SysFW::{name}"), uid(f"BuildFile::SysFW::{name}"))
        for name in system_frameworks
    ]

    swift_entries = [
        (rel_path, Path(rel_path).name, uid(f"FileRef::{rel_path}"), uid(f"BuildFile::{rel_path}"))
        for rel_path in swift_files
    ]

    sources_phase_uuid = uid("Phase::Sources")
    frameworks_phase_uuid = uid("Phase::Frameworks")
    resources_phase_uuid = uid("Phase::Resources")

    proj_cfg_list_uuid = uid("ConfigList::Project")
    proj_debug_uuid = uid("Config::Project::Debug")
    proj_release_uuid = uid("Config::Project::Release")

    target_cfg_list_uuid = uid("ConfigList::Target")
    target_debug_uuid = uid("Config::Target::Debug")
    target_release_uuid = uid("Config::Target::Release")

    lines: list[str] = []
    lines.append("// !$*UTF8*$!")
    lines.append("{")
    lines.append("\tarchiveVersion = 1;")
    lines.append("\tclasses = {")
    lines.append("\t};")
    lines.append("\tobjectVersion = 56;")
    lines.append("\tobjects = {")
    lines.append("")

    # PBXBuildFile
    lines.append("/* Begin PBXBuildFile section */")
    for rel_path, name, ref_id, build_id in swift_entries:
        lines.append(f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};")
    lines.append(f"\t\t{assets_build_uuid} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {assets_ref_uuid} /* Assets.xcassets */; }};")
    lines.append(f"\t\t{xcfw_build_uuid} /* OpenUUCore.xcframework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {xcfw_ref_uuid} /* OpenUUCore.xcframework */; }};")
    for fw_name, ref_id, build_id in sys_fw_entries:
        lines.append(f"\t\t{build_id} /* {fw_name} in Frameworks */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {fw_name} */; }};")
    lines.append("/* End PBXBuildFile section */")
    lines.append("")

    # PBXFileReference
    lines.append("/* Begin PBXFileReference section */")
    lines.append(f"\t\t{app_product_uuid} /* OpenUUMobile.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = OpenUUMobile.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
    lines.append(f"\t\t{info_plist_uuid} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};")
    lines.append(f"\t\t{assets_ref_uuid} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; name = Assets.xcassets; path = Resources/Assets.xcassets; sourceTree = \"<group>\"; }};")
    lines.append(f"\t\t{xcfw_ref_uuid} /* OpenUUCore.xcframework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; name = OpenUUCore.xcframework; path = Frameworks/OpenUUCore.xcframework; sourceTree = \"<group>\"; }};")
    for fw_name, ref_id, _ in sys_fw_entries:
        lines.append(f"\t\t{ref_id} /* {fw_name} */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = {fw_name}; path = System/Library/Frameworks/{fw_name}; sourceTree = SDKROOT; }};")
    for rel_path, name, ref_id, _ in swift_entries:
        lines.append(f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = {name}; path = {rel_path}; sourceTree = \"<group>\"; }};")
    lines.append("/* End PBXFileReference section */")
    lines.append("")

    # PBXFrameworksBuildPhase
    lines.append("/* Begin PBXFrameworksBuildPhase section */")
    lines.append(f"\t\t{frameworks_phase_uuid} /* Frameworks */ = {{")
    lines.append("\t\t\tisa = PBXFrameworksBuildPhase;")
    lines.append("\t\t\tbuildActionMask = 2147483647;")
    lines.append("\t\t\tfiles = (")
    lines.append(f"\t\t\t\t{xcfw_build_uuid} /* OpenUUCore.xcframework in Frameworks */,")
    for fw_name, _, build_id in sys_fw_entries:
        lines.append(f"\t\t\t\t{build_id} /* {fw_name} in Frameworks */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    lines.append("\t\t};")
    lines.append("/* End PBXFrameworksBuildPhase section */")
    lines.append("")

    # PBXGroup
    lines.append("/* Begin PBXGroup section */")
    lines.append(f"\t\t{main_group_uuid} = {{")
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    lines.append(f"\t\t\t\t{sources_group_uuid} /* Sources */,")
    lines.append(f"\t\t\t\t{resources_group_uuid} /* Resources */,")
    lines.append(f"\t\t\t\t{info_plist_uuid} /* Info.plist */,")
    lines.append(f"\t\t\t\t{frameworks_group_uuid} /* Frameworks */,")
    lines.append(f"\t\t\t\t{products_group_uuid} /* Products */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tsourceTree = \"<group>\";")
    lines.append("\t\t};")

    lines.append(f"\t\t{sources_group_uuid} /* Sources */ = {{")
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    for _, name, ref_id, _ in swift_entries:
        lines.append(f"\t\t\t\t{ref_id} /* {name} */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tname = Sources;")
    lines.append("\t\t\tsourceTree = \"<group>\";")
    lines.append("\t\t};")

    lines.append(f"\t\t{resources_group_uuid} /* Resources */ = {{")
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    lines.append(f"\t\t\t\t{assets_ref_uuid} /* Assets.xcassets */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tname = Resources;")
    lines.append("\t\t\tsourceTree = \"<group>\";")
    lines.append("\t\t};")

    lines.append(f"\t\t{frameworks_group_uuid} /* Frameworks */ = {{")
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    lines.append(f"\t\t\t\t{xcfw_ref_uuid} /* OpenUUCore.xcframework */,")
    for fw_name, ref_id, _ in sys_fw_entries:
        lines.append(f"\t\t\t\t{ref_id} /* {fw_name} */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tname = Frameworks;")
    lines.append("\t\t\tsourceTree = \"<group>\";")
    lines.append("\t\t};")

    lines.append(f"\t\t{products_group_uuid} /* Products */ = {{")
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    lines.append(f"\t\t\t\t{app_product_uuid} /* OpenUUMobile.app */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tname = Products;")
    lines.append("\t\t\tsourceTree = \"<group>\";")
    lines.append("\t\t};")
    lines.append("/* End PBXGroup section */")
    lines.append("")

    # PBXNativeTarget
    lines.append("/* Begin PBXNativeTarget section */")
    lines.append(f"\t\t{target_uuid} /* OpenUUMobile */ = {{")
    lines.append("\t\t\tisa = PBXNativeTarget;")
    lines.append(f"\t\t\tbuildConfigurationList = {target_cfg_list_uuid} /* Build configuration list for PBXNativeTarget \"OpenUUMobile\" */;")
    lines.append("\t\t\tbuildPhases = (")
    lines.append(f"\t\t\t\t{sources_phase_uuid} /* Sources */,")
    lines.append(f"\t\t\t\t{frameworks_phase_uuid} /* Frameworks */,")
    lines.append(f"\t\t\t\t{resources_phase_uuid} /* Resources */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tbuildRules = (")
    lines.append("\t\t\t);")
    lines.append("\t\t\tdependencies = (")
    lines.append("\t\t\t);")
    lines.append("\t\t\tname = OpenUUMobile;")
    lines.append("\t\t\tproductName = OpenUUMobile;")
    lines.append(f"\t\t\tproductReference = {app_product_uuid} /* OpenUUMobile.app */;")
    lines.append("\t\t\tproductType = \"com.apple.product-type.application\";")
    lines.append("\t\t};")
    lines.append("/* End PBXNativeTarget section */")
    lines.append("")

    # PBXProject
    lines.append("/* Begin PBXProject section */")
    lines.append(f"\t\t{proj_uuid} /* Project object */ = {{")
    lines.append("\t\t\tisa = PBXProject;")
    lines.append("\t\t\tattributes = {")
    lines.append("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    lines.append("\t\t\t\tLastSwiftUpdateCheck = 1600;")
    lines.append("\t\t\t\tLastUpgradeCheck = 1600;")
    lines.append("\t\t\t};")
    lines.append(f"\t\t\tbuildConfigurationList = {proj_cfg_list_uuid} /* Build configuration list for PBXProject \"OpenUUMobile\" */;")
    lines.append("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    lines.append("\t\t\tdevelopmentRegion = \"zh-Hans\";")
    lines.append("\t\t\thasScannedForEncodings = 0;")
    lines.append("\t\t\tknownRegions = (")
    lines.append("\t\t\t\ten,")
    lines.append("\t\t\t\t\"zh-Hans\",")
    lines.append("\t\t\t\tBase,")
    lines.append("\t\t\t);")
    lines.append(f"\t\t\tmainGroup = {main_group_uuid};")
    lines.append(f"\t\t\tproductRefGroup = {products_group_uuid} /* Products */;")
    lines.append("\t\t\tprojectDirPath = \"\";")
    lines.append("\t\t\tprojectRoot = \"\";")
    lines.append("\t\t\ttargets = (")
    lines.append(f"\t\t\t\t{target_uuid} /* OpenUUMobile */,")
    lines.append("\t\t\t);")
    lines.append("\t\t};")
    lines.append("/* End PBXProject section */")
    lines.append("")

    # PBXResourcesBuildPhase
    lines.append("/* Begin PBXResourcesBuildPhase section */")
    lines.append(f"\t\t{resources_phase_uuid} /* Resources */ = {{")
    lines.append("\t\t\tisa = PBXResourcesBuildPhase;")
    lines.append("\t\t\tbuildActionMask = 2147483647;")
    lines.append("\t\t\tfiles = (")
    lines.append(f"\t\t\t\t{assets_build_uuid} /* Assets.xcassets in Resources */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    lines.append("\t\t};")
    lines.append("/* End PBXResourcesBuildPhase section */")
    lines.append("")

    # PBXSourcesBuildPhase
    lines.append("/* Begin PBXSourcesBuildPhase section */")
    lines.append(f"\t\t{sources_phase_uuid} /* Sources */ = {{")
    lines.append("\t\t\tisa = PBXSourcesBuildPhase;")
    lines.append("\t\t\tbuildActionMask = 2147483647;")
    lines.append("\t\t\tfiles = (")
    for _, name, _, build_id in swift_entries:
        lines.append(f"\t\t\t\t{build_id} /* {name} in Sources */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    lines.append("\t\t};")
    lines.append("/* End PBXSourcesBuildPhase section */")
    lines.append("")

    # XCBuildConfiguration
    lines.append("/* Begin XCBuildConfiguration section */")
    proj_common = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
\t\t\t\tSWIFT_VERSION = 6.0;"""

    lines.append(f"\t\t{proj_debug_uuid} /* Debug */ = {{")
    lines.append("\t\t\tisa = XCBuildConfiguration;")
    lines.append("\t\t\tbuildSettings = {")
    lines.append(proj_common)
    lines.append("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
    lines.append("\t\t\t\tENABLE_TESTABILITY = YES;")
    lines.append("\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;")
    lines.append("\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;")
    lines.append("\t\t\t\tONLY_ACTIVE_ARCH = YES;")
    lines.append("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = \"DEBUG $(inherited)\";")
    lines.append("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";")
    lines.append("\t\t\t};")
    lines.append("\t\t\tname = Debug;")
    lines.append("\t\t};")

    lines.append(f"\t\t{proj_release_uuid} /* Release */ = {{")
    lines.append("\t\t\tisa = XCBuildConfiguration;")
    lines.append("\t\t\tbuildSettings = {")
    lines.append(proj_common)
    lines.append("\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";")
    lines.append("\t\t\t\tENABLE_NS_ASSERTIONS = NO;")
    lines.append("\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;")
    lines.append("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-O\";")
    lines.append("\t\t\t\tVALIDATE_PRODUCT = YES;")
    lines.append("\t\t\t};")
    lines.append("\t\t\tname = Release;")
    lines.append("\t\t};")

    target_common = """\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 5;
\t\t\t\tENABLE_PREVIEWS = YES;
\t\t\t\tFRAMEWORK_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"$(PROJECT_DIR)/Frameworks",
\t\t\t\t);
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = Info.plist;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 0.5.0;
\t\t\t\tOTHER_LDFLAGS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"-lc++",
\t\t\t\t\t"-lresolv",
\t\t\t\t);
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = ren.onekb.openuu;
\t\t\t\tPRODUCT_NAME = OpenUUMobile;
\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;
\t\t\t\tSWIFT_VERSION = 6.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";"""

    lines.append(f"\t\t{target_debug_uuid} /* Debug */ = {{")
    lines.append("\t\t\tisa = XCBuildConfiguration;")
    lines.append("\t\t\tbuildSettings = {")
    lines.append(target_common)
    lines.append("\t\t\t};")
    lines.append("\t\t\tname = Debug;")
    lines.append("\t\t};")

    lines.append(f"\t\t{target_release_uuid} /* Release */ = {{")
    lines.append("\t\t\tisa = XCBuildConfiguration;")
    lines.append("\t\t\tbuildSettings = {")
    lines.append(target_common)
    lines.append("\t\t\t};")
    lines.append("\t\t\tname = Release;")
    lines.append("\t\t};")
    lines.append("/* End XCBuildConfiguration section */")
    lines.append("")

    # XCConfigurationList
    lines.append("/* Begin XCConfigurationList section */")
    lines.append(f"\t\t{proj_cfg_list_uuid} /* Build configuration list for PBXProject \"OpenUUMobile\" */ = {{")
    lines.append("\t\t\tisa = XCConfigurationList;")
    lines.append("\t\t\tbuildConfigurations = (")
    lines.append(f"\t\t\t\t{proj_debug_uuid} /* Debug */,")
    lines.append(f"\t\t\t\t{proj_release_uuid} /* Release */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tdefaultConfigurationIsVisible = 0;")
    lines.append("\t\t\tdefaultConfigurationName = Release;")
    lines.append("\t\t};")

    lines.append(f"\t\t{target_cfg_list_uuid} /* Build configuration list for PBXNativeTarget \"OpenUUMobile\" */ = {{")
    lines.append("\t\t\tisa = XCConfigurationList;")
    lines.append("\t\t\tbuildConfigurations = (")
    lines.append(f"\t\t\t\t{target_debug_uuid} /* Debug */,")
    lines.append(f"\t\t\t\t{target_release_uuid} /* Release */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tdefaultConfigurationIsVisible = 0;")
    lines.append("\t\t\tdefaultConfigurationName = Release;")
    lines.append("\t\t};")
    lines.append("/* End XCConfigurationList section */")

    lines.append("\t};")
    lines.append(f"\trootObject = {proj_uuid} /* Project object */;")
    lines.append("}")
    lines.append("")

    PROJ_DIR.mkdir(parents=True, exist_ok=True)
    pbxproj_path = PROJ_DIR / "project.pbxproj"
    pbxproj_path.write_text("\n".join(lines), encoding="utf-8")

    # Shared scheme so `xcodebuild -scheme OpenUUMobile` works out of the box
    schemes_dir = PROJ_DIR / "xcshareddata" / "xcschemes"
    schemes_dir.mkdir(parents=True, exist_ok=True)
    scheme_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_uuid}"
               BuildableName = "OpenUUMobile.app"
               BlueprintName = "OpenUUMobile"
               ReferencedContainer = "container:OpenUUMobile.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_uuid}"
            BuildableName = "OpenUUMobile.app"
            BlueprintName = "OpenUUMobile"
            ReferencedContainer = "container:OpenUUMobile.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    (schemes_dir / "OpenUUMobile.xcscheme").write_text(scheme_xml, encoding="utf-8")
    print(f"Generated {pbxproj_path} ({len(swift_files)} Swift files)")


if __name__ == "__main__":
    generate()
