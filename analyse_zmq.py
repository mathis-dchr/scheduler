#!/usr/bin/env python3
# usage : python3 analyse_zmq.py ~/resultats/scaling_XXXX
import glob, json, os, sys
import pandas as pd
import matplotlib.pyplot as plt

res = sys.argv[1]
lignes = []
for d in sorted(glob.glob(os.path.join(res, "N*")), key=lambda p: int(os.path.basename(p)[1:])):
    n = int(os.path.basename(d)[1:])
    if os.path.exists(os.path.join(d, "ECHEC")):
        print(f"N={n} : test ignoré (attachement incomplet)")
        continue
    for i in range(1, n + 1):
        try:
            j = json.load(open(os.path.join(d, f"iperf_ue{i}.json")))
            mbps = j["end"]["sum_received"]["bits_per_second"] / 1e6
        except Exception:
            mbps = 0.0                         # iperf en erreur : on compte 0
        lignes.append(dict(nof_ues=n, ue=i, dl_mbps=mbps))

df = pd.DataFrame(lignes)
df.to_csv(os.path.join(res, "debits_par_ue.csv"), index=False)

def jain(x):
    s2 = (x ** 2).sum()
    return x.sum() ** 2 / (len(x) * s2) if s2 > 0 else 0

r = df.groupby("nof_ues").dl_mbps.agg(total="sum", moyen="mean", minimum="min", jain=jain)
print(r.round(3))
r.to_csv(os.path.join(res, "resume.csv"))

fig, ax = plt.subplots(1, 3, figsize=(14, 4))
r.total.plot(ax=ax[0], marker="o", title="Débit total de la cellule")
r.moyen.plot(ax=ax[1], marker="o", title="Débit moyen par UE")
r.jain.plot(ax=ax[2], marker="o", title="Indice de Jain", ylim=(0, 1.05))
for a, y in zip(ax, ["Mbit/s", "Mbit/s", ""]):
    a.set_xlabel("Nombre d'UE"); a.set_ylabel(y); a.grid(alpha=.3)
plt.tight_layout(); plt.savefig(os.path.join(res, "scaling_zmq.png"), dpi=150)