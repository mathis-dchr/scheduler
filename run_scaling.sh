#!/bin/bash
# =====================================================================
# Montée en charge du scheduler srsRAN 4G avec ZMQ
#   - un test par nombre d'UE de la liste, avec trafic downlink iperf3
#   - s'arrête au premier test qui échoue (limite de la machine)
#   - protection contre le manque de mémoire, avant et pendant chaque test
#   - graphiques créés automatiquement à la fin (dossier graphiques/ des résultats),
#     même si la série s'arrête sur un échec ou un Ctrl+C
#     (prérequis : sudo apt-get install python3-matplotlib)
#   - refaire les graphiques d'une série déjà faite :
#           ./run_scaling.sh --graphiques ~/resultats/scaling_AAAAMMJJ_HHMMSS
#
# usage   : sudo ./run_scaling.sh <duree_en_s> <N1> [N2 ...]
# temps max d'attachement des UE : 60 s + 30 s par UE (modifiable : ATTENTE_MAX=300)
# exemple : sudo ./run_scaling.sh 30 1 2 3 4 5 6 7 8
# choisir le scheduler (sinon celui de config/enb.conf) :
#           sudo POLICY=time_rr ./run_scaling.sh 30 1 2 4
#           sudo POLICY=time_pf ./run_scaling.sh 30 1 2 4
#
# une UE agressive (UDP : les autres UE demandent DEBIT, l'UE n° AGRESSIF demande DEBIT_AGRESSIF) :
#           sudo POLICY=time_rr AGRESSIF=1 ./run_scaling.sh 30 1 2 4
#           (à 1 UE, l'UE agressive est seule : c'est la référence de départ)
#           sudo POLICY=time_rr AGRESSIF=1 DEBIT=5M DEBIT_AGRESSIF=40M ./run_scaling.sh 30 2 4
#
# résultats : ~/scheduler/resultats/<scheduler>_<NPRB>prb_<date>/
#               N1/, N2/...        résultats bruts de chaque test
#               N1/graphiques/     graphiques de ce test (débit de chaque UE, mémoire)
#               graphiques/        graphiques de toute la série (comparaison entre N)
# copie automatique des résultats (clé USB) :
#           sudo COPIE=/media/ubuntu/MA_CLE ./run_scaling.sh 30 1 2 3 4
# bande plus étroite (moins de charge CPU) :
#           sudo NPRB=25 ./run_scaling.sh 30 2 4 6 8 10 12
# =====================================================================
set -u

