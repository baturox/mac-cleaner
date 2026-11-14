// Downloaded AI models: Hugging Face, Ollama, LM Studio, PyTorch, Whisper, Keras, NLTK, Stable Diffusion UIs.
import Foundation

enum ModelsScanner {
    static func scan(_ ctx: ScanContext) async -> [CleanCategory] {
        ctx.progress("Measuring AI models…")
        async let hf = huggingFace(ctx)
        async let ol = ollama(ctx)
        async let lm = lmStudio(ctx)
        async let other = misc(ctx)
        return await ([hf, ol, lm].compactMap { $0 }) + other
    }

    private static func make(_ ctx: ScanContext, id: String, name: String, detail: String, items: [CleanItem]) -> CleanCategory? {
        ctx.category(id: id, name: name, detail: detail, level: .caution, symbol: "brain", group: .models,
                     items: items, selectable: true)
    }

    // MARK: Hugging Face

    /// "models--meta-llama--Llama-3.1-8B" -> "meta-llama/Llama-3.1-8B"; datasets get a suffix.
    static func huggingFaceLabel(_ dirName: String) -> String? {
        let kinds = [("models--", ""), ("datasets--", " (dataset)"), ("spaces--", " (space)")]
        for (prefix, suffix) in kinds where dirName.hasPrefix(prefix) {
            let rest = String(dirName.dropFirst(prefix.count))
            guard !rest.isEmpty else { return nil }
            if let r = rest.range(of: "--") {
                return rest[rest.startIndex..<r.lowerBound] + "/" + rest[r.upperBound...] + suffix
            }
            return rest + suffix
        }
        return nil
    }

    static func huggingFaceHub(_ env: EngineEnvironment) -> String {
        if let hub = env.variable("HF_HUB_CACHE") ?? env.variable("HUGGINGFACE_HUB_CACHE") { return env.expand(hub) }
        let home = env.variable("HF_HOME").map(env.expand) ?? env.home + "/.cache/huggingface"
        return home + "/hub"
    }

    private static func huggingFace(_ ctx: ScanContext) async -> CleanCategory? {
        let hub = huggingFaceHub(ctx.env)
        var paths: [String] = [], labels: [String: String] = [:], dates: [String: Date] = [:]
        for e in readDir(hub) ?? [] where e.isDir && !e.isLink {
            guard let label = huggingFaceLabel(e.name) else { continue }
            let p = hub + "/" + e.name
            paths.append(p); labels[p] = label
            dates[p] = modificationDate(p + "/snapshots") ?? modificationDate(p)
        }
        let xet = (ctx.env.variable("HF_HOME").map(ctx.env.expand) ?? ctx.home + "/.cache/huggingface") + "/xet"
        if ctx.env.isDirectory(xet) { paths.append(xet); labels[xet] = "Xet download cache" }
        return make(ctx, id: "hf-models", name: "Hugging Face models & datasets",
                    detail: "Large files downloaded by transformers/diffusers; downloaded again when a script needs them",
                    items: await ctx.items(paths, labels: labels, dates: dates))
    }

    // MARK: Ollama

    struct OllamaModel: Equatable { var label: String; var manifest: String; var bytes: Int64 }

    /// One model per manifest file under `<base>/manifests/<host>/<namespace>/<name>/<tag>`.
    /// Size is the sum of the config and layer blobs the manifest references that exist on disk.
    static func ollamaModels(base: String) -> [OllamaModel] {
        let root = base + "/manifests"
        var out: [OllamaModel] = []
        func walk(_ dir: String, _ parts: [String]) {
            for e in readDir(dir) ?? [] {
                if e.isLink { continue }
                if e.isDir { walk(dir + "/" + e.name, parts + [e.name]); continue }
                guard parts.count >= 3, let data = FileManager.default.contents(atPath: dir + "/" + e.name),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                var digests: [String: Int64] = [:]
                var blobs = obj["layers"] as? [[String: Any]] ?? []
                if let cfg = obj["config"] as? [String: Any] { blobs.append(cfg) }
                for b in blobs {
                    guard let digest = b["digest"] as? String else { continue }
                    let file = base + "/blobs/" + digest.replacingOccurrences(of: ":", with: "-")
                    var st = stat()
                    if lstat(file, &st) == 0 { digests[digest] = Int64(st.st_blocks) * 512 }
                }
                // parts = [host, namespace, name…]
                let host = parts[0], namespace = parts[1], name = parts[2...].joined(separator: "/")
                var label = name
                if host != "registry.ollama.ai" { label = host + "/" + namespace + "/" + name }
                else if namespace != "library" { label = namespace + "/" + name }
                out.append(OllamaModel(label: label + ":" + e.name, manifest: dir + "/" + e.name,
                                       bytes: digests.values.reduce(0, +)))
            }
        }
        walk(root, [])
        return out.sorted { $0.bytes > $1.bytes }
    }

    private static func ollama(_ ctx: ScanContext) async -> CleanCategory? {
        let base = ctx.env.variable("OLLAMA_MODELS").map(ctx.env.expand) ?? ctx.home + "/.ollama/models"
        guard ctx.env.isDirectory(base) else { return nil }
        let detail = "Language models pulled with Ollama; pull them again when needed. Models sharing layers free less than shown"
        if ToolPaths.which("ollama") == nil {
            let items = await ctx.items([base], labels: [base: "Ollama models (ollama is not installed)"])
            return make(ctx, id: "ollama-models", name: "Ollama models", detail: detail, items: items)
        }
        let models = await onBackground { ollamaModels(base: base) }
        var items: [CleanItem] = []
        for m in models where m.bytes > 0 && ctx.visible(m.manifest) {
            items.append(CleanItem(url: URL(fileURLWithPath: m.manifest), sizeBytes: m.bytes, label: m.label,
                                   lastUsed: modificationDate(m.manifest), deleteCommand: ["ollama", "rm", m.label]))
        }
        return make(ctx, id: "ollama-models", name: "Ollama models", detail: detail, items: items)
    }

