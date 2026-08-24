import os
import uuid

def generate_id():
    return uuid.uuid4().hex[:24].upper()

root_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
sources_dir = os.path.join(root_dir, 'Sources')

# 收集 Swift/C 源文件、桥接头与资源
file_entries = []
resource_entries = []
for root, dirs, files in os.walk(sources_dir):
    if 'Assets.xcassets' in root:
        continue
    # The Core ML model directory is copied as one folder reference. Do not
    # flatten its nested .mlmodelc files into individual Xcode resources.
    if 'SpeakerKitModels' in root.split(os.sep):
        dirs[:] = []
        continue
    for d in dirs:
        if d == 'Assets.xcassets':
            full_p = os.path.join(root, d)
            rel_p = os.path.relpath(full_p, root_dir)
            resource_entries.append((d, rel_p, 'assetcatalog'))
        elif d == 'SpeakerKitModels':
            full_p = os.path.join(root, d)
            rel_p = os.path.relpath(full_p, root_dir)
            resource_entries.append((d, rel_p, 'folder'))
    for f in files:
        if f.endswith(('.swift', '.c', '.h')) or f == 'Info.plist' or f == 'ggml-silero-v6.2.0.bin' or f.endswith('-LICENSE.txt'):
            full_p = os.path.join(root, f)
            rel_p = os.path.relpath(full_p, root_dir)
            if f.endswith(('.swift', '.c')):
                kind = 'source'
            elif f.endswith('.h'):
                kind = 'header'
            elif f.endswith('.bin') or f.endswith('-LICENSE.txt'):
                kind = 'resource'
            else:
                kind = 'plist'
            file_entries.append((f, rel_p, kind))

# PBX IDs
proj_id = generate_id()
main_group_id = generate_id()
sources_group_id = generate_id()
products_group_id = generate_id()
target_id = generate_id()
app_product_id = generate_id()
sources_build_phase_id = generate_id()
frameworks_build_phase_id = generate_id()
resources_build_phase_id = generate_id()
embed_frameworks_build_phase_id = generate_id()
proj_config_list_id = generate_id()
target_config_list_id = generate_id()
debug_config_id = generate_id()
release_config_id = generate_id()
target_debug_config_id = generate_id()
target_release_config_id = generate_id()
package_reference_id = generate_id()
speakerkit_product_dependency_id = generate_id()

pbx_file_refs = []
pbx_build_files = []
source_build_file_ids = []
resource_build_file_ids = []
framework_build_file_ids = []
embed_framework_build_file_ids = []

for name, path, resource_kind in resource_entries:
    file_ref_id = generate_id()
    file_type = 'folder.assetcatalog' if resource_kind == 'assetcatalog' else 'folder'
    pbx_file_refs.append(f'\t\t{file_ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {file_type}; path = "{path}"; sourceTree = "<group>"; }};')
    build_file_id = generate_id()
    pbx_build_files.append(f'\t\t{build_file_id} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* {name} */; }};')
    resource_build_file_ids.append(f'\t\t\t\t{build_file_id} /* {name} in Resources */,')

for filename, path, kind in file_entries:
    file_ref_id = generate_id()
    file_types = {
        'source': 'sourcecode.swift' if filename.endswith('.swift') else 'sourcecode.c.c',
        'header': 'sourcecode.c.h',
        'resource': 'archive' if filename.endswith('.bin') else 'text',
        'plist': 'text.plist.xml',
    }
    file_type = file_types[kind]
    pbx_file_refs.append(f'\t\t{file_ref_id} /* {filename} */ = {{isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = {file_type}; path = "{path}"; sourceTree = "<group>"; }};')
    
    if kind == 'source':
        build_file_id = generate_id()
        pbx_build_files.append(f'\t\t{build_file_id} /* {filename} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* {filename} */; }};')
        source_build_file_ids.append(f'\t\t\t\t{build_file_id} /* {filename} in Sources */,')
    elif kind == 'resource':
        build_file_id = generate_id()
        pbx_build_files.append(f'\t\t{build_file_id} /* {filename} in Resources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* {filename} */; }};')
        resource_build_file_ids.append(f'\t\t\t\t{build_file_id} /* {filename} in Resources */,')

