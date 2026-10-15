# Riset: Inferensi Model HuggingFace PyTorch (.bin/.safetensors) Langsung di Swift + macOS Apple Silicon — Tanpa WhisperKit CoreML

**Tanggal:** Oktober 2026
**Konteks:** Kanso Dictate (push-to-talk dictation, macOS Apple Silicon), lih. `docs/research/whisperkit-integration.md`
**Pertanyaan:** Bisakah model seperti `cahya/whisper-tiny-id` dijalankan langsung di Swift tanpa konversi ke format WhisperKit CoreML? Framework/repo apa yang mempercepatnya? Apakah WhisperKit tetap pilihan tercepat?

**Jawaban singkat:** Inferensi *byte-identical tanpa konversi format apa pun* tidak praktis — tidak ada runtime Swift yang mengeksekusi `state_dict` PyTorch secara langsung. Semua jalur realistis membutuhkan **satu kali ekspor format** (ggml, `.pte`, `.onnx`, atau `.mlpackage`), tetapi ekspor tersebut **tidak harus ke format WhisperKit**. Jalur non-WhisperKit yang paling matang adalah **whisper.cpp (ggml) + Swift via XCFramework**, dengan opsi resmi kedua **ExecuTorch (`.pte`) + Swift**. Untuk latensi push-to-talk terendah, **WhisperKit tetap verdict tercepat**, dan model kustom seperti `cahya/whisper-tiny-id` *dapat* dikonversi ke format WhisperKit memakai tool resmi `whisperkit-generate-model` — jadi "model Indonesia kustom" bukan alasan meninggalkan WhisperKit.

---

## 1. Anatomi model `cahya/whisper-tiny-id` (kenapa "langsung" itu masalah)

Dari metadata resmi Hugging Face API untuk `cahya/whisper-tiny-id` [S1]:

- `tags` memuat `pytorch` dan `transformers`; `library_name: transformers`.
- Arsitektur: `WhisperForConditionalGeneration`, `model_type: whisper` — varian standar arsitektur Whisper, bukan arsitektur kustom.
- File bobot: **`pytorch_model.bin`** (format pickle PyTorch era 2022, *bukan* `.safetensors`). File lain: `config.json`, `vocab.json`, `merges.txt`, `added_tokens.json`, `tokenizer_config.json`, `preprocessor_config.json`.
- Lisensi `apache-2.0` — konversi/redistribusi bobot diizinkan.
- Terakhir diubah `2022-12-18`; dilatih dengan Transformers `4.26.0.dev0` + PyTorch `1.13.0` [S2].

Dari model card resmi [S2]: fine-tune dari `openai/whisper-tiny` memakai Common Voice 11.0 + magic_data + titml + fleurs, hasil evaluasi **WER 18.28 / loss 0.2409**.

**Implikasinya:**

1. `.bin`/`.safetensors` adalah **serialisasi tensor + `state_dict` PyTorch**, bukan graf komputasi portabel. Mengeksekusinya butuh runtime PyTorch (ATen/autograd) atau hasil ekspor graf (`torch.export` / TorchScript / tracing) [S7].
2. Karena arsitekturnya Whisper standar [S1], *setiap* konverter yang mendukung Whisper HF generik (whisper.cpp, whisperkittools, optimum-executorch) secara prinsip dapat memprosesnya — tidak ada operator kustom yang perlu di-porting. (Ini inferensi dari `model_type: whisper` + daftar konverter di bawah; belum diuji eksekusinya — lih. risiko §7.)
3. Format `.bin` lawas justru menguntungkan untuk skrip konversi whisper.cpp yang memuat model via `transformers.from_pretrained` (§3), karena skrip itu ditulis di era `.bin` [S5].

---

## 2. Jawaban inti: "tanpa konversi sama sekali" — mungkin, tapi didiskualifikasi