# ---------------------------------------------------------------------
# Graphiques : lit RES/N*/ (iperf_ue*.json, memoire.csv, ECHEC) et écrit
# RES/graphiques/*.png + RES/graphiques/resume.csv
# ---------------------------------------------------------------------
faire_graphiques() {
  local dossier=$1 legende=${2:-}
  if ! python3 -c "import matplotlib" 2>/dev/null; then
    echo "matplotlib absent : pas de graphiques (sudo apt-get install python3-matplotlib)"
    return
  fi
  echo "Création des graphiques..."
  python3 - "$dossier" "$legende" <<'PY'
import csv, glob, json, os, re, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

RES, LEGENDE = sys.argv[1], sys.argv[2]

# Paramètres écrits par le script de test (UE agressive éventuelle)
PARAMS = {}
try:
    for l in open(os.path.join(RES, "parametres.txt")):
        if "=" in l:
            k, v = l.strip().split("=", 1)
            PARAMS[k] = v
except OSError:
    pass
AGR = int(PARAMS["AGRESSIF"]) if PARAMS.get("AGRESSIF", "").isdigit() else 0   # n° de l'UE agressive, 0 = aucune
OUT = os.path.join(RES, "graphiques")
os.makedirs(OUT, exist_ok=True)

BLEU, ORANGE = "#2a78d6", "#eb6834"
FOND, ENCRE, ENCRE2, GRILLE = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
plt.rcParams.update({
    "figure.facecolor": FOND, "axes.facecolor": FOND, "savefig.facecolor": FOND,
    "axes.edgecolor": GRILLE, "axes.labelcolor": ENCRE2, "xtick.color": ENCRE2,
    "ytick.color": ENCRE2, "text.color": ENCRE, "axes.grid": True, "grid.color": GRILLE,
    "axes.spines.top": False, "axes.spines.right": False, "font.size": 10,
    "legend.frameon": False,
})

def lire_iperf(f):
    """Débit reçu (Mbit/s) et série temporelle, ou (None, [], raison) si la mesure a échoué.
    Une mesure échouée n'est PAS un débit nul : elle ne doit pas entrer dans les statistiques."""
    try:
        texte = open(f, errors="replace").read()
    except FileNotFoundError:
        return None, [], "fichier iperf absent"
    err = ""
    try:
        err = " | ".join(l.strip() for l in open(f[:-5] + ".err") if l.strip())[:200]
    except OSError:
        pass
    # Le JSON peut être entouré de messages d'erreur d'iperf : on l'extrait du texte
    debut = texte.find("{")
    hors_json = texte[:debut].strip() if debut >= 0 else texte.strip()
    try:
        j, fin = json.JSONDecoder().raw_decode(texte[debut:]) if debut >= 0 else (None, 0)
        hors_json = (hors_json + " " + texte[debut + fin:].strip()).strip()
    except json.JSONDecodeError:
        j = None
    if j is None:
        raison = hors_json.splitlines()[-1] if hors_json else ("JSON tronqué (iperf interrompu ?)" if texte.strip() else "fichier vide")
        return None, [], (raison + (" | " + err if err else ""))[:250]
    try:
        if "error" in j:
            return None, [], j["error"] + (" | " + err if err else "")
        sj = j.get("server_output_json")
        if sj and "end" in sj:
            # mesures du récepteur (l'UE) : vrai débit reçu, aussi en UDP
            se = sj["end"]
            s = se.get("sum_received") or se.get("sum")
            serie = [iv["sum"]["bits_per_second"] / 1e6 for iv in sj.get("intervals", [])]
            return s["bits_per_second"] / 1e6, serie, ""
        e = j["end"]
        s = e.get("sum_received") or e.get("sum")
        r = s["bits_per_second"] / 1e6
        if "sum_received" not in e and s.get("lost_percent") is not None:
            r *= 1 - s["lost_percent"] / 100
        serie = [iv["sum"]["bits_per_second"] / 1e6 for iv in j.get("intervals", [])]
        return r, serie, ""
    except Exception as ex:
        return None, [], f"résultat iperf illisible ({type(ex).__name__})"

def lire_octets(d, n):
    """Débit de chaque UE d'après les octets reçus sur tun_srsue (indépendant d'iperf).
    Renvoie (débits, séries) ou None si les relevés manquent."""
    try:
        with open(os.path.join(d, "octets_ue.csv")) as fh:
            rows = [l.strip().split(";") for l in fh][1:]
        rows = [r for r in rows if len(r) == n + 1]
        if len(rows) < 3:
            return None
        # On ne garde que la durée du test : si un iperf bloque à la fin, le relevé
        # continue, et la moyenne serait faussée par les secondes sans trafic
        duree = float(PARAMS.get("DUREE", "0") or 0)
        if duree > 0:
            debut = float(rows[0][0])
            garde = [r for r in rows if float(r[0]) <= debut + duree + 0.5]
            if len(garde) >= 3:
                rows = garde
        t = [float(r[0]) for r in rows]
        debits, series = [], []
        for i in range(1, n + 1):
            v = [int(r[i]) if r[i] else None for r in rows]
            pts = [(tt, vv) for tt, vv in zip(t, v) if vv is not None]
            if len(pts) < 3:
                return None
            # on ignore la 1re seconde (démarrage d'iperf)
            (t0, v0), (t1, v1) = pts[1], pts[-1]
            debits.append((v1 - v0) * 8 / (t1 - t0) / 1e6 if t1 > t0 else 0.0)
            series.append([max(0.0, (pts[k][1] - pts[k - 1][1]) * 8 / (pts[k][0] - pts[k - 1][0]) / 1e6)
                           for k in range(2, len(pts)) if pts[k][0] > pts[k - 1][0]])
        return debits, series
    except (OSError, ValueError):
        return None

tests, echecs, mesures_ko = [], [], []
for d in glob.glob(os.path.join(RES, "N*")):
    m = re.fullmatch(r"N(\d+)", os.path.basename(d))
    if not m or not os.path.isdir(d):
        continue
    n = int(m.group(1))
    if os.path.exists(os.path.join(d, "ECHEC")):
        echecs.append(n)
        continue
    debits, series, ko = [], [], []
    for i in range(1, n + 1):
        r, s, raison = lire_iperf(os.path.join(d, f"iperf_ue{i}.json"))
        if r is None:
            ko.append((i, raison))
        debits.append(r); series.append(s)
    compteurs = lire_octets(d, n)
    if compteurs:
        # Débit mesuré sur l'interface de chaque UE : fiable même si iperf a échoué
        debits, series = compteurs
        for i, raison in ko:
            print(f"  ({n} UE) UE{i} : iperf a échoué ({raison}), débit pris sur l'interface de l'UE")
        ko = []
    if ko:
        # Un test avec une mesure manquante fausserait total, moyenne et équité : on l'écarte
        mesures_ko.append(n)
        print(f"  ATTENTION {n} UE : mesure iperf échouée, test écarté des graphiques :")
        for i, raison in ko:
            print(f"     UE{i} : {raison}")
        continue
    rss_max = None
    try:
        with open(os.path.join(d, "memoire.csv")) as fh:
            vals = [float(r["rss_total_srsue_mo"]) for r in csv.DictReader(fh, delimiter=";")]
        rss_max = max(vals) if vals else None
    except Exception:
        pass
    total = sum(debits)
    carres = sum(x * x for x in debits)
    jain = total * total / (n * carres) if carres else 0.0
    L = max((len(s) for s in series), default=0)
    serie_tot = [sum(s[k] for s in series if k < len(s)) for k in range(L)]
    tests.append(dict(n=n, dossier=d, series=series, debits=debits, total=total, moy=total / n, mini=min(debits),
                      maxi=max(debits), jain=jain, rss=rss_max, serie=serie_tot))

# Graphiques de chaque test, dans N<n>/graphiques/
def graphiques_test(d, n, debits_ue, series_ue):
    g = os.path.join(d, "graphiques")
    os.makedirs(g, exist_ok=True)
    titre = f"{n} UE" + (f" - {LEGENDE}" if LEGENDE else "")
    # débit de chaque UE au cours du test
    if any(series_ue):
        fig, ax = plt.subplots(figsize=(8, 4.5))
        couleurs = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
        if AGR and AGR <= n:
            # UE agressive en orange, les autres en bleu
            for i, s in enumerate(series_ue):
                if not s:
                    continue
                agr = (i + 1 == AGR)
                ax.plot(range(1, len(s) + 1), s, color=ORANGE if agr else BLEU, lw=2.5 if agr else 1.5,
                        alpha=1 if agr else 0.6, zorder=3 if agr else 2)
            ax.plot([], [], color=ORANGE, lw=2.5, label=f"UE{AGR} (agressive)")
            if n > 1:
                ax.plot([], [], color=BLEU, lw=1.5, alpha=0.6, label="autres UE")
            ax.legend(loc="upper right")
        else:
            for i, s in enumerate(series_ue):
                if not s:
                    continue
                c = couleurs[i] if n <= len(couleurs) else BLEU
                ax.plot(range(1, len(s) + 1), s, lw=2 if n <= len(couleurs) else 1, color=c,
                        alpha=1 if n <= len(couleurs) else 0.5, label=f"UE{i + 1}" if n <= len(couleurs) else None)
            if 1 < n <= len(couleurs):
                ax.legend(loc="lower right", ncol=min(n, 4))
        ax.set_ylim(bottom=0)
        ax.set_title("Débit downlink de chaque UE - " + titre, loc="left", fontsize=12, fontweight="bold")
        ax.set_xlabel("Temps (s)"); ax.set_ylabel("Débit (Mbit/s)")
        fig.tight_layout(); fig.savefig(os.path.join(g, "debit_ue_temps.png"), dpi=150); plt.close(fig)
    # débit moyen de chaque UE
    fig, ax = plt.subplots(figsize=(max(8, 0.5 * n + 3), 4.5))
    noms = [f"UE{i + 1}" + (" (agr.)" if i + 1 == AGR else "") for i in range(n)]
    ax.bar(noms, debits_ue, width=0.6, color=[ORANGE if i + 1 == AGR else BLEU for i in range(n)])
    moy = sum(debits_ue) / n
    ax.axhline(moy, color=ENCRE, lw=1.5, label=f"moyenne : {moy:.2f} Mbit/s")
    ax.grid(axis="x", visible=False)
    ax.set_ylim(0, max(debits_ue) * 1.2 if max(debits_ue) > 0 else 1)
    ax.legend(loc="upper right")
    ax.set_title("Débit moyen de chaque UE - " + titre, loc="left", fontsize=12, fontweight="bold")
    ax.set_ylabel("Débit (Mbit/s)")
    if n > 12:
        ax.tick_params(axis="x", labelrotation=90)
    fig.tight_layout(); fig.savefig(os.path.join(g, "debit_par_ue.png"), dpi=150); plt.close(fig)
    # mémoire au cours du test
    try:
        with open(os.path.join(d, "memoire.csv")) as fh:
            rows = list(csv.DictReader(fh, delimiter=";"))
        if rows:
            t = [int(r["seconde"]) for r in rows]
            fig, ax = plt.subplots(figsize=(8, 4.5))
            ax.plot(t, [float(r["rss_total_srsue_mo"]) for r in rows], color=BLEU, lw=2, label="utilisée par les srsue")
            ax.plot(t, [float(r["dispo_mo"]) for r in rows], color=ORANGE, lw=2, label="encore disponible")
            ax.legend(loc="lower right"); ax.set_ylim(bottom=0)
            ax.set_title("Mémoire pendant le test - " + titre, loc="left", fontsize=12, fontweight="bold")
            ax.set_xlabel("Temps (s)"); ax.set_ylabel("Mémoire (Mo)")
            fig.tight_layout(); fig.savefig(os.path.join(g, "memoire_temps.png"), dpi=150); plt.close(fig)
    except Exception:
        pass

tests.sort(key=lambda t: t["n"])
for t in tests:
    graphiques_test(t["dossier"], t["n"], t["debits"], t["series"])
    print(f"  N{t['n']}/graphiques/")

tests.sort(key=lambda t: t["n"])
if not tests:
    print("  Aucun test réussi : pas de graphiques.")
    sys.exit(0)

Ns = [t["n"] for t in tests]
titre_suffixe = f" - {LEGENDE}" if LEGENDE else ""

def finir(fig, ax, nom, titre, ylabel, xlabel="Nombre d'UE"):
    ax.set_title(titre + titre_suffixe, loc="left", fontsize=12, fontweight="bold")
    ax.set_xlabel(xlabel); ax.set_ylabel(ylabel)
    if xlabel == "Nombre d'UE":
        ax.set_xticks(Ns)
    notes = []
    if echecs:
        notes.append("échec du test : " + ", ".join(f"{n} UE" for n in sorted(echecs)))
    if mesures_ko:
        notes.append("mesure iperf échouée : " + ", ".join(f"{n} UE" for n in sorted(mesures_ko)))
    if notes and xlabel == "Nombre d'UE":
        fig.text(0.01, 0.01, "Non tracé - " + " ; ".join(notes), fontsize=8, color=ENCRE2)
    fig.tight_layout(rect=(0, 0.03, 1, 1))
    fig.savefig(os.path.join(OUT, nom), dpi=150)
    plt.close(fig)
    print("  " + nom)

def ligne(ax, xs, ys, couleur, label=None):
    ax.plot(xs, ys, color=couleur, lw=2, marker="o", ms=8,
            markeredgecolor=FOND, markeredgewidth=2, label=label)

# 1. Débit total de la cellule
fig, ax = plt.subplots(figsize=(8, 4.5))
ligne(ax, Ns, [t["total"] for t in tests], BLEU)
ax.set_ylim(bottom=0)
finir(fig, ax, "debit_total.png", "Débit downlink total de la cellule", "Débit (Mbit/s)")

# 2. Débit par UE : chaque UE + moyenne
fig, ax = plt.subplots(figsize=(8, 4.5))
for t in tests:
    k = len(t["debits"])
    dx = [t["n"] + (0.3 * ((i + 0.5) / k - 0.5) if k > 1 else 0) for i in range(k)]
    ax.scatter(dx, t["debits"], s=28, edgecolors=FOND, linewidths=1, zorder=3,
               color=[ORANGE if i + 1 == AGR else BLEU for i in range(k)])
    ax.plot([t["n"] - 0.2, t["n"] + 0.2], [t["moy"]] * 2, color=ENCRE, lw=1.5, zorder=4)
ax.scatter([], [], s=28, color=BLEU, label="une UE" if not AGR else "UE normale")
if AGR:
    ax.scatter([], [], s=28, color=ORANGE, label="UE agressive")
ax.plot([], [], color=ENCRE, lw=1.5, label="moyenne")
ax.legend(loc="upper right")
ax.set_ylim(bottom=0)
finir(fig, ax, "debit_par_ue.png", "Débit downlink de chaque UE", "Débit par UE (Mbit/s)")

# 2b. UE agressive comparée aux autres (à 1 UE, l'UE agressive est seule : point de départ)
if AGR:
    pts = [t for t in tests if AGR <= t["n"]]
    autres = [t for t in pts if t["n"] > 1]
    if pts:
        fig, ax = plt.subplots(figsize=(8, 4.5))
        xs = [t["n"] for t in pts]
        ligne(ax, xs, [t["debits"][AGR - 1] for t in pts], ORANGE, f"UE{AGR} (agressive)")
        if autres:
            ligne(ax, [t["n"] for t in autres],
                  [(t["total"] - t["debits"][AGR - 1]) / (t["n"] - 1) for t in autres], BLEU,
                  "moyenne des autres UE")
        ax.legend(loc="upper right")
        ax.set_ylim(bottom=0)
        finir(fig, ax, "agressive_vs_autres.png", "UE agressive face aux autres UE", "Débit (Mbit/s)")
        # part de la cellule prise par l'UE agressive
        fig, ax = plt.subplots(figsize=(8, 4.5))
        ligne(ax, xs, [100 * t["debits"][AGR - 1] / t["total"] if t["total"] else 0 for t in pts], ORANGE,
              f"UE{AGR} (agressive)")
        ax.plot(xs, [100 / t["n"] for t in pts], color=ENCRE2, lw=1.5, ls="--", label="part équitable (1/N)")
        ax.legend(loc="upper right")
        ax.set_ylim(0, 105)
        finir(fig, ax, "part_agressive.png", f"Part du débit total prise par l'UE{AGR} agressive", "Part (%)")

# 3. Équité (indice de Jain)
fig, ax = plt.subplots(figsize=(8, 4.5))
ligne(ax, Ns, [t["jain"] for t in tests], BLEU)
ax.set_ylim(0, 1.05)
finir(fig, ax, "equite_jain.png", "Équité entre UE (1 = parfaitement équitable)", "Indice de Jain")

# 4. Débit total au cours du temps, une courbe par nombre d'UE (bleu clair -> foncé)
fig, ax = plt.subplots(figsize=(8, 4.5))
cmap = plt.get_cmap("Blues")
for k, t in enumerate(tests):
    if t["serie"]:
        c = cmap(0.35 + 0.6 * (k / max(len(tests) - 1, 1)))
        ax.plot(range(1, len(t["serie"]) + 1), t["serie"], color=c, lw=2, label=f"{t['n']} UE")
ax.legend(loc="lower right", ncol=min(len(tests), 4))
ax.set_ylim(bottom=0)
finir(fig, ax, "debit_temps.png", "Débit downlink total au cours du test",
      "Débit (Mbit/s)", xlabel="Temps (s)")

# 5. Mémoire
mem = [t for t in tests if t["rss"]]
if mem:
    fig, ax = plt.subplots(figsize=(8, 4.5))
    ligne(ax, [t["n"] for t in mem], [t["rss"] for t in mem], BLEU, "total des srsue")
    ligne(ax, [t["n"] for t in mem], [t["rss"] / t["n"] for t in mem], ORANGE, "par UE")
    ax.legend(loc="upper left")
    ax.set_ylim(bottom=0)
    finir(fig, ax, "memoire.png", "Mémoire utilisée par les UE (maximum pendant le test)", "Mémoire (Mo)")

# Résumé chiffré
with open(os.path.join(OUT, "resume.csv"), "w", newline="") as fh:
    w = csv.writer(fh, delimiter=";")
    w.writerow(["n_ue", "debit_total_mbps", "debit_moyen_mbps", "debit_min_mbps",
                "debit_max_mbps", "jain", "rss_srsue_max_mo", "debit_ue_agressive_mbps"])
    for t in tests:
        w.writerow([t["n"], f"{t['total']:.2f}", f"{t['moy']:.2f}", f"{t['mini']:.2f}",
                    f"{t['maxi']:.2f}", f"{t['jain']:.3f}",
                    f"{t['rss']:.0f}" if t["rss"] else "",
                    f"{t['debits'][AGR - 1]:.2f}" if AGR and AGR <= t["n"] else ""])
print("  resume.csv")
print(f"Graphiques dans {OUT}")
PY
}

