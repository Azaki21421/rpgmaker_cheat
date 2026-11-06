# -*- coding: utf-8 -*-
# ============================================================================
# RPGMCheat — Universal In-Game Cheat Menu for RPG Maker (Ruby / RGSS)
# Supported engines (uses the game's built-in RGSS Ruby runtime):
#   - RPG Maker VX Ace (RGSS3 / Ruby 1.9.2)
#   - RPG Maker VX     (RGSS2 / Ruby 1.8.1)
#   - RPG Maker XP     (RGSS1 / Ruby 1.8.1)
#   - mkxp / mkxp-z    (Ruby 2.x / 3.x)
#
# Default Controls:
#   F8                   — Open / close cheat menu (map, menu, or battle)
#   Q / W (PgUp / PgDn)  — Previous / next tab
#   Up / Down Arrows     — Navigate list (hold Ctrl to jump 10 rows)
#   Left / Right Arrows  — Adjust value: +-1 (Shift: +-10, Ctrl: +-100)
#   Enter / Space / Z    — Open exact digit-by-digit input / trigger action
#   Key A                — Switch party member (Stats tab) / refresh Bag
#   Key S                — Toggle empty DB slots (Items/Weapons/Armors) / heal
#   Esc / X              — Close number popup or exit cheat menu
# ============================================================================