whisper_framework_ref_id = generate_id()
whisper_framework_link_id = generate_id()
whisper_framework_embed_id = generate_id()
pbx_file_refs.append(f'\t\t{whisper_framework_ref_id} /* whisper.xcframework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = "Vendor/Whisper/whisper.xcframework"; sourceTree = "<group>"; }};')
pbx_build_files.append(f'\t\t{whisper_framework_link_id} /* whisper.xcframework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {whisper_framework_ref_id} /* whisper.xcframework */; }};')
pbx_build_files.append(f'\t\t{whisper_framework_embed_id} /* whisper.xcframework in Embed Frameworks */ = {{isa = PBXBuildFile; fileRef = {whisper_framework_ref_id} /* whisper.xcframework */; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};')
framework_build_file_ids.append(f'\t\t\t\t{whisper_framework_link_id} /* whisper.xcframework in Frameworks */,')
embed_framework_build_file_ids.append(f'\t\t\t\t{whisper_framework_embed_id} /* whisper.xcframework in Embed Frameworks */,')

file_refs_str = "\n".join(pbx_file_refs)
build_files_str = "\n".join(pbx_build_files)
sources_phase_files_str = "\n".join(source_build_file_ids)
resources_phase_files_str = "\n".join(resource_build_file_ids)
frameworks_phase_files_str = "\n".join(framework_build_file_ids)
embed_frameworks_phase_files_str = "\n".join(embed_framework_build_file_ids)

# Group children
group_children = []
for filename, path, _ in file_entries:
    # find file_ref_id
    for line in pbx_file_refs:
        if f'/* {filename} */' in line:
            fid = line.strip().split()[0]
            group_children.append(f'\t\t\t\t{fid} /* {filename} */,')
            break
for name, path, _ in resource_entries:
    for line in pbx_file_refs:
        if f'/* {name} */' in line:
            fid = line.strip().split()[0]
            group_children.append(f'\t\t\t\t{fid} /* {name} */,')
            break
group_children.append(f'\t\t\t\t{whisper_framework_ref_id} /* whisper.xcframework */,')
group_children_str = "\n".join(group_children)

pbxproj_content = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{build_files_str}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
\t\t{app_product_id} /* MacAboboo.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = MacAboboo.app; sourceTree = BUILT_PRODUCTS_DIR; }};
{file_refs_str}
/* End PBXFileReference section */

/* Begin PBXCopyFilesBuildPhase section */
\t\t{embed_frameworks_build_phase_id} /* Embed Frameworks */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "";
\t\t\tdstSubfolderSpec = 10;
\t\t\tfiles = (
{embed_frameworks_phase_files_str}
\t\t\t);
\t\t\tname = "Embed Frameworks";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXCopyFilesBuildPhase section */

/* Begin PBXFrameworksBuildPhase section */
\t\t{frameworks_build_phase_id} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{frameworks_phase_files_str}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
\t\t{main_group_id} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{sources_group_id} /* Sources */,
\t\t\t\t{products_group_id} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{sources_group_id} /* Sources */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{group_children_str}
\t\t\t);
\t\t\tname = Sources;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{products_group_id} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{app_product_id} /* MacAboboo.app */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{target_id} /* MacAboboo */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {target_config_list_id} /* Build configuration list for PBXNativeTarget "MacAboboo" */;
\t\t\tbuildPhases = (
\t\t\t\t{sources_build_phase_id} /* Sources */,
\t\t\t\t{frameworks_build_phase_id} /* Frameworks */,
\t\t\t\t{resources_build_phase_id} /* Resources */,
\t\t\t\t{embed_frameworks_build_phase_id} /* Embed Frameworks */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tpackageProductDependencies = (
\t\t\t\t{speakerkit_product_dependency_id} /* SpeakerKit */,
\t\t\t);
\t\t\tname = MacAboboo;
\t\t\tproductName = MacAboboo;
\t\t\tproductReference = {app_product_id} /* MacAboboo.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{proj_id} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1500;
\t\t\t\tLastUpgradeCheck = 1500;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{target_id} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;
\t\t\t\t\t\tProvisioningStyle = Automatic;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {proj_config_list_id} /* Build configuration list for PBXProject "MacAboboo" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = zh_CN;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t\tzh_CN,
\t\t\t);
\t\t\tmainGroup = {main_group_id};
\t\t\tpackageReferences = (
\t\t\t\t{package_reference_id} /* XCRemoteSwiftPackageReference "argmax-oss-swift" */,
\t\t\t);
\t\t\tproductRefGroup = {products_group_id} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{target_id} /* MacAboboo */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t{resources_build_phase_id} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{resources_phase_files_str}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t{sources_build_phase_id} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{sources_phase_files_str}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */

/* Begin XCRemoteSwiftPackageReference section */
\t\t{package_reference_id} /* XCRemoteSwiftPackageReference "argmax-oss-swift" */ = {{
\t\t\tisa = XCRemoteSwiftPackageReference;
\t\t\trepositoryURL = "https://github.com/argmaxinc/argmax-oss-swift.git";
\t\t\trequirement = {{
\t\t\t\tkind = exactVersion;
\t\t\t\tversion = 1.1.0;
\t\t\t}};
\t\t}};
/* End XCRemoteSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
\t\t{speakerkit_product_dependency_id} /* SpeakerKit */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tpackage = {package_reference_id} /* XCRemoteSwiftPackageReference "argmax-oss-swift" */;
\t\t\tproductName = SpeakerKit;
\t\t}};
/* End XCSwiftPackageProductDependency section */

/* Begin XCBuildConfiguration section */
\t\t{debug_config_id} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (
\t\t\t\t\t"DEBUG=1",
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"GL_SILENCE_DEPRECATION=1",
\t\t\t\t);
\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;
\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
\t\t\t\tGCC_WARN_UNDEFINED_VARIABLES = YES;
\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;
\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSDKROOT = macosx;
\t\t\t\tENABLE_DEBUG_DYLIB = YES;
\t\t\t\tENABLE_PREVIEWS = YES;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG GL_SILENCE_DEPRECATION";
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{release_config_id} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_NS_ASSERTIONS = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"GL_SILENCE_DEPRECATION=1",
\t\t\t\t);
\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;
\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
\t\t\t\tGCC_WARN_UNDEFINED_VARIABLES = YES;
\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "GL_SILENCE_DEPRECATION";
\t\t\t\tSWIFT_COMPILATION_MODE = "wholemodule";
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{target_debug_config_id} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 44;
\t\t\t\tENABLE_DEBUG_DYLIB = YES;
\t\t\t\tENABLE_PREVIEWS = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = Sources/MacAbobooApp/Info.plist;
\t\t\t\tHEADER_SEARCH_PATHS = "$(SRCROOT)/Sources/CSpeechRuntime/include";
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0.43;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.samuel.MacAboboo;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t\tSWIFT_OBJC_BRIDGING_HEADER = Sources/CSpeechRuntime/MacAboboo-Bridging-Header.h;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{target_release_config_id} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 44;
\t\t\t\tENABLE_PREVIEWS = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = Sources/MacAbobooApp/Info.plist;
\t\t\t\tHEADER_SEARCH_PATHS = "$(SRCROOT)/Sources/CSpeechRuntime/include";
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0.43;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.samuel.MacAboboo;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_OBJC_BRIDGING_HEADER = Sources/CSpeechRuntime/MacAboboo-Bridging-Header.h;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{proj_config_list_id} /* Build configuration list for PBXProject "MacAboboo" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{debug_config_id} /* Debug */,
\t\t\t\t{release_config_id} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{target_config_list_id} /* Build configuration list for PBXNativeTarget "MacAboboo" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{target_debug_config_id} /* Debug */,
\t\t\t\t{target_release_config_id} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */

\t}};
\trootObject = {proj_id} /* Project object */;
}}
"""

xcodeproj_path = os.path.join(root_dir, 'MacAboboo.xcodeproj')
os.makedirs(xcodeproj_path, exist_ok=True)
pbxproj_path = os.path.join(xcodeproj_path, 'project.pbxproj')

with open(pbxproj_path, 'w', encoding='utf-8') as f:
    f.write(pbxproj_content)

# 生成 Shared Scheme
schemes_dir = os.path.join(xcodeproj_path, 'xcshareddata', 'xcschemes')
os.makedirs(schemes_dir, exist_ok=True)
scheme_content = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
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
               BlueprintIdentifier = "{target_id}"
               BuildableName = "MacAboboo.app"
               BlueprintName = "MacAboboo"
               ReferencedContainer = "container:MacAboboo.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
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
            BlueprintIdentifier = "{target_id}"
            BuildableName = "MacAboboo.app"
            BlueprintName = "MacAboboo"
            ReferencedContainer = "container:MacAboboo.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "MacAboboo.app"
            BlueprintName = "MacAboboo"
            ReferencedContainer = "container:MacAboboo.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
with open(os.path.join(schemes_dir, 'MacAboboo.xcscheme'), 'w', encoding='utf-8') as f:
    f.write(scheme_content)

print(f"🎉 成功生成 Xcode 原生工程：{xcodeproj_path}")