# Mode « graphiques seulement » : ./run_scaling.sh --graphiques <dossier_de_resultats>
if [ "${1:-}" = "--graphiques" ]; then
  faire_graphiques "${2:?dossier de résultats manquant}" "${3:-}"
  exit 0
fi

DUR=${1:-30}
shift
LISTE_N=${*:-1 2 3 4}

NPRB=${NPRB:-50}         # largeur de bande de la cellule, en PRB
case "$NPRB" in          # fréquence d'échantillonnage correspondante, identique pour l'eNB et toutes les UE
  6)   SRATE=1.92e6 ;;
  15)  SRATE=3.84e6 ;;
  25)  SRATE=5.76e6 ;;
  50)  SRATE=11.52e6 ;;
  75)  SRATE=15.36e6 ;;
  100) SRATE=23.04e6 ;;
  *)   echo "NPRB doit valoir 6, 15, 25, 50, 75 ou 100"; exit 1 ;;
esac
MO_PAR_UE=830           # mémoire estimée par UE (Mo), recalculée après chaque test réussi
MARGE_MO=1000            # mémoire toujours gardée libre pour le système (Mo), ne pas descendre en dessous
COPIE=${COPIE:-}         # dossier où copier les résultats après chaque test (optionnel)
POLICY=${POLICY:-}       # scheduler : time_rr, time_pf... (vide = celui de enb.conf)
AGRESSIF=${AGRESSIF:-}   # n° de l'UE agressive (vide = toutes les UE pareilles, en TCP)
DEBIT=${DEBIT:-5M}                     # débit UDP demandé par les UE normales (si AGRESSIF)
DEBIT_AGRESSIF=${DEBIT_AGRESSIF:-40M}  # débit UDP demandé par l'UE agressive

