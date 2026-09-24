import Foundation
import ResonanceCore

extension AppModel {
    func loadRaphaelSample() {
        guard let database else { return }
        do {
            let source = "https://hbb.squig.link/data/Artipical%20Raphael%20R.txt"
            var reference = curves.first { $0.source == "builtin:flat-reference" }
            if reference == nil {
                let flat = LibraryCurve(name: "平直参考（计算基线）", frequencies: [20, 20_000], levels: [0, 0],
                    source: "builtin:flat-reference", measurementSystem: "", validMin: 20, validMax: 20_000,
                    isReference: true, notes: "全频 0 dB，方便观察频响起伏；可更换为你偏好的目标曲线。")
                try database.save(flat, kind: "curves", id: flat.id.uuidString)
                curves.append(flat)
                reference = flat
            }
            var measured = curves.first { $0.source == source && !$0.isReference }
            if measured == nil {
                let bundledURL: URL?
                if Bundle.main.bundleURL.pathExtension == "app" {
                    bundledURL = Bundle.main.resourceURL?.appendingPathComponent("Resonance_ResonanceApp.bundle/Resources/Artipical_Raphael_HBB_R.csv")
                } else {
                    bundledURL = Bundle.module.url(forResource: "Artipical_Raphael_HBB_R", withExtension: "csv", subdirectory: "Resources")
                }
                guard let bundledURL else { throw StoreError.database("找不到拉斐尔示例文件") }
                let parsed = try CurveImporter().load(from: bundledURL, name: "Artipical Raphael · HBB 右声道", source: source, measurementSystem: "unknown")
                let curve = LibraryCurve(id: parsed.id, name: parsed.name, frequencies: parsed.points.map(\.frequencyHz), levels: parsed.points.map(\.decibels),
                    source: source, measurementSystem: "unknown", validMin: parsed.validMinHz, validMax: parsed.validMaxHz,
                    isReference: false, notes: "HBB 公开实测，480 点、19.5 Hz–20 kHz。测量设备未注明；20 kHz 以上暂无数据。")
                try database.save(curve, kind: "curves", id: curve.id.uuidString)
                curves.append(curve)
                measured = curve
            }
            guard let measured, let reference else { return }
            var headphone = headphones.first { $0.curveID == measured.id }
                ?? HeadphoneEntry(name: "拉斐尔 · HBB", curveID: measured.id, owned: true)
            // Reopening the sample keeps a reference the user already selected.
            if headphone.referenceID == nil { headphone.referenceID = reference.id }
            headphone.owned = true
            try database.save(headphone, kind: "headphones", id: headphone.id.uuidString)
            if let index = headphones.firstIndex(where: { $0.id == headphone.id }) { headphones[index] = headphone }
            else { headphones.append(headphone) }
            selectedHeadphoneID = headphone.id
            if selectedTrackID == nil { selectedTrackID = tracks.first(where: \.analyzed)?.id }
            showLibrary = false
            showBrowser = false
            status = "拉斐尔已就绪 · 参考可在资料库更换"
            recompute()
        } catch { report(error) }
    }
}
