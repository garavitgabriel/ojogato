// ojogato-vision — on-device subject recognition for Ojo de Gato.
//
// Answers the one question the pixel detector cannot: is there a SUBJECT in this frame,
// or did the pixels merely change? mpdecimate measures difference, and a webcam whose
// auto-exposure keeps hunting against a bright doorway produces plenty of difference in
// an empty room. This looks for the things the product actually cares about: cats, dogs
// and people.
//
// Apple's Vision framework, so no model download, no network, no API key, no Python.
// VNRecognizeAnimalsRequest ships with macOS and knows exactly Cat and Dog — which is the
// whole subject list here, plus the humans who feed them. Everything stays on the machine,
// which matters for a camera pointed at someone's kitchen.
//
// TILING is load-bearing, not an optimisation. Vision downsamples its input, so a cat
// eight feet down the corridor is a few dozen pixels by the time the recogniser sees it
// and produces no observation at all — not a low score, NO observation, which is why
// lowering --min changes nothing for those frames. Running the same recogniser over
// overlapping upscaled crops makes that cat large in its own tile. Measured on the
// reference camera over one day: full-frame-only recognised 199 animal frames, tiled
// recognised 349, at the same confidence floor and with no new false positives.
// The overlap matters too: a subject straddling a seam is cut in half in both tiles, so
// the grid overlaps ~40% and no seam runs through the food bowls.
//
// Usage:
//   ojogato-vision [--min 0.30] [--tiles 0|2x2|3x2] [--json] <image.jpg> [more.jpg ...]
//   ojogato-vision [--min 0.30] -            # newline-separated paths on stdin
//
// Output (TSV, one line per image, flushed as it goes so a long run is observable and a
// caller can stream it):
//   <path>\t<verdict>\t<score>\t<detail>
// verdict is cat|dog|person|none; detail says where it was found (full, or tile t0..t5).
// A file that cannot be read is "none" with detail=unreadable — an unreadable frame must
// never read as a sighting. Exit status is always 0 so a pipeline cannot be broken by one
// bad JPEG.
//
// Species note: at this resolution Vision's cat/dog split is not reliable — pale
// low-contrast animals (the reference household's ragdolls, white with grey points) read
// as "dog" in a minority of frames. Callers should treat cat and dog as one "pet" class
// and phrase reports from configuration rather than from this label. The raw label is
// still reported here because throwing information away in the sensor is the wrong layer
// to do it in.

import Foundation
import Vision
import CoreImage

var minConfidence: Float = 0.30
var jsonOut = false
var tileMode = "3x2"
var paths: [String] = []
var readStdin = false

let argv = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < argv.count {
    switch argv[i] {
    case "--min":
        i += 1
        if i < argv.count, let v = Float(argv[i]) { minConfidence = v }
    case "--tiles":
        i += 1
        if i < argv.count { tileMode = argv[i] }
    case "--json":
        jsonOut = true
    case "-":
        readStdin = true
    case "-h", "--help":
        print("usage: ojogato-vision [--min 0.30] [--tiles 0|2x2|3x2] [--json] <image.jpg>... | -")
        exit(0)
    default:
        paths.append(argv[i])
    }
    i += 1
}

// Normalised crop rects, overlapping so no subject falls in a seam.
func cropRects(_ mode: String) -> [(String, CGRect)] {
    switch mode {
    case "0", "none":
        return []
    case "2x2":
        return [
            ("t0", CGRect(x: 0.00, y: 0.00, width: 0.60, height: 0.60)),
            ("t1", CGRect(x: 0.40, y: 0.00, width: 0.60, height: 0.60)),
            ("t2", CGRect(x: 0.00, y: 0.40, width: 0.60, height: 0.60)),
            ("t3", CGRect(x: 0.40, y: 0.40, width: 0.60, height: 0.60)),
        ]
    default: // 3x2 — the default; the third column buys the far end of the corridor.
        return [
            ("t0", CGRect(x: 0.00, y: 0.00, width: 0.45, height: 0.60)),
            ("t1", CGRect(x: 0.28, y: 0.00, width: 0.45, height: 0.60)),
            ("t2", CGRect(x: 0.55, y: 0.00, width: 0.45, height: 0.60)),
            ("t3", CGRect(x: 0.00, y: 0.40, width: 0.45, height: 0.60)),
            ("t4", CGRect(x: 0.28, y: 0.40, width: 0.45, height: 0.60)),
            ("t5", CGRect(x: 0.55, y: 0.40, width: 0.45, height: 0.60)),
        ]
    }
}