U=${SUDO_USER:-$USER}
UHOME=$(getent passwd "$U" | cut -d: -f6)       # le ~ de l'utilisateur, même sous sudo
REPO=$UHOME/scheduler
CFG=$REPO/config
# Scheduler utilisé : celui demandé, sinon celui écrit dans enb.conf (time_pf par défaut dans srsRAN)
if [ -n "$POLICY" ]; then
  SCHED=$POLICY
  OPT_SCHED=(--scheduler.policy="$POLICY")
else
  SCHED=$(awk '/^\[scheduler\]/ {s = 1; next} /^\[/ {s = 0}
               s && /^[[:space:]]*policy[[:space:]]*=/ {sub(/.*=[[:space:]]*/, ""); sub(/[[:space:]#].*/, ""); print; exit}' \
          "$CFG/enb.conf")
  SCHED=${SCHED:-time_pf}
  OPT_SCHED=()
fi
SUFFIXE=""
[ -n "$AGRESSIF" ] && SUFFIXE="_agressif_ue$AGRESSIF"
RES=$REPO/resultats/${SCHED}_${NPRB}prb${SUFFIXE}_$(date +%Y%m%d_%H%M%S)

imsi_of()  { printf "%015d" $((1010123456780 + $1 - 1)); }   # UE1 -> 001010123456780, UE2 -> ...781
dispo_mo() { awk '/MemAvailable/ {print int($2 / 1024)}' /proc/meminfo; }

stop_all() {
  for prog in srsue srsenb srsepc; do
    pkill -INT -x "$prog"
    for t in $(seq 1 15); do
      pgrep -x "$prog" > /dev/null || break
      sleep 1
    done
    pkill -9 -x "$prog" 2>/dev/null
  done
  pkill -f multi_ue_zmq.py; pkill -x iperf3
  sleep 1
}

sauver() {
  chown -R "$U" "$RES"
  if [ -n "$COPIE" ]; then
    mkdir -p "$COPIE/$(basename "$RES")" && cp -r "$1" "$COPIE/$(basename "$RES")/"
  fi
}

terminer() {
  [ -n "$COPIE" ] && [ -d "$RES/graphiques" ] && \
    mkdir -p "$COPIE/$(basename "$RES")" && cp -r "$RES/graphiques" "$COPIE/$(basename "$RES")/"
  chown -R "$U" "$RES"
}

interrompu() {
  echo; echo "Interrompu : arrêt de srsRAN, puis graphiques des tests terminés."
  exec 3>&- 2>/dev/null
  stop_all
  [ "$EN_COURS" = 1 ] && rm -rf "$OUT"   # le test en cours n'est pas complet
  faire_graphiques "$RES" "$LEGENDE"
  terminer
  exit 130
}
OUT=""; EN_COURS=0; LEGENDE=""
trap interrompu INT TERM

mkdir -p "$RES"
{
  echo "SCHEDULER=$SCHED"; echo "NPRB=$NPRB"; echo "DUREE=$DUR"
  echo "AGRESSIF=$AGRESSIF"
  [ -n "$AGRESSIF" ] && { echo "DEBIT=$DEBIT"; echo "DEBIT_AGRESSIF=$DEBIT_AGRESSIF"; }
} > "$RES/parametres.txt"
LEGENDE="$SCHED, $NPRB PRB, ${DUR} s"
[ -n "$AGRESSIF" ] && LEGENDE="$LEGENDE, UE$AGRESSIF agressive"
[ -n "$AGRESSIF" ] && echo "UE agressive : UE$AGRESSIF à $DEBIT_AGRESSIF, les autres à $DEBIT (UDP)"
echo "Scheduler : $SCHED | cellule de $NPRB PRB (échantillonnage $SRATE)"
echo "Résultats : $RES"
echo "Mémoire disponible au départ : $(dispo_mo) Mo"

for N in $LISTE_N; do
  OUT=$RES/N$N
  mkdir -p "$OUT"
  EN_COURS=1
  echo "=== Test avec $N UE ==="
  stop_all
  ECHEC=0

  # --- Garde-fou mémoire avant le test ---
  DISPO=$(dispo_mo)
  BESOIN=$((N * MO_PAR_UE + MARGE_MO))
  if [ "$DISPO" -lt "$BESOIN" ]; then
    echo "  Mémoire insuffisante : $DISPO Mo disponibles, environ $BESOIN Mo nécessaires. Arrêt de la série."
    rmdir "$OUT" 2>/dev/null
    EN_COURS=0
    break
  fi

  # --- Base d'abonnés propre à ce test (IP fixes : UE i -> 172.16.0.(i+1)) ---
  : > "$OUT/user_db.csv"
  for i in $(seq 1 "$N"); do
    echo "ue$i,mil,$(imsi_of "$i"),00112233445566778899aabbccddeeff,opc,63bfa50ee6523365ff14c1f45f88737d,9001,000000001234,7,172.16.0.$((i + 1))" >> "$OUT/user_db.csv"
    ip netns add "ue$i" 2>/dev/null
  done

  # --- EPC ---
  srsepc "$CFG/epc.conf" --hss.db_file="$OUT/user_db.csv" --log.filename="$OUT/epc.log" \
    > "$OUT/epc.out" 2>&1 < /dev/null &
  disown                                        # pas de « Processus arrêté » à l'arrêt
  sleep 3

  # --- eNB ---
  srsenb "$CFG/enb.conf" --enb.n_prb="$NPRB" "${OPT_SCHED[@]}" --rf.device_name=zmq \
    --rf.device_args="fail_on_disconnect=true,tx_port=tcp://*:2000,rx_port=tcp://localhost:2001,id=enb,base_srate=$SRATE" \
    --log.all_level=warning --log.mac_level=info --log.filename="$OUT/enb.log" \
    --expert.report_json_enable=true --expert.report_json_filename="$OUT/enb_report.json" \
    --expert.metrics_csv_enable=true --expert.metrics_csv_filename="$OUT/enb_metrics.csv" \
    --expert.metrics_period_secs=1 \
    > "$OUT/enb.out" 2>&1 < /dev/null &
  disown
  sleep 3

  # --- UE ---
  for i in $(seq 1 "$N"); do
    p=$((2000 + 100 * i))                       # UE1 : écoute 2100, émet 2101 ; UE2 : 2200/2201 ...
    srsue "$CFG/ue.conf" --rf.device_name=zmq \
      --rf.device_args="tx_port=tcp://*:$((p + 1)),rx_port=tcp://localhost:$p,id=ue$i,base_srate=$SRATE" \
      --usim.imsi="$(imsi_of "$i")" --gw.netns="ue$i" --log.filename="$OUT/ue$i.log" \
      --phy.nof_phy_threads=1 \
      > "$OUT/ue$i.out" 2>&1 < /dev/null &
    disown                                      # bash n'affiche plus « Processus arrêté » à l'arrêt
    sleep 1
    if [ "$(dispo_mo)" -lt "$MARGE_MO" ]; then
      echo "  Mémoire presque pleine pendant le lancement de l'UE $i. Arrêt du test."
      ECHEC=1
      break
    fi
  done

  # --- Broker, en dernier (entrée = tube gardé ouvert, pour qu'un input() ne l'arrête pas) ---
  rm -f "$OUT/broker_in"; mkfifo "$OUT/broker_in"
  python3 "$REPO/multi_ue_zmq.py" "$N" < "$OUT/broker_in" > "$OUT/broker.out" 2>&1 &
  exec 3> "$OUT/broker_in"

  # --- Attente de l'attachement de toutes les UE ---
  n_ok=0
  if [ "$ECHEC" -eq 0 ]; then
    ATTENTE=${ATTENTE_MAX:-$((60 + 30 * N))}   # les UE s'attachent une par une, lentement en ZMQ
    for t in $(seq 1 "$ATTENTE"); do
      n_ok=0
      for i in $(seq 1 "$N"); do
        ip netns exec "ue$i" ip -4 addr show tun_srsue 2>/dev/null | grep -q inet && n_ok=$((n_ok + 1))
      done
      [ "$n_ok" -eq "$N" ] && break
      sleep 1
    done
    echo "  $n_ok/$N UE attachées"
    [ "$n_ok" -ne "$N" ] && ECHEC=1
  fi

  # --- Trafic downlink vers toutes les UE en même temps ---
  if [ "$ECHEC" -eq 0 ]; then
    for i in $(seq 1 "$N"); do ip netns exec "ue$i" iperf3 -s -D; done
    sleep 1
    pids=()
    for i in $(seq 1 "$N"); do
      # Sans -R : le serveur EPC envoie vers l'UE = downlink
      # --get-server-output : on récupère aussi les mesures de l'UE (débit réellement reçu)
      opts=(-t "$DUR" -J --get-server-output)
      if [ -n "$AGRESSIF" ]; then
        if [ "$i" -eq "$AGRESSIF" ]; then opts+=(-u -b "$DEBIT_AGRESSIF"); else opts+=(-u -b "$DEBIT"); fi
      fi
      iperf3 -c "172.16.0.$((i + 1))" "${opts[@]}" > "$OUT/iperf_ue$i.json" 2> "$OUT/iperf_ue$i.err" &
      pids+=($!)
    done

    # Surveillance pendant le trafic, chaque seconde :
    #  - mémoire (arrêt d'urgence si besoin)
    #  - octets reçus sur l'interface de chaque UE : mesure du débit qui ne dépend pas d'iperf
    #    (iperf peut perdre sa connexion de contrôle quand la file de l'UE est saturée)
    echo "seconde;dispo_mo;rss_total_srsue_mo" > "$OUT/memoire.csv"
    { printf "temps_s"; for i in $(seq 1 "$N"); do printf ";ue%d_rx_octets" "$i"; done; echo; } > "$OUT/octets_ue.csv"
    releve_octets() {
      printf "%s" "$(date +%s.%N)"
      for i in $(seq 1 "$N"); do
        printf ";%s" "$(ip netns exec "ue$i" cat /sys/class/net/tun_srsue/statistics/rx_bytes 2>/dev/null || echo)"
      done
      echo
    }
    un_iperf_actif() { for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && return 0; done; return 1; }
    s=0
    while un_iperf_actif && [ "$s" -lt $((DUR + 30)) ]; do
      releve_octets >> "$OUT/octets_ue.csv"
      DISPO=$(dispo_mo)
      RSS=$(ps -o rss= -C srsue | awk '{t += $1} END {print int(t / 1024)}')
      echo "$s;$DISPO;$RSS" >> "$OUT/memoire.csv"
      if [ "$DISPO" -lt "$MARGE_MO" ]; then
        echo "  Mémoire presque pleine pendant le trafic ($DISPO Mo). Arrêt d'urgence du test."
        kill "${pids[@]}" 2>/dev/null
        ECHEC=1
        break
      fi
      sleep 1
      s=$((s + 1))
    done
    releve_octets >> "$OUT/octets_ue.csv"
    kill "${pids[@]}" 2>/dev/null          # iperf bloqué au-delà de DUR + 30 s
    wait "${pids[@]}" 2>/dev/null

    # Mémoire réelle par UE, pour mieux estimer le test suivant (+20 % de marge)
    if [ "$ECHEC" -eq 0 ]; then
      MAX_RSS=$(awk -F';' 'NR > 1 && $3 > m {m = $3} END {print m + 0}' "$OUT/memoire.csv")
      PAR_UE=$(( (MAX_RSS * 11 / 10) / N + 1 ))
      [ "$PAR_UE" -gt "$MO_PAR_UE" ] && MO_PAR_UE=$PAR_UE
      echo "  Mémoire mesurée : $((MAX_RSS / N)) Mo par UE (estimation retenue : $MO_PAR_UE Mo)"
    fi
  fi

  exec 3>&-
  stop_all

  if [ "$ECHEC" -eq 1 ]; then
    echo "test échoué avec $N UE ($n_ok/$N attachées)" > "$OUT/ECHEC"
    sauver "$OUT"
    EN_COURS=0
    echo "Limite atteinte avec $N UE. Arrêt de la série."
    break
  fi
  sauver "$OUT"
  EN_COURS=0
done

trap - INT TERM
faire_graphiques "$RES" "$LEGENDE"
terminer
echo "Résultats dans $RES"
[ -n "$COPIE" ] && echo "Copie dans $COPIE/$(basename "$RES")"