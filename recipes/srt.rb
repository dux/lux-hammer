# desc: Local SRT extraction via whisper.cpp

desc <<~TXT
  Local subtitle extraction with whisper.cpp.

  Quickstart:
    srt install              # brew install whisper-cpp + pick a model
    srt model:select         # pick a model (downloads it, removes others)
    srt extract video.mp4    # video -> video.srt

  Pieces (composed by `extract`, also runnable on their own):
    srt audio      video.mp4   # video -> video.wav (16 kHz mono)
    srt transcribe clip.wav    # wav   -> clip.srt
    srt doctor
TXT

MODELS_DIR ||= File.expand_path('~/.cache/whisper-models')
MODEL_URL  ||= 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main'
# Silero VAD model lives in a sibling dir so the catalog scan in
# `current_model` doesn't see it as a transcription model.
VAD_DIR    ||= File.join(MODELS_DIR, 'vad')
VAD_FILE   ||= 'ggml-silero-v5.1.2.bin'
VAD_URL    ||= "https://huggingface.co/ggml-org/whisper-vad/resolve/main/#{VAD_FILE}"

# Curated subset of the whisper.cpp ggml catalog. Name matches the suffix
# in `ggml-<name>.bin`; sizes are approximate.
MODEL_CATALOG ||= [
  ['tiny',           '39 MB',  'fastest, multilingual'],
  ['tiny.en',        '39 MB',  'fastest, English only'],
  ['base',           '74 MB',  'small + balanced, multilingual'],
  ['base.en',        '74 MB',  'small + balanced, English only'],
  ['small',          '244 MB', 'good quality, multilingual'],
  ['small.en',       '244 MB', 'good quality, English only'],
  ['medium',         '769 MB', 'better quality, slower'],
  ['medium.en',      '769 MB', 'better quality, English only'],
  ['large-v3',       '1.5 GB', 'best quality, slowest'],
  ['large-v3-turbo', '809 MB', 'near-large quality, much faster']
].freeze

# Recipe bodies eval inside Hammer::Builder#instance_exec, so top-level
# `def` lands on the builder singleton and is invisible to handler procs.
# Constants and module methods resolve lexically, so helpers go here.
module SRT
  module_function

  def have?(bin)
    system("command -v #{bin} >/dev/null 2>&1")
  end

  def require_tool!(bin, hint)
    return if have?(bin)
    Hammer::Shell.error "#{bin} not found on PATH - #{hint}"
  end

  # Name of the currently-selected model (nil if nothing downloaded yet).
  def current_model
    return nil unless File.directory?(MODELS_DIR)
    file = Dir.children(MODELS_DIR).find { |f| f =~ /\Aggml-(.+)\.bin\z/ }
    file && file[/\Aggml-(.+)\.bin\z/, 1]
  end

  def current_model_path
    name = current_model or return nil
    File.join(MODELS_DIR, "ggml-#{name}.bin")
  end

  VIDEO_EXTS ||= %w[.mp4 .mkv .mov .avi .webm .m4v].freeze

  # Largest video file in `dir` (by bytes), or nil if none. Used by
  # `extract` when called without an explicit video.
  def largest_video(dir)
    return nil unless dir && File.directory?(dir)
    Dir.children(dir)
      .select { |f| VIDEO_EXTS.include?(File.extname(f).downcase) }
      .map    { |f| File.join(dir, f) }
      .select { |p| File.file?(p) }
      .max_by { |p| File.size(p) }
  end

  # Ensure the Silero VAD model is on disk and return its path. Downloaded
  # on first use; whisper-cli's --vad flag is what keeps it from
  # hallucinating over music and silence.
  def ensure_vad!
    require 'fileutils'
    FileUtils.mkdir_p(VAD_DIR)
    path = File.join(VAD_DIR, VAD_FILE)
    return path if File.file?(path)
    tmp = "#{path}.partial"
    Hammer::Shell.say.gray "downloading Silero VAD model..."
    ok = system(%(curl -L --fail -o "#{tmp}" "#{VAD_URL}"))
    Hammer::Shell.error 'failed to download Silero VAD model' unless ok
    File.rename(tmp, path)
    path
  end
end

task :install do
  desc 'Install whisper-cpp via brew and pick a model'

  proc do
    if SRT.have?('whisper-cli')
      say.gray 'whisper-cli present, skipping brew install'
    else
      sh 'brew install whisper-cpp'
    end
    hammer 'model:select' unless SRT.current_model
  end
end

namespace :model do
  task :select do
    desc 'Pick a whisper model: downloads it and removes any others'

    proc do
      current = SRT.current_model
      items = MODEL_CATALOG.map do |name, size, info|
        mark = current == name ? '*' : ' '
        "#{mark} #{name.ljust(16)} #{size.ljust(8)} #{info}"
      end
      idx = choose 'pick a model (* = current)', items
      next say.gray('cancelled') unless idx

      name = MODEL_CATALOG[idx][0]
      require 'fileutils'
      FileUtils.mkdir_p(MODELS_DIR)
      dest = File.join(MODELS_DIR, "ggml-#{name}.bin")
      unless File.file?(dest)
        sh %(curl -L --fail -o "#{dest}" "#{MODEL_URL}/ggml-#{name}.bin")
      end

      # Drop every other ggml-*.bin so only the selection remains.
      Dir.children(MODELS_DIR).each do |f|
        next unless f =~ /\Aggml-.+\.bin\z/
        next if f == "ggml-#{name}.bin"
        File.delete(File.join(MODELS_DIR, f))
        say.gray "removed #{f}"
      end
      say.green "selected #{name}"
    end
  end
