// Makes a short h.265 clip out of one still image, as the simulated glasses'
// camera feed. Meta's Mock Device Kit only plays h.265 video.
// `scripts/simulate.sh` runs this once and keeps the clip in build/.
//
//     swift make_clip.swift face.jpg clip.mov

import AVFoundation
import CoreImage
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: swift make_clip.swift <image> <output.mov>")
    exit(1)
}
let source = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
try? FileManager.default.removeItem(at: output)

let width = 540, height = 960, fps: Int32 = 15, seconds = 8

guard let image = CIImage(contentsOf: source) else {
    print("could not read \(source.path)")
    exit(1)
}
// Fit the image inside the frame, centred on black.
let scale = min(CGFloat(width) / image.extent.width, CGFloat(height) / image.extent.height)
let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
let placed = scaled.transformed(
    by: CGAffineTransform(
        translationX: (CGFloat(width) - scaled.extent.width) / 2 - scaled.extent.minX,
        y: (CGFloat(height) - scaled.extent.height) / 2 - scaled.extent.minY
    )
)
let frame = placed.composited(
    over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
)

let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ]
)
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ]
)
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let context = CIContext()
for index in 0..<(Int(fps) * seconds) {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    context.render(frame, to: buffer!)
    adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else {
    print("failed: \(String(describing: writer.error))")
    exit(1)
}
print("wrote \(output.path)")