| Jalur "nol konversi" | Status | Alasan |
|---|---|---|
| Bundle interpreter Python + `torch`/`transformers` di dalam app, panggil via `Process`/XPC | Teknis mungkin, **tidak direkomendasikan** | Ukuran distribusi (runtime torch + dependensi Python mencapai orde GB), startup lambat, manajemen proses rapuh — tidak cocok untuk aplikasi menu-bar push-to-talk yang harus responsif. *(Engineering assessment; tidak ada sumber primer yang merekomendasikan pola ini untuk shipping app.)* |
| Link LibTorch (PyTorch C++) langsung ke Swift via ObjC++/C interop | **Tidak ada jalur resmi untuk macOS/Swift yang ditemukan** | Dokumentasi PyTorch C++ menargetkan distribusi C++ generik [S7-dok]; hasil riset ini tidak menemukan artefak LibTorch resmi (SPM/XCFramework/CocoaPods) untuk macOS, dan jalur ini tetap CPU-only tanpa akses ANE/GPU yang ergonomis. *(Assessment berdasarkan ketiadaan dukungan resmi yang ditemukan.)* |
| Tulis ulang forward-pass Whisper manual (Metal shaders / Accelerate) | Mungkin tapi = menulis ulang whisper.cpp | Tidak masuk akal ketika implementasi C/C++ bebas-dependensi sudah ada [S4]. |

**Kesimpulan §2:** Pertanyaan yang benar bukan "tanpa konversi", melainkan "**konversi satu-kali ke format apa**, dan **runtime Swift apa**". Kandidatnya: ggml (whisper.cpp), `.pte` (ExecuTorch), `.onnx` (ONNX Runtime), `.mlpackage` manual (CoreML), atau tetap WhisperKit-CoreML via tool resmi (§6).

---

## 3. Jalur utama non-WhisperKit: whisper.cpp (ggml) + Swift

### 3.1 Kenapa ini kandidat terkuat non-CoreML

Dari README resmi whisper.cpp [S4]:

- Implementasi **C/C++ polos tanpa dependensi**; "Apple Silicon first-class citizen — optimized via ARM NEON, Accelerate framework, Metal and Core ML".
- API publik berupa **C-style API** (`include/whisper.h`) — mudah di-bind ke Swift via ObjC bridging/module map, tanpa perlu binding komunitas yang tidak terawat.
- Mendukung **Metal full-GPU inference** di Apple Silicon, kuantisasi integer (`q5_0`), dan "zero memory allocations at runtime".
- Tabel memori resmi: tiny 75 MiB disk / ~273 MB RAM; base 142 MiB / ~388 MB; small 466 MiB / ~852 MB [S4].

### 3.2 Konversi `cahya/whisper-tiny-id` → ggml: didukung resmi untuk model fine-tuned HF

Dari `models/README.md` resmi whisper.cpp [S3]:

- Model PyTorch asli OpenAI dikonversi ke format biner kustom `ggml` agar bisa dimuat di C/C++.
- Bagian **"Fine-tuned models"** secara eksplisit mendukung model hasil fine-tune ala blog Hugging Face (implementasi Transformers Whisper) memakai skrip **`convert-h5-to-ggml.py`**: `python3 convert-h5-to-ggml.py ./whisper-medium/ ./whisper .` — dengan catatan formatnya "sedikit berbeda dibanding format asli OpenAI" dan skrip inilah yang menanganinya.

Dari source skrip konversi itu sendiri [S5]:

- Memuat model via **`WhisperForConditionalGeneration.from_pretrained(dir_model)`** — persis arsitektur `cahya/whisper-tiny-id` [S1] — lalu memetakan nama bobot HF→ggml lewat `conv_map`, membaca `vocab.json` + mel filter dari repo `openai/whisper`, dan menulis `ggml-model.bin` (default fp16).
- **Caveat primer:** skrip memanggil `from_pretrained` tanpa argumen format, sehingga perilaku terhadap `.bin` vs `.safetensors` mengikuti versi `transformers` yang terinstal. `cahya/whisper-tiny-id` yang berformat `.bin` [S1] cocok dengan era skrip ini. Untuk model `.safetensors`-only, komunitas melaporkan perlu adaptasi kecil (ganti pemuatan bobot ke `safetensors.torch.load_file`) — sumber sekunder, perlu verifikasi [S16b].

### 3.3 Integrasi ke Swift: pola resmi (XCFramework + contoh Apple)

