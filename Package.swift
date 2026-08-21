// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "c-compiler",
    targets: [
        .target(name: "CCommon", dependencies: []),
        .target(name: "CPreproc", dependencies: ["CCommon"]),
        .target(name: "CParser", dependencies: ["CCommon", "CPreproc"]),
        .target(name: "CSema", dependencies: ["CCommon", "CParser"]),
        .target(name: "CCodegen", dependencies: ["CCommon", "CSema"]),
        .target(name: "CDriver", dependencies: ["CCommon", "CPreproc", "CParser", "CSema", "CCodegen"]),
        .testTarget(name: "CCompilerTests", dependencies: ["CCommon", "CPreproc", "CParser", "CSema", "CCodegen", "CDriver"]),
    ]
)