module RPGMCheat
  # Menu toggle hotkey (:F5, :F6, :F7, :F8, :F9)
  HOTKEY_SYMBOL = :F8

  # Hide unnamed database entries by default
  DEFAULT_HIDE_EMPTY = true

  @active        = false
  @god_mode      = false
  @noclip        = false
  @no_encounters = false
  @always_save   = false
  @uncap_stats   = false
  @uncap_items   = false
  @hide_empty    = DEFAULT_HIDE_EMPTY

  class << self
    attr_accessor :god_mode
    attr_accessor :noclip
    attr_accessor :no_encounters
    attr_accessor :always_save
    attr_accessor :uncap_stats
    attr_accessor :uncap_items
    attr_accessor :hide_empty

    def active?
      @active
    end

    def hotkey_code
      if defined?(Input) && Input.const_defined?(HOTKEY_SYMBOL)
        Input.const_get(HOTKEY_SYMBOL)
      else
        Input::F8
      end
    end

    def play_se(kind)
      begin
        if defined?(Sound)
          case kind
          when :cursor then Sound.play_cursor
          when :ok     then Sound.play_ok
          when :cancel then Sound.play_cancel
          when :buzzer then Sound.play_buzzer
          end
        elsif $game_system && $data_system
          case kind
          when :cursor then $game_system.se_play($data_system.cursor_se)
          when :ok     then $game_system.se_play($data_system.decision_se)
          when :cancel then $game_system.se_play($data_system.cancel_se)
          when :buzzer then $game_system.se_play($data_system.buzzer_se)
          end
        end
      rescue Exception
        # Ignore audio errors in custom engines
      end
    end

    def on_input_update
      return if @active
      return unless Bridge.in_game?

      install_hooks unless @hooks_installed
      @hooks_installed = true if defined?(Game_Player)

      apply_passive_cheats if @god_mode

      if Input.trigger?(hotkey_code)
        open_menu
      end
    end

    def apply_passive_cheats
      actors = Bridge.party_actors
      i = 0
      while i < actors.size
        actor = actors[i]
        if actor
          mhp = Bridge.actor_max_hp(actor)
          mmp = Bridge.actor_max_mp(actor)
          actor.hp = mhp if actor.hp < mhp
          Bridge.set_actor_mp(actor, mmp) if Bridge.actor_mp(actor) < mmp
        end
        i += 1
      end
    rescue Exception
    end

    def open_menu
      @active = true
      session = nil
      begin
        play_se(:ok)
        session = MenuSession.new
        loop do
          Graphics.update
          Input.rpgm_cheat_orig_update
          session.update
          break unless session.running?
        end
        # Flush input state so Esc/F8 does not leak into the active scene
        Input.rpgm_cheat_orig_update
      ensure
        session.dispose if session
        @active = false
      end
    end
  end

  # ==========================================================================
  # Bridge — Compatibility layer across RGSS1 (XP), RGSS2 (VX), RGSS3 (VX Ace)
  # ==========================================================================
  module Bridge
    module_function

    def in_game?
      return false if $game_party.nil? || $data_items.nil?
      if defined?(SceneManager) && SceneManager.respond_to?(:scene)
        sc = SceneManager.scene
        return false if sc.nil?
        sname = sc.class.name.to_s
        return false if sname == "Scene_Title" || sname == "Scene_File" ||
                        sname == "Scene_Load"  || sname == "Scene_Gameover"
      elsif defined?($scene)
        return false if $scene.nil?
        sname = $scene.class.name.to_s
        return false if sname == "Scene_Title" || sname == "Scene_File" ||
                        sname == "Scene_Load"  || sname == "Scene_Gameover"
      end
      true
    end

    def engine
      return :xp if $game_party && $game_party.respond_to?(:gain_weapon)
      if defined?(Game_Actor) && Game_Actor.method_defined?(:add_param)
        return :vxa
      end
      :vx
    end

    def engine_label
      case engine
      when :vxa then "VX Ace (RGSS3)"
      when :vx  then "VX (RGSS2)"
      else           "XP (RGSS1)"
      end
    end

    def screen_size
      w = (defined?(Graphics) && Graphics.respond_to?(:width))  ? Graphics.width  : 640
      h = (defined?(Graphics) && Graphics.respond_to?(:height)) ? Graphics.height : 480
      [w, h]
    end

    # --- Party Gold ---

    def gold
      $game_party ? $game_party.gold : 0
    end

    def max_gold
      if $game_party && $game_party.respond_to?(:max_gold)
        $game_party.max_gold
      else
        9999999
      end
    end

    def add_gold(delta)
      return unless $game_party
      $game_party.gain_gold(delta)
    end

    def set_gold(target)
      return unless $game_party
      target = 0 if target < 0
      limit = max_gold
      target = limit if target > limit
      add_gold(target - gold)
    end

    # --- Inventory & Database Items ---

    def db_for(kind)
      case kind
      when :item   then $data_items
      when :weapon then $data_weapons
      when :armor  then $data_armors
      else nil
      end
    end

    def item_count(kind, obj)
      return 0 if obj.nil? || $game_party.nil?
      if engine == :xp
        case kind
        when :item   then $game_party.item_number(obj.id)
        when :weapon then $game_party.weapon_number(obj.id)
        when :armor  then $game_party.armor_number(obj.id)
        else 0
        end
      else
        $game_party.item_number(obj)
      end
    end

    def max_item_for(obj)
      if engine == :vxa && $game_party && $game_party.respond_to?(:max_item_number)
        $game_party.max_item_number(obj)
      else
        99
      end
    end

    def gain_item(kind, obj, delta)
      return if obj.nil? || delta == 0 || $game_party.nil?
      if engine == :xp
        case kind
        when :item   then $game_party.gain_item(obj.id, delta)
        when :weapon then $game_party.gain_weapon(obj.id, delta)
        when :armor  then $game_party.gain_armor(obj.id, delta)
        end
      else
        $game_party.gain_item(obj, delta)
      end
    end

    def set_item_count(kind, obj, target)
      return if obj.nil?
      target = 0 if target < 0
      limit = max_item_for(obj)
      target = limit if target > limit
      current = item_count(kind, obj)
      gain_item(kind, obj, target - current)
    end

    def owned_entries
      result = []
      groups = [
        [:item,   $data_items,   "Item"],
        [:weapon, $data_weapons, "Wpn"],
        [:armor,  $data_armors,  "Arm"]
      ]
      gi = 0
      while gi < groups.size
        kind = groups[gi][0]
        arr  = groups[gi][1]
        tag  = groups[gi][2]
        if arr
          id = 1
          while id < arr.size
            obj = arr[id]
            if obj && item_count(kind, obj) > 0
              result.push({ :kind => kind, :obj => obj, :tag => tag })
            end
            id += 1
          end
        end
        gi += 1
      end
      result
    end

    def db_entries(kind, hide_empty)
      result = []
      arr = db_for(kind)
      return result unless arr
      id = 1
      while id < arr.size
        obj = arr[id]
        if obj
          nm = obj.name.to_s
          if !hide_empty || !nm.strip.empty?
            result.push({ :kind => kind, :obj => obj })
          end
        end
        id += 1
      end
      result
    end

    def item_description(obj)
      return "" unless obj && obj.respond_to?(:description)
      obj.description.to_s.gsub(/[\r\n]+/, " ").strip
    end

    # --- Party Members & Stats ---

    def party_actors
      return [] unless $game_party
      if $game_party.respond_to?(:all_members)
        $game_party.all_members
      elsif $game_party.respond_to?(:members)
        $game_party.members
      elsif $game_party.respond_to?(:actors)
        $game_party.actors
      else
        []
      end
    end

    def actor_max_level(actor)
      return 99 unless actor
      actor.respond_to?(:max_level) ? actor.max_level : 99
    end

    def actor_max_hp(actor)
      return 1 unless actor
      actor.respond_to?(:mhp) ? actor.mhp : actor.maxhp
    end

    def actor_max_mp(actor)
      return 0 unless actor
      if actor.respond_to?(:mmp)
        actor.mmp
      elsif actor.respond_to?(:maxmp)
        actor.maxmp
      else
        actor.maxsp
      end
    end

    def actor_mp(actor)
      return 0 unless actor
      actor.respond_to?(:mp) ? actor.mp : actor.sp
    end

    def set_actor_mp(actor, val)
      return unless actor
      if actor.respond_to?(:mp=)
        actor.mp = val
      elsif actor.respond_to?(:sp=)
        actor.sp = val
      end
    end

    def heal_actor(actor)
      return unless actor
      if actor.respond_to?(:recover_all)
        actor.recover_all
      else
        actor.hp = actor_max_hp(actor)
        set_actor_mp(actor, actor_max_mp(actor))
      end
    end

    def heal_party
      list = party_actors
      i = 0
      while i < list.size
        heal_actor(list[i])
        i += 1
      end
    end

    def stat_definitions(actor)
      return [] unless actor
      eng = engine
      param_cap = (eng == :vxa && RPGMCheat.uncap_stats) ? 999999 : 9999
      other_cap = (eng == :vxa && RPGMCheat.uncap_stats) ? 999999 : 999

      defs = [
        { :key => :level, :name => "Level",      :min => 1, :max => actor_max_level(actor) },
        { :key => :hp,    :name => "Current HP", :min => 1, :max => [actor_max_hp(actor), 1].max },
        { :key => :mp,    :name => (eng == :xp ? "Current SP" : "Current MP"), :min => 0, :max => [actor_max_mp(actor), 0].max }
      ]

      case eng
      when :vxa
        defs.push({ :key => :p0, :name => "Max HP (MHP)",    :min => 1, :max => (RPGMCheat.uncap_stats ? 999999 : 9999) })
        defs.push({ :key => :p1, :name => "Max MP (MMP)",    :min => 0, :max => (RPGMCheat.uncap_stats ? 999999 : 9999) })
        defs.push({ :key => :p2, :name => "Attack (ATK)",    :min => 1, :max => other_cap })
        defs.push({ :key => :p3, :name => "Defense (DEF)",   :min => 1, :max => other_cap })
        defs.push({ :key => :p4, :name => "M.Attack (MAT)",  :min => 1, :max => other_cap })
        defs.push({ :key => :p5, :name => "M.Defense (MDF)", :min => 1, :max => other_cap })
        defs.push({ :key => :p6, :name => "Agility (AGI)",   :min => 1, :max => other_cap })
        defs.push({ :key => :p7, :name => "Luck (LUK)",      :min => 1, :max => other_cap })
      when :vx
        defs.push({ :key => :maxhp, :name => "Max HP (MaxHP)", :min => 1, :max => param_cap })
        defs.push({ :key => :maxmp, :name => "Max MP (MaxMP)", :min => 0, :max => param_cap })
        defs.push({ :key => :atk,   :name => "Attack (ATK)",   :min => 1, :max => 999 })
        defs.push({ :key => :def,   :name => "Defense (DEF)",  :min => 1, :max => 999 })
        defs.push({ :key => :spi,   :name => "Spirit (SPI)",   :min => 1, :max => 999 })
        defs.push({ :key => :agi,   :name => "Agility (AGI)",  :min => 1, :max => 999 })
      when :xp
        defs.push({ :key => :maxhp, :name => "Max HP (MaxHP)",     :min => 1, :max => 9999 })
        defs.push({ :key => :maxsp, :name => "Max SP (MaxSP)",     :min => 0, :max => 9999 })
        defs.push({ :key => :str,   :name => "Strength (STR)",     :min => 1, :max => 999 })
        defs.push({ :key => :dex,   :name => "Dexterity (DEX)",    :min => 1, :max => 999 })
        defs.push({ :key => :agi,   :name => "Agility (AGI)",      :min => 1, :max => 999 })
        defs.push({ :key => :int,   :name => "Intelligence (INT)", :min => 1, :max => 999 })
      end
      defs
    end

    def get_stat(actor, key)
      return 0 unless actor
      case key
      when :level then actor.level
      when :hp    then actor.hp
      when :mp    then actor_mp(actor)
      when :p0    then actor.param(0)
      when :p1    then actor.param(1)
      when :p2    then actor.param(2)
      when :p3    then actor.param(3)
      when :p4    then actor.param(4)
      when :p5    then actor.param(5)
      when :p6    then actor.param(6)
      when :p7    then actor.param(7)
      when :maxhp then actor.maxhp
      when :maxmp then actor.maxmp
      when :maxsp then actor.maxsp
      when :atk   then actor.atk
      when :def   then actor.def
      when :spi   then actor.spi
      when :agi   then actor.agi
      when :str   then actor.str
      when :dex   then actor.dex
      when :int   then actor.int
      else 0
      end
    end

    def set_stat(actor, key, val)
      return unless actor
      case key
      when :level
        ml = actor_max_level(actor)
        val = 1 if val < 1
        val = ml if val > ml
        if actor.respond_to?(:change_level)
          actor.change_level(val, false)
        else
          actor.level = val
        end
      when :hp
        m = actor_max_hp(actor)
        val = 1 if val < 1
        val = m if val > m
        actor.hp = val
      when :mp
        m = actor_max_mp(actor)
        val = 0 if val < 0
        val = m if val > m
        set_actor_mp(actor, val)
      when :p0, :p1, :p2, :p3, :p4, :p5, :p6, :p7
        pid = key.to_s[1, 1].to_i
        min_v = (pid == 1 ? 0 : 1)
        val = min_v if val < min_v
        delta = val - actor.param(pid)
        actor.add_param(pid, delta) if delta != 0
      when :maxhp
        val = 1 if val < 1
        actor.maxhp = val
      when :maxmp
        val = 0 if val < 0
        actor.maxmp = val
      when :maxsp
        val = 0 if val < 0
        actor.maxsp = val
      when :atk
        val = 1 if val < 1
        actor.atk = val
      when :def
        val = 1 if val < 1
        actor.def = val
      when :spi
        val = 1 if val < 1
        actor.spi = val
      when :agi
        val = 1 if val < 1
        actor.agi = val
      when :str
        val = 1 if val < 1
        actor.str = val
      when :dex
        val = 1 if val < 1
        actor.dex = val
      when :int
        val = 1 if val < 1
        actor.int = val
      end
    end

    def add_stat(actor, key, delta)
      return unless actor
      set_stat(actor, key, get_stat(actor, key) + delta)
    end
  end

  # ==========================================================================
  # MenuSession — Overlay UI Renderer & Input Controller (Sprite + Bitmap)
  # ==========================================================================
  class MenuSession
    TABS = [
      { :id => :bag,     :title => "1.Bag"     },
      { :id => :items,   :title => "2.Items"   },
      { :id => :weapons, :title => "3.Weapons" },
      { :id => :armors,  :title => "4.Armors"  },
      { :id => :stats,   :title => "5.Stats"   },
      { :id => :cheats,  :title => "6.Cheats"  }
    ]

    DIGITS_COUNT = 7

    def initialize
      sz = Bridge.screen_size
      @screen_w = sz[0]
      @screen_h = sz[1]

      @panel_w = [[@screen_w - 20, 504].max, 700].min
      @panel_w = @screen_w - 8 if @panel_w > @screen_w - 8
      @panel_h = [[@screen_h - 20, 392].max, 540].min
      @panel_h = @screen_h - 8 if @panel_h > @screen_h - 8

      @panel_x = (@screen_w - @panel_w) / 2
      @panel_y = (@screen_h - @panel_h) / 2

      @row_h    = 24
      @header_h = 84
      @footer_h = 34
      @list_h   = @panel_h - @header_h - @footer_h
      @vis_rows = [@list_h / @row_h, 5].max

      @sprite = Sprite.new
      @sprite.z = 30000
      @bitmap = Bitmap.new(@screen_w, @screen_h)
      if @bitmap.font.respond_to?(:outline=)
        @bitmap.font.outline = true
      end
      if @bitmap.font.respond_to?(:shadow=)
        @bitmap.font.shadow = true
      end
      @sprite.bitmap = @bitmap

      @running     = true
      @tab_index   = 0
      @cursors     = {}
      @scrolls     = {}
      @actor_index = 0
      @modal       = nil
      @notice_text = ""
      @notice_ttl  = 0
      @dirty       = true

      rebuild_rows
    end

    def running?
      @running
    end

    def dispose
      if @bitmap && !@bitmap.disposed?
        @bitmap.dispose
      end
      if @sprite && !@sprite.disposed?
        @sprite.dispose
      end
    end

    def current_tab_id
      TABS[@tab_index][:id]
    end

    def cursor
      @cursors[current_tab_id] || 0
    end

    def set_cursor(val)
      @cursors[current_tab_id] = val
    end

    def scroll
      @scrolls[current_tab_id] || 0
    end

    def set_scroll(val)
      @scrolls[current_tab_id] = val
    end

    def show_notice(msg)
      @notice_text = msg.to_s
      @notice_ttl  = 110
      @dirty       = true
    end

    def current_actor
      list = Bridge.party_actors
      return nil if list.empty?
      @actor_index = 0 if @actor_index >= list.size || @actor_index < 0
      list[@actor_index]
    end

    def rebuild_rows
      tab = current_tab_id
      @rows = []

      case tab
      when :bag
        @rows.push({ :type => :gold })
        owned = Bridge.owned_entries
        i = 0
        while i < owned.size
          @rows.push({
            :type => :item,
            :kind => owned[i][:kind],
            :obj  => owned[i][:obj],
            :tag  => owned[i][:tag]
          })
          i += 1
        end
      when :items
        build_db_rows(:item)
      when :weapons
        build_db_rows(:weapon)
      when :armors
        build_db_rows(:armor)
      when :stats
        actor = current_actor
        if actor
          @rows.push({ :type => :heal_actor })
          defs = Bridge.stat_definitions(actor)
          i = 0
          while i < defs.size
            d = defs[i]
            @rows.push({
              :type => :stat,
              :key  => d[:key],
              :name => d[:name],
              :min  => d[:min],
              :max  => d[:max]
            })
            i += 1
          end
        end
      when :cheats
        @rows.push({ :type => :gold })
        @rows.push({ :type => :action, :act => :heal_party,    :label => "Fully Heal Entire Party (HP / MP)" })
        @rows.push({ :type => :action, :act => :kill_enemies,   :label => "Defeat All Enemies in Battle" })
        @rows.push({ :type => :action, :act => :give_all_1,    :label => "Give +1 of Every Database Item" })
        @rows.push({ :type => :action, :act => :give_all_10,   :label => "Give +10 of Every Database Item" })
        @rows.push({ :type => :toggle, :opt => :god_mode,      :label => "God Mode (Auto Full HP/MP)" })
        @rows.push({ :type => :toggle, :opt => :noclip,        :label => "Walk Through Walls (Noclip)" })
        @rows.push({ :type => :toggle, :opt => :no_encounters, :label => "Disable Random Encounters" })
        @rows.push({ :type => :toggle, :opt => :always_save,   :label => "Always Enable Saving (Save Anywhere)" })
        if Bridge.engine == :vxa
          @rows.push({ :type => :toggle, :opt => :uncap_stats, :label => "Uncap Actor Stats (up to 999,999)" })
          @rows.push({ :type => :toggle, :opt => :uncap_items, :label => "Uncap Item Stack Limit (up to 9,999)" })
        end
      end

      clamp_cursor
      @dirty = true
    end

    def build_db_rows(kind)
      entries = Bridge.db_entries(kind, RPGMCheat.hide_empty)
      i = 0
      while i < entries.size
        @rows.push({
          :type => :item,
          :kind => kind,
          :obj  => entries[i][:obj],
          :tag  => nil
        })
        i += 1
      end
    end

    def clamp_cursor
      if @rows.empty?
        set_cursor(0)
        set_scroll(0)
        return
      end
      c = cursor
      c = @rows.size - 1 if c >= @rows.size
      c = 0 if c < 0
      set_cursor(c)

      s = scroll
      s = c if c < s
      s = c - @vis_rows + 1 if c >= s + @vis_rows
      max_s = [@rows.size - @vis_rows, 0].max
      s = max_s if s > max_s
      s = 0 if s < 0
      set_scroll(s)
    end

    # --- Per-frame update ---

    def update
      if @notice_ttl > 0
        @notice_ttl -= 1
        if @notice_ttl == 0
          @notice_text = ""
          @dirty = true
        end
      end

      if @modal
        update_modal
      else
        update_main
      end

      render if @dirty
    end

    def step_multiplier(is_gold)
      ctrl  = Input.press?(Input::CTRL)
      shift = Input.press?(Input::SHIFT)
      if is_gold
        return 10000 if ctrl
        return 1000  if shift
        100
      else
        return 100 if ctrl
        return 10  if shift
        1
      end
    end

    def update_main
      if Input.trigger?(Input::B) || Input.trigger?(RPGMCheat.hotkey_code)
        RPGMCheat.play_se(:cancel)
        @running = false
        return
      end

      # Switch tabs: Q / W (PageUp / PageDown)
      if Input.trigger?(Input::L)
        @tab_index = (@tab_index - 1) % TABS.size
        RPGMCheat.play_se(:cursor)
        rebuild_rows
        return
      elsif Input.trigger?(Input::R)
        @tab_index = (@tab_index + 1) % TABS.size
        RPGMCheat.play_se(:cursor)
        rebuild_rows
        return
      end

      # Key A (Input::X): switch actor in Stats / refresh Bag
      if Input.trigger?(Input::X)
        if current_tab_id == :stats
          actors = Bridge.party_actors
          if actors.size > 1
            @actor_index = (@actor_index + 1) % actors.size
            RPGMCheat.play_se(:cursor)
            rebuild_rows
          end
          return
        elsif current_tab_id == :bag
          RPGMCheat.play_se(:cursor)
          rebuild_rows
          show_notice("Inventory list refreshed")
          return
        end
      end

      # Key S (Input::Y): toggle empty DB entries / quick-heal actor in Stats
      if Input.trigger?(Input::Y)
        tid = current_tab_id
        if tid == :items || tid == :weapons || tid == :armors
          RPGMCheat.hide_empty = !RPGMCheat.hide_empty
          RPGMCheat.play_se(:ok)
          rebuild_rows
          show_notice(RPGMCheat.hide_empty ? "Hidden unnamed DB slots" : "Showing all DB slots")
          return
        elsif tid == :stats
          actor = current_actor
          if actor
            Bridge.heal_actor(actor)
            RPGMCheat.play_se(:ok)
            show_notice("Restored HP/MP: " + actor.name.to_s)
            @dirty = true
          end
          return
        end
      end

      return if @rows.empty?

      # List navigation (Up / Down)
      jump = Input.press?(Input::CTRL) ? 10 : 1
      if Input.repeat?(Input::DOWN)
        c = cursor
        if jump == 1 && Input.trigger?(Input::DOWN) && c == @rows.size - 1
          set_cursor(0)
        else
          set_cursor([c + jump, @rows.size - 1].min)
        end
        clamp_cursor
        RPGMCheat.play_se(:cursor)
        @dirty = true
        return
      elsif Input.repeat?(Input::UP)
        c = cursor
        if jump == 1 && Input.trigger?(Input::UP) && c == 0
          set_cursor(@rows.size - 1)
        else
          set_cursor([c - jump, 0].max)
        end
        clamp_cursor
        RPGMCheat.play_se(:cursor)
        @dirty = true
        return
      end

      row = @rows[cursor]
      return unless row

      # Adjust values with Left / Right arrows
      if Input.repeat?(Input::LEFT)
        adjust_row(row, -1)
        return
      elsif Input.repeat?(Input::RIGHT)
        adjust_row(row, 1)
        return
      end

      # Enter / Space / Z: exact input modal or trigger action
      if Input.trigger?(Input::C)
        activate_row(row)
      end
    end

    def adjust_row(row, dir)
      case row[:type]
      when :gold
        step = step_multiplier(true) * dir
        Bridge.add_gold(step)
        RPGMCheat.play_se(:cursor)
        @dirty = true
      when :item
        step = step_multiplier(false) * dir
        Bridge.gain_item(row[:kind], row[:obj], step)
        RPGMCheat.play_se(:cursor)
        @dirty = true
      when :stat
        actor = current_actor
        return unless actor
        step = step_multiplier(false) * dir
        Bridge.add_stat(actor, row[:key], step)
        if row[:key] == :level || row[:key] == :p0 || row[:key] == :p1 ||
           row[:key] == :maxhp || row[:key] == :maxmp || row[:key] == :maxsp
          rebuild_rows
        end
        RPGMCheat.play_se(:cursor)
        @dirty = true
      when :toggle
        toggle_option(row[:opt])
      end
    end

    def activate_row(row)
      case row[:type]
      when :gold
        open_number_modal(
          "Party Gold",
          Bridge.gold,
          0,
          Bridge.max_gold,
          :gold,
          row
        )
      when :item
        obj = row[:obj]
        nm  = obj.name.to_s.empty? ? ("Item #" + obj.id.to_s) : obj.name.to_s
        open_number_modal(
          nm,
          Bridge.item_count(row[:kind], obj),
          0,
          Bridge.max_item_for(obj),
          :item,
          row
        )
      when :stat
        actor = current_actor
        return unless actor
        open_number_modal(
          actor.name.to_s + " - " + row[:name],
          Bridge.get_stat(actor, row[:key]),
          row[:min],
          row[:max],
          :stat,
          row
        )
      when :heal_actor
        actor = current_actor
        if actor
          Bridge.heal_actor(actor)
          RPGMCheat.play_se(:ok)
          show_notice("Fully healed: " + actor.name.to_s)
        end
      when :toggle
        toggle_option(row[:opt])
      when :action
        run_action(row[:act])
      end
    end

    def toggle_option(opt)
      case opt
      when :god_mode      then RPGMCheat.god_mode      = !RPGMCheat.god_mode
      when :noclip        then RPGMCheat.noclip        = !RPGMCheat.noclip
      when :no_encounters then RPGMCheat.no_encounters = !RPGMCheat.no_encounters
      when :always_save   then RPGMCheat.always_save   = !RPGMCheat.always_save
      when :uncap_stats   then RPGMCheat.uncap_stats   = !RPGMCheat.uncap_stats
      when :uncap_items   then RPGMCheat.uncap_items   = !RPGMCheat.uncap_items
      end
      RPGMCheat.play_se(:ok)
      @dirty = true
    end

    def option_enabled?(opt)
      case opt
      when :god_mode      then RPGMCheat.god_mode
      when :noclip        then RPGMCheat.noclip
      when :no_encounters then RPGMCheat.no_encounters
      when :always_save   then RPGMCheat.always_save
      when :uncap_stats   then RPGMCheat.uncap_stats
      when :uncap_items   then RPGMCheat.uncap_items
      else false
      end
    end

    def run_action(act)
      case act
      when :heal_party
        Bridge.heal_party
        RPGMCheat.play_se(:ok)
        show_notice("Entire party fully healed!")
      when :kill_enemies
        if defined?($game_troop) && $game_troop && $game_troop.respond_to?(:members)
          killed = 0
          list = $game_troop.members
          i = 0
          while i < list.size
            e = list[i]
            if e && (!e.respond_to?(:exist?) || e.exist?) && (!e.respond_to?(:dead?) || !e.dead?)
              e.hp = 0 if e.respond_to?(:hp=)
              killed += 1
            end
            i += 1
          end
          RPGMCheat.play_se(:ok)
          show_notice(killed > 0 ? "Defeated #{killed} enemies!" : "No active enemies in battle")
        else
          show_notice("Not currently in battle")
        end
      when :give_all_1
        cnt = mass_give_items(1)
        RPGMCheat.play_se(:ok)
        show_notice("Added +1 of " + cnt.to_s + " items")
      when :give_all_10
        cnt = mass_give_items(10)
        RPGMCheat.play_se(:ok)
        show_notice("Added +10 of " + cnt.to_s + " items")
      end
      @dirty = true
    end

    def mass_give_items(amount)
      entries = Bridge.db_entries(:item, true)
      i = 0
      while i < entries.size
        Bridge.gain_item(:item, entries[i][:obj], amount)
        i += 1
      end
      entries.size
    end

    # --- Digit-by-digit Exact Value Editor ---

    def open_number_modal(title, current_val, min_v, max_v, target_kind, row)
      RPGMCheat.play_se(:ok)
      @modal = {
        :title       => title,
        :digits      => int_to_digits(current_val),
        :pos         => DIGITS_COUNT - 1,
        :min         => min_v,
        :max         => max_v,
        :target_kind => target_kind,
        :row         => row
      }
      @dirty = true
    end

    def int_to_digits(val)
      val = 0 if val < 0
      val = 9999999 if val > 9999999
      arr = Array.new(DIGITS_COUNT, 0)
      i = DIGITS_COUNT - 1
      while i >= 0
        arr[i] = val % 10
        val /= 10
        i -= 1
      end
      arr
    end

    def digits_to_int(arr)
      val = 0
      i = 0
      while i < arr.size
        val = val * 10 + arr[i]
        i += 1
      end
      val
    end

    def update_modal
      if Input.trigger?(Input::B) || Input.trigger?(RPGMCheat.hotkey_code)
        RPGMCheat.play_se(:cancel)
        @modal = nil
        @dirty = true
        return
      end

      if Input.repeat?(Input::LEFT)
        @modal[:pos] = (@modal[:pos] - 1) % DIGITS_COUNT
        RPGMCheat.play_se(:cursor)
        @dirty = true
        return
      elsif Input.repeat?(Input::RIGHT)
        @modal[:pos] = (@modal[:pos] + 1) % DIGITS_COUNT
        RPGMCheat.play_se(:cursor)
        @dirty = true
        return
      end

      if Input.repeat?(Input::UP)
        p = @modal[:pos]
        @modal[:digits][p] = (@modal[:digits][p] + 1) % 10
        RPGMCheat.play_se(:cursor)
        @dirty = true
        return
      elsif Input.repeat?(Input::DOWN)
        p = @modal[:pos]
        @modal[:digits][p] = (@modal[:digits][p] - 1) % 10
        RPGMCheat.play_se(:cursor)
        @dirty = true
        return
      end

      # Key A (Input::X) — set minimum
      if Input.trigger?(Input::X)
        @modal[:digits] = int_to_digits(@modal[:min])
        RPGMCheat.play_se(:cursor)
        @dirty = true
        return
      end

      # Key S (Input::Y) — set maximum
      if Input.trigger?(Input::Y)
        @modal[:digits] = int_to_digits(@modal[:max])
        RPGMCheat.play_se(:cursor)
        @dirty = true
        return
      end

      if Input.trigger?(Input::C)
        val = digits_to_int(@modal[:digits])
        val = @modal[:min] if val < @modal[:min]
        val = @modal[:max] if val > @modal[:max]
        apply_modal_value(val)
        RPGMCheat.play_se(:ok)
        @modal = nil
        @dirty = true
      end
    end

    def apply_modal_value(val)
      row = @modal[:row]
      case @modal[:target_kind]
      when :gold
        Bridge.set_gold(val)
      when :item
        Bridge.set_item_count(row[:kind], row[:obj], val)
      when :stat
        actor = current_actor
        if actor
          Bridge.set_stat(actor, row[:key], val)
          rebuild_rows
        end
      end
    end

    # ========================================================================
    # UI Rendering
    # ========================================================================

    def render
      @dirty = false
      b = @bitmap

      c_dim        = Color.new(0, 0, 0, 120)
      c_bg         = Color.new(16, 20, 30, 240)
      c_border     = Color.new(95, 145, 225, 255)
      c_header_bg  = Color.new(26, 34, 52, 255)
      c_tab_act    = Color.new(62, 108, 185, 255)
      c_tab_idle   = Color.new(30, 38, 56, 255)
      c_sub_bg     = Color.new(22, 28, 42, 255)
      c_sel_bg     = Color.new(52, 92, 158, 210)
      c_alt_bg     = Color.new(24, 30, 44, 150)
      c_footer_bg  = Color.new(22, 28, 42, 255)

      c_white      = Color.new(242, 245, 250, 255)
      c_muted      = Color.new(165, 178, 202, 255)
      c_gold       = Color.new(255, 215, 90, 255)
      c_green      = Color.new(110, 235, 145, 255)
      c_cyan       = Color.new(120, 210, 255, 255)
      c_zero       = Color.new(130, 138, 155, 255)

      # Dim screen backdrop
      b.fill_rect(0, 0, @screen_w, @screen_h, c_dim)

      # Main panel box
      draw_box(b, @panel_x, @panel_y, @panel_w, @panel_h, c_bg, c_border)

      # 1. Top title bar
      b.fill_rect(@panel_x + 2, @panel_y + 2, @panel_w - 4, 26, c_header_bg)
      b.font.size  = 16
      b.font.bold  = true
      b.font.color = c_cyan
      b.draw_text(@panel_x + 10, @panel_y + 3, 280, 24, "CHEAT MENU [" + HOTKEY_SYMBOL.to_s + "] | " + Bridge.engine_label, 0)

      b.font.color = c_gold
      b.draw_text(@panel_x + @panel_w - 220, @panel_y + 3, 210, 24, "Gold: " + Bridge.gold.to_s + " G", 2)

      # 2. Tab bar
      tab_y = @panel_y + 30
      tab_w = (@panel_w - 16) / TABS.size
      b.font.size = 14
      ti = 0
      while ti < TABS.size
        tx = @panel_x + 8 + ti * tab_w
        active = (ti == @tab_index)
        b.fill_rect(tx, tab_y, tab_w - 2, 24, active ? c_tab_act : c_tab_idle)
        if active
          b.fill_rect(tx, tab_y + 22, tab_w - 2, 2, c_gold)
        end
        b.font.bold  = active
        b.font.color = active ? c_white : c_muted
        b.draw_text(tx + 2, tab_y + 1, tab_w - 6, 22, TABS[ti][:title], 1)
        ti += 1
      end

      # 3. Context / notice bar
      sub_y = @panel_y + 57
      b.fill_rect(@panel_x + 2, sub_y, @panel_w - 4, 25, c_sub_bg)
      b.font.size = 14
      b.font.bold = false

      if !@notice_text.empty?
        b.font.color = c_green
        b.draw_text(@panel_x + 10, sub_y + 1, @panel_w - 20, 22, ">> " + @notice_text, 0)
      else
        render_subheader(b, sub_y, c_white, c_muted, c_cyan)
      end

      # 4. Scrollable row list
      list_y = @panel_y + @header_h
      if @rows.empty?
        b.font.size  = 16
        b.font.color = c_muted
        empty_msg = (current_tab_id == :bag) ? "Inventory is empty. Switch to tabs 2-4 (Q/W) to add items." : "No entries found."
        b.draw_text(@panel_x + 16, list_y + (@list_h / 2) - 14, @panel_w - 32, 26, empty_msg, 1)
      else
        b.font.size = 15
        vi = 0
        while vi < @vis_rows
          idx = scroll + vi
          break if idx >= @rows.size
          ry  = list_y + vi * @row_h
          sel = (idx == cursor && @modal.nil?)
          if sel
            b.fill_rect(@panel_x + 6, ry, @panel_w - 18, @row_h - 1, c_sel_bg)
          elsif (vi % 2) == 1
            b.fill_rect(@panel_x + 6, ry, @panel_w - 18, @row_h - 1, c_alt_bg)
          end
          render_row(b, @rows[idx], @panel_x + 12, ry, @panel_w - 30, sel, c_white, c_muted, c_gold, c_green, c_cyan, c_zero)
          vi += 1
        end

        # Scrollbar
        if @rows.size > @vis_rows
          sb_x = @panel_x + @panel_w - 9
          sb_h = @vis_rows * @row_h
          b.fill_rect(sb_x, list_y, 4, sb_h, c_tab_idle)
          thumb_h = [[(sb_h * @vis_rows) / @rows.size, 16].max, sb_h].min
          max_s   = @rows.size - @vis_rows
          thumb_y = list_y + ((sb_h - thumb_h) * scroll) / [max_s, 1].max
          b.fill_rect(sb_x, thumb_y, 4, thumb_h, c_border)
        end
      end

      # 5. Bottom controls bar
      foot_y = @panel_y + @panel_h - @footer_h
      b.fill_rect(@panel_x + 2, foot_y, @panel_w - 4, @footer_h - 2, c_footer_bg)
      b.fill_rect(@panel_x + 2, foot_y, @panel_w - 4, 1, c_border)
      b.font.size  = 13
      b.font.bold  = false
      b.font.color = c_muted
      b.draw_text(@panel_x + 8, foot_y + 6, @panel_w - 16, 22, footer_hint_text, 1)

      # 6. Exact number input popup
      render_modal(b) if @modal
    end

    def render_subheader(b, y, c_white, c_muted, c_cyan)
      tid = current_tab_id
      case tid
      when :stats
        actors = Bridge.party_actors
        actor  = current_actor
        if actor
          b.font.color = c_cyan
          hero_txt = sprintf("Actor [%d/%d]: %s (Lv. %d | HP %d/%d)",
                             @actor_index + 1, actors.size, actor.name.to_s,
                             actor.level, actor.hp, Bridge.actor_max_hp(actor))
          b.draw_text(@panel_x + 10, y + 1, @panel_w - 195, 22, hero_txt, 0)
          b.font.color = c_muted
          b.draw_text(@panel_x + @panel_w - 190, y + 1, 180, 22, "[A] Actor  [S] Heal", 2)
        else
          b.font.color = c_muted
          b.draw_text(@panel_x + 10, y + 1, @panel_w - 20, 22, "No actors in party", 0)
        end
      when :bag, :items, :weapons, :armors
        row = @rows[cursor]
        left_txt = ""
        if row && row[:type] == :item
          desc = Bridge.item_description(row[:obj])
          left_txt = desc.empty? ? "No description" : desc
        elsif row && row[:type] == :gold
          left_txt = "Party Gold (Left/Right: +-100, Shift: +-1000, Ctrl: +-10000)"
        end
        b.font.color = c_white
        b.draw_text(@panel_x + 10, y + 1, @panel_w - 185, 22, left_txt, 0)

        b.font.color = c_muted
        pos_str = @rows.empty? ? "0/0" : ((cursor + 1).to_s + "/" + @rows.size.to_s)
        extra   = (tid == :bag) ? ("[A] Refresh  " + pos_str) : ("[S] Empty  " + pos_str)
        b.draw_text(@panel_x + @panel_w - 175, y + 1, 165, 22, extra, 2)
      else
        b.font.color = c_muted
        b.draw_text(@panel_x + 10, y + 1, @panel_w - 20, 22, "Quick actions & runtime cheats (does not pollute save data)", 0)
      end
    end

    def render_row(b, row, x, y, w, sel, c_white, c_muted, c_gold, c_green, c_cyan, c_zero)
      case row[:type]
      when :gold
        b.font.bold  = true
        b.font.color = c_gold
        b.draw_text(x, y, w - 150, @row_h, "* Party Gold", 0)
        val_txt = sel ? ("< " + Bridge.gold.to_s + " G >") : (Bridge.gold.to_s + " G")
        b.draw_text(x + w - 150, y, 150, @row_h, val_txt, 2)
        b.font.bold = false

      when :item
        obj = row[:obj]
        cnt = Bridge.item_count(row[:kind], obj)
        nm  = obj.name.to_s
        nm  = "(unnamed)" if nm.strip.empty?
        prefix = sprintf("[%04d] ", obj.id)
        prefix = prefix + "[" + row[:tag] + "] " if row[:tag]

        b.font.color = (cnt > 0) ? c_white : c_muted
        b.draw_text(x, y, w - 115, @row_h, prefix + nm, 0)

        b.font.bold  = sel
        b.font.color = (cnt > 0) ? c_green : c_zero
        val_txt = sel ? sprintf("< x %d >", cnt) : sprintf("x %d", cnt)
        b.draw_text(x + w - 115, y, 115, @row_h, val_txt, 2)
        b.font.bold = false

      when :heal_actor
        b.font.bold  = sel
        b.font.color = c_green
        b.draw_text(x, y, w, @row_h, "+ Fully Restore Actor HP & MP [Enter]", 0)
        b.font.bold = false

      when :stat
        actor = current_actor
        val   = Bridge.get_stat(actor, row[:key])
        b.font.color = c_white
        b.draw_text(x, y, w - 130, @row_h, row[:name], 0)

        b.font.bold  = sel
        b.font.color = c_cyan
        val_txt = sel ? sprintf("< %d >", val) : val.to_s
        b.draw_text(x + w - 130, y, 130, @row_h, val_txt, 2)
        b.font.bold = false

      when :toggle
        on = option_enabled?(row[:opt])
        b.font.color = c_white
        b.draw_text(x, y, w - 105, @row_h, row[:label], 0)
        b.font.bold  = true
        b.font.color = on ? c_green : c_zero
        st = on ? "[ ON ]" : "[ OFF ]"
        b.draw_text(x + w - 105, y, 105, @row_h, st, 2)
        b.font.bold = false

      when :action
        b.font.bold  = sel
        b.font.color = c_cyan
        b.draw_text(x, y, w, @row_h, "> " + row[:label], 0)
        b.font.bold = false
      end
    end

    def render_modal(b)
      mw = [[@panel_w - 40, 360].max, 460].min
      mh = 152
      mx = (@screen_w - mw) / 2
      my = (@screen_h - mh) / 2

      b.fill_rect(0, 0, @screen_w, @screen_h, Color.new(0, 0, 0, 130))
      draw_box(b, mx, my, mw, mh, Color.new(20, 26, 40, 250), Color.new(255, 215, 90, 255))

      b.font.size  = 15
      b.font.bold  = true
      b.font.color = Color.new(255, 215, 90, 255)
      b.draw_text(mx + 12, my + 8, mw - 24, 22, @modal[:title], 1)

      b.font.size  = 13
      b.font.bold  = false
      b.font.color = Color.new(170, 185, 210, 255)
      range_txt = sprintf("Valid range: %d .. %d", @modal[:min], @modal[:max])
      b.draw_text(mx + 12, my + 30, mw - 24, 20, range_txt, 1)

      cell_w  = 36
      cell_h  = 40
      total_w = DIGITS_COUNT * (cell_w + 6) - 6
      start_x = mx + (mw - total_w) / 2
      cy      = my + 58

      b.font.size = 22
      b.font.bold = true
      i = 0
      while i < DIGITS_COUNT
        cx  = start_x + i * (cell_w + 6)
        sel = (i == @modal[:pos])
        bg  = sel ? Color.new(68, 118, 205, 255) : Color.new(34, 42, 64, 255)
        brd = sel ? Color.new(255, 215, 90, 255) : Color.new(85, 105, 145, 255)
        draw_box(b, cx, cy, cell_w, cell_h, bg, brd)
        b.font.color = Color.new(255, 255, 255, 255)
        b.draw_text(cx, cy + 6, cell_w, cell_h - 12, @modal[:digits][i].to_s, 1)
        i += 1
      end

      b.font.size  = 13
      b.font.bold  = false
      b.font.color = Color.new(175, 190, 215, 255)
      b.draw_text(mx + 8, my + mh - 30, mw - 16, 22, "Left/Right: Digit | Up/Down: +-1 | A: Min | S: Max | Enter: OK", 1)
    end

    def footer_hint_text
      "Q/W: Tab | Left/Right: +-1 (Shift +-10, Ctrl +-100) | Enter: Exact | Esc: Close"
    end

    def draw_box(b, x, y, w, h, bg_color, border_color)
      b.fill_rect(x, y, w, h, border_color)
      b.fill_rect(x + 2, y + 2, w - 4, h - 4, bg_color)
    end
  end
