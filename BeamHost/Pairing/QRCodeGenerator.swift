// QRCodeGenerator.swift
// Generates a QR code NSImage from a string using CoreImage filters.

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum QRCodeGenerator {

    /// Generates a high-resolution QR code image from the given string.
    /// - Parameters:
    ///   - string: The content to encode (e.g., a pairing URL)
    ///   - size: The desired output size in points
    /// - Returns: An NSImage, or nil if generation fails
    static func generate(from string: String, size: CGSize) -> NSImage? {
        guard let data = string.data(using: .utf8) else { return nil }

        // Create CIQRCodeGenerator filter
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")  // High redundancy

        guard let ciImage = filter.outputImage else { return nil }

        // Scale to desired size
        let scaleX = size.width / ciImage.extent.width
        let scaleY = size.height / ciImage.extent.height
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Invert colors for dark mode (white QR on black → black QR on white)
        let invertedImage = scaledImage
            .applyingFilter("CIColorInvert")
            .applyingFilter("CIMaskToAlpha")

        // Convert to NSImage
        let rep = NSCIImageRep(ciImage: invertedImage)
        let nsImage = NSImage(size: size)
        nsImage.addRepresentation(rep)

        return nsImage
    }
}