    // MARK: LM Studio

    private static func lmStudio(_ ctx: ScanContext) async -> CleanCategory? {
        var paths: [String] = [], labels: [String: String] = [:]
        for base in ["/.lmstudio/models", "/.cache/lm-studio/models"].map({ ctx.home + $0 }) {
            for publisher in readDir(base) ?? [] where publisher.isDir && !publisher.isLink && !publisher.name.hasPrefix(".") {
                for model in readDir(base + "/" + publisher.name) ?? [] where !model.name.hasPrefix(".") {
                    let p = base + "/" + publisher.name + "/" + model.name
                    paths.append(p); labels[p] = publisher.name + "/" + model.name
                }
            }
        }
        return make(ctx, id: "lmstudio-models", name: "LM Studio models",
                    detail: "Model files downloaded in LM Studio; download them again from its catalog",
                    items: await ctx.items(paths, labels: labels))
    }

    // MARK: The rest

    private static func misc(_ ctx: ScanContext) async -> [CleanCategory] {
        let h = ctx.home
        var torchPaths: [String] = [], torchLabels: [String: String] = [:]
        let torch = h + "/.cache/torch"
        for e in readDir(torch) ?? [] where !e.name.hasPrefix(".") {
            let p = torch + "/" + e.name
            if e.name == "hub" {
                for sub in readDir(p) ?? [] where !sub.name.hasPrefix(".") {
                    let hp = p + "/" + sub.name
                    if sub.name == "checkpoints" {
                        for c in readDir(hp) ?? [] { torchPaths.append(hp + "/" + c.name); torchLabels[hp + "/" + c.name] = "PyTorch · " + c.name }
                    } else { torchPaths.append(hp); torchLabels[hp] = "PyTorch hub · " + sub.name }
                }
            } else { torchPaths.append(p); torchLabels[p] = "PyTorch · " + e.name }
        }
        func listing(_ dir: String, prefix: String, files: Bool = true) -> ([String], [String: String]) {
            var paths: [String] = [], labels: [String: String] = [:]
            for e in readDir(dir) ?? [] where !e.name.hasPrefix(".") && (files || e.isDir) {
                paths.append(dir + "/" + e.name); labels[dir + "/" + e.name] = prefix + e.name
            }
            return (paths, labels)
        }
        let whisper = listing(h + "/.cache/whisper", prefix: "Whisper · ")
        var keras = listing(h + "/.keras/models", prefix: "Keras model · ")
        let kd = listing(h + "/.keras/datasets", prefix: "Keras dataset · ")
        keras.0 += kd.0; keras.1.merge(kd.1) { a, _ in a }
        let nltk = listing(h + "/nltk_data", prefix: "NLTK · ", files: false)
        var sd: ([String], [String: String]) = ([], [:])
        for (dir, marker, label) in [("ComfyUI", "main.py", "ComfyUI"), ("comfyui", "main.py", "ComfyUI"),
                                     ("stable-diffusion-webui", "webui.py", "Stable Diffusion WebUI")] {
            let root = h + "/" + dir
            guard ctx.env.exists(root + "/" + marker) else { continue }
            for kind in readDir(root + "/models") ?? [] where kind.isDir && !kind.isLink {
                for f in readDir(root + "/models/" + kind.name) ?? [] where !f.isDir && !f.name.hasPrefix(".") {
                    let p = root + "/models/" + kind.name + "/" + f.name
                    var st = stat()
                    if lstat(p, &st) == 0, Int64(st.st_blocks) * 512 >= 100 * oneMB {
                        sd.0.append(p); sd.1[p] = "\(label) · \(kind.name)/\(f.name)"
                    }
                }
            }
        }
        let (tp, tl, kerasList, sdList) = (torchPaths, torchLabels, keras, sd)
        async let t = ctx.items(tp, labels: tl)
        async let w = ctx.items(whisper.0, labels: whisper.1)
        async let k = ctx.items(kerasList.0, labels: kerasList.1)
        async let n = ctx.items(nltk.0, labels: nltk.1)
        async let s = ctx.items(sdList.0, labels: sdList.1)
        let (ti, wi, ki, ni, si) = await (t, w, k, n, s)
        return [
            make(ctx, id: "torch-models", name: "PyTorch hub & checkpoints", detail: "Pretrained weights cached by torch.hub; downloaded again on next use", items: ti),
            make(ctx, id: "whisper-models", name: "Whisper models", detail: "Speech models cached by openai-whisper; downloaded again on next use", items: wi),
            make(ctx, id: "keras-models", name: "Keras models & datasets", detail: "Pretrained weights and datasets cached by Keras; downloaded again on next use", items: ki),
            make(ctx, id: "nltk-data", name: "NLTK data", detail: "Corpora and models fetched with nltk.download()", items: ni),
            make(ctx, id: "sd-models", name: "Stable Diffusion model files", detail: "Checkpoints, LoRAs and VAEs of ComfyUI / WebUI; some may be files you trained yourself", items: si),
        ].compactMap { $0 }
    }
}