end

# ============================================================================
# RGSS Hooks (Input, Game_Player, Game_System, Game_BattlerBase, Game_Party)
# ============================================================================

module RPGMCheat
  def self.install_hooks
    if defined?(::Game_Player)
      ::Game_Player.class_eval do
        if method_defined?(:debug_through?)
          unless method_defined?(:rpgm_cheat_orig_debug_through?)
            alias_method :rpgm_cheat_orig_debug_through?, :debug_through?
            def debug_through?
              return true if RPGMCheat.noclip
              rpgm_cheat_orig_debug_through?
            end
          end
        elsif method_defined?(:passable?)
          unless method_defined?(:rpgm_cheat_orig_passable?)
            alias_method :rpgm_cheat_orig_passable?, :passable?
            def passable?(x, y, d)
              if RPGMCheat.noclip
                nx = x + (d == 6 ? 1 : d == 4 ? -1 : 0)
                ny = y + (d == 2 ? 1 : d == 8 ? -1 : 0)
                return $game_map ? $game_map.valid?(nx, ny) : true
              end
              rpgm_cheat_orig_passable?(x, y, d)
            end
          end
        end
      end
    end

    if defined?(::Game_System)
      ::Game_System.class_eval do
        if method_defined?(:encounter_disabled)
          unless method_defined?(:rpgm_cheat_orig_encounter_disabled)
            alias_method :rpgm_cheat_orig_encounter_disabled, :encounter_disabled
            def encounter_disabled
              return true if RPGMCheat.no_encounters
              rpgm_cheat_orig_encounter_disabled
            end
          end
        end
        if method_defined?(:save_disabled)
          unless method_defined?(:rpgm_cheat_orig_save_disabled)
            alias_method :rpgm_cheat_orig_save_disabled, :save_disabled
            def save_disabled
              return false if RPGMCheat.always_save
              rpgm_cheat_orig_save_disabled
            end
          end
        end
      end
    end

    if defined?(::Game_BattlerBase)
      ::Game_BattlerBase.class_eval do
        if method_defined?(:param_max)
          unless method_defined?(:rpgm_cheat_orig_param_max)
            alias_method :rpgm_cheat_orig_param_max, :param_max
            def param_max(param_id)
              return 999999 if RPGMCheat.uncap_stats
              rpgm_cheat_orig_param_max(param_id)
            end
          end
        end
      end
    end

    if defined?(::Game_Party)
      ::Game_Party.class_eval do
        if method_defined?(:max_item_number)
          unless method_defined?(:rpgm_cheat_orig_max_item_number)
            alias_method :rpgm_cheat_orig_max_item_number, :max_item_number
            def max_item_number(item)
              return 9999 if RPGMCheat.uncap_items
              rpgm_cheat_orig_max_item_number(item)
            end
          end
        end
      end
    end
  end
end

if defined?(Input)
  class << Input
    unless method_defined?(:rpgm_cheat_orig_update)
      alias_method :rpgm_cheat_orig_update, :update
      def update
        rpgm_cheat_orig_update
        RPGMCheat.on_input_update
      end
    end
  end
end

RPGMCheat.install_hooks
