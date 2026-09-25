const std = @import("std");
const routes_mod = @import("../data/routes.zig");

pub const RouteMatrix = struct {
    baseTimes: [12][12]u32,
    boatTimes: [12][12]u32,
};

// ── Index constants ───────────────────────────────────────────────────────────
// Must match OUTPOST_KEYS in src/data/config.zig:
//   0=tirChonaill  1=dunbarton  2=bangor   3=cobh
//   4=tara         5=emainMacha 6=taillteann 7=belvast
//   8=qilla        9=cor        10=filia   11=vales

const TC  = 0; // tirChonaill
const DUN = 1; // dunbarton
const BAN = 2; // bangor
const COB = 3; // cobh
const TAR = 4; // tara
const EMA = 5; // emainMacha
const TAI = 6; // taillteann
const BEL = 7; // belvast
const QIL = 8; // qilla
const COR = 9; // cor
const FIL = 10; // filia
const VAL = 11; // vales

/// Build a RouteMatrix from parsed RouteData.  No allocator required — the
/// result is a plain fixed-size value type.
///
/// Routing rules applied:
///   R1  Uladh↔Uladh direct land routes (diagonal = 0)
///   R2  Uladh↔Belvast via portBelvast (Cobh departure)
///   R3  Uladh↔Qilla via portQilla (Cobh departure)
///   R4  Uladh↔Cor via portQilla (Cobh departure) — except Bangor uses R5
///   R5  Bangor↔Cor via portConnous (Bangor departure)
///   R6  Belvast↔Qilla shortcut via belvastBoatToQillaBoat dock transfer
///   R7  Belvast↔Cor shortcut via belvastBoatToQillaBoat dock transfer
///   R8  Iria↔Iria direct land routes (diagonal = 0)
///   R9  Uladh↔Vales via portSella (Bangor departure)
///   R10 Uladh↔Filia via portConnous (Bangor departure)
///   R11 Belvast↔Vales via portBelvast (reverse to Cobh) + portSella (Bangor)
///   R12 Belvast↔Filia via portBelvast (reverse to Cobh) + portConnous (Bangor)
pub fn build(route_data: routes_mod.RouteData) RouteMatrix {
    var m = RouteMatrix{
        .baseTimes  = [_][12]u32{[_]u32{0} ** 12} ** 12,
        .boatTimes  = [_][12]u32{[_]u32{0} ** 12} ** 12,
    };

    const r = route_data;
    const pb = r.boats.portBelvast;
    const pq = r.boats.portQilla;
    const ps = r.boats.portSella;
    const pc = r.boats.portConnous;

    // ── R1: Uladh↔Uladh direct land routes ───────────────────────────────────
    // tirChonaill (0) with each other Uladh outpost
    set(&m, TC, DUN, r.tirChonaill.dunbarton,  0);
    set(&m, TC, BAN, r.tirChonaill.bangor,      0);
    set(&m, TC, COB, r.tirChonaill.cobh,        0);
    set(&m, TC, TAR, r.tirChonaill.tara,        0);
    set(&m, TC, EMA, r.tirChonaill.emainMacha,  0);
    set(&m, TC, TAI, r.tirChonaill.taillteann,  0);

    // dunbarton (1) with remaining Uladh outposts
    set(&m, DUN, BAN, r.dunbarton.bangor,      0);
    set(&m, DUN, COB, r.dunbarton.cobh,        0);
    set(&m, DUN, TAR, r.dunbarton.tara,        0);
    set(&m, DUN, EMA, r.dunbarton.emainMacha,  0);
    set(&m, DUN, TAI, r.dunbarton.taillteann,  0);

    // bangor (2) with remaining Uladh outposts
    set(&m, BAN, COB, r.bangor.cobh,        0);
    set(&m, BAN, TAR, r.bangor.tara,        0);
    set(&m, BAN, EMA, r.bangor.emainMacha,  0);
    set(&m, BAN, TAI, r.bangor.taillteann,  0);

    // cobh (3) with remaining Uladh outposts
    set(&m, COB, TAR, r.cobh.tara,        0);
    set(&m, COB, EMA, r.cobh.emainMacha,  0);
    set(&m, COB, TAI, r.cobh.taillteann,  0);

    // tara (4) with remaining Uladh outposts
    set(&m, TAR, EMA, r.tara.emainMacha,  0);
    set(&m, TAR, TAI, r.tara.taillteann,  0);

    // emainMacha (5) with remaining
    set(&m, EMA, TAI, r.emainMacha.taillteann, 0);

    // ── R2: Uladh↔Belvast via portBelvast ────────────────────────────────────
    // baseTimes = outpost→cobh + portBelvast.fromCobh + portBelvast.toBelvast
    // boatTimes = portBelvast.wait + portBelvast.travel
    const boat_bel: u32 = pb.wait + pb.travel;
    const bel_base_cobh: u32 = pb.fromCobh + pb.toBelvast; // walk legs: Cobh→dock + dock→Belvast town
    set(&m, TC,  BEL, r.tirChonaill.cobh + bel_base_cobh, boat_bel);
    set(&m, DUN, BEL, r.dunbarton.cobh   + bel_base_cobh, boat_bel);
    set(&m, BAN, BEL, r.bangor.cobh      + bel_base_cobh, boat_bel);
    set(&m, COB, BEL, bel_base_cobh,                      boat_bel);
    set(&m, TAR, BEL, r.cobh.tara        + bel_base_cobh, boat_bel);
    set(&m, EMA, BEL, r.cobh.emainMacha  + bel_base_cobh, boat_bel);
    set(&m, TAI, BEL, r.cobh.taillteann  + bel_base_cobh, boat_bel);

    // ── R3: Uladh↔Qilla via portQilla ────────────────────────────────────────
    // baseTimes = outpost→cobh + portQilla.fromCobh + portQilla.toQilla
    // boatTimes = portQilla.wait + portQilla.travel
    const boat_qil: u32 = pq.wait + pq.travel;
    const qil_base_cobh: u32 = pq.fromCobh + pq.toQilla;
    set(&m, TC,  QIL, r.tirChonaill.cobh + qil_base_cobh, boat_qil);
    set(&m, DUN, QIL, r.dunbarton.cobh   + qil_base_cobh, boat_qil);
    set(&m, BAN, QIL, r.bangor.cobh      + qil_base_cobh, boat_qil);
    set(&m, COB, QIL, qil_base_cobh,                      boat_qil);
    set(&m, TAR, QIL, r.cobh.tara        + qil_base_cobh, boat_qil);
    set(&m, EMA, QIL, r.cobh.emainMacha  + qil_base_cobh, boat_qil);
    set(&m, TAI, QIL, r.cobh.taillteann  + qil_base_cobh, boat_qil);

    // ── R4: Uladh↔Cor via portQilla (all Uladh except Bangor — see R5) ───────
    // baseTimes = outpost→cobh + portQilla.fromCobh + portQilla.toCor
    // boatTimes = portQilla.wait + portQilla.travel
    const cor_qil_base_cobh: u32 = pq.fromCobh + pq.toCor;
    set(&m, TC,  COR, r.tirChonaill.cobh + cor_qil_base_cobh, boat_qil);
    set(&m, DUN, COR, r.dunbarton.cobh   + cor_qil_base_cobh, boat_qil);
    set(&m, COB, COR, cor_qil_base_cobh,                      boat_qil);
    set(&m, TAR, COR, r.cobh.tara        + cor_qil_base_cobh, boat_qil);
    set(&m, EMA, COR, r.cobh.emainMacha  + cor_qil_base_cobh, boat_qil);
    set(&m, TAI, COR, r.cobh.taillteann  + cor_qil_base_cobh, boat_qil);

    // ── R5: Bangor↔Cor via portConnous ───────────────────────────────────────
    // baseTimes = portConnous.fromBangor + portConnous.toCor
    // boatTimes = portConnous.wait + portConnous.travel
    set(&m, BAN, COR, pc.fromBangor + pc.toCor, pc.wait + pc.travel);

    // ── R6: Belvast↔Qilla shortcut ───────────────────────────────────────────
    // baseTimes = portBelvast.toBelvast + portBelvast.belvastBoatToQillaBoat + portQilla.toQilla
    // boatTimes = portQilla.wait + portQilla.travel
    set(&m, BEL, QIL, pb.toBelvast + pb.belvastBoatToQillaBoat + pq.toQilla, boat_qil);

    // ── R7: Belvast↔Cor shortcut ─────────────────────────────────────────────
    // baseTimes = portBelvast.toBelvast + portBelvast.belvastBoatToQillaBoat + portQilla.toCor
    // boatTimes = portQilla.wait + portQilla.travel
    set(&m, BEL, COR, pb.toBelvast + pb.belvastBoatToQillaBoat + pq.toCor, boat_qil);

    // ── R8: Iria↔Iria direct land routes ─────────────────────────────────────
    set(&m, QIL, VAL, r.qilla.vales, 0);
    set(&m, QIL, FIL, r.qilla.filia, 0);
    set(&m, QIL, COR, r.qilla.cor,   0);
    set(&m, VAL, FIL, r.vales.filia, 0);
    set(&m, VAL, COR, r.vales.cor,   0);
    set(&m, FIL, COR, r.filia.cor,   0);

    // ── R9: Uladh↔Vales via portSella (Bangor departure) ────────────────────
    // baseTimes = outpost→bangor + portSella.fromBangor + portSella.toVales
    // boatTimes = portSella.wait + portSella.travel
    const boat_sel: u32 = ps.wait + ps.travel;
    const val_sel_base_ban: u32 = ps.fromBangor + ps.toVales;
    set(&m, TC,  VAL, r.tirChonaill.bangor  + val_sel_base_ban, boat_sel);
    set(&m, DUN, VAL, r.dunbarton.bangor    + val_sel_base_ban, boat_sel);
    set(&m, BAN, VAL, val_sel_base_ban,                         boat_sel);
    set(&m, COB, VAL, r.cobh.bangor         + val_sel_base_ban, boat_sel);
    set(&m, TAR, VAL, r.tara.bangor         + val_sel_base_ban, boat_sel);
    set(&m, EMA, VAL, r.emainMacha.bangor   + val_sel_base_ban, boat_sel);
    set(&m, TAI, VAL, r.taillteann.bangor   + val_sel_base_ban, boat_sel);

    // ── R10: Uladh↔Filia via portConnous (Bangor departure) ──────────────────
    // baseTimes = outpost→bangor + portConnous.fromBangor + portConnous.toFilia
    // boatTimes = portConnous.wait + portConnous.travel
    const boat_con: u32 = pc.wait + pc.travel;
    const fil_con_base_ban: u32 = pc.fromBangor + pc.toFilia;
    set(&m, TC,  FIL, r.tirChonaill.bangor  + fil_con_base_ban, boat_con);
    set(&m, DUN, FIL, r.dunbarton.bangor    + fil_con_base_ban, boat_con);
    set(&m, BAN, FIL, fil_con_base_ban,                         boat_con);
    set(&m, COB, FIL, r.cobh.bangor         + fil_con_base_ban, boat_con);
    set(&m, TAR, FIL, r.tara.bangor         + fil_con_base_ban, boat_con);
    set(&m, EMA, FIL, r.emainMacha.bangor   + fil_con_base_ban, boat_con);
    set(&m, TAI, FIL, r.taillteann.bangor   + fil_con_base_ban, boat_con);

    // ── R11: Belvast↔Vales via portBelvast reverse + portSella ───────────────
    // Belvast→Cobh: portBelvast.toBelvast + portBelvast.fromCobh (both walk legs)
    // Cobh→Bangor: r.cobh.bangor (= r.bangor.cobh, symmetric)
    // Bangor→Sella→Vales: portSella.fromBangor + portSella.toVales
    // baseTimes = pb.toBelvast + pb.fromCobh + r.bangor.cobh + ps.fromBangor + ps.toVales
    // boatTimes = pb.wait + pb.travel + ps.wait + ps.travel
    const bel_val_base: u32 = pb.toBelvast + pb.fromCobh + r.bangor.cobh + ps.fromBangor + ps.toVales;
    const bel_val_boat: u32 = pb.wait + pb.travel + ps.wait + ps.travel;
    set(&m, BEL, VAL, bel_val_base, bel_val_boat);

    // ── R12: Belvast↔Filia via portBelvast reverse + portConnous ─────────────
    // Same Belvast→Cobh→Bangor walk, then portConnous→Filia
    // baseTimes = pb.toBelvast + pb.fromCobh + r.bangor.cobh + pc.fromBangor + pc.toFilia
    // boatTimes = pb.wait + pb.travel + pc.wait + pc.travel
    const bel_fil_base: u32 = pb.toBelvast + pb.fromCobh + r.bangor.cobh + pc.fromBangor + pc.toFilia;
    const bel_fil_boat: u32 = pb.wait + pb.travel + pc.wait + pc.travel;
    set(&m, BEL, FIL, bel_fil_base, bel_fil_boat);

    return m;
}

/// Write baseTimes and boatTimes symmetrically for pair (i, j).
fn set(m: *RouteMatrix, i: usize, j: usize, base: u32, boat: u32) void {
    std.debug.assert(i < 12 and j < 12);
    std.debug.assert(i != j);
    m.baseTimes[i][j] = base;
    m.baseTimes[j][i] = base;
    m.boatTimes[i][j] = boat;
    m.boatTimes[j][i] = boat;
}
