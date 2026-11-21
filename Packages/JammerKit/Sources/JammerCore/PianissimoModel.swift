import Foundation

/// The two Core ML builds of Klang Pianissimo, pinned to published Hugging Face file checksums.
public enum PianissimoModel: String, CaseIterable, Sendable {
    case swedish = "sv"
    case danish = "da"

    public var id: String { "pianissimo-\(rawValue)" }
    public var sourceDirectory: String { self == .swedish ? "compiled/1.1.0" : "" }
    public var manifest: ModelManifest { self == .swedish ? Self.swedishManifest : Self.danishManifest }
    public var downloadBytes: Int64 { manifest.entries.values.reduce(0) { $0 + $1.size } }

    static let swedishManifest = ModelManifest(repo: "markstrom/pianissimo-sv-coreml",
        commit: "dd578628d1ae6577b4672221b99fff59112ff5b4", lines: [
        "Decoder.mlmodelc/analytics/coremldata.bin|243|sha256:f172c15a50f309f5bd296bdde67465c751e04d3341f578870ae415c334ac04d2",
        "Decoder.mlmodelc/coremldata.bin|693|sha256:2192e1baeac694eddedd142a2cfa43f421e60961c6c58fcd2ee32defc7926e49",
        "Decoder.mlmodelc/metadata.json|3599|blob:c9f42d0e7117f052548a0297626f50f54b7f84ea",
        "Decoder.mlmodelc/model.mil|13110|blob:1177d26b92ef8aa5b442604ee7ba03553ce1ca96",
        "Decoder.mlmodelc/weights/weight.bin|23604992|sha256:9e34a5cc5da3477cf0e49126f55d4754a6a332b5df52a22812d6ddbd84af0e39",
        "Encoder.mlmodelc/analytics/coremldata.bin|243|sha256:d2f394285367a7a1db5d563072cd06b998a493e9fd1d3b2ee85cfbb45cd35855",
        "Encoder.mlmodelc/coremldata.bin|681|sha256:4b815f51d37de350d752ff32ea619352038dc8f3d931d885c14d84199beeb4c1",
        "Encoder.mlmodelc/metadata.json|3146|blob:0db8c4e64115a79a2af8fc09448c9d649440d3eb",
        "Encoder.mlmodelc/model.mil|991866|blob:12ce117751234a1bdcf027ca80d4d9a258949bc3",
        "Encoder.mlmodelc/weights/weight.bin|649181632|sha256:e9623b969e8f31ba12bfbec7cdcdacb3bfb74e5a3a9bd3a812e4a942c1b1b9ed",
        "JointDecisionv3.mlmodelc/analytics/coremldata.bin|243|sha256:a3d3094441bfc2b7006dd25144269ea59ff1d54403b7801f24a4d3028c6ec617",
        "JointDecisionv3.mlmodelc/coremldata.bin|740|sha256:74843f3c1b075b1fbb017b04e21f05a9cfb3578ca474eb605877fdefc73dd02c",
        "JointDecisionv3.mlmodelc/metadata.json|3758|blob:4399b8e38acbbef113003c02a6bcd95ffea6bfe5",
        "JointDecisionv3.mlmodelc/model.mil|11777|blob:322a3748e073a27aefd42984cfa25e26bb52b63f",
        "JointDecisionv3.mlmodelc/weights/weight.bin|12642764|sha256:1f841daf3a6ce483ac136cd7a5e48d6071543e7c5eddcbba4525bda74695cb61",
        "Preprocessor.mlmodelc/analytics/coremldata.bin|243|sha256:791541080e887157342fb733e8d5c56ef5bf317ce62f3f21650c7157e7f38256",
        "Preprocessor.mlmodelc/coremldata.bin|633|sha256:8f314d8ab7016a8e1d2c3649b43fbacaa75e984adf89306a23c2628fbfee5d6a",
        "Preprocessor.mlmodelc/metadata.json|2992|blob:32ed9bb3eecebece8abcc96e97bd4c6677f1d6ce",
        "Preprocessor.mlmodelc/model.mil|24852|blob:da71d340fc865e77f993ea92add9c4e869327080",
        "Preprocessor.mlmodelc/weights/weight.bin|1953088|sha256:c69139820fc62c199f92c83d2c97458f8aaff337e5026abd9606ff03ba52b8e1",
        "parakeet_vocab.json|151122|blob:c684822ec3b671ebc449c433a7012398d39b8bb0",
    ])

    static let danishManifest = ModelManifest(repo: "KlangAI/pianissimo-da-coreml",
        commit: "9e6213c13d3a91b87f8e4a2310ac77bec45e54ef", lines: [
        "Decoder.mlmodelc/analytics/coremldata.bin|243|sha256:7bba8f05f6cbd328b5a2d853a7ec552a0538e5e1b614c5755d84b4a0a14d1fad",
        "Decoder.mlmodelc/coremldata.bin|560|sha256:5f5d73300252cf66a6a229017f7392133f9a91220f401f279e361d63ab9799a9",
        "Decoder.mlmodelc/model.mil|13116|blob:aecd44ac75f305332fa6d1caed9fa2369db4e22d",
        "Decoder.mlmodelc/weights/weight.bin|23604992|sha256:1cd3cef64f2e7d4777dff911e319c53a3c290dc66920bdd0981c1a0e3b7f399a",
        "Encoder.mlmodelc/analytics/coremldata.bin|243|sha256:34c1ab900ad3d7631422d7f1be892b768c23db93e39eef95ab824f6dd8ca2efd",
        "Encoder.mlmodelc/coremldata.bin|484|sha256:8cbaf7da3433a93afb44130c18a36825d9668a706897df38aea58abfb34d98b2",
        "Encoder.mlmodelc/model.mil|960233|blob:d381af633a0cb4255a425c602f53cbfff5bc38fb",
        "Encoder.mlmodelc/weights/weight.bin|593445952|sha256:01b7c312d3279119cac5c651dbb8181231e173da44b6046dafd7c9b1eaa58e0a",
        "JointDecisionv3.mlmodelc/analytics/coremldata.bin|243|sha256:2fe2c04a97cf60d66487ebf243c06f387ec92893775af5faa81ea5d9f9725445",
        "JointDecisionv3.mlmodelc/coremldata.bin|597|sha256:399ff3c28224538afbbb116fefdae7aa8f38188eb2e55c6db95e685d9d058e4a",
        "JointDecisionv3.mlmodelc/model.mil|11783|blob:ce097bfe6e6034b9b744b168af6ff2cb0961785b",
        "JointDecisionv3.mlmodelc/weights/weight.bin|12642764|sha256:18d70720039884a14639f5543b7e355a9c2ba97b59408de3a51326d0eaf1ddd8",
        "Preprocessor.mlmodelc/analytics/coremldata.bin|243|sha256:c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d",
        "Preprocessor.mlmodelc/coremldata.bin|486|sha256:dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d",
        "Preprocessor.mlmodelc/metadata.json|2841|blob:06162c58cf2f5343a0e60f36f843bcdf3cc58527",
        "Preprocessor.mlmodelc/model.mil|28181|blob:f987e2479228436c49189aa47edb376db74dcff5",
        "Preprocessor.mlmodelc/weights/weight.bin|491072|sha256:129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea",
        "parakeet_vocab.json|151122|blob:c684822ec3b671ebc449c433a7012398d39b8bb0",
    ])
}
