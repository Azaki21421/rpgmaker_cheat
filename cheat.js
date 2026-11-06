/*:
 * @target MV MZ
 * @plugindesc Universal In-Game Cheat Menu [F8] — Inventory, Item Spawner, Actor Stats & Cheats
 * @author RPGMCheat
 * @help
 * Press F8 in-game (on map, menu, or in battle) to open/close the Cheat Menu.
 *
 * Controls:
 *   F8                   - Open / close cheat menu
 *   Q / W (PgUp / PgDn)  - Switch tabs (1..6)
 *   Up / Down Arrows     - Navigate list (hold Ctrl to jump 10 rows)
 *   Left / Right Arrows  - Adjust value: +-1 (Shift: +-10, Ctrl: +-100)
 *   Enter / Space / Z    - Open exact number input / trigger action
 *   Key A                - Switch party member (Stats tab) / refresh Bag
 *   Key S                - Toggle empty DB slots / quick-heal actor
 *   Key F or /           - Filter database items by name (tabs 2-4)
 *   Esc / X              - Close popup or exit cheat menu
 *   Mouse                - Full click & scroll wheel support
 */

(function () {
  "use strict";

  if (window.RPGMCheat) return;

  var HOTKEY_CODE = "F8"; // KeyEvent.code or key name ("F8", "F7", "F6", "F9")

  var RPGMCheat = {
    active: false,
    godMode: false,
    noclip: false,
    noEncounters: false,
    alwaysSave: false,
    uncapStats: false,
    uncapItems: false,
    hideEmpty: true,
    _hooked: false
  };
  window.RPGMCheat = RPGMCheat;

  // ==========================================================================
  // Bridge — Compatibility Adapter for RPG Maker MV & RPG Maker MZ
  // ==========================================================================

  var Bridge = {
    isReady: function () {
      return !!(
        window.SceneManager &&
        window.DataManager &&
        window.Game_Party &&
        window.Game_Player &&
        window.Game_BattlerBase
      );
    },

    inGame: function () {
      if (!window.$gameParty || !window.$dataItems || !window.SceneManager) {
        return false;
      }
      var sc = SceneManager._scene;
      if (!sc || !sc.constructor) return false;
      var name = sc.constructor.name || "";
      if (
        name === "Scene_Boot" ||
        name === "Scene_Splash" ||
        name === "Scene_Title" ||
        name === "Scene_Gameover" ||
        name === "Scene_Load"
      ) {
        return false;
      }
      return true;
    },

    engineLabel: function () {
      if (window.Utils && Utils.RPGMAKER_NAME === "MZ") {
        return "RPG Maker MZ";
      }
      return "RPG Maker MV";
    },

    clearGameInput: function () {
      try {
        if (window.Input && Input.clear) Input.clear();
        if (window.TouchInput && TouchInput.clear) TouchInput.clear();
      } catch (e) {}
    },

    playSe: function (kind) {
      try {
        if (!window.SoundManager) return;
        if (kind === "cursor") SoundManager.playCursor();
        else if (kind === "ok") SoundManager.playOk();
        else if (kind === "cancel") SoundManager.playCancel();
        else if (kind === "buzzer") SoundManager.playBuzzer();
      } catch (e) {}
    },

    // --- Gold ---

    gold: function () {
      return window.$gameParty ? $gameParty.gold() : 0;
    },

    maxGold: function () {
      return window.$gameParty && $gameParty.maxGold ? $gameParty.maxGold() : 99999999;
    },

    addGold: function (delta) {
      if (!window.$gameParty || !delta) return;
      $gameParty.gainGold(delta);
    },

    setGold: function (target) {
      if (!window.$gameParty) return;
      var max = this.maxGold();
      target = Math.max(0, Math.min(max, Math.floor(target)));
      this.addGold(target - this.gold());
    },

    // --- Items / Weapons / Armors ---

    dbFor: function (kind) {
      if (kind === "item") return window.$dataItems;
      if (kind === "weapon") return window.$dataWeapons;
      if (kind === "armor") return window.$dataArmors;
      return null;
    },

    isIndependentClone: function (obj) {
      return !!(obj && obj.baseItemId && obj.id !== obj.baseItemId);
    },

    itemCount: function (obj) {
      if (!obj || !window.$gameParty) return 0;
      if (
        window.DataManager &&
        DataManager.isIndependent &&
        DataManager.isIndependent(obj) &&
        !obj.baseItemId &&
        $gameParty.numIndependentItems
      ) {
        return $gameParty.numIndependentItems(obj);
      }
      return $gameParty.numItems(obj);
    },

    maxItemFor: function (obj) {
      if (RPGMCheat.uncapItems) return 9999;
      if (window.$gameParty && $gameParty.maxItems && obj) {
        return $gameParty.maxItems(obj);
      }
      return 99;
    },

    gainItem: function (obj, delta) {
      if (!obj || !delta || !window.$gameParty) return;
      // Handle Yanfly YEP_ItemCore independent base items when removing
      if (
        delta < 0 &&
        window.DataManager &&
        DataManager.isIndependent &&
        DataManager.isIndependent(obj) &&
        !obj.baseItemId
      ) {
        var toRemove = -delta;
        var pool = DataManager.isWeapon(obj)
          ? $gameParty.weapons()
          : DataManager.isArmor(obj)
          ? $gameParty.armors()
          : $gameParty.items();
        for (var i = pool.length - 1; i >= 0 && toRemove > 0; i--) {
          var inst = pool[i];
          if (inst && (inst.baseItemId === obj.id || inst.id === obj.id)) {
            $gameParty.gainItem(inst, -1, false);
            toRemove--;
          }
        }
        return;
      }
      $gameParty.gainItem(obj, delta, false);
    },

    setItemCount: function (obj, target) {
      if (!obj) return;
      var max = this.maxItemFor(obj);
      target = Math.max(0, Math.min(max, Math.floor(target)));
      var cur = this.itemCount(obj);
      if (target !== cur) {
        this.gainItem(obj, target - cur);
      }
    },

    ownedEntries: function () {
      if (!window.$gameParty) return [];
      var result = [];
      var groups = [
        { list: $gameParty.items(), kind: "item", tag: "Item" },
        { list: $gameParty.weapons(), kind: "weapon", tag: "Wpn" },
        { list: $gameParty.armors(), kind: "armor", tag: "Arm" }
      ];
      for (var g = 0; g < groups.length; g++) {
        var grp = groups[g];
        var arr = grp.list || [];
        for (var i = 0; i < arr.length; i++) {
          var obj = arr[i];
          if (obj && $gameParty.numItems(obj) > 0) {
            result.push({ kind: grp.kind, obj: obj, tag: grp.tag });
          }
        }
      }
      return result;
    },

    dbEntries: function (kind, hideEmpty, searchQuery) {
      var arr = this.dbFor(kind);
      if (!arr) return [];
      var q = (searchQuery || "").trim().toLowerCase();
      var res = [];
      for (var id = 1; id < arr.length; id++) {
        var obj = arr[id];
        if (!obj) continue;
        if (this.isIndependentClone(obj)) continue;
        var nm = String(obj.name || "");
        if (hideEmpty && nm.trim() === "") continue;
        if (q && nm.toLowerCase().indexOf(q) === -1 && String(obj.id).indexOf(q) === -1) {
          continue;
        }
        res.push({ kind: kind, obj: obj, tag: null });
      }
      return res;
    },

    itemDescription: function (obj) {
      if (!obj || !obj.description) return "";
      return String(obj.description).replace(/\\[A-Za-z]+\[\d+\]/g, "").replace(/[\r\n]+/g, " ").trim();
    },

    // --- Party Actors & Stats ---

    partyActors: function () {
      if (!window.$gameParty) return [];
      if ($gameParty.allMembers) return $gameParty.allMembers();
      if ($gameParty.members) return $gameParty.members();
      return [];
    },

    healActor: function (actor) {
      if (actor && actor.recoverAll) actor.recoverAll();
    },

    healParty: function () {
      var list = this.partyActors();
      for (var i = 0; i < list.length; i++) {
        this.healActor(list[i]);
      }
    },

    statDefinitions: function (actor) {
      if (!actor) return [];
      var mhpCap = RPGMCheat.uncapStats ? 999999 : 999999;
      var statCap = RPGMCheat.uncapStats ? 999999 : 9999;
      var maxLv = actor.maxLevel ? actor.maxLevel() : 99;
      return [
        { key: "level", name: "Level", min: 1, max: maxLv },
        { key: "hp", name: "Current HP", min: 1, max: Math.max(1, actor.mhp) },
        { key: "mp", name: "Current MP", min: 0, max: Math.max(0, actor.mmp) },
        { key: "p0", name: "Max HP (MHP)", min: 1, max: mhpCap },
        { key: "p1", name: "Max MP (MMP)", min: 0, max: mhpCap },
        { key: "p2", name: "Attack (ATK)", min: 1, max: statCap },
        { key: "p3", name: "Defense (DEF)", min: 1, max: statCap },
        { key: "p4", name: "M.Attack (MAT)", min: 1, max: statCap },
        { key: "p5", name: "M.Defense (MDF)", min: 1, max: statCap },
        { key: "p6", name: "Agility (AGI)", min: 1, max: statCap },
        { key: "p7", name: "Luck (LUK)", min: 1, max: statCap }
      ];
    },

    getStat: function (actor, key) {
      if (!actor) return 0;
      if (key === "level") return actor.level;
      if (key === "hp") return actor.hp;
      if (key === "mp") return actor.mp;
      if (key.charAt(0) === "p") {
        var pid = parseInt(key.slice(1), 10);
        return actor.param(pid);
      }
      return 0;
    },

    setStat: function (actor, key, val) {
      if (!actor) return;
      val = Math.floor(val);
      if (key === "level") {
        var maxLv = actor.maxLevel ? actor.maxLevel() : 99;
        val = Math.max(1, Math.min(maxLv, val));
        if (actor.changeLevel) actor.changeLevel(val, false);
      } else if (key === "hp") {
        val = Math.max(1, Math.min(actor.mhp, val));
        actor.setHp(val);
      } else if (key === "mp") {
        val = Math.max(0, Math.min(actor.mmp, val));
        actor.setMp(val);
      } else if (key.charAt(0) === "p") {
        var pid = parseInt(key.slice(1), 10);
        var minV = pid === 1 ? 0 : 1;
        val = Math.max(minV, val);
        var delta = val - actor.param(pid);
        if (delta !== 0) actor.addParam(pid, delta);
      }
    },

    addStat: function (actor, key, delta) {
      if (!actor) return;
      this.setStat(actor, key, this.getStat(actor, key) + delta);
    }
  };

  // ==========================================================================
  // UI Controller & DOM Overlay
  // ==========================================================================

  var TABS = [
    { id: "bag", title: "1.Bag" },
    { id: "items", title: "2.Items" },
    { id: "weapons", title: "3.Weapons" },
    { id: "armors", title: "4.Armors" },
    { id: "stats", title: "5.Stats" },
    { id: "cheats", title: "6.Cheats" }
  ];

  var DIGITS_COUNT = 7;

  var State = {
    tabIndex: 0,
    cursors: {},
    actorIndex: 0,
    searchQuery: "",
    searchMode: false,
    rows: [],
    modal: null,
    noticeText: "",
    noticeTimer: null,
    rootEl: null
  };

  function currentTabId() {
    return TABS[State.tabIndex].id;
  }

  function getCursor() {
    return State.cursors[currentTabId()] || 0;
  }

  function setCursor(v) {
    State.cursors[currentTabId()] = v;
  }

  function currentActor() {
    var list = Bridge.partyActors();
    if (!list.length) return null;
    if (State.actorIndex < 0 || State.actorIndex >= list.length) {
      State.actorIndex = 0;
    }
    return list[State.actorIndex];
  }

  function showNotice(msg) {
    State.noticeText = String(msg || "");
    if (State.noticeTimer) clearTimeout(State.noticeTimer);
    State.noticeTimer = setTimeout(function () {
      State.noticeText = "";
      if (RPGMCheat.active) renderUI();
    }, 2200);
    renderUI();
  }

  function rebuildRows() {
    var tid = currentTabId();
    var rows = [];

    if (tid === "bag") {
      rows.push({ type: "gold" });
      var owned = Bridge.ownedEntries();
      for (var i = 0; i < owned.length; i++) {
        rows.push({
          type: "item",
          kind: owned[i].kind,
          obj: owned[i].obj,
          tag: owned[i].tag
        });
      }
    } else if (tid === "items" || tid === "weapons" || tid === "armors") {
      var kind = tid === "items" ? "item" : tid === "weapons" ? "weapon" : "armor";
      var entries = Bridge.dbEntries(kind, RPGMCheat.hideEmpty, State.searchQuery);
      for (var j = 0; j < entries.length; j++) {
        rows.push({
          type: "item",
          kind: kind,
          obj: entries[j].obj,
          tag: null
        });
      }
    } else if (tid === "stats") {
      var actor = currentActor();
      if (actor) {
        rows.push({ type: "heal_actor" });
        var defs = Bridge.statDefinitions(actor);
        for (var k = 0; k < defs.length; k++) {
          rows.push({
            type: "stat",
            key: defs[k].key,
            name: defs[k].name,
            min: defs[k].min,
            max: defs[k].max
          });
        }
      }
    } else if (tid === "cheats") {
      rows.push({ type: "gold" });
      rows.push({ type: "action", act: "heal_party", label: "Fully Heal Entire Party (HP / MP)" });
      rows.push({ type: "action", act: "kill_enemies", label: "Defeat All Enemies in Battle" });
      rows.push({ type: "action", act: "give_all_1", label: "Give +1 of Every Database Item" });
      rows.push({ type: "action", act: "give_all_10", label: "Give +10 of Every Database Item" });
      rows.push({ type: "toggle", opt: "godMode", label: "God Mode (Auto Full HP/MP)" });
      rows.push({ type: "toggle", opt: "noclip", label: "Walk Through Walls (Noclip)" });
      rows.push({ type: "toggle", opt: "noEncounters", label: "Disable Random Encounters" });
      rows.push({ type: "toggle", opt: "alwaysSave", label: "Always Enable Saving (Save Anywhere)" });
      rows.push({ type: "toggle", opt: "uncapStats", label: "Uncap Actor Stats (up to 999,999)" });
      rows.push({ type: "toggle", opt: "uncapItems", label: "Uncap Item Stack Limit (up to 9,999)" });
    }

    State.rows = rows;
    clampCursor();
  }

  function clampCursor() {
    if (!State.rows.length) {
      setCursor(0);
      return;
    }
    var c = getCursor();
    if (c >= State.rows.length) c = State.rows.length - 1;
    if (c < 0) c = 0;
    setCursor(c);
  }

  function ensureStyles() {
    if (document.getElementById("rpgm-cheat-style")) return;
    var st = document.createElement("style");
    st.id = "rpgm-cheat-style";
    st.textContent = [
      "#rpgm-cheat-root{position:fixed;inset:0;z-index:2147483647;background:rgba(0,0,0,0.48);display:flex;align-items:center;justify-content:center;font-family:'Segoe UI',Tahoma, Geneva,Verdana,sans-serif;user-select:none;color:#f2f5fa;}",
      "#rpgm-cheat-panel{width:min(720px,94vw);height:min(540px,92vh);background:rgba(16,20,30,0.96);border:2px solid #5f91e1;box-shadow:0 12px 40px rgba(0,0,0,0.75);display:flex;flex-direction:column;border-radius:4px;overflow:hidden;}",
      ".rc-header{background:#1a2234;padding:6px 12px;display:flex;justify-content:space-between;align-items:center;font-size:15px;font-weight:700;}",
      ".rc-title{color:#78d2ff;}",
      ".rc-gold{color:#ffd75a;}",
      ".rc-tabs{display:grid;grid-template-columns:repeat(6,1fr);gap:3px;padding:4px 8px;background:#121826;}",
      ".rc-tab{background:#1e2638;color:#a5b2ca;text-align:center;padding:5px 4px;font-size:13px;cursor:pointer;border-bottom:2px solid transparent;border-radius:2px;}",
      ".rc-tab.active{background:#3e6cb9;color:#fff;font-weight:700;border-bottom-color:#ffd75a;}",
      ".rc-sub{background:#161c2a;padding:5px 12px;display:flex;justify-content:space-between;align-items:center;font-size:13px;min-height:26px;border-top:1px solid #26324b;border-bottom:1px solid #26324b;gap:10px;}",
      ".rc-sub-left{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1;}",
      ".rc-sub-right{color:#a5b2ca;white-space:nowrap;font-size:12px;}",
      ".rc-notice{color:#6eeb91;font-weight:600;}",
      ".rc-search-input{background:#0d121c;color:#fff;border:1px solid #ffd75a;padding:2px 8px;font-size:13px;border-radius:2px;width:240px;outline:none;}",
      ".rc-list{flex:1;overflow-y:auto;padding:4px 8px;}",
      ".rc-list::-webkit-scrollbar{width:6px;}",
      ".rc-list::-webkit-scrollbar-track{background:#182030;}",
      ".rc-list::-webkit-scrollbar-thumb{background:#5f91e1;border-radius:3px;}",
      ".rc-row{display:flex;justify-content:space-between;align-items:center;padding:4px 10px;font-size:14px;border-radius:2px;cursor:pointer;min-height:24px;}",
      ".rc-row:nth-child(even){background:rgba(24,30,44,0.55);}",
      ".rc-row.selected{background:rgba(52,92,158,0.85);outline:1px solid rgba(120,210,255,0.45);}",
      ".rc-row-label{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding-right:12px;}",
      ".rc-row-val{white-space:nowrap;font-family:Consolas,monospace;font-size:14px;}",
      ".rc-c-gold{color:#ffd75a;font-weight:700;}",
      ".rc-c-green{color:#6eeb91;font-weight:600;}",
      ".rc-c-cyan{color:#78d2ff;font-weight:600;}",
      ".rc-c-muted{color:#a5b2ca;}",
      ".rc-c-zero{color:#828a9b;}",
      ".rc-empty{height:100%;display:flex;align-items:center;justify-content:center;color:#a5b2ca;font-size:14px;text-align:center;padding:20px;}",
      ".rc-footer{background:#161c2a;border-top:1px solid #5f91e1;padding:6px 10px;text-align:center;color:#a5b2ca;font-size:12px;}",
      ".rc-modal-backdrop{position:absolute;inset:0;background:rgba(0,0,0,0.58);display:flex;align-items:center;justify-content:center;}",
      ".rc-modal{background:#141a28;border:2px solid #ffd75a;border-radius:4px;padding:14px 18px;min-width:360px;max-width:90vw;text-align:center;box-shadow:0 10px 32px rgba(0,0,0,0.85);}",
      ".rc-modal-title{color:#ffd75a;font-weight:700;font-size:15px;margin-bottom:4px;}",
      ".rc-modal-range{color:#aab9d2;font-size:12px;margin-bottom:12px;}",
      ".rc-digits{display:flex;justify-content:center;gap:6px;margin-bottom:12px;}",
      ".rc-digit{width:36px;height:42px;line-height:42px;font-size:22px;font-weight:700;font-family:Consolas,monospace;background:#222a40;border:2px solid #556991;border-radius:3px;color:#fff;cursor:pointer;}",
      ".rc-digit.sel{background:#4476cd;border-color:#ffd75a;}",
      ".rc-modal-hint{color:#afbed7;font-size:12px;}"
    ].join("\n");
    document.head.appendChild(st);
  }

  function openMenu() {
    if (RPGMCheat.active) return;
    ensureStyles();
    RPGMCheat.active = true;
    State.modal = null;
    State.searchMode = false;
    Bridge.clearGameInput();
    Bridge.playSe("ok");

    if (!State.rootEl) {
      State.rootEl = document.createElement("div");
      State.rootEl.id = "rpgm-cheat-root";
      document.body.appendChild(State.rootEl);
    }
    State.rootEl.style.display = "flex";
    rebuildRows();
    renderUI();
  }

  function closeMenu() {
    if (!RPGMCheat.active) return;
    Bridge.playSe("cancel");
    RPGMCheat.active = false;
    State.modal = null;
    State.searchMode = false;
    if (State.rootEl) {
      State.rootEl.style.display = "none";
    }
    Bridge.clearGameInput();
  }

  function pad4(n) {
    var s = String(n);
    while (s.length < 4) s = "0" + s;
    return s;
  }

  function escapeHtml(str) {
    return String(str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function renderUI() {
    if (!State.rootEl || !RPGMCheat.active) return;

    var tid = currentTabId();
    var cur = getCursor();

    var tabsHtml = "";
    for (var t = 0; t < TABS.length; t++) {
      var cls = t === State.tabIndex ? "rc-tab active" : "rc-tab";
      tabsHtml += '<div class="' + cls + '" data-tab="' + t + '">' + escapeHtml(TABS[t].title) + "</div>";
    }

    var subHtml = "";
    if (State.searchMode) {
      subHtml =
        '<div class="rc-sub-left">Filter: <input id="rc-search-box" class="rc-search-input" type="text" value="' +
        escapeHtml(State.searchQuery) +
        '" placeholder="Type name or ID... (Enter/Esc)" /></div>' +
        '<div class="rc-sub-right">' + State.rows.length + " matches</div>";
    } else if (State.noticeText) {
      subHtml = '<div class="rc-sub-left rc-notice">&raquo; ' + escapeHtml(State.noticeText) + "</div>";
    } else if (tid === "stats") {
      var actors = Bridge.partyActors();
      var actor = currentActor();
      if (actor) {
        var hTxt =
          "Actor [" +
          (State.actorIndex + 1) +
          "/" +
          actors.length +
          "]: " +
          actor.name() +
          " (Lv. " +
          actor.level +
          " | HP " +
          actor.hp +
          "/" +
          actor.mhp +
          ")";
        subHtml =
          '<div class="rc-sub-left rc-c-cyan">' +
          escapeHtml(hTxt) +
          '</div><div class="rc-sub-right">[A] Actor &nbsp; [S] Heal</div>';
      } else {
        subHtml = '<div class="rc-sub-left rc-c-muted">No actors in party</div>';
      }
    } else if (tid === "bag" || tid === "items" || tid === "weapons" || tid === "armors") {
      var selRow = State.rows[cur];
      var leftTxt = "";
      if (selRow && selRow.type === "item") {
        var desc = Bridge.itemDescription(selRow.obj);
        leftTxt = desc || "No description";
      } else if (selRow && selRow.type === "gold") {
        leftTxt = "Party Gold (Left/Right: +-100, Shift: +-1000, Ctrl: +-10000)";
      }
      if (State.searchQuery && tid !== "bag") {
        leftTxt = '[Filter: "' + State.searchQuery + '"] ' + leftTxt;
      }
      var posStr = State.rows.length ? cur + 1 + "/" + State.rows.length : "0/0";
      var rightHint =
        tid === "bag"
          ? "[A] Refresh &nbsp; " + posStr
          : "[F] Search &nbsp; [S] Empty &nbsp; " + posStr;
      subHtml =
        '<div class="rc-sub-left">' +
        escapeHtml(leftTxt) +
        '</div><div class="rc-sub-right">' +
        rightHint +
        "</div>";
    } else {
      subHtml =
        '<div class="rc-sub-left rc-c-muted">Quick actions &amp; runtime cheats (does not pollute save data)</div>';
    }

    var listHtml = "";
    if (!State.rows.length) {
      var emptyMsg =
        tid === "bag"
          ? "Inventory is empty. Switch to tabs 2-4 (Q/W) to obtain items."
          : State.searchQuery
          ? 'No items match "' + escapeHtml(State.searchQuery) + '". Press [F] to clear filter.'
          : "No entries found.";
      listHtml = '<div class="rc-empty">' + emptyMsg + "</div>";
    } else {
      for (var i = 0; i < State.rows.length; i++) {
        var r = State.rows[i];
        var isSel = i === cur && !State.modal;
        var rCls = isSel ? "rc-row selected" : "rc-row";
        listHtml += '<div class="' + rCls + '" data-idx="' + i + '">' + renderRowInner(r, isSel) + "</div>";
      }
    }

    var modalHtml = "";
    if (State.modal) {
      var dHtml = "";
      for (var d = 0; d < DIGITS_COUNT; d++) {
        var dCls = d === State.modal.pos ? "rc-digit sel" : "rc-digit";
        dHtml += '<div class="' + dCls + '" data-digit="' + d + '">' + State.modal.digits[d] + "</div>";
      }
      modalHtml =
        '<div class="rc-modal-backdrop">' +
        '<div class="rc-modal">' +
        '<div class="rc-modal-title">' +
        escapeHtml(State.modal.title) +
        "</div>" +
        '<div class="rc-modal-range">Valid range: ' +
        State.modal.min +
        " .. " +
        State.modal.max +
        " (type 0-9 or use arrows)</div>" +
        '<div class="rc-digits">' +
        dHtml +
        "</div>" +
        '<div class="rc-modal-hint">0-9 / Backspace | Left/Right: Digit | Up/Down: +-1 | A: Min | S: Max | Enter: OK</div>' +
        "</div></div>";
    }

    State.rootEl.innerHTML =
      '<div id="rpgm-cheat-panel">' +
      '<div class="rc-header">' +
      '<span class="rc-title">CHEAT MENU [' +
      HOTKEY_CODE +
      "] | " +
      escapeHtml(Bridge.engineLabel()) +
      "</span>" +
      '<span class="rc-gold">Gold: ' +
      Bridge.gold() +
      " G</span>" +
      "</div>" +
      '<div class="rc-tabs">' +
      tabsHtml +
      "</div>" +
      '<div class="rc-sub">' +
      subHtml +
      "</div>" +
      '<div class="rc-list" id="rc-list-box">' +
      listHtml +
      "</div>" +
      '<div class="rc-footer">Q/W: Tab | Left/Right: +-1 (Shift +-10, Ctrl +-100) | Enter: Exact | Esc: Close</div>' +
      modalHtml +
      "</div>";

    var listBox = document.getElementById("rc-list-box");
    if (listBox) {
      var selEl = listBox.querySelector(".rc-row.selected");
      if (selEl) selEl.scrollIntoView({ block: "nearest" });
    }

    if (State.searchMode) {
      var sb = document.getElementById("rc-search-box");
      if (sb) {
        sb.focus();
        sb.setSelectionRange(sb.value.length, sb.value.length);
        sb.oninput = function () {
          State.searchQuery = sb.value;
          setCursor(0);
          rebuildRows();
          refreshSearchResults();
        };
      }
    }

    bindMouseHandlers();
  }

  function refreshSearchResults() {
    if (!State.rootEl) return;
    var cntEl = State.rootEl.querySelector(".rc-sub-right");
    if (cntEl) cntEl.textContent = State.rows.length + " matches";
    var listBox = document.getElementById("rc-list-box");
    if (!listBox) return;
    if (!State.rows.length) {
      listBox.innerHTML =
        '<div class="rc-empty">No items match "' +
        escapeHtml(State.searchQuery) +
        '". Press [Esc] to clear.</div>';
    } else {
      var cur = getCursor();
      var html = "";
      for (var i = 0; i < State.rows.length; i++) {
        var isSel = i === cur && !State.modal;
        var cls = isSel ? "rc-row selected" : "rc-row";
        html += '<div class="' + cls + '" data-idx="' + i + '">' + renderRowInner(State.rows[i], isSel) + "</div>";
      }
      listBox.innerHTML = html;
    }
    bindMouseHandlers();
  }

  function renderRowInner(row, sel) {
    if (row.type === "gold") {
      var g = Bridge.gold();
      var gTxt = sel ? "&lt; " + g + " G &gt;" : g + " G";
      return (
        '<span class="rc-row-label rc-c-gold">* Party Gold</span>' +
        '<span class="rc-row-val rc-c-gold">' +
        gTxt +
        "</span>"
      );
    }
    if (row.type === "item") {
      var obj = row.obj;
      var cnt = Bridge.itemCount(obj);
      var nm = String(obj.name || "").trim() || "(unnamed)";
      var pref = "[" + pad4(obj.id) + "] " + (row.tag ? "[" + row.tag + "] " : "");
      var lCls = cnt > 0 ? "rc-row-label" : "rc-row-label rc-c-muted";
      var vCls = cnt > 0 ? "rc-row-val rc-c-green" : "rc-row-val rc-c-zero";
      var vTxt = sel ? "&lt; x " + cnt + " &gt;" : "x " + cnt;
      return '<span class="' + lCls + '">' + escapeHtml(pref + nm) + '</span><span class="' + vCls + '">' + vTxt + "</span>";
    }
    if (row.type === "heal_actor") {
      return '<span class="rc-row-label rc-c-green">+ Fully Restore Actor HP &amp; MP [Enter]</span><span></span>';
    }
    if (row.type === "stat") {
      var val = Bridge.getStat(currentActor(), row.key);
      var sTxt = sel ? "&lt; " + val + " &gt;" : String(val);
      return (
        '<span class="rc-row-label">' +
        escapeHtml(row.name) +
        '</span><span class="rc-row-val rc-c-cyan">' +
        sTxt +
        "</span>"
      );
    }
    if (row.type === "toggle") {
      var on = !!RPGMCheat[row.opt];
      var tCls = on ? "rc-row-val rc-c-green" : "rc-row-val rc-c-zero";
      return (
        '<span class="rc-row-label">' +
        escapeHtml(row.label) +
        '</span><span class="' +
        tCls +
        '">' +
        (on ? "[ ON ]" : "[ OFF ]") +
        "</span>"
      );
    }
    if (row.type === "action") {
      return '<span class="rc-row-label rc-c-cyan">&gt; ' + escapeHtml(row.label) + "</span><span></span>";
    }
    return "";
  }

  function bindMouseHandlers() {
    if (!State.rootEl) return;
    var tabEls = State.rootEl.querySelectorAll(".rc-tab");
    for (var i = 0; i < tabEls.length; i++) {
      tabEls[i].onclick = function (ev) {
        var idx = parseInt(ev.currentTarget.getAttribute("data-tab"), 10);
        if (!isNaN(idx) && idx !== State.tabIndex) {
          State.tabIndex = idx;
          State.searchMode = false;
          Bridge.playSe("cursor");
          rebuildRows();
          renderUI();
        }
      };
    }

    var rowEls = State.rootEl.querySelectorAll(".rc-row");
    for (var r = 0; r < rowEls.length; r++) {
      rowEls[r].onclick = function (ev) {
        if (State.modal) return;
        var idx = parseInt(ev.currentTarget.getAttribute("data-idx"), 10);
        if (!isNaN(idx)) {
          if (getCursor() === idx) {
            activateRow(State.rows[idx]);
          } else {
            setCursor(idx);
            Bridge.playSe("cursor");
            renderUI();
          }
        }
      };
    }

    var digEls = State.rootEl.querySelectorAll(".rc-digit");
    for (var d = 0; d < digEls.length; d++) {
      digEls[d].onclick = function (ev) {
        if (!State.modal) return;
        var pos = parseInt(ev.currentTarget.getAttribute("data-digit"), 10);
        if (!isNaN(pos)) {
          State.modal.pos = pos;
          State.modal.typedFresh = false;
          renderUI();
        }
      };
    }
  }

  // --- Value Adjustment & Exact Modal ---

  function stepMultiplier(e, isGold) {
    var ctrl = e.ctrlKey || e.metaKey;
    var shift = e.shiftKey;
    if (isGold) {
      if (ctrl) return 10000;
      if (shift) return 1000;
      return 100;
    }
    if (ctrl) return 100;
    if (shift) return 10;
    return 1;
  }

  function adjustRow(row, dir, e) {
    if (!row) return;
    if (row.type === "gold") {
      Bridge.addGold(stepMultiplier(e, true) * dir);
      Bridge.playSe("cursor");
      renderUI();
    } else if (row.type === "item") {
      Bridge.gainItem(row.obj, stepMultiplier(e, false) * dir);
      Bridge.playSe("cursor");
      renderUI();
    } else if (row.type === "stat") {
      var actor = currentActor();
      if (!actor) return;
      Bridge.addStat(actor, row.key, stepMultiplier(e, false) * dir);
      if (row.key === "level" || row.key === "p0" || row.key === "p1") {
        rebuildRows();
      }
      Bridge.playSe("cursor");
      renderUI();
    } else if (row.type === "toggle") {
      RPGMCheat[row.opt] = !RPGMCheat[row.opt];
      Bridge.playSe("ok");
      renderUI();
    }
  }

  function intToDigits(val) {
    val = Math.max(0, Math.min(9999999, Math.floor(val)));
    var arr = new Array(DIGITS_COUNT);
    for (var i = DIGITS_COUNT - 1; i >= 0; i--) {
      arr[i] = val % 10;
      val = Math.floor(val / 10);
    }
    return arr;
  }

  function digitsToInt(arr) {
    var v = 0;
    for (var i = 0; i < arr.length; i++) v = v * 10 + arr[i];
    return v;
  }

  function openNumberModal(title, currentVal, minV, maxV, targetKind, row) {
    Bridge.playSe("ok");
    State.modal = {
      title: title,
      digits: intToDigits(currentVal),
      pos: DIGITS_COUNT - 1,
      min: minV,
      max: Math.min(maxV, 9999999),
      targetKind: targetKind,
      row: row,
      typedFresh: true
    };
    renderUI();
  }

  function activateRow(row) {
    if (!row) return;
    if (row.type === "gold") {
      openNumberModal("Party Gold", Bridge.gold(), 0, Bridge.maxGold(), "gold", row);
    } else if (row.type === "item") {
      var nm = String(row.obj.name || "").trim() || "Item #" + row.obj.id;
      openNumberModal(nm, Bridge.itemCount(row.obj), 0, Bridge.maxItemFor(row.obj), "item", row);
    } else if (row.type === "stat") {
      var actor = currentActor();
      if (!actor) return;
      openNumberModal(
        actor.name() + " - " + row.name,
        Bridge.getStat(actor, row.key),
        row.min,
        row.max,
        "stat",
        row
      );
    } else if (row.type === "heal_actor") {
      var a = currentActor();
      if (a) {
        Bridge.healActor(a);
        Bridge.playSe("ok");
        showNotice("Fully healed: " + a.name());
      }
    } else if (row.type === "toggle") {
      RPGMCheat[row.opt] = !RPGMCheat[row.opt];
      Bridge.playSe("ok");
      renderUI();
    } else if (row.type === "action") {
      if (row.act === "heal_party") {
        Bridge.healParty();
        Bridge.playSe("ok");
        showNotice("Entire party fully healed!");
      } else if (row.act === "kill_enemies") {
        if (window.$gameTroop && $gameTroop.members) {
          var enemies = $gameTroop.members();
          var killed = 0;
          for (var k = 0; k < enemies.length; k++) {
            var en = enemies[k];
            if (en && (!en.isAlive || en.isAlive())) {
              if (en.die) en.die();
              else if (en.setHp) en.setHp(0);
              if (en.refresh) en.refresh();
              killed++;
            }
          }
          Bridge.playSe("ok");
          showNotice(killed > 0 ? "Defeated " + killed + " enemies!" : "No active enemies in battle");
        } else {
          showNotice("Not currently in battle");
        }
      } else if (row.act === "give_all_1" || row.act === "give_all_10") {
        var amt = row.act === "give_all_10" ? 10 : 1;
        var entries = Bridge.dbEntries("item", true, "");
        for (var i = 0; i < entries.length; i++) {
          Bridge.gainItem(entries[i].obj, amt);
        }
        Bridge.playSe("ok");
        showNotice("Added +" + amt + " of " + entries.length + " items");
      }
    }
  }

  function handleModalKey(e) {
    var key = e.key;
    var code = e.code;

    if (key === "Escape" || code === "KeyX" || code === HOTKEY_CODE) {
      Bridge.playSe("cancel");
      State.modal = null;
      renderUI();
      return;
    }

    if (key >= "0" && key <= "9") {
      var d = key.charCodeAt(0) - 48;
      var curVal = State.modal.typedFresh ? 0 : digitsToInt(State.modal.digits);
      State.modal.typedFresh = false;
      var nextVal = Math.min(9999999, curVal * 10 + d);
      State.modal.digits = intToDigits(nextVal);
      State.modal.pos = DIGITS_COUNT - 1;
      Bridge.playSe("cursor");
      renderUI();
      return;
    }

    if (key === "Backspace" || key === "Delete") {
      State.modal.typedFresh = false;
      var v = Math.floor(digitsToInt(State.modal.digits) / 10);
      State.modal.digits = intToDigits(v);
      Bridge.playSe("cursor");
      renderUI();
      return;
    }

    if (key === "ArrowLeft") {
      State.modal.typedFresh = false;
      State.modal.pos = (State.modal.pos + DIGITS_COUNT - 1) % DIGITS_COUNT;
      Bridge.playSe("cursor");
      renderUI();
    } else if (key === "ArrowRight") {
      State.modal.typedFresh = false;
      State.modal.pos = (State.modal.pos + 1) % DIGITS_COUNT;
      Bridge.playSe("cursor");
      renderUI();
    } else if (key === "ArrowUp") {
      State.modal.typedFresh = false;
      var p1 = State.modal.pos;
      State.modal.digits[p1] = (State.modal.digits[p1] + 1) % 10;
      Bridge.playSe("cursor");
      renderUI();
    } else if (key === "ArrowDown") {
      State.modal.typedFresh = false;
      var p2 = State.modal.pos;
      State.modal.digits[p2] = (State.modal.digits[p2] + 9) % 10;
      Bridge.playSe("cursor");
      renderUI();
    } else if (code === "KeyA") {
      State.modal.typedFresh = false;
      State.modal.digits = intToDigits(State.modal.min);
      Bridge.playSe("cursor");
      renderUI();
    } else if (code === "KeyS") {
      State.modal.typedFresh = false;
      State.modal.digits = intToDigits(State.modal.max);
      Bridge.playSe("cursor");
      renderUI();
    } else if (key === "Enter" || key === " " || code === "KeyZ") {
      var finalVal = digitsToInt(State.modal.digits);
      finalVal = Math.max(State.modal.min, Math.min(State.modal.max, finalVal));
      var r = State.modal.row;
      if (State.modal.targetKind === "gold") {
        Bridge.setGold(finalVal);
      } else if (State.modal.targetKind === "item") {
        Bridge.setItemCount(r.obj, finalVal);
      } else if (State.modal.targetKind === "stat") {
        Bridge.setStat(currentActor(), r.key, finalVal);
        rebuildRows();
      }
      Bridge.playSe("ok");
      State.modal = null;
      renderUI();
    }
  }

  function handleMainKey(e) {
    var key = e.key;
    var code = e.code;
    var tid = currentTabId();

    if (State.searchMode) {
      if (key === "Enter") {
        State.searchMode = false;
        Bridge.playSe("ok");
        rebuildRows();
        renderUI();
      } else if (key === "Escape") {
        State.searchMode = false;
        State.searchQuery = "";
        Bridge.playSe("cancel");
        rebuildRows();
        renderUI();
      }
      return;
    }

    if (key === "Escape" || code === "KeyX" || code === HOTKEY_CODE || key === HOTKEY_CODE) {
      closeMenu();
      return;
    }

    if (code === "KeyQ" || key === "PageUp") {
      State.tabIndex = (State.tabIndex + TABS.length - 1) % TABS.length;
      Bridge.playSe("cursor");
      rebuildRows();
      renderUI();
      return;
    }
    if (code === "KeyW" || key === "PageDown") {
      State.tabIndex = (State.tabIndex + 1) % TABS.length;
      Bridge.playSe("cursor");
      rebuildRows();
      renderUI();
      return;
    }

    if ((code === "KeyF" || key === "/") && (tid === "items" || tid === "weapons" || tid === "armors")) {
      State.searchMode = true;
      Bridge.playSe("cursor");
      renderUI();
      return;
    }

    if (code === "KeyA") {
      if (tid === "stats") {
        var actors = Bridge.partyActors();
        if (actors.length > 1) {
          State.actorIndex = (State.actorIndex + 1) % actors.length;
          Bridge.playSe("cursor");
          rebuildRows();
          renderUI();
        }
      } else if (tid === "bag") {
        Bridge.playSe("cursor");
        rebuildRows();
        showNotice("Inventory list refreshed");
      }
      return;
    }

    if (code === "KeyS") {
      if (tid === "items" || tid === "weapons" || tid === "armors") {
        RPGMCheat.hideEmpty = !RPGMCheat.hideEmpty;
        Bridge.playSe("ok");
        rebuildRows();
        showNotice(RPGMCheat.hideEmpty ? "Hidden unnamed DB slots" : "Showing all DB slots");
      } else if (tid === "stats") {
        var actor = currentActor();
        if (actor) {
          Bridge.healActor(actor);
          Bridge.playSe("ok");
          showNotice("Restored HP/MP: " + actor.name());
        }
      }
      return;
    }

    if (!State.rows.length) return;

    var jump = e.ctrlKey || e.metaKey ? 10 : 1;
    var c = getCursor();

    if (key === "ArrowDown") {
      if (jump === 1 && !e.repeat && c === State.rows.length - 1) {
        setCursor(0);
      } else {
        setCursor(Math.min(c + jump, State.rows.length - 1));
      }
      Bridge.playSe("cursor");
      renderUI();
      return;
    }
    if (key === "ArrowUp") {
      if (jump === 1 && !e.repeat && c === 0) {
        setCursor(State.rows.length - 1);
      } else {
        setCursor(Math.max(c - jump, 0));
      }
      Bridge.playSe("cursor");
      renderUI();
      return;
    }

    var row = State.rows[c];
    if (key === "ArrowLeft") {
      adjustRow(row, -1, e);
    } else if (key === "ArrowRight") {
      adjustRow(row, 1, e);
    } else if (key === "Enter" || key === " " || code === "KeyZ") {
      activateRow(row);
    }
  }

  // ==========================================================================
  // Engine Hooks & Bootstrapper
  // ==========================================================================

  function installHooks() {
    if (RPGMCheat._hooked || !Bridge.isReady()) return false;
    RPGMCheat._hooked = true;

    // Pause active scene updates while Cheat Menu is open & apply God Mode
    var origUpdateScene = SceneManager.updateScene;
    SceneManager.updateScene = function () {
      if (RPGMCheat.active) return;
      if (RPGMCheat.godMode && Bridge.inGame()) {
        var list = Bridge.partyActors();
        for (var i = 0; i < list.length; i++) {
          var a = list[i];
          if (a) {
            if (a.hp < a.mhp) a.setHp(a.mhp);
            if (a.mp < a.mmp) a.setMp(a.mmp);
          }
        }
      }
      origUpdateScene.apply(this, arguments);
    };

    // Walk Through Walls (Noclip)
    var origDebugThrough = Game_Player.prototype.isDebugThrough;
    Game_Player.prototype.isDebugThrough = function () {
      if (RPGMCheat.noclip) return true;
      return origDebugThrough.apply(this, arguments);
    };

    // Disable Random Encounters
    var origCanEncounter = Game_Player.prototype.canEncounter;
    Game_Player.prototype.canEncounter = function () {
      if (RPGMCheat.noEncounters) return false;
      return origCanEncounter.apply(this, arguments);
    };

    // Uncap Actor Stats (999,999)
    var origParamMax = Game_BattlerBase.prototype.paramMax;
    Game_BattlerBase.prototype.paramMax = function (paramId) {
      if (RPGMCheat.uncapStats) return 999999;
      return origParamMax.call(this, paramId);
    };

    // Uncap Item Stack Limit (9,999)
    var origMaxItems = Game_Party.prototype.maxItems;
    Game_Party.prototype.maxItems = function (item) {
      if (RPGMCheat.uncapItems) return 9999;
      return origMaxItems.call(this, item);
    };

    // Always Allow Saving (Save Anywhere)
    if (window.Game_System && Game_System.prototype.isSaveEnabled) {
      var origIsSaveEnabled = Game_System.prototype.isSaveEnabled;
      Game_System.prototype.isSaveEnabled = function () {
        if (RPGMCheat.alwaysSave) return true;
        return origIsSaveEnabled.apply(this, arguments);
      };
    }

    // Public API hooks
    RPGMCheat.open = openMenu;
    RPGMCheat.close = closeMenu;
    RPGMCheat.toggle = function () {
      if (RPGMCheat.active) closeMenu();
      else openMenu();
    };

    // Multi-touch gesture (3 fingers tap) for mobile / touch devices
    window.addEventListener(
      "touchstart",
      function (e) {
        if (e.touches && e.touches.length >= 3 && Bridge.inGame()) {
          e.preventDefault();
          RPGMCheat.toggle();
        }
      },
      { passive: false }
    );

    // Capture-phase keyboard & mouse isolation
    window.addEventListener(
      "keydown",
      function (e) {
        if (!RPGMCheat.active) {
          if ((e.code === HOTKEY_CODE || e.key === HOTKEY_CODE) && !e.repeat && Bridge.inGame()) {
            e.preventDefault();
            e.stopImmediatePropagation();
            openMenu();
          }
          return;
        }
        // Allow F5 (reload) and F12 (DevTools)
        if (e.code === "F5" || e.code === "F12") return;

        if (State.searchMode && e.key !== "Enter" && e.key !== "Escape") {
          e.stopPropagation();
          return;
        }

        e.preventDefault();
        e.stopImmediatePropagation();
        if (State.modal) handleModalKey(e);
        else handleMainKey(e);
      },
      true
    );

    var blockMouse = function (e) {
      if (RPGMCheat.active) {
        e.stopPropagation();
      }
    };
    window.addEventListener("mousedown", blockMouse, true);
    window.addEventListener("mouseup", blockMouse, true);
    window.addEventListener("wheel", blockMouse, true);
    window.addEventListener("contextmenu", function (e) {
      if (RPGMCheat.active) {
        e.preventDefault();
        e.stopPropagation();
        if (State.modal) {
          Bridge.playSe("cancel");
          State.modal = null;
          renderUI();
        } else {
          closeMenu();
        }
      }
    }, true);

    return true;
  }

  if (!installHooks()) {
    var timer = setInterval(function () {
      if (installHooks()) clearInterval(timer);
    }, 50);
  }
})();