end

task :audio do
  desc    "Extract 16 kHz mono WAV (whisper.cpp's input format) from a video"
  example 'audio movie.mp4'
  example 'audio movie.mp4 -o tmp/movie.wav'
  # `:video` is declared first so positional ARGV fills it; the parser
  # fills non-boolean opts in declaration order.
  opt :video,  req: true, placeholder: 'VIDEO'
  opt :output, alias: :o, desc: 'output wav path (default: <input>.wav)'

  proc do |opts|
    src = opts[:video]
    error "no such file: #{src}" unless File.file?(src)
    SRT.require_tool! 'ffmpeg', 'install with `brew install ffmpeg`'
    wav = opts[:output] || src.sub(/\.[^.]+\z/, '') + '.wav'
    sh %(ffmpeg -y -loglevel error -i "#{src}" -ar 16000 -ac 1 -c:a pcm_s16le "#{wav}")
    say.green wav
  end
end

task :transcribe do
  desc    'Transcribe a 16 kHz mono WAV into an SRT next to it'
  example 'transcribe clip.wav'
  example 'transcribe clip.wav --lang auto'
  opt :wav,  req: true, placeholder: 'WAV'
  opt :lang, default: 'en', desc: 'language code or "auto"'

  proc do |opts|
    wav = opts[:wav]
    error "no such file: #{wav}" unless File.file?(wav)
    SRT.require_tool! 'whisper-cli', 'run `srt install`'
    mdl = SRT.current_model_path or error 'no model selected - run `srt model:select`'
    vad = SRT.ensure_vad!
    # Tag the output with the lang so multiple tracks can coexist:
    # clip.wav -> clip.en.srt
    base = wav.sub(/\.wav\z/, '') + ".#{opts[:lang]}"
    # -mc 0          : don't carry prior-segment text into the next window
    #                  (kills the "same line repeated 100x" loop on long audio)
    # --suppress-nst : suppress non-speech tokens during music / silence
    # --vad -vm ...  : Silero VAD pre-pass so silent sections aren't transcribed
    sh %(whisper-cli -m "#{mdl}" -l #{opts[:lang]} -mc 0 --suppress-nst ) +
      %(--vad -vm "#{vad}" -osrt -of "#{base}" "#{wav}")
    say.green "#{base}.srt"
  end
end

task :extract do
  desc    'Video -> SRT (audio extraction + whisper transcription)'
  example 'extract                    # picks largest video in cwd'
  example 'extract movie.mp4 --lang en --keep-wav'
  opt :video,    placeholder: 'VIDEO'
  opt :lang,     default: 'en', desc: 'language code or "auto"'
  opt :keep_wav, type: :boolean, desc: 'keep the intermediate .wav'

  proc do |opts|
    # `LLM_LOCAL_CWD` is set by the `llm-local` wrapper before it chdirs
    # into the project; falls back to Dir.pwd for direct `srt` runs.
    src = opts[:video] || SRT.largest_video(ENV['LLM_LOCAL_CWD'] || Dir.pwd)
    error 'no video given and none found in current folder' unless src
    error "no such file: #{src}" unless File.file?(src)
    base = src.sub(/\.[^.]+\z/, '')
    wav  = "#{base}.wav"
    hammer :audio,      src, output: wav
    hammer :transcribe, wav, lang: opts[:lang]
    File.delete(wav) unless opts[:keep_wav]
    say.green "#{base}.#{opts[:lang]}.srt"
  end
end

task :fix do
  desc    'Translate non-target-language cues in an SRT via claude/codex CLI'
  example 'fix movie.en.srt              # target inferred from filename'
  example 'fix movie.srt --lang en       # target from --lang fallback'
  opt :srt,  req: true, placeholder: 'SRT'
  opt :lang, default: 'en', desc: 'target language code (default: en)'

  proc do |opts|
    src = opts[:srt]
    error "no such file: #{src}" unless File.file?(src)

    # Prefer the language tag baked into the filename (e.g. movie.en.srt -> en);
    # fall back to --lang when the filename has no tag.
    target = File.basename(src)[/\.([a-z]{2,3})\.srt\z/i, 1]&.downcase || opts[:lang]

    cli =
      if    SRT.have?('claude') then 'claude'
      elsif SRT.have?('codex')  then 'codex'
      else  error 'neither `claude` nor `codex` CLI found on PATH'
      end

    prompt = <<~TXT
      Edit the SRT file at "#{src}" in place.
      Target language: #{target}.
      For every subtitle cue whose text is not in #{target}, translate the text to #{target}.
      Leave cues already in #{target} unchanged.
      Preserve cue numbers, timestamps, and blank lines exactly as in the original.
      Do not add commentary - just write the corrected SRT back to the same file.
    TXT

    require 'shellwords'
    cmd =
      case cli
      when 'claude' then %(claude -p --permission-mode acceptEdits #{Shellwords.escape(prompt)})
      when 'codex'  then %(codex exec -s workspace-write #{Shellwords.escape(prompt)})
      end

    say.gray cmd
    sh cmd
    say.green src
  end
end

task :doctor do
  desc 'Check ffmpeg / whisper-cli / selected model are present'

  proc do
    {
      'ffmpeg'      => 'ffmpeg',
      'whisper-cli' => 'whisper-cli'
    }.each do |label, bin|
      SRT.have?(bin) ? say.green("ok  #{label}") : say.red("--  #{label} (missing)")
    end
    if (m = SRT.current_model)
      say.green "ok  model #{m}"
    else
      say.red '--  no model selected (run `srt model:select`)'
    end
  end
end
