import AppKit

@main
enum MakeIcon {
    static func main() throws {
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for (name, size) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
            try DashboardBrand.bitmap(pixels: size).representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name + ".png"))
        }
    }
}