let tiles = cropRects(tileMode)

// A full-frame hit this confident is not going to be improved on by any tile, so the
// tile pass is skipped. Most real events contain at least one such frame, which is what
// keeps the average cost per frame near a single inference rather than seven.
let shortCircuit: Float = 0.60

struct Result {
    var verdict = "none"
    var score: Float = 0
    var detail = ""
}

// Scans one CIImage and returns the best (label, confidence) found. Animals outrank
// people: a cat is the subject this product exists for, so a confident cat wins even
// when someone is standing at the bowls in the same frame.
func scan(_ img: CIImage) -> (String, Float)? {
    let animalRequest = VNRecognizeAnimalsRequest()
    let humanRequest = VNDetectHumanRectanglesRequest()
    let handler = VNImageRequestHandler(ciImage: img, options: [:])
    do {
        try handler.perform([animalRequest, humanRequest])
    } catch {
        return nil
    }

    var best: (String, Float)? = nil
    for obs in (animalRequest.results ?? []) {
        for label in obs.labels where label.confidence >= minConfidence {
            let name = label.identifier.lowercased()
            if best == nil || label.confidence > best!.1 { best = (name, label.confidence) }
        }
    }
    if let b = best { return b }

    var bestHuman: Float = 0
    for obs in (humanRequest.results ?? []) where obs.confidence >= minConfidence {
        bestHuman = max(bestHuman, obs.confidence)
    }
    if bestHuman > 0 { return ("person", bestHuman) }
    return nil
}

func classify(_ path: String) -> Result {
    var r = Result()
    guard let img = CIImage(contentsOf: URL(fileURLWithPath: path)) else {
        r.detail = "unreadable"
        return r
    }

    if let hit = scan(img) {
        r.verdict = hit.0; r.score = hit.1; r.detail = "full"
        if hit.1 >= shortCircuit { return r }
    }

    let ext = img.extent
    for (name, rect) in tiles {
        let crop = CGRect(x: ext.origin.x + rect.origin.x * ext.width,
                          y: ext.origin.y + rect.origin.y * ext.height,
                          width: rect.width * ext.width,
                          height: rect.height * ext.height)
        // Upscale the crop. Vision downsamples internally, so handing it a small tile at
        // native size throws away the very resolution the tiling exists to preserve.
        let tile = img.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.origin.x, y: -crop.origin.y))
            .transformed(by: CGAffineTransform(scaleX: 2.0, y: 2.0))
        if let hit = scan(tile), hit.1 > r.score {
            r.verdict = hit.0; r.score = hit.1; r.detail = name
        }
    }
    return r
}

if readStdin {
    while let line = readLine(strippingNewline: true) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { paths.append(t) }
    }
}

for p in paths {
    let r = classify(p)
    let score = String(format: "%.3f", r.score)
    if jsonOut {
        print("{\"path\":\"\(p)\",\"verdict\":\"\(r.verdict)\",\"score\":\(score),\"detail\":\"\(r.detail)\"}")
    } else {
        print("\(p)\t\(r.verdict)\t\(score)\t\(r.detail)")
    }
    // Flushed per line: a 1600-frame backfill is otherwise invisible until it finishes,
    // and vision-run.sh reads this incrementally.
    fflush(stdout)
}
