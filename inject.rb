#!/usr/bin/env ruby
# -*- coding: utf-8 -*-
# ============================================================================
# inject.rb — Universal Ruby CLI Installer, Uninstaller & RGSS Decryptor
# (Optional alternative to inject.py / inject.bat when Ruby is installed)
#
# Automatically detects game folders (including www/, data/, parent/subfolders)
# and supports ALL RPG Maker engines + encrypted RGSS archives:
#   - RPG Maker MV     (www/js/plugins.js, www/index.html, www/data/*.json) -> cheat.js
#   - RPG Maker MZ     (js/plugins.js, index.html, data/*.json)             -> cheat.js
#   - RPG Maker VX Ace (Data/Scripts.rvdata2 OR packed *.rgss3a archive!)   -> cheat.rb
#   - RPG Maker VX     (Data/Scripts.rvdata  OR packed *.rgss2a archive!)   -> cheat.rb
#   - RPG Maker XP     (Data/Scripts.rxdata  OR packed *.rgssad archive!)   -> cheat.rb
# ============================================================================

require "zlib"
require "fileutils"

module RPGMInjector
  SECTION_TAG     = "[CheatMenu]"
  JS_PLUGIN_NAME  = "RPGMCheat"
  JS_PLUGIN_ENTRY = '{"name":"RPGMCheat","status":true,"description":"Universal Cheat Menu [F8]","parameters":{}}'
  HTML_SCRIPT_TAG = '<script type="text/javascript" src="js/rpgm_cheat.js"></script>'

  SCRIPT_FILES   = ["Scripts.rvdata2", "Scripts.rvdata", "Scripts.rxdata"]
  ARCHIVE_EXTS   = [".rgss3a", ".rgss2a", ".rgssad"]
  SUBDIR_PARENTS = ["www", "data", "js", "plugins", "audio", "img", "movies", "save", "locales", "swiftshader", "fonts", "system", "graphics"]
  SKIP_SCAN_DIRS = ["img", "audio", "movies", "locales", "swiftshader", "save", "graphics", "fonts", "node_modules", ".git"]

  # ==========================================================================
  # RGSSAD / RGSS2A / RGSS3A Decryptor & Surgical Patcher
  # ==========================================================================

  class RgssArchive
    attr_reader :path, :file_size, :version, :master_key, :entries

    def initialize(path)
      @path      = path
      @file_size = File.size(path)
      @version   = 0
      @entries   = []
      parse_index
    end

    def self.xor_buffer!(buf, len, key)
      buf.force_encoding("ASCII-8BIT") if buf.respond_to?(:force_encoding)
      k = key & 0xFFFFFFFF
      i = 0
      while i + 4 <= len
        w = buf.byteslice(i, 4).unpack("V")[0] ^ k
        buf[i, 4] = [w].pack("V")
        k = (k * 7 + 3) & 0xFFFFFFFF
        i += 4
      end
      if i < len
        rem = len - i
        rem.times do |b|
          byte = buf.getbyte(i + b) ^ ((k >> (8 * b)) & 0xFF)
          buf.setbyte(i + b, byte)
        end
        k = (k * 7 + 3) & 0xFFFFFFFF
      end
      k
    end

    def self.xor_copy(data, subkey)
      out = data.dup
      out.force_encoding("ASCII-8BIT") if out.respond_to?(:force_encoding)
      xor_buffer!(out, out.bytesize, subkey)
      out
    end

    def self.sanitize_rel_path(name)
      norm = name.tr("\\", "/").sub(/\A\/+/, "").sub(/\A[A-Za-z]:\/+/, "")
      parts = norm.split("/").reject { |p| p.empty? || p == "." }
      raise "Unsafe archive entry path rejected: #{name}" if parts.empty? || parts.include?("..")
      File.join(*parts)
    end

    def parse_index
      File.open(@path, "rb") do |f|
        hdr = f.read(8)
        if hdr.nil? || hdr.bytesize < 8 || hdr.byteslice(0, 7) != "RGSSAD\x00"
          raise "Not a valid RGSSAD archive (header mismatch): #{@path}"
        end
        @version = hdr.getbyte(7)

        if @version == 3
          seed_raw = f.read(4)
          raise "Truncated RGSS3A key header." if seed_raw.nil? || seed_raw.bytesize < 4
          seed = seed_raw.unpack("V")[0]
          key  = (seed * 9 + 3) & 0xFFFFFFFF
          @master_key = key

          while !f.eof?
            entry_pos = f.pos
            off_raw = f.read(4)
            break if off_raw.nil? || off_raw.bytesize < 4
            offset = off_raw.unpack("V")[0] ^ key
            break if offset == 0

            rest = f.read(12)
            raise "Truncated RGSS3A directory entry." if rest.nil? || rest.bytesize < 12
            r_size, r_subkey, r_nlen = rest.unpack("VVV")
            size   = r_size ^ key
            subkey = r_subkey ^ key
            nlen   = r_nlen ^ key

            if nlen > 4096 || offset < 16 || offset + size > @file_size
              raise "Archive uses non-standard custom key protection."
            end

            enc_name = f.read(nlen)
            raise "Truncated RGSS3A entry filename." if enc_name.nil? || enc_name.bytesize < nlen
            dec_bytes = []
            nlen.times do |i|
              dec_bytes << (enc_name.getbyte(i) ^ ((key >> (8 * (i & 3))) & 0xFF))
            end
            dec_name = dec_bytes.pack("C*")
            dec_name.force_encoding("UTF-8") if dec_name.respond_to?(:force_encoding)

            @entries << {
              :name       => dec_name,
              :offset     => offset,
              :size       => size,
              :subkey     => subkey,
              :header_pos => entry_pos
            }
          end
        elsif @version == 1 || @version == 2
          key = 0xDEADCAFE
          @master_key = key

          while f.pos < @file_size
            entry_pos = f.pos
            nl_raw = f.read(4)
            break if nl_raw.nil? || nl_raw.empty?
            raise "Truncated RGSSAD v1 header." if nl_raw.bytesize < 4
            nlen = nl_raw.unpack("V")[0] ^ key
            key  = (key * 7 + 3) & 0xFFFFFFFF

            if nlen == 0 || nlen > 4096 || f.pos + nlen + 4 > @file_size
              raise "Archive uses non-standard custom key protection."
            end

            enc_name = f.read(nlen)
            dec_bytes = []
            nlen.times do |i|
              dec_bytes << (enc_name.getbyte(i) ^ (key & 0xFF))
              key = (key * 7 + 3) & 0xFFFFFFFF
            end
            dec_name = dec_bytes.pack("C*")
            dec_name.force_encoding("UTF-8") if dec_name.respond_to?(:force_encoding)

            sz_raw = f.read(4)
            size_xor_key = key
            size = sz_raw.unpack("V")[0] ^ key
            key  = (key * 7 + 3) & 0xFFFFFFFF

            data_off = f.pos
            raise "Truncated RGSSAD v1 payload." if data_off + size > @file_size

            @entries << {
              :name            => dec_name,
              :offset          => data_off,
              :size            => size,
              :subkey          => key,
              :header_pos      => entry_pos,
              :raw_name_header => nl_raw + enc_name,
              :size_xor_key    => size_xor_key
            }
            f.seek(data_off + size)
          end
        else
          raise "Unsupported RGSSAD version: #{@version}"
        end
      end
    end

    def find_scripts_entry(custom_rel = nil)
      targets = []
      targets << custom_rel.tr("/", "\\").downcase if custom_rel && !custom_rel.empty?
      targets.concat([
        "data\\scripts.rvdata2",
        "data\\scripts.rvdata",
        "data\\scripts.rxdata",
        "scripts.rvdata2",
        "scripts.rvdata",
        "scripts.rxdata"
      ])
      by_norm = {}
      @entries.each do |e|
        k = e[:name].tr("/", "\\").downcase
        by_norm[k] ||= e
      end
      targets.each do |t|
        return by_norm[t] if by_norm.key?(t)
      end
      nil
    end

    def read_entry_bytes(entry)
      enc = nil
      File.open(@path, "rb") do |f|
        f.seek(entry[:offset])
        enc = f.read(entry[:size]) || ""
      end
      self.class.xor_copy(enc, entry[:subkey])
    end

    def extract_all(dest_dir)
      total = @entries.length
      File.open(@path, "rb") do |f|
        @entries.each_with_index do |e, idx|
          rel = self.class.sanitize_rel_path(e[:name])
          out_path = File.join(dest_dir, rel)
          FileUtils.mkdir_p(File.dirname(out_path))
          f.seek(e[:offset])
          rem = e[:size]
          k   = e[:subkey]
          File.open(out_path, "wb") do |out_f|
            while rem > 0
              take = rem > 65536 ? 65536 : rem
              chunk = f.read(take)
              break if chunk.nil? || chunk.empty?
              k = self.class.xor_buffer!(chunk, chunk.bytesize, k)
              out_f.write(chunk)
              rem -= chunk.bytesize
            end
          end
          num = idx + 1
          if num == 1 || (num % 200 == 0) || num == total
            puts "[Decryptor] Extracted #{num}/#{total} files..."
          end
        end
      end
    end

    def self.read_json_int(txt, field)
      if txt =~ /"#{Regexp.escape(field)}"\s*:\s*(\d+)/
        return $1.to_i
      end
      raise "Missing field #{field} in backup metadata"
    end

    def patch_scripts_entry(entry, new_plain_bytes)
      enc_payload = self.class.xor_copy(new_plain_bytes, entry[:subkey])
      new_size    = enc_payload.bytesize

      if @version == 3
        meta_path = @path + ".rpgmcheat_bak"
        append_offset = if File.exist?(meta_path)
          mtxt = File.open(meta_path, "rb") { |f| f.read }
          self.class.read_json_int(mtxt, "orig_archive_size")
        else
          mtxt = "{\n  \"version\": 3,\n  \"orig_archive_size\": #{@file_size},\n  \"header_pos\": #{entry[:header_pos]},\n  \"orig_offset\": #{entry[:offset]},\n  \"orig_size\": #{entry[:size]}\n}\n"
          File.open(meta_path, "wb") { |f| f.write(mtxt) }
          @file_size
        end

        raise "Archive exceeds 4 GB RGSS3A offset limit." if append_offset + new_size > 0xFFFFFFFF

        File.open(@path, "r+b") do |f|
          f.seek(append_offset)
          f.write(enc_payload)
          f.truncate(append_offset + new_size)
          f.seek(entry[:header_pos])
          f.write([(append_offset ^ @master_key) & 0xFFFFFFFF, (new_size ^ @master_key) & 0xFFFFFFFF].pack("VV"))
          f.flush
        end
        @file_size = append_offset + new_size
      else
        bak_path = @path + ".bak"
        unless File.exist?(bak_path)
          FileUtils.cp(@path, bak_path)
          puts "[Backup] Created archive backup: #{bak_path}"
        end

        tmp_path = @path + ".tmp"
        File.open(@path, "rb") do |src|
          File.open(tmp_path, "wb") do |dst|
            dst.write(src.read(8))
            @entries.each do |e|
              if e.equal?(entry)
                dst.write(e[:raw_name_header])
                dst.write([(new_size ^ e[:size_xor_key]) & 0xFFFFFFFF].pack("V"))
                dst.write(enc_payload)
              else
                src.seek(e[:header_pos])
                rem = (e[:offset] - e[:header_pos]) + e[:size]
                while rem > 0
                  take = rem > 65536 ? 65536 : rem
                  chunk = src.read(take)
                  break if chunk.nil? || chunk.empty?
                  dst.write(chunk)
                  rem -= chunk.bytesize
                end
              end
            end
          end
        end
        FileUtils.mv(tmp_path, @path)
        @file_size = File.size(@path)
      end
    end

    def self.revert_patch(archive_path)
      meta_path = archive_path + ".rpgmcheat_bak"
      if File.exist?(meta_path)
        mtxt     = File.open(meta_path, "rb") { |f| f.read }
        orig_len = read_json_int(mtxt, "orig_archive_size")
        hdr_pos  = read_json_int(mtxt, "header_pos")
        orig_off = read_json_int(mtxt, "orig_offset")
        orig_sz  = read_json_int(mtxt, "orig_size")

        File.open(archive_path, "r+b") do |f|
          f.seek(8)
          seed = f.read(4).unpack("V")[0]
          key  = (seed * 9 + 3) & 0xFFFFFFFF
          f.seek(hdr_pos)
          f.write([(orig_off ^ key) & 0xFFFFFFFF, (orig_sz ^ key) & 0xFFFFFFFF].pack("VV"))
          f.flush
          f.truncate(orig_len)
        end
        File.delete(meta_path)
        return true
      end

      bak_path = archive_path + ".bak"
      if File.exist?(bak_path)
        hdr = File.open(archive_path, "rb") { |f| f.read(8) }
        if hdr && hdr.byteslice(0, 7) == "RGSSAD\x00" && hdr.getbyte(7) <= 2
          FileUtils.mv(bak_path, archive_path)
          return true
        end
      end
      false
    end
  end

  module_function

  def run(argv)
    mode = :install
    standalone = false
    target_arg = nil

    argv.each do |arg|
      case arg
      when "-h", "--help"
        print_help
        return 0
      when "-r", "--remove", "--uninstall"
        mode = :remove
      when "-d", "--decrypt", "--extract", "--unpack"
        mode = :decrypt
      when "-s", "--standalone", "--embed"
        standalone = true
      else
        target_arg = arg
      end
    end

    own_dir       = File.dirname(File.expand_path(__FILE__))
    cheat_rb_path = File.join(own_dir, "cheat.rb")
    cheat_js_path = File.join(own_dir, "cheat.js")

    target = discover_target(target_arg, mode)
    return 1 unless target

    if mode == :decrypt
      return decrypt_archive_command(target)
    end

    if target[:kind] == :js
      puts "[Detected] RPG Maker #{target[:engine_hint]} project at: #{target[:web_root]}"
      if mode == :remove
        uninstall_js(target)
      else
        unless File.exist?(cheat_js_path)
          $stderr.puts "[Error] cheat.js not found next to inject.rb: #{cheat_js_path}"
          return 1
        end
        install_js(target, cheat_js_path)
      end
    else
      disp = target[:archive_path] || target[:scripts_path]
      puts "[Detected] RPG Maker RGSS target: #{disp}"
      if mode == :remove
        uninstall_rgss(target, cheat_rb_path)
      else
        unless File.exist?(cheat_rb_path)
          $stderr.puts "[Error] cheat.rb not found next to inject.rb: #{cheat_rb_path}"
          return 1
        end
        install_rgss(target, cheat_rb_path, standalone)
      end
    end
    0
  end

  def print_help
    puts <<-'HELP'
