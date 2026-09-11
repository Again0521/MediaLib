#!/usr/bin/env swift
import Foundation

guard CommandLine.arguments.count == 12 else {
    FileHandle.standardError.write(Data("usage: generate_build_manifest.swift <output> <version> <build> <commit> <dirty> <architecture> <toolchain> <libmpv> <ffmpeg> <ffprobe> <dependency-digest>\n".utf8))
    exit(2)
}

let values = Array(CommandLine.arguments.dropFirst())
let manifest: [String: Any] = [
    "schemaVersion": 1,
    "productVersion": values[1],
    "buildNumber": values[2],
    "commit": values[3],
    "dirty": values[4] == "true",
    "architecture": values[5],
    "toolchain": values[6],
    "mediaRuntimeVersions": [
        "libmpv": values[7],
        "ffmpeg": values[8],
        "ffprobe": values[9],
    ],
    "dependencyDigest": values[10],
]

let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
var terminated = data
terminated.append(0x0A)
try terminated.write(to: URL(fileURLWithPath: values[0]), options: .atomic)
