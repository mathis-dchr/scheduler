#!/usr/bin/env python3
# Analyse des tests de montée en charge ZMQ.
# usage : python3 analyse_zmq.py <dossier_resultats> [autre_dossier ...]
# Les graphiques sont enregistrés dans le premier dossier.
import glob, json, os, re, sys
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

dossiers = sys.argv[1:]
if not dossiers:
    sys.exit("usage : python3 analyse_zmq.py <dossier_resultats> [autre_dossier ...]")
sortie_dir = dossiers[0]

lignes, series = [], []
for res in dossiers:
    for d in glob.glob(os.path.join(res, "N*")):
        m = re.fullmatch(r"N(\d+)", os.path.basename(d))
        if m is None:
            continue                     # dossiers d'essais ratés (N2_echec1...) : ignorés
        n = int(m.group(1))
        if os.path.exists(os.path.join(d, "ECHEC")):
            print(f"N={n} : test ignoré (marqué ECHEC)")
            continue
        injoignables = set()
        f_inj = os.path.join(d, "injoignables.txt")
        if os.path.exists(f_inj):
            injoignables = {l.strip() for l in open(f_inj) if l.strip()}
        for i in range(1, n + 1):
            f = os.path.join(d, f"iperf_ue{i}.json")
            mbps, erreur = None, ""
            if f"UE{i}" in injoignables:
                erreur = "UE injoignable (banc ZMQ), pas de trafic"
            else:
                try:
                    j = json.load(open(f))
                    if "error" in j:
                        erreur = j["error"]
                    else:
                        mbps = j["end"]["sum_received"]["bits_per_second"] / 1e6
                        for iv in j.get("intervals", []):
                            series.append(dict(nof_ues=n, ue=i, t=iv["sum"]["end"],
                                               mbps=iv["sum"]["bits_per_second"] / 1e6))
                except FileNotFoundError:
                    erreur = "fichier iperf absent"
                except Exception as e:
                    erreur = f"fichier illisible ({e.__class__.__name__})"
            lignes.append(dict(nof_ues=n, ue=i, dl_mbps=mbps, erreur=erreur))

if not lignes:
    sys.exit("\nAucun test exploitable dans ce dossier : rien à analyser.")

df = pd.DataFrame(lignes).sort_values(["nof_ues", "ue"])
df.to_csv(os.path.join(sortie_dir, "debits_par_ue.csv"), index=False)

# --- UE sans mesure : à regarder avant d'interpréter les débits ---
err = df[df.erreur != ""]
if not err.empty:
    print("\nATTENTION : UE sans mesure (exclues des calculs) :")
    print(err[["nof_ues", "ue", "erreur"]].to_string(index=False))

# --- Débit de chaque UE ---
print("\nDébit moyen par UE sur le test (Mbit/s) :")
print(df.pivot(index="nof_ues", columns="ue", values="dl_mbps").round(2).to_string())

# --- Résumé par nombre d'UE, sur les flux valides ---
def jain(x):
    x = x.dropna()
    s2 = (x ** 2).sum()
    return x.sum() ** 2 / (len(x) * s2) if s2 > 0 else float("nan")

ok = df.dropna(subset=["dl_mbps"])
r = ok.groupby("nof_ues").dl_mbps.agg(total="sum", moyen="mean", minimum="min", maximum="max", jain=jain)
r["part_ue_max_%"] = 100 * r["maximum"] / r["total"]      # part de l'UE la mieux servie
r["ue_mesurees"] = ok.groupby("nof_ues").size()
r["ue_lancees"] = df.groupby("nof_ues").size()
print("\nRésumé :")
print(r.round(2).to_string())
r.to_csv(os.path.join(sortie_dir, "resume.csv"))

# --- Graphique 1 : vue d'ensemble selon le nombre d'UE ---
fig, ax = plt.subplots(1, 3, figsize=(16, 4.5))
ax[0].plot(r.index, r.total, marker="o")
ax[0].set_title("Débit total de la cellule")
ax[0].set_ylabel("Mbit/s")

ax[1].scatter(ok.nof_ues, ok.dl_mbps, alpha=0.6, label="une UE")
ax[1].plot(r.index, r.moyen, marker="o", color="black", label="moyenne")
ax[1].plot(r.index, r.total.max() / r.index, linestyle="--", color="gray", label="partage égal (débit total max ÷ N)")
ax[1].set_title("Débit de chaque UE")
ax[1].set_ylabel("Mbit/s")
ax[1].legend()

ax[2].plot(r.index, r["part_ue_max_%"], marker="o", label="part de l'UE la mieux servie")
ax[2].axhline(90, linestyle="--", color="gray", label="90 %")
ax[2].set_title("Part du débit de l'UE la mieux servie")
ax[2].set_ylabel("%")
ax[2].set_ylim(0, 105)
ax[2].legend()

for a in ax:
    a.set_xlabel("Nombre d'UE")
    a.grid(alpha=0.3)
    a.set_xticks(r.index)
plt.tight_layout()
sortie = os.path.join(sortie_dir, "scaling_zmq.png")
plt.savefig(sortie, dpi=150)
plt.close()
print(f"\nGraphique d'ensemble : {sortie}")

# --- Graphique 2 : débit de chaque UE seconde par seconde, un graphique par test ---
if series:
    s = pd.DataFrame(series)
    for n, g in s.groupby("nof_ues"):
        plt.figure(figsize=(9, 4))
        for ue, gu in g.groupby("ue"):
            plt.plot(gu.t, gu.mbps, marker=".", label=f"UE{ue}")
        plt.title(f"Débit de chaque UE au cours du temps ({n} UE lancées)")
        plt.xlabel("Temps (s)")
        plt.ylabel("Mbit/s")
        plt.grid(alpha=0.3)
        plt.legend()
        plt.tight_layout()
        f = os.path.join(sortie_dir, f"debit_temps_N{n}.png")
        plt.savefig(f, dpi=150)
        plt.close()
        print(f"Graphique dans le temps ({n} UE) : {f}")