"""Dependency-free, deterministic Xcode project generation (Python 3.9+)."""
from pathlib import Path
import hashlib
import sys

ROOT = Path(__file__).resolve().parents[1]


def identifier(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def project_text():
    lines = ['// !$*UTF8*$!', '{', '\tarchiveVersion = 1;', '\tclasses = {};',
             '\tobjectVersion = 56;', '\tobjects = {']

    def obj(name, fields):
        lines.append(f'\t\t{identifier(name)} = {{ {fields} }};')

    sources = sorted((ROOT / 'QuietCamera').glob('*.swift'))
    for source in sources:
        name = source.name
        obj('file:' + name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "QuietCamera/{name}"; sourceTree = "<group>";')
        obj('build:' + name, f'isa = PBXBuildFile; fileRef = {identifier("file:" + name)};')
    obj('app', 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = QuietCamera.app; sourceTree = BUILT_PRODUCTS_DIR;')
    refs = ', '.join(identifier('file:' + s.name) for s in sources)
    obj('root', f'isa = PBXGroup; children = ({refs}, {identifier("products")},); sourceTree = "<group>";')
    obj('products', f'isa = PBXGroup; children = ({identifier("app")},); name = Products; sourceTree = "<group>";')
    builds = ', '.join(identifier('build:' + s.name) for s in sources)
    obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({builds},); runOnlyForDeploymentPostprocessing = 0;')
    obj('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    obj('resources', 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    for configuration in ['Debug', 'Release']:
        project_settings = '''CLANG_ENABLE_MODULES = YES; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 18.0;
            SWIFT_VERSION = 5.0; SWIFT_STRICT_CONCURRENCY = minimal; ENABLE_USER_SCRIPT_SANDBOXING = YES;
            CLANG_ENABLE_OBJC_ARC = YES; GCC_C_LANGUAGE_STANDARD = gnu17;'''
        project_settings += ' SWIFT_OPTIMIZATION_LEVEL = "-Onone"; DEBUG_INFORMATION_FORMAT = dwarf;' if configuration == 'Debug' else ' SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";'
        obj('project:' + configuration, f'isa = XCBuildConfiguration; buildSettings = {{ {project_settings} }}; name = {configuration};')
        target_settings = '''PRODUCT_BUNDLE_IDENTIFIER = com.sanarurung.QuietCamera; PRODUCT_NAME = "$(TARGET_NAME)";
            INFOPLIST_FILE = QuietCamera/Info.plist; GENERATE_INFOPLIST_FILE = NO; TARGETED_DEVICE_FAMILY = 1;
            SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; SUPPORTS_MACCATALYST = NO;
            CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = "";
            LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";
            LOCALIZATION_PREFERS_STRING_CATALOGS = YES;'''
        obj('target:' + configuration, f'isa = XCBuildConfiguration; buildSettings = {{ {target_settings} }}; name = {configuration};')
    for kind in ['project', 'target']:
        configs = ', '.join(identifier(kind + ':' + c) for c in ['Debug', 'Release'])
        obj(kind + ':configs', f'isa = XCConfigurationList; buildConfigurations = ({configs},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    phases = ', '.join(identifier(p) for p in ['sources', 'frameworks', 'resources'])
    obj('target', f'isa = PBXNativeTarget; buildConfigurationList = {identifier("target:configs")}; buildPhases = ({phases},); buildRules = (); dependencies = (); name = QuietCamera; productName = QuietCamera; productReference = {identifier("app")}; productType = "com.apple.product-type.application";')
    obj('project', f'''isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; }};
        buildConfigurationList = {identifier("project:configs")}; compatibilityVersion = "Xcode 14.0";
        developmentRegion = ko; hasScannedForEncodings = 0; knownRegions = (ko, en, Base,);
        mainGroup = {identifier("root")}; productRefGroup = {identifier("products")};
        projectDirPath = ""; projectRoot = ""; targets = ({identifier("target")},);''')
    lines += ['\t};', f'\trootObject = {identifier("project")};', '}']
    return '\n'.join(lines) + '\n'


def scheme_text():
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier('target')}" BuildableName="QuietCamera.app" BlueprintName="QuietCamera" ReferencedContainer="container:QuietCamera.xcodeproj"/>
    </BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier('target')}" BuildableName="QuietCamera.app" BlueprintName="QuietCamera" ReferencedContainer="container:QuietCamera.xcodeproj"/></BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''


def main():
    generated = {
        ROOT / 'QuietCamera.xcodeproj/project.pbxproj': project_text(),
        ROOT / 'QuietCamera.xcodeproj/xcshareddata/xcschemes/QuietCamera.xcscheme': scheme_text(),
    }
    check = '--check' in sys.argv
    for path, content in generated.items():
        if check:
            if not path.exists() or path.read_text(encoding='utf-8') != content:
                raise SystemExit(f'Out of date: {path.relative_to(ROOT)}')
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding='utf-8', newline='\n')
    print('Xcode project verified' if check else 'Xcode project generated')


if __name__ == '__main__':
    main()