Usage:
  ruby inject.rb [options] [path_to_game_folder_or_archive]

Supported layouts & encrypted archives:
  - RPG Maker MV / MZ   (www/js/plugins.js, js/plugins.js, index.html)
  - RPG Maker XP/VX/VXA (Data/Scripts.* OR Game.rgss3a / .rgss2a / .rgssad)

Options:
  (default)          Installs cheat.js (MV/MZ) or cheat.rb (XP/VX/VXA & .rgss* archives).
  -d, --decrypt      Extracts all files from Game.rgss3a/.rgss2a/.rgssad to disk.
  -s, --standalone   For RGSS: embeds cheat.rb inside game scripts only.
  -r, --remove       Cleanly uninstalls the cheat menu & restores original archive.
  -h, --help         Show this help message.
HELP
  end

  def find_ci_child(parent_dir, target_name)
    return nil unless parent_dir && File.directory?(parent_dir)
    exact = File.join(parent_dir, target_name)
    return exact if File.exist?(exact)
    low = target_name.downcase
    Dir.entries(parent_dir).each do |e|
      return File.join(parent_dir, e) if e.downcase == low
    end
    nil
  rescue SystemCallError
    nil
  end

  def get_ini_info(game_dir)
    info = { :scripts_rel => nil, :archive_rel => nil }
    return info unless game_dir && File.directory?(game_dir)
    Dir.entries(game_dir).sort.each do |fn|
      next unless fn.downcase.end_with?(".ini")
      full = File.join(game_dir, fn)
      next unless File.file?(full)
      txt = File.open(full, "rb") { |f| f.read }
      if info[:scripts_rel].nil? && txt =~ /^\s*Scripts\s*=\s*(.+?)\s*$/i
        info[:scripts_rel] = $1.strip.gsub(/\A["']|["']\z/, "")
      end
      if info[:archive_rel].nil? && txt =~ /^\s*Archive\s*=\s*(.+?)\s*$/i
        info[:archive_rel] = $1.strip.gsub(/\A["']|["']\z/, "")
      end
    end
    info
  rescue SystemCallError
    info
  end

  def find_rgss_scripts(dir)
    ini = get_ini_info(dir)
    if ini[:scripts_rel]
      cand = File.join(dir, ini[:scripts_rel].tr("\\", "/"))
      return cand if File.file?(cand)
    end
    data_dir = find_ci_child(dir, "Data")
    SCRIPT_FILES.each do |fname|
      if data_dir && File.directory?(data_dir)
        f = find_ci_child(data_dir, fname)
        return f if f && File.file?(f)
      end
      d = find_ci_child(dir, fname)
      return d if d && File.file?(d)
    end
    nil
  end

  def find_rgss_archive(dir)
    return nil unless dir && File.directory?(dir)
    ini = get_ini_info(dir)
    if ini[:archive_rel]
      cand = File.join(dir, ini[:archive_rel].tr("\\", "/"))
      return cand if File.file?(cand)
    end
    ["Game.rgss3a", "Game.rgss2a", "Game.rgssad"].each do |std|
      hit = find_ci_child(dir, std)
      return hit if hit && File.file?(hit)
    end
    Dir.entries(dir).sort.each do |fn|
      low = fn.downcase
      if ARCHIVE_EXTS.any? { |ext| low.end_with?(ext) }
        full = File.join(dir, fn)
        return full if File.file?(full)
      end
    end
    nil
  rescue SystemCallError
    nil
  end

  def mv_mz_web_root?(web_dir)
    return false unless web_dir && File.directory?(web_dir)
    js_dir = find_ci_child(web_dir, "js")
    if js_dir && File.directory?(js_dir)
      ["plugins.js", "rpg_core.js", "rmmz_core.js", "main.js"].each do |m|
        hit = find_ci_child(js_dir, m)
        return true if hit && File.file?(hit)
      end
    end
    data_dir = find_ci_child(web_dir, "data")
    if data_dir && File.directory?(data_dir)
      ["System.json", "Actors.json", "Items.json", "MapInfos.json"].each do |m|
        hit = find_ci_child(data_dir, m)
        return true if hit && File.file?(hit)
      end
    end
    false
  end

  def find_html_entry(game_root, web_root)
    idx = find_ci_child(web_root, "index.html")
    return idx if idx && File.file?(idx)
    [game_root, web_root].each do |base|
      next unless base
      pkg = find_ci_child(base, "package.json")
      if pkg && File.file?(pkg)
        raw = File.open(pkg, "rb") { |f| f.read }
        if raw =~ /"main"\s*:\s*"([^"]+\.html?)"/i
          cand = File.join(base, $1.tr("\\", "/"))
          return cand if File.file?(cand)
        end
      end
    end
    nil
  end

  def probe_directory(cand_dir)
    return nil unless cand_dir && File.directory?(cand_dir)

    arc  = find_rgss_archive(cand_dir)
    rgss = find_rgss_scripts(cand_dir)
    if arc || rgss
      ini = get_ini_info(cand_dir)
      return {
        :kind            => :rgss,
        :game_dir        => cand_dir,
        :archive_path    => arc,
        :scripts_path    => rgss,
        :ini_scripts_rel => ini[:scripts_rel]
      }
    end

    www_dir = find_ci_child(cand_dir, "www")
    if www_dir && File.directory?(www_dir) && mv_mz_web_root?(www_dir)
      return {
        :kind        => :js,
        :engine_hint => "MV",
        :game_dir    => cand_dir,
        :web_root    => www_dir,
        :html_path   => find_html_entry(cand_dir, www_dir)
      }
    end

    if mv_mz_web_root?(cand_dir)
      is_www    = (File.basename(cand_dir).downcase == "www")
      parent    = File.dirname(cand_dir)
      game_root = (is_www && parent && parent != cand_dir) ? parent : cand_dir
      return {
        :kind        => :js,
        :engine_hint => is_www ? "MV" : "MV/MZ",
        :game_dir    => game_root,
        :web_root    => cand_dir,
        :html_path   => find_html_entry(game_root, cand_dir)
      }
    end

    nil
  end

  def discover_target(raw_arg, mode)
    if raw_arg.nil? || raw_arg.strip.empty?
      local = discover_from_path(Dir.pwd, false)
      return local if local
      prompt = (mode == :decrypt) ? "Enter path to the RPG Maker game folder (or .rgss* archive): " : "Enter path to the RPG Maker game folder: "
      print prompt
      $stdout.flush
      input = $stdin.gets
      if input.nil? || input.strip.empty?
        $stderr.puts "[Error] No path provided."
        return nil
      end
      raw_arg = input
    end
    discover_from_path(raw_arg.strip.gsub(/\A["']|["']\z/, ""), true)
  end

  def discover_from_path(path_str, report_errors)
    expanded = File.expand_path(path_str)

    if File.file?(expanded)
      low = expanded.downcase
      if low.end_with?(".rvdata2", ".rvdata", ".rxdata")
        parent = File.dirname(expanded)
        root   = (File.basename(parent).downcase == "data") ? File.dirname(parent) : parent
        return { :kind => :rgss, :game_dir => root, :archive_path => nil, :scripts_path => expanded, :ini_scripts_rel => nil }
      end
      if ARCHIVE_EXTS.any? { |ext| low.end_with?(ext) }
        root = File.dirname(expanded)
        ini  = get_ini_info(root)
        return { :kind => :rgss, :game_dir => root, :archive_path => expanded, :scripts_path => find_rgss_scripts(root), :ini_scripts_rel => ini[:scripts_rel] }
      end
      start_dir = File.dirname(expanded)
    elsif File.directory?(expanded)
      start_dir = expanded
    else
      $stderr.puts "[Error] Path not found: #{expanded}" if report_errors
      return nil
    end

    candidates = [start_dir]
    cur = start_dir
    4.times do
      base = File.basename(cur).downcase
      par  = File.dirname(cur)
      break if par.nil? || par == cur
      if SUBDIR_PARENTS.include?(base)
        candidates << par unless candidates.include?(par)
        cur = par
      else
        break
      end
    end

    candidates.each do |c|
      hit = probe_directory(c)
      return hit if hit
    end

    if report_errors
      level1 = []
      Dir.entries(start_dir).sort.each do |e|
        next if e.start_with?(".") || SKIP_SCAN_DIRS.include?(e.downcase)
        sub = File.join(start_dir, e)
        level1 << sub if File.directory?(sub)
      end

      level1.each do |sub|
        hit = probe_directory(sub)
        return hit if hit
      end

      level1.each do |sub|
        Dir.entries(sub).sort.each do |e|
          next if e.start_with?(".") || SKIP_SCAN_DIRS.include?(e.downcase)
          sub2 = File.join(sub, e)
          if File.directory?(sub2)
            hit = probe_directory(sub2)
            return hit if hit
          end
        end
      end

      $stderr.puts "[Error] Could not find supported RPG Maker files in: #{expanded}"
      $stderr.puts "        Checked for: MV/MZ (www/js/plugins.js, js/plugins.js, index.html, data/*.json)"
      $stderr.puts "                     and XP/VX/VXA (Data/Scripts.*, *.rgss3a/*.rgss2a/*.rgssad, Game.ini)."
    end
    nil
  end

  def decrypt_archive_command(target)
    if target[:kind] != :rgss
      puts "[Info] RPG Maker MV/MZ projects do not use .rgss* archives (data/*.json and js/ are already unpacked)."
      return 0
    end
    arc_path = target[:archive_path]
    game_dir = target[:game_dir]
    unless arc_path && File.file?(arc_path)
      $stderr.puts "[Error] No .rgss3a/.rgss2a/.rgssad archive found in: #{game_dir}"
      return 1
    end
    begin
      puts "[Decryptor] Opening archive: #{arc_path}"
      arc = RgssArchive.new(arc_path)
      puts "[Decryptor] Detected RGSSAD v#{arc.version} (#{arc.entries.length} files). Extracting to: #{game_dir}"
      arc.extract_all(game_dir)
      bak_arc = arc_path + ".bak"
      bak_arc = arc_path + ".unpacked_bak" if File.exist?(bak_arc)
      FileUtils.mv(arc_path, bak_arc)
      File.delete(arc_path + ".rpgmcheat_bak") if File.exist?(arc_path + ".rpgmcheat_bak")
      puts "[Decryptor] Renamed archive to #{bak_arc} so the game loads unpacked files from disk."
      puts "[Done] Archive fully unpacked!"
      0
    rescue => e
      $stderr.puts "[Error] #{e.message}"
      1
    end
  end

  def read_bin(path)
    File.open(path, "rb") { |f| f.read }
  end

  def write_bin(path, data)
    File.open(path, "wb") { |f| f.write(data) }
  end

  def install_js(target, cheat_js_path)
    web_root = target[:web_root]
    js_dir   = find_ci_child(web_root, "js") || File.join(web_root, "js")
    FileUtils.mkdir_p(js_dir)

    plugins_js = find_ci_child(js_dir, "plugins.js")
    main_js    = find_ci_child(js_dir, "main.js")
    used_pjs   = false

    if plugins_js && File.file?(plugins_js)
      raw = read_bin(plugins_js)
      raw.force_encoding("UTF-8") if raw.respond_to?(:force_encoding)
      raw = raw.sub(/\A\xEF\xBB\xBF/, "")

      patched = nil
      verb    = "Installed"
      if raw =~ /\{\s*"name"\s*:\s*"RPGMCheat"[^\r\n]*\}/
        patched = raw.sub(/\{\s*"name"\s*:\s*"RPGMCheat"[^\r\n]*\}/, JS_PLUGIN_ENTRY)
        verb    = "Updated"
      elsif raw =~ /\$plugins\s*=\s*\[/
        open_idx   = raw.index("[", $~.begin(0))
        last_close = raw.rindex("]")
        if open_idx && last_close && last_close >= open_idx
          inner    = raw[(open_idx + 1)...last_close]
          stripped = inner.rstrip
          if stripped.empty?
            patched = raw[0..open_idx] + "\n" + JS_PLUGIN_ENTRY + "\n" + raw[last_close..-1]
          elsif stripped.end_with?(",")
            ins = open_idx + 1 + stripped.length
            patched = raw[0...ins] + "\n" + JS_PLUGIN_ENTRY + "\n" + raw[last_close..-1]
          else
            ins = open_idx + 1 + stripped.length
            patched = raw[0...ins] + ",\n" + JS_PLUGIN_ENTRY + "\n" + raw[last_close..-1]
          end
        end
      end

      if patched
        plugins_dir = find_ci_child(js_dir, "plugins") || File.join(js_dir, "plugins")
        FileUtils.mkdir_p(plugins_dir)
        bak = plugins_js + ".bak"
        unless File.exist?(bak)
          FileUtils.cp(plugins_js, bak)
          puts "[Backup] Created backup: #{bak}"
        end
        write_bin(plugins_js, patched)
        dest = File.join(plugins_dir, JS_PLUGIN_NAME + ".js")
        FileUtils.cp(cheat_js_path, dest)
        puts "[#{verb}] Registered #{JS_PLUGIN_NAME} in #{plugins_js}"
        puts "[File] Copied plugin to #{dest}"
        used_pjs = true
      end
    end

    unless used_pjs
      dest_script = File.join(js_dir, "rpgm_cheat.js")
      FileUtils.cp(cheat_js_path, dest_script)
      html_path = target[:html_path]

      if html_path && File.file?(html_path)
        ht = read_bin(html_path)
        ht.force_encoding("UTF-8") if ht.respond_to?(:force_encoding)
        unless ht.include?("rpgm_cheat.js")
          bak = html_path + ".bak"
          FileUtils.cp(html_path, bak) unless File.exist?(bak)
          if ht =~ /<\/body\s*>/i
            ht = ht.sub(/(<\/body\s*>)/i, HTML_SCRIPT_TAG + "\n\\1")
          else
            ht = ht.rstrip + "\n" + HTML_SCRIPT_TAG + "\n"
          end
          write_bin(html_path, ht)
          puts "[Installed] Injected script tag into #{html_path}"
        else
          puts "[Updated] Refreshed #{dest_script}"
        end
      elsif main_js && File.file?(main_js)
        mt = read_bin(main_js)
        mt.force_encoding("UTF-8") if mt.respond_to?(:force_encoding)
        unless mt.include?("rpgm_cheat.js")
          bak = main_js + ".bak"
          FileUtils.cp(main_js, bak) unless File.exist?(bak)
          hook = "\n// RPGMCheat Loader\n(function(){var s=document.createElement(\"script\");s.src=\"js/rpgm_cheat.js\";document.body.appendChild(s);})();\n"
          write_bin(main_js, mt + hook)
          puts "[Installed] Appended loader to #{main_js}"
        end
      else
        plugins_dir = File.join(js_dir, "plugins")
        FileUtils.mkdir_p(plugins_dir)
        dest = File.join(plugins_dir, JS_PLUGIN_NAME + ".js")
        FileUtils.cp(cheat_js_path, dest)
        new_pjs = File.join(js_dir, "plugins.js")
        write_bin(new_pjs, "// Generated by RPG Maker.\nvar $plugins =\n[\n" + JS_PLUGIN_ENTRY + "\n];\n")
        puts "[Installed] Created #{new_pjs} and #{dest}"
      end
    end

    puts "[Done] Launch the game and press F8 on the map or in battle!"
  end

  def uninstall_js(target)
    web_root = target[:web_root]
    js_dir   = find_ci_child(web_root, "js")
    removed  = false

    if js_dir && File.directory?(js_dir)
      plugins_js = find_ci_child(js_dir, "plugins.js")
      if plugins_js && File.file?(plugins_js)
        raw = read_bin(plugins_js)
        raw.force_encoding("UTF-8") if raw.respond_to?(:force_encoding)
        if raw.include?('"RPGMCheat"')
          c1 = raw.gsub(/,\s*\{\s*"name"\s*:\s*"RPGMCheat"[^\r\n]*\}/, "")
          c1 = raw.gsub(/\{\s*"name"\s*:\s*"RPGMCheat"[^\r\n]*\}\s*,\s*/, "") if c1 == raw
          c1 = raw.gsub(/\{\s*"name"\s*:\s*"RPGMCheat"[^\r\n]*\}\r?\n?/, "") if c1 == raw
          write_bin(plugins_js, c1)
          puts "[Removed] Unregistered #{JS_PLUGIN_NAME} from #{plugins_js}"
          removed = true
        end
      end

      plugins_dir = find_ci_child(js_dir, "plugins")
      if plugins_dir && File.directory?(plugins_dir)
        pf = find_ci_child(plugins_dir, JS_PLUGIN_NAME + ".js")
        if pf && File.file?(pf)
          File.delete(pf)
          puts "[Removed] Deleted #{pf}"
          removed = true
        end
      end

      djs = find_ci_child(js_dir, "rpgm_cheat.js")
      if djs && File.file?(djs)
        File.delete(djs)
        puts "[Removed] Deleted #{djs}"
        removed = true
      end
    end

    html_path = target[:html_path]
    if html_path && File.file?(html_path)
      ht = read_bin(html_path)
      ht.force_encoding("UTF-8") if ht.respond_to?(:force_encoding)
      if ht.include?("rpgm_cheat.js")
        ht = ht.gsub(/\s*<script[^>]*rpgm_cheat\.js[^>]*><\/script>/i, "")
        write_bin(html_path, ht)
        puts "[Removed] Removed script tag from #{html_path}"
        removed = true
      end
    end

    puts "[Info] #{JS_PLUGIN_NAME} was not installed in #{web_root}." unless removed
  end

  def patch_scripts_blob(raw_bytes, name_hint, compressed)
    scripts = Marshal.load(raw_bytes)
    raise "Invalid script table root" unless scripts.is_a?(Array)

    sec_title = SECTION_TAG.dup
    if name_hint.downcase.end_with?(".rvdata2")
      sec_title.force_encoding("UTF-8") if sec_title.respond_to?(:force_encoding)
    else
      sec_title.force_encoding("ASCII-8BIT") if sec_title.respond_to?(:force_encoding)
    end

    existing_idx = scripts.index { |e| e.is_a?(Array) && e[1].to_s == SECTION_TAG }
    if existing_idx
      scripts[existing_idx][1] = sec_title
      scripts[existing_idx][2] = compressed
      msg = "updated at slot ##{existing_idx}"
    else
      insert_at = find_main_index(scripts)
      magic_id  = rand(89_999_999) + 10_000_000
      scripts.insert(insert_at, [magic_id, sec_title, compressed])
      msg = "inserted above Main at slot ##{insert_at}"
    end
    [Marshal.dump(scripts), msg]
  end

  def install_rgss(target, cheat_rb_path, standalone)
    game_dir     = target[:game_dir]
    archive_path = target[:archive_path]
    scripts_path = target[:scripts_path]

    clean_code = read_bin(cheat_rb_path)
    clean_code.force_encoding("UTF-8") if clean_code.respond_to?(:force_encoding)
    clean_code = clean_code.sub(/\A#.*coding:.*\r?\n/, "")

    payload = if standalone
      "# -*- coding: utf-8 -*-\n# Auto-generated by RPGMCheat inject.rb (standalone)\nunless defined?(RPGMCheat)\n" + clean_code + "\nend\n"
    else
      <<-'LOADER_HEAD' + clean_code + "\nend\n"
# -*- coding: utf-8 -*-
# Auto-generated by RPGMCheat inject.rb (hybrid loader + fallback)
if File.exist?("cheat.rb") && !defined?(RPGMCheat)
  rpgm_cheat_raw = File.open("cheat.rb", "rb") { |f| f.read }
  rpgm_cheat_bom = [0xEF, 0xBB, 0xBF].pack("C*")
  if rpgm_cheat_raw.length >= 3 && rpgm_cheat_raw[0, 3] == rpgm_cheat_bom
    rpgm_cheat_raw = rpgm_cheat_raw[3, rpgm_cheat_raw.length - 3]
  end
  if rpgm_cheat_raw.respond_to?(:force_encoding)
    rpgm_cheat_raw.force_encoding("UTF-8")
  end
  eval(rpgm_cheat_raw, TOPLEVEL_BINDING, "cheat.rb")
end

unless defined?(RPGMCheat)
LOADER_HEAD
    end

    compressed  = Zlib::Deflate.deflate(payload, Zlib::BEST_COMPRESSION)
    patched_arc = false

    if archive_path && File.file?(archive_path)
      puts "[Decryptor] Reading encrypted archive: #{archive_path}"
      begin
        arc = RgssArchive.new(archive_path)
        s_entry = arc.find_scripts_entry(target[:ini_scripts_rel])
        if s_entry
          raw_scripts = arc.read_entry_bytes(s_entry)
          new_bytes, msg = patch_scripts_blob(raw_scripts, s_entry[:name], compressed)
          arc.patch_scripts_entry(s_entry, new_bytes)
          puts "[Installed] #{SECTION_TAG} #{msg} directly inside #{File.basename(archive_path)} (#{s_entry[:name]})!"
          patched_arc = true
        end
      rescue => e
        unless scripts_path
          $stderr.puts "[Error] Could not patch #{archive_path}: #{e.message}"
          return
        end
        $stderr.puts "[Warning] Could not patch #{File.basename(archive_path)}: #{e.message}"
      end
    end

    if scripts_path && File.file?(scripts_path)
      bak_path = scripts_path + ".bak"
      unless File.exist?(bak_path)
        FileUtils.cp(scripts_path, bak_path)
        puts "[Backup] Created backup: #{bak_path}"
      end
      new_bytes, msg = patch_scripts_blob(read_bin(scripts_path), scripts_path, compressed)
      write_bin(scripts_path, new_bytes)
      puts "[Installed] #{SECTION_TAG} #{msg} in #{scripts_path}."
    end

    unless patched_arc || (scripts_path && File.file?(scripts_path))
      $stderr.puts "[Error] No Scripts entry found in #{game_dir}."
      return
    end

    target_cheat_rb = File.join(game_dir, "cheat.rb")
    if standalone
      if File.exist?(target_cheat_rb) && File.expand_path(target_cheat_rb) != File.expand_path(cheat_rb_path)
        File.delete(target_cheat_rb)
      end
      puts "[Mode] Standalone: cheat menu embedded inside game scripts."
    else
      if File.expand_path(target_cheat_rb) != File.expand_path(cheat_rb_path)
        FileUtils.cp(cheat_rb_path, target_cheat_rb)
      end
      puts "[File] Copied #{target_cheat_rb} (edit settings anytime without re-injecting)."
    end

    puts "[Done] Launch the game and press F8 on the map or in battle!"
  end

  def find_main_index(scripts)
    idx = scripts.length - 1
    while idx >= 0
      entry = scripts[idx]
      if entry.is_a?(Array) && entry.length >= 3
        return idx if entry[1].to_s.strip.downcase == "main"
        begin
          code = Zlib::Inflate.inflate(entry[2]).to_s
          return idx if code.include?("rgss_main") || code.include?("SceneManager.run") || code.include?("$scene.main")
        rescue Exception
        end
      end
      idx -= 1
    end
    [scripts.length - 1, 0].max
  end

  def uninstall_rgss(target, own_cheat_rb)
    game_dir     = target[:game_dir]
    archive_path = target[:archive_path]
    scripts_path = target[:scripts_path]
    removed_any  = false

    if archive_path && File.file?(archive_path)
      if RgssArchive.revert_patch(archive_path)
        puts "[Removed] Restored original unpatched archive: #{archive_path}"
        removed_any = true
      end
    end

    if scripts_path && File.file?(scripts_path)
      scripts = Marshal.load(read_bin(scripts_path))
      before  = scripts.length
      scripts.reject! { |e| e.is_a?(Array) && e[1].to_s == SECTION_TAG }
      if scripts.length < before
        write_bin(scripts_path, Marshal.dump(scripts))
        puts "[Removed] #{SECTION_TAG} removed from #{scripts_path}."
        removed_any = true
      end
    end

    target_cheat_rb = File.join(game_dir, "cheat.rb")
    if File.exist?(target_cheat_rb) && File.expand_path(target_cheat_rb) != File.expand_path(own_cheat_rb)
      File.delete(target_cheat_rb)
      puts "[Removed] Deleted #{target_cheat_rb}."
      removed_any = true
    end

    puts "[Info] #{SECTION_TAG} was not installed in #{game_dir}." unless removed_any
  end
end

if __FILE__ == $0
  exit(RPGMInjector.run(ARGV))
end