- Contoh resmi `examples/whisper.swiftui` mendokumentasikan alur: build XCFramework via **`./build-xcframework.sh`**, lalu seret `build-apple/whisper.xcframework` ke proyek Xcode [S6]. Ada juga contoh ObjC (`whisper.objc`) [S4].
- Fakta arsitektur penting dari README contoh tersebut [S6]: **"The ggml model file is required as the Core ML model is only used for the encoder. The decoder which is in the ggml model is still required."** — di whisper.cpp, CoreML (kalau dipakai) *hanya* mengakselerasi encoder; decoder selalu jalan di CPU/Metal dari bobot ggml.
- Rekomendasikan build konfigurasi **Release** (`-O3 -DNDEBUG`) untuk performa transkripsi [S6].

### 3.4 Performa whisper.cpp di Apple Silicon (angka dari sumber primer)

- Klaim README: eksekusi encoder di ANE via Core ML menghasilkan **speed-up >3x dibanding CPU-only**; first run lambat karena kompilasi ANE, run berikutnya cepat [S4].
- PR resmi **ANEForge (#3905)**, backend encoder alternatif yang dispatch langsung ke ANE: latensi encoder per-call (fp16, `whisper-bench`) — tiny **5.7 ms (ANEForge) vs 11.2 ms (CoreML) vs 7.3 ms (Metal)**; base 12.2 vs 23.0 vs 13.5; small 40.3 vs 77.2 vs 40.9 — ~2x lebih cepat dari encoder CoreML [S12]. **Caveat:** ANEForge memakai simbol privat Espresso/`e5rt` ("undocumented, can change with macOS… research path") — bukan pilihan produksi untuk aplikasi shipping [S12].
- Keterbatasan fundamental (diskusi resmi repo #548, dari kontributor/komunitas): encoder adalah graf statis yang cocok untuk ANE, sedangkan **decoder autoregresif + KV-cache sulit/inefisien di ANE** (bentuk dinamis, I/O KV-cache CPU↔ANE tiap langkah); satu eksperimen melaporkan decoder (1,1)-token ~16 ms di ANE vs ~7 ms di CPU [S13]. Inilah alasan arsitektural kenapa whisper.cpp menaruh decoder di CPU/Metal [S6] — dan kenapa WhisperKit yang menaruh decoder di ANE punya keunggulan (§6).

---

## 4. Jalur resmi PyTorch: ExecuTorch (`.pte`) + Swift

Dari dokumentasi resmi "Using ExecuTorch on iOS" (berlaku untuk iOS + macOS) [S7]:

- ExecuTorch mendukung **iOS dan macOS via Objective-C, Swift, dan C++**, dengan backend akselerasi **Core ML dan MLX** di platform Apple.
- Runtime didistribusikan sebagai **prebuilt `.xcframework` + paket SwiftPM** (`branch: swiftpm-<version>`); syarat minimum **iOS 17 / macOS 14**; perlu linker flag `-all_load`/`-force_load` agar registrasi backend/kernel terjadi saat startup.
- API berupa wrapper ObjC (`ExecuTorchModule`) yang auto-bridge ke Swift (`Module(filePath:)` → `load` → `forward`) [S7].

Dari README contoh Whisper resmi di repo `pytorch/executorch` [S8]:

- Ekspor model Whisper HF memakai **`optimum-cli export executorch --recipe metal|cuda`** menghasilkan `model.pte` (+ `.ptd` opsional), plus preprocessor mel-spectrogram terpisah (`whisper_preprocessor.pte`) dan tokenizer JSON dari repo HF.
- **Caveat primer:** contoh build yang didokumentasikan hanya `whisper-cpu/cuda/metal` (runner C++ desktop) dan **demo mobile yang dirujuk hanya Android** (`WhisperApp`) — tidak ada contoh Swift/Apple siap pakai untuk Whisper [S8]. Artinya: jalur ini resmi dan terawat, tetapi untuk Kanso Dictate butuh merakit sendiri (ekspor optimum → Module Swift → preprocessing → decode loop) dengan effort lebih besar daripada whisper.cpp yang sudah punya contoh SwiftUI [S6].

---

## 5. Jalur lain: ONNX Runtime, CoreML manual

**ONNX Runtime.** Dari docs resmi [S9][S10]:

- API Objective-C tersedia dan bisa dipanggil dari Swift via bridging header (`#import <onnxruntime.h>`), tetapi artefak terpublikasi (`onnxruntime-objc`, CPU + CoreML) **hanya untuk iOS via CocoaPods** [S9] — tidak ada pod macOS.
- Untuk macOS, CoreML Execution Provider hanya hadir bila build dengan **`--use_coreml`** (wheels Python dan paket C/C++ arm64 resmi menyertakannya; custom build tidak) [S10]; pemakaian dari Swift berarti interop C/C++ manual + registrasi EP eksplisit + opsi seperti `ModelFormat: MLProgram`, `MLComputeUnits: ALL`, `ModelCacheDirectory` [S10].
- Assessment: layak (CoreML EP → ANE), tetapi rantai PyTorch→ONNX untuk Whisper (dynamic axes, KV-cache, greedy loop) + plumbing Swift manual = effort terbesar di antara kandidat, tanpa contoh ujung-ke-ujung resmi. **Peringkat terakhir** untuk kebutuhan ini.

**CoreML manual via coremltools.** Pola ini valid — skrip `generate-coreml-model.sh` whisper.cpp sendiri memakai `coremltools` + `ane_transformers` + `openai-whisper` di Python 3.11, macOS 14+ direkomendasikan [S4] — tetapi menulis pipeline konversi + inference Whisper manual dari nol pada dasarnya menduplikasi kerja WhisperKit/whisperkittools (§6). Hanya masuk akal bila butuh kontrol graf penuh yang tidak diberikan tool resmi.

---

## 6. Fakta kunci: model kustom TIDAK mengharuskan meninggalkan WhisperKit

Dari README resmi `argmaxinc/whisperkittools` [S11]:

- Tool **`whisperkit-generate-model --model-version <model-version> --output-dir <output-dir>`** mengonversi "**Hugging Face Whisper Models (PyTorch)**" ke format WhisperKit (Core ML).
- Alur publikasi model kustom didokumentasikan: set `MODEL_REPO_ID=my-org/my-repo`, jalankan generate dengan `--model-version` menunjuk repo sumber (contoh: `distil-whisper/distil-small.en`), hasilnya terbit di Hub dan over-the-air deployable ke aplikasi WhisperKit [S11].
- Paket juga menyediakan evaluasi (`whisperkit-evaluate-model` di librispeech/earnings22) dan wrapper Python pembanding (`WhisperKit`, `WhisperCpp`, `WhisperMLX`) [S11] — berguna untuk uji A/B `cahya/whisper-tiny-id` vs `openai_whisper-tiny` sebelum shipping.

**Kenapa ini penting untuk verdict:** keberatan "tapi saya butuh model Indonesia `cahya/…`" terjawab oleh tool resmi — konversi satu-kali, setelah itu model kustom berjalan di pipeline ANE penuh WhisperKit (encoder *dan* decoder di Neural Engine, lih. `ModelComputeOptions` di riset sebelumnya [S15]) plus optimasi seperti context-prefill KV-cache (`--generate-decoder-context-prefill-data`, dari dokumentasi tool [S16a]).

---

## 7. Best practice low-latency (khusus push-to-talk, bersumber primer)

1. **Prewarm / antisipasi kompilasi pertama.** First run di device lambat karena CoreML/ANE mengompilasi model ke format spesifik-device; run berikutnya cepat [S4]. Di WhisperKit: `prewarm: true` + `initialize()` saat launch [S15]. Di ONNX Runtime: set `ModelCacheDirectory` agar subgraph CoreML terkompilasi dipakai ulang [S10]. Panduan coremltools: spesialisasi device bisa memakan waktu detik–menit untuk model besar [S14].
2. **Tempatkan komputasi di ANE, bukan CPU.** WhisperKit: `audioEncoderCompute` + `textDecoderCompute = .cpuAndNeuralEngine` (macOS 14+) [S15]; semantik `cpuAndNeuralEngine` = CPU + Neural Engine, tanpa GPU [S14]. whisper.cpp: encoder ANE via CoreML + decoder CPU/Metal [S4][S6].
3. **Pilih model kecil + kuantisasi untuk jalur CPU.** tiny/base + varian `-q5_0` yang menghemat memori/disk [S3][S4]; matriks varian WhisperKit (`tiny` → `small_216MB`) di [S15].
4. **Decoding greedy minimal untuk dictation.** `temperature = 0.0`, `withoutTimestamps = true`, `skipSpecialTokens = true` [S15]; contoh runner ExecuTorch memakai `--temperature 0` [S8].
5. **Jaga format audio tetap 16 kHz mono Float32** (`[Float]` ternormalisasi) agar tanpa resampling di hot path; konversi mic via `AVAudioConverter` [S15].
6. **Isolasi inference dari MainActor** (actor khusus, hanya tipe `Sendable` melintasi batas) agar kompilasi/inferensi tak menghitch UI [S15].
7. **Build Release** (`-O3 -DNDEBUG`) untuk biner shipping [S6].

---

## 8. Verdict untuk Kanso Dictate

1. **WhisperKit tetap pilihan tercepat dan termurah-effort untuk push-to-talk dictation.** Alasannya struktural, bukan preferensi: WhisperKit menaruh *encoder dan decoder* di ANE [S15], sementara whisper.cpp hanya mengakselerasi encoder (decoder tetap CPU/Metal [S6]) karena KV-cache autoregresif tidak cocok untuk ANE [S13]. Untuk utterance pendek (3–10 detik) yang didominasi decode loop per-token, keunggulan decoder-di-ANE ini menentukan. Ditambah distribusi SPM native, tokenizer/VAD terintegrasi, dan prewarm [S15].
2. **"Tanpa konversi ke WhisperKit CoreML" dimungkinkan via whisper.cpp** — konversi `cahya/whisper-tiny-id` → ggml memakai skrip resmi `convert-h5-to-ggml.py` [S3][S5], integrasi Swift via XCFramework + contoh resmi [S6], akselerasi Metal/ANE-encoder [S4]. Pilih ini bila: butuh portabilitas ggml/kuantisasi ekstrem, toolchain CoreML bermasalah, atau ingin menghindari dependensi SPM besar. Ekspektasi latensi: kompetitif di encoder (satu digit ms untuk tiny [S12]), tetapi decoder CPU/Metal menjadi batas bawah latensi ujung-ke-ujung.
3. **Untuk kebutuhan "model Indonesia" spesifik: konversi `cahya/whisper-tiny-id` via `whisperkit-generate-model`, bukan pindah runtime** [S11]. Modelnya berarsitektur Whisper standar + lisensi Apache-2.0 [S1], sehingga kompatibel secara prinsip dengan konverter generik. Langkah yang disarankan: (a) spike konversi + evaluasi WER vs `openai_whisper-tiny/base` memakai `whisperkit-evaluate-model` [S11]; (b) bila WER Indonesia menang signifikan pada latensi setara, ship varian kustom; bila tidak, tetap pada varian bawaan yang sudah teruji [S15]. Risiko terbuka: model era Transformers 4.26/PyTorch 1.13 [S2] belum diverifikasi terhadap versi `whisperkittools` saat ini — verifikasi empiris sebelum komitmen.
4. **ExecuTorch adalah runner-up resmi** (SPM + backend CoreML/MLX + min macOS 14 [S7]) bila suatu hari Kanso butuh runtime PyTorch-generik di luar Whisper; untuk Whisper-spesifik hari ini, effort integrasinya lebih besar tanpa keunggulan latensi yang terdokumentasi atas WhisperKit. ONNX Runtime dan LibTorch langsung **tidak direkomendasikan** untuk kasus ini (§2, §5).

---

## Sumber

- [S1] Hugging Face API, `cahya/whisper-tiny-id` (metadata mentah: tags `pytorch`/`transformers`, arsitektur `WhisperForConditionalGeneration`, sibling `pytorch_model.bin`, lisensi `apache-2.0`, `lastModified 2022-12-18`). `https://huggingface.co/api/models/cahya/whisper-tiny-id`
- [S2] Model card `cahya/whisper-tiny-id` (fine-tune `openai/whisper-tiny`; WER 18.2837; Transformers 4.26.0.dev0, PyTorch 1.13.0). `https://huggingface.co/cahya/whisper-tiny-id`
- [S3] `ggml-org/whisper.cpp`, `models/README.md` (format ggml; 3 cara perolehan model; bagian "Fine-tuned models" + `convert-h5-to-ggml.py`; tabel ukuran; kuantisasi `-q5_0`). `https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md`
- [S4] `ggml-org/whisper.cpp`, `README.md` (C/C++ tanpa dependensi; Apple Silicon: NEON/Accelerate/Metal/CoreML; C-style API `whisper.h`; tabel memori; §Core ML support: encoder-ANE >3x vs CPU, `generate-coreml-model.sh`, first-run lambat; §ANEForge). `https://github.com/ggml-org/whisper.cpp/blob/master/README.md`
- [S5] `ggml-org/whisper.cpp`, `models/convert-h5-to-ggml.py` (source: `WhisperForConditionalGeneration.from_pretrained` + `conv_map` + mel filter + output `ggml-model.bin` fp16). `https://github.com/ggml-org/whisper.cpp/blob/master/models/convert-h5-to-ggml.py`
- [S6] `ggml-org/whisper.cpp`, `examples/whisper.swiftui/README.md` (`build-xcframework.sh`; CoreML hanya encoder, decoder ggml tetap wajib; build Release `-O3 -DNDEBUG`). `https://github.com/ggml-org/whisper.cpp/blob/master/examples/whisper.swiftui/README.md`
- [S7] PyTorch docs, "Using ExecuTorch on iOS" (ObjC/Swift/C++ untuk iOS+macOS; backend CoreML+MLX; SPM `swiftpm-<version>`; min iOS 17/macOS 14; `-all_load`; API `ExecuTorchModule`/`Module`). `https://docs.pytorch.org/executorch/main/using-executorch-ios.html`
- [S8] `pytorch/executorch`, `examples/models/whisper/README.md` (`optimum-cli export executorch --recipe metal/cuda` → `model.pte`; `whisper_preprocessor.pte`; tokenizer dari HF; `--temperature 0`; demo mobile hanya Android). `https://github.com/pytorch/executorch/blob/main/examples/models/whisper/README.md`
- [S9] ONNX Runtime docs, "Get started with ORT for Objective-C" (ObjC API + Swift via bridging header; artefak `onnxruntime-objc` CPU+CoreML **iOS saja** via CocoaPods). `https://onnxruntime.ai/docs/get-started/with-obj-c.html`
- [S10] ONNX Runtime docs, "CoreML Execution Provider" (syarat iOS 13/macOS 10.15; macOS butuh build `--use_coreml`; registrasi EP eksplisit; opsi `ModelFormat`, `MLComputeUnits`, `ModelCacheDirectory`). `https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html`
- [S11] `argmaxinc/whisperkittools`, `README.md` (`whisperkit-generate-model --model-version --output-dir` untuk HF Whisper PyTorch→CoreML; publikasi model kustom via `MODEL_REPO_ID`; `whisperkit-evaluate-model`; wrapper `WhisperKit/WhisperCpp/WhisperMLX`). `https://github.com/argmaxinc/whisperkittools`
- [S12] `ggml-org/whisper.cpp` PR #3905, ANEForge encoder backend (tabel latensi tiny/base/small/medium; ~2x vs CoreML; simbol privat Espresso/`e5rt` = research path). `https://github.com/ggml-org/whisper.cpp/pull/3905`
- [S13] `ggml-org/whisper.cpp` Discussion #548, "Run encoder on Apple Neural Engine" (encoder cocok ANE; decoder autoregresif + KV-cache sulit di ANE; eksperimen decoder (1,1)-token 16 ms vs 7 ms CPU). `https://github.com/ggml-org/whisper.cpp/discussions/548`
- [S14] Apple Developer Docs `MLComputeUnits`/`cpuAndNeuralEngine` + panduan coremltools "Model Prediction" (kompilasi spesialisasi-device detik–menit). `https://developer.apple.com/documentation/coreml/mlcomputeunits` ; `https://apple.github.io/coremltools/docs-guides/source/model-prediction.html`
- [S15] Riset repo ini: `docs/research/whisperkit-integration.md` (`ModelComputeOptions` ANE; `prewarm`; matriks varian; format audio `[Float]` 16 kHz; pola actor Swift 6).
- [S16] Sekunder (ditandai, bukan dasar verdict): (a) DeepWiki `whisperkittools` 4.1 — detail `--generate-decoder-context-prefill-data`, `--generate-quantized-variants`, `load_whisper_model` menerima HF ID atau path lokal; (b) CasaDelKrogh "Whisper.cpp Safetensors Conversion" — adaptasi `convert-h5-to-ggml.py` ke `safetensors.torch.load_file` untuk model safetensors-only.
