import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fputs("usage: make_icon input.png output.png\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("cannot read input image\n", stderr)
    exit(1)
}

let width = image.width
let height = image.height
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("cannot create bitmap context\n", stderr)
    exit(1)
}

context.clear(CGRect(x: 0, y: 0, width: width, height: height))
context.saveGState()

// The source is a square icon rendered on a black canvas. Clip the outside
// corners while keeping the dark navy artwork inside the rounded rectangle.
let margin: CGFloat = CGFloat(width) * 0.012
let iconRect = CGRect(
    x: margin,
    y: margin,
    width: CGFloat(width) - margin * 2,
    height: CGFloat(height) - margin * 2
)
let radius = CGFloat(width) * 0.115
context.addPath(CGPath(
    roundedRect: iconRect,
    cornerWidth: radius,
    cornerHeight: radius,
    transform: nil
))
context.clip()

context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
context.restoreGState()

guard let outputImage = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
          outputURL as CFURL,
          UTType.png.identifier as CFString,
          1,
          nil
      ) else {
    fputs("cannot create output PNG\n", stderr)
    exit(1)
}

CGImageDestinationAddImage(destination, outputImage, nil)
if !CGImageDestinationFinalize(destination) {
    fputs("failed to write output PNG\n", stderr)
    exit(1)
}
