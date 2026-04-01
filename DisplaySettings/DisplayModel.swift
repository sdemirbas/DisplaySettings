import Foundation
import CoreGraphics

struct DisplayModel: Identifiable, Equatable {
    let id: CGDirectDisplayID
    var name: String
    var brightness: Double   // 0–100
    var contrast: Double     // 0–100
    var maxBrightness: Double
    var maxContrast: Double
    var volume: Double        // 0–100, -1 if not supported
    var maxVolume: Double
    var inputSource: Int      // DDC VCP 0x60 value, -1 if unknown
    var colorTemp: Double     // 0–100 mapped from VCP 0xB2, -1 if not supported
    var gainR: Double         // 0–100 from VCP 0x16, -1 if not supported
    var gainG: Double         // 0–100 from VCP 0x18, -1 if not supported
    var gainB: Double         // 0–100 from VCP 0x1A, -1 if not supported
    var resolution: String    // e.g. "2560×1440"
    var ddcSupported: Bool
    var usesSoftwareBrightness: Bool  // true when DDC unavailable; brightness controlled via CoreDisplay/gamma
    var isLoading: Bool

    init(
        id: CGDirectDisplayID,
        name: String,
        brightness: Double = 50,
        contrast: Double = 50,
        maxBrightness: Double = 100,
        maxContrast: Double = 100,
        volume: Double = -1,
        maxVolume: Double = 100,
        inputSource: Int = -1,
        colorTemp: Double = -1,
        gainR: Double = -1,
        gainG: Double = -1,
        gainB: Double = -1,
        resolution: String = "",
        ddcSupported: Bool = true,
        usesSoftwareBrightness: Bool = false,
        isLoading: Bool = false
    ) {
        self.id = id
        self.name = name
        self.brightness = brightness
        self.contrast = contrast
        self.maxBrightness = maxBrightness
        self.maxContrast = maxContrast
        self.volume = volume
        self.maxVolume = maxVolume
        self.inputSource = inputSource
        self.colorTemp = colorTemp
        self.gainR = gainR
        self.gainG = gainG
        self.gainB = gainB
        self.resolution = resolution
        self.ddcSupported = ddcSupported
        self.usesSoftwareBrightness = usesSoftwareBrightness
        self.isLoading = isLoading
    }
}
