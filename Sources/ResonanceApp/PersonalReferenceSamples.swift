import Foundation
import ResonanceCore

extension AppModel {
    /// These are two separately chosen examples, not an averaged or universal target.
    /// Existing choices (including an explicit opt-out) survive app launches.
    func loadPersonalReferenceSamples() throws {
        guard let database else { return }
        let samples: [(resource: String, name: String, source: String, note: String)] = [
            ("Sennheiser_HE1_HuiHiFi", "Sennheiser HE1 · 毁HiFi",
             "https://huihifi.com/evaluation/16a081dd-0c20-4ef2-9918-f2f9fa5554d2",
             "HE1，大奥菲斯二代，开放式头戴；用户已确认此型号为喜欢的声音。"),
            ("MA_Audio_Alter_Ego_No_Dot_HuiHiFi", "MA Audio ALTER EGO（无点档位）· 毁HiFi",
             "https://huihifi.com/evaluation/ea9f19d1-89bb-4cc8-8267-5bb92f6a6b63",
             "入耳式，无点档位；独立保留此版本，不与有点档位或 HE1 混合。")
        ]
        for sample in samples {
            if let index = curves.firstIndex(where: { $0.source == sample.source && $0.isReference }) {
                if curves[index].isPreferred == nil {
                    var existing = curves[index]
                    existing.isPreferred = true
                    try database.save(existing, kind: "curves", id: existing.id.uuidString)
                    curves[index] = existing
                }
                continue
            }
            let url: URL?
            if Bundle.main.bundleURL.pathExtension == "app" {
                url = Bundle.main.resourceURL?.appendingPathComponent("Resonance_ResonanceApp.bundle/Resources/\(sample.resource).csv")
            } else {
                url = Bundle.module.url(forResource: sample.resource, withExtension: "csv", subdirectory: "Resources")
            }
            guard let url else { throw StoreError.database("找不到内置偏好曲线：\(sample.name)") }
            let parsed = try CurveImporter().load(from: url, name: sample.name,
                source: sample.source, measurementSystem: "毁HiFi（该产品页未注明具体夹具）", isReference: true)
            var item = LibraryCurve(id: parsed.id, name: parsed.name,
                frequencies: parsed.points.map(\.frequencyHz), levels: parsed.points.map(\.decibels),
                source: sample.source, measurementSystem: parsed.measurementSystem,
                validMin: parsed.validMinHz, validMax: parsed.validMaxHz, isReference: true,
                notes: "\(sample.note) 2026-09-26 从公开频响图表采集 957 个数值点，20–19896.97461 Hz；不是本项目自行测量。产品页未注明具体夹具、补偿和声道；网站白皮书仅称主要基于 GRAS 5010 人耳模型。20 kHz 以上无数据。")
            item.isPreferred = true
            try database.save(item, kind: "curves", id: item.id.uuidString)
            curves.append(item)
        }
    }
}
